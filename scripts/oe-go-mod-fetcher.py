#!/usr/bin/env python3

"""
Go Module Git Fetcher - Hybrid Architecture
Version 3.0.0 - Complete rewrite using Go download for discovery + git builds
Author: AI Assistant
Description: Use Go's download for discovery, build from git sources

ARCHITECTURE:
Phase 1: Discovery - Use 'go mod download' + filesystem walk to get correct module paths
Phase 2: Recipe Generation - Generate BitBake recipe with git:// SRC_URI entries
Phase 3: Cache Building - Build module cache from git sources during do_create_module_cache

This approach eliminates:
- Complex go list -m -json parsing
- Manual go.sum parsing and augmentation
- Parent module detection heuristics
- Version path manipulation (/v2+/v3+ workarounds)
- Module path normalization bugs

Instead we:
- Let Go download modules to temporary cache (discovery only)
- Walk filesystem to get CORRECT module paths (no parsing!)
- Extract VCS info from .info files
- Fetch git repositories for each module
- Build module cache from git during BitBake build

CHANGELOG v3.0.0:
- Complete architectural rewrite following CLAUDE.md design
- Removed all go list and go.sum parsing logic (4000+ lines)
- Implemented 3-phase hybrid approach
- Discovery uses go mod download + filesystem walk
- Module paths from filesystem, not from go list (no more /v3 stripping bugs!)
- Builds entirely from git sources
- Compatible with oe-core's gomod:// fetcher (same cache structure)
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple
from datetime import datetime, timedelta

VERSION = "3.0.0"

# =============================================================================
# BitBake Task Templates
# =============================================================================

def parse_go_sum(go_sum_path: Path) -> Set[Tuple[str, str]]:
    modules: Set[Tuple[str, str]] = set()
    if not go_sum_path.exists():
        return modules

    with go_sum_path.open() as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('//'):
                continue
            parts = line.split()
            if len(parts) != 3:
                continue

            module_path, version, _ = parts
            # Strip /go.mod suffix if present (we want the base version)
            if version.endswith('/go.mod'):
                version = version[:-7]  # Remove '/go.mod'
            modules.add((module_path, version))
    return modules


SCRIPT_DIR = Path(__file__).resolve().parent
LS_REMOTE_CACHE_PATH = SCRIPT_DIR / ".oe-go-mod-fetcher.ls-remote-cache.json"

LS_REMOTE_CACHE: Dict[Tuple[str, str], Optional[str]] = {}
LS_REMOTE_CACHE_DIRTY = False

MODULE_METADATA_CACHE_PATH = SCRIPT_DIR / ".oe-go-mod-fetcher.module-cache.json"
MODULE_METADATA_CACHE: Dict[Tuple[str, str], Dict[str, str]] = {}
MODULE_METADATA_CACHE_DIRTY = False


def _cache_key(url: str, ref: str) -> str:
    return f"{url}|||{ref}"


def load_ls_remote_cache() -> None:
    if not LS_REMOTE_CACHE_PATH.exists():
        return
    try:
        data = json.loads(LS_REMOTE_CACHE_PATH.read_text())
    except Exception:
        return
    for key, value in data.items():
        try:
            url, ref = key.split("|||", 1)
        except ValueError:
            continue
        LS_REMOTE_CACHE[(url, ref)] = value


def save_ls_remote_cache() -> None:
    if not LS_REMOTE_CACHE_DIRTY:
        return
    try:
        payload = {
            _cache_key(url, ref): value
            for (url, ref), value in LS_REMOTE_CACHE.items()
        }
        LS_REMOTE_CACHE_PATH.write_text(json.dumps(payload, indent=2, sort_keys=True))
    except Exception:
        pass


def git_ls_remote(url: str, ref: str) -> Optional[str]:
    global LS_REMOTE_CACHE_DIRTY
    key = (url, ref)
    if key in LS_REMOTE_CACHE:
        return LS_REMOTE_CACHE[key]
    try:
        result = subprocess.run(
            ["git", "ls-remote", url, ref],
            capture_output=True,
            text=True,
            check=True,
        )
        for line in result.stdout.strip().splitlines():
            if not line:
                continue
            LS_REMOTE_CACHE[key] = line.split()[0]
            LS_REMOTE_CACHE_DIRTY = True
            return LS_REMOTE_CACHE[key]
    except subprocess.CalledProcessError:
        LS_REMOTE_CACHE[key] = None
        LS_REMOTE_CACHE_DIRTY = True
        return None
    return None


def get_github_mirror_url(vcs_url: str) -> Optional[str]:
    """
    Get GitHub mirror URL for golang.org/x repositories.

    golang.org/x repositories are mirrored on GitHub at github.com/golang/*.
    These mirrors are often more reliable than go.googlesource.com.

    Args:
        vcs_url: Original VCS URL (e.g., https://go.googlesource.com/tools)

    Returns:
        GitHub mirror URL if applicable, None otherwise
    """
    if 'go.googlesource.com' in vcs_url:
        # Extract package name from URL
        # https://go.googlesource.com/tools -> tools
        pkg_name = vcs_url.rstrip('/').split('/')[-1]
        return f"https://github.com/golang/{pkg_name}"
    return None


def resolve_pseudo_version_commit(vcs_url: str, timestamp_str: str, short_commit: str,
                                   clone_cache_dir: Optional[Path] = None) -> Optional[str]:
    """
    Resolve a pseudo-version's short commit hash to a full 40-character hash.

    This function clones (or updates) a git repository and searches the commit history
    for a commit that matches both the timestamp and short commit hash from a pseudo-version.

    For golang.org/x repositories, automatically tries GitHub mirrors if the primary
    source fails (go.googlesource.com can be slow or unreliable).

    Args:
        vcs_url: Git repository URL
        timestamp_str: Timestamp from pseudo-version (format: YYYYMMDDHHmmss)
        short_commit: Short commit hash (12 characters) from pseudo-version
        clone_cache_dir: Optional directory to cache cloned repositories (recommended)

    Returns:
        Full 40-character commit hash, or None if not found
    """
    # Parse timestamp
    try:
        dt = datetime.strptime(timestamp_str, "%Y%m%d%H%M%S")
        # Search window: ±1 day around timestamp for efficiency
        since = (dt - timedelta(days=1)).isoformat()
        until = (dt + timedelta(days=1)).isoformat()
    except ValueError:
        return None

    # Try primary URL and GitHub mirror (if applicable)
    urls_to_try = [vcs_url]
    github_mirror = get_github_mirror_url(vcs_url)
    if github_mirror:
        urls_to_try.append(github_mirror)

    for try_url in urls_to_try:
        # Determine clone directory based on URL being tried
        if clone_cache_dir:
            clone_cache_dir.mkdir(parents=True, exist_ok=True)
            repo_hash = hashlib.sha256(try_url.encode()).hexdigest()[:16]
            clone_dir = clone_cache_dir / f"repo_{repo_hash}"
        else:
            clone_dir = Path(tempfile.mkdtemp(prefix="pseudo-resolve-"))

        try:
            # Clone or update repository
            if clone_dir.exists() and (clone_dir / 'HEAD').exists():
                # Repository already cloned, fetch latest
                try:
                    subprocess.run(
                        ['git', 'fetch', '--all', '--quiet'],
                        cwd=clone_dir,
                        capture_output=True,
                        check=True,
                        timeout=60
                    )
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                    # Fetch failed, try to use existing clone anyway
                    pass
            else:
                # Clone repository (bare clone for efficiency)
                if clone_dir.exists():
                    shutil.rmtree(clone_dir)
                clone_dir.mkdir(parents=True, exist_ok=True)

                subprocess.run(
                    ['git', 'clone', '--bare', '--quiet', try_url, str(clone_dir)],
                    capture_output=True,
                    check=True,
                    timeout=300  # 5 minute timeout
                )

            # Search for commits matching timestamp and short hash
            result = subprocess.run(
                ['git', 'log', '--all', '--format=%H %ct',
                 f'--since={since}', f'--until={until}'],
                cwd=clone_dir,
                capture_output=True,
                text=True,
                check=True,
                timeout=30
            )

            # Find commit with matching short hash prefix
            for line in result.stdout.strip().splitlines():
                if not line:
                    continue
                parts = line.split()
                if len(parts) < 2:
                    continue
                full_hash = parts[0]
                if full_hash.startswith(short_commit):
                    return full_hash

            # Commit not found in this repository, try next URL
            continue

        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
            # Clone/fetch failed, try next URL if available
            if not clone_cache_dir and clone_dir.exists():
                shutil.rmtree(clone_dir)
            continue
        finally:
            # Clean up temp directory if we created one
            if not clone_cache_dir and clone_dir.exists():
                try:
                    shutil.rmtree(clone_dir)
                except:
                    pass

    # All URLs failed
    return None


def derive_timestamp_from_version(version: str) -> str:
    pseudo = re.match(r'v\d+\.\d+\.\d+-(\d{14})-', version)
    if pseudo:
        try:
            return datetime.strptime(pseudo.group(1), "%Y%m%d%H%M%S").strftime("%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            pass
    return "1970-01-01T00:00:00Z"


def _cache_metadata_key(module_path: str, version: str) -> Tuple[str, str]:
    return (module_path, version)


def load_metadata_cache_file() -> None:
    if not MODULE_METADATA_CACHE_PATH.exists():
        return
    try:
        data = json.loads(MODULE_METADATA_CACHE_PATH.read_text())
    except Exception:
        return
    for key, value in data.items():
        try:
            module_path, version = key.split("|||", 1)
        except ValueError:
            continue
        if not isinstance(value, dict):
            continue
        MODULE_METADATA_CACHE[_cache_metadata_key(module_path, version)] = {
            'vcs_url': value.get('vcs_url', ''),
            'commit': value.get('commit', ''),
            'timestamp': value.get('timestamp', ''),
            'subdir': value.get('subdir', ''),
        }


def save_metadata_cache() -> None:
    if not MODULE_METADATA_CACHE_DIRTY:
        return
    payload = {
        f"{module}|||{version}": value
        for (module, version), value in MODULE_METADATA_CACHE.items()
    }
    try:
        MODULE_METADATA_CACHE_PATH.write_text(json.dumps(payload, indent=2, sort_keys=True))
    except Exception:
        pass


def update_metadata_cache(module_path: str, version: str, vcs_url: str, commit: str,
                          timestamp: str = "", subdir: str = "", dirty: bool = True) -> None:
    global MODULE_METADATA_CACHE_DIRTY
    key = _cache_metadata_key(module_path, version)
    value = {
        'vcs_url': vcs_url or '',
        'commit': commit or '',
        'timestamp': timestamp or '',
        'subdir': subdir or '',
    }
    if MODULE_METADATA_CACHE.get(key) != value:
        MODULE_METADATA_CACHE[key] = value
        if dirty:
            MODULE_METADATA_CACHE_DIRTY = True


def get_cached_metadata(module_path: str, version: str) -> Optional[dict]:
    entry = MODULE_METADATA_CACHE.get(_cache_metadata_key(module_path, version))
    if not entry:
        return None
    timestamp = entry.get('timestamp') or derive_timestamp_from_version(version)
    return {
        "module_path": module_path,
        "version": version,
        "vcs_url": entry.get('vcs_url', ''),
        "vcs_hash": entry.get('commit', ''),
        "vcs_ref": "",
        "timestamp": timestamp,
        "subdir": entry.get('subdir', ''),
    }


def load_metadata_from_inc(output_dir: Path) -> None:
    git_inc = output_dir / "go-mod-git.inc"
    cache_inc = output_dir / "go-mod-cache.inc"

    sha_to_url: Dict[str, str] = {}
    if git_inc.exists():
        for line in git_inc.read_text().splitlines():
            line = line.strip()
            if not line.startswith('SRC_URI'):
                continue
            if '"' not in line:
                continue
            content = line.split('"', 1)[1].rsplit('"', 1)[0]
            parts = [p for p in content.split(';') if p]
            if not parts:
                continue
            url_part = parts[0]
            dest_sha = None
            for part in parts[1:]:
                if part.startswith('destsuffix='):
                    dest = part.split('=', 1)[1]
                    dest_sha = dest.rsplit('/', 1)[-1]
                    break
            if not dest_sha:
                continue
            if url_part.startswith('git://'):
                url_https = 'https://' + url_part[6:]
            else:
                url_https = url_part
            sha_to_url[dest_sha] = url_https

    if cache_inc.exists():
        text = cache_inc.read_text()
        marker = "GO_MODULE_CACHE_DATA = '"
        if marker in text:
            start = text.index(marker) + len(marker)
            try:
                end = text.index("'\n\n", start)
            except ValueError:
                end = len(text)
            try:
                data = json.loads(text[start:end])
            except Exception:
                data = []
            for entry in data:
                module_path = entry.get('module')
                version = entry.get('version')
                sha = entry.get('vcs_hash')
                commit = entry.get('commit')
                timestamp = entry.get('timestamp', '')
                subdir = entry.get('subdir', '')
                if not module_path or not version:
                    continue
                vcs_url = sha_to_url.get(sha, '')
                if not vcs_url:
                    continue
                # Skip entries with invalid commit hashes
                if commit and len(commit) != 40:
                    continue
                if not timestamp:
                    timestamp = derive_timestamp_from_version(version)
                update_metadata_cache(module_path, version, vcs_url, commit or '', timestamp, subdir, dirty=False)


def load_metadata_from_module_cache_task(output_dir: Path) -> None:
    legacy_path = output_dir / "module_cache_task.inc"
    if not legacy_path.exists():
        return
    import ast
    pattern = re.compile(r'\(\{.*?\}\)', re.DOTALL)
    text = legacy_path.read_text()
    for match in pattern.finditer(text):
        blob = match.group()[1:-1]  # strip parentheses
        try:
            entry = ast.literal_eval(blob)
        except Exception:
            continue
        module_path = entry.get('module')
        version = entry.get('version')
        vcs_url = entry.get('repo_url') or entry.get('url') or ''
        commit = entry.get('commit') or ''
        subdir = entry.get('subdir', '')
        if not module_path or not version or not vcs_url or not commit:
            continue
        if vcs_url.startswith('git://'):
            vcs_url = 'https://' + vcs_url[6:]
        timestamp = derive_timestamp_from_version(version)
        update_metadata_cache(module_path, version, vcs_url, commit, timestamp, subdir, dirty=True)


def bootstrap_metadata_cache(output_dir: Path) -> None:
    load_metadata_cache_file()
    load_metadata_from_inc(output_dir)
    load_metadata_from_module_cache_task(output_dir)


def resolve_module_metadata(module_path: str, version: str) -> Optional[dict]:
    parts = module_path.split('/')

    # Handle gopkg.in special case
    if parts[0] == 'gopkg.in':
        # gopkg.in/pkg.v3 -> github.com/go-pkg/pkg
        # gopkg.in/user/pkg.v3 -> github.com/user/pkg
        if len(parts) == 2:
            # gopkg.in/pkg.v3
            pkg_name = parts[1].rsplit('.', 1)[0]  # Remove .vN suffix
            vcs_url = f"https://github.com/go-{pkg_name}/{pkg_name}"
            base_repo = f"github.com/go-{pkg_name}/{pkg_name}"
        elif len(parts) == 3:
            # gopkg.in/user/pkg.v3
            user = parts[1]
            pkg_name = parts[2].rsplit('.', 1)[0]  # Remove .vN suffix
            vcs_url = f"https://github.com/{user}/{pkg_name}"
            base_repo = f"github.com/{user}/{pkg_name}"
        else:
            print(f"  ⚠️  Unable to derive repository for gopkg.in path {module_path}@{version}")
            return None
        subdir = ''
    elif len(parts) < 3:
        print(f"  ⚠️  Unable to derive repository for {module_path}@{version}")
        return None
    else:
        base_repo = '/'.join(parts[:3])
        # Calculate subdir from module path, but strip version suffixes (v2, v3, v11, etc.)
        if len(parts) > 3:
            subdir_parts = parts[3:]
            # Remove trailing version suffix if present (e.g., v2, v3, v11)
            if subdir_parts and subdir_parts[-1].startswith('v') and subdir_parts[-1][1:].isdigit():
                subdir_parts = subdir_parts[:-1]
            subdir = '/'.join(subdir_parts) if subdir_parts else ''
        else:
            subdir = ''
        vcs_url = f"https://{base_repo}"

    tag = version.split('+')[0]
    commit = None
    pseudo_match = re.match(r'v\d+\.\d+\.\d+-\d{14}-([0-9a-fA-F]+)', tag)
    expected_commit = pseudo_match.group(1) if pseudo_match else None

    cached = get_cached_metadata(module_path, version)
    if cached and cached.get('vcs_url') and cached.get('vcs_hash'):
        cached_commit = cached.get('vcs_hash') or ''
        if expected_commit and cached_commit and not cached_commit.startswith(expected_commit):
            cached = None
        if cached:
            return cached

    if pseudo_match:
        short_commit = expected_commit
        commit = git_ls_remote(vcs_url, short_commit)
        if not commit:
            # Can't expand short commit - BitBake needs full hash
            cached = get_cached_metadata(module_path, version)
            if cached and cached.get('vcs_hash'):
                return cached
            return None
    else:
        commit = git_ls_remote(vcs_url, f"refs/tags/{tag}") or git_ls_remote(vcs_url, tag)

    if not commit:
        cached = get_cached_metadata(module_path, version)
        if cached and cached.get('vcs_hash'):
            return cached
        # Don't print warning here - caller will handle skipping indirect-only deps
        return None

    if pseudo_match:
        timestamp_raw = tag.split('-')[1]
        timestamp = datetime.strptime(timestamp_raw, "%Y%m%d%H%M%S").strftime("%Y-%m-%dT%H:%M:%SZ")
    else:
        timestamp = "1970-01-01T00:00:00Z"

    update_metadata_cache(module_path, version, vcs_url, commit, timestamp, subdir, dirty=True)

    return {
        "module_path": module_path,
        "version": version,
        "vcs_url": vcs_url,
        "vcs_hash": commit,
        "vcs_ref": "",
        "timestamp": timestamp,
        "subdir": subdir,
    }


MODULE_CACHE_TASK_HEADER = textwrap.dedent(r'''
DEPENDS += "go-dirhash-native"

python do_create_module_cache() {
    """
    Build Go module cache from downloaded git repositories.
    This creates the same cache structure as oe-core's gomod.bbclass.
    """
    import hashlib
    import json
    import os
    import shutil
    import subprocess
    import zipfile
    import stat
    from pathlib import Path
    from datetime import datetime

    go_helper = Path(d.getVar('STAGING_BINDIR_NATIVE')) / "dirhash"
    if not go_helper.exists():
        bb.fatal(f"Go checksum helper not found at {go_helper}. Ensure go-dirhash-native is in DEPENDS.")

    go_sum_hashes = {}
    go_sum_path = Path(d.getVar('S')) / "src" / "import" / "go.sum"
    if go_sum_path.exists():
        with open(go_sum_path, 'r') as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) != 3:
                    continue
                mod, ver, hash_value = parts
                if mod.endswith('/go.mod') or not hash_value.startswith('h1:'):
                    continue
                key = f"{mod}@{ver}"
                go_sum_hashes.setdefault(key, hash_value)

    def escape_module_path(path):
        """Escape capital letters using exclamation points (same as BitBake gomod.py)"""
        import re
        return re.sub(r'([A-Z])', lambda m: '!' + m.group(1).lower(), path)

    def sanitize_module_name(name):
        """Remove quotes from module names"""
        if not name:
            return name
        stripped = name.strip()
        if len(stripped) >= 2 and stripped[0] == '"' and stripped[-1] == '"':
            return stripped[1:-1]
        return stripped

    def create_module_zip(module_path, version, vcs_path, subdir, timestamp, commit):
        """Create module zip file from git repository"""
        module_path = sanitize_module_name(module_path)
        escaped_module = escape_module_path(module_path)
        escaped_version = escape_module_path(version)

        # Create cache directory structure
        workdir = Path(d.getVar('WORKDIR'))
        s = Path(d.getVar('S'))
        cache_dir = s / "pkg" / "mod" / "cache" / "download"
        download_dir = cache_dir / escaped_module / "@v"
        download_dir.mkdir(parents=True, exist_ok=True)

        bb.note(f"Creating cache for {module_path}@{version}")

        # 1. Create .info file
        info_path = download_dir / f"{escaped_version}.info"
        info_data = {
            "Version": version,
            "Time": timestamp
        }
        with open(info_path, 'w') as f:
            json.dump(info_data, f)
        bb.debug(1, f"Created {info_path}")

        # 2. Create .mod file
        mod_path = download_dir / f"{escaped_version}.mod"
        effective_subdir = subdir or ""

        def candidate_subdirs():
            candidates = []
            parts = module_path.split('/')
            if len(parts) >= 4:
                extra = '/'.join(parts[3:])
                if extra:
                    candidates.append(extra)

            if effective_subdir:
                candidates.insert(0, effective_subdir)
            else:
                candidates.append('')

            suffix = parts[-1]
            if suffix.startswith('v') and suffix[1:].isdigit():
                suffix_path = f"{effective_subdir}/{suffix}" if effective_subdir else suffix
                if suffix_path not in candidates:
                    candidates.insert(0, suffix_path)

            if '' not in candidates:
                candidates.append('')
            return candidates

        gomod_file = None
        for candidate in candidate_subdirs():
            path_candidate = Path(vcs_path) / candidate / "go.mod" if candidate else Path(vcs_path) / "go.mod"
            if path_candidate.exists():
                gomod_file = path_candidate
                if candidate != effective_subdir:
                    effective_subdir = candidate
                    subdir = effective_subdir
                    module['subdir'] = effective_subdir
                break

        if gomod_file is None:
            gomod_file = Path(vcs_path) / effective_subdir / "go.mod" if effective_subdir else Path(vcs_path) / "go.mod"

        def synthesize_go_mod(modname):
            sanitized = sanitize_module_name(modname)
            return f"module {sanitized}\n".encode('utf-8')

        mod_content = None

        def is_vendored_package(rel_path):
            if rel_path.startswith("vendor/"):
                prefix_len = len("vendor/")
            else:
                idx = rel_path.find("/vendor/")
                if idx < 0:
                    return False
                prefix_len = len("/vendor/")
            return "/" in rel_path[prefix_len:]

        if '+incompatible' in version:
            mod_content = synthesize_go_mod(module_path)
            bb.debug(1, f"Synthesizing go.mod for +incompatible module {module_path}@{version}")
        elif gomod_file.exists():
            mod_content = gomod_file.read_bytes()
        else:
            bb.debug(1, f"go.mod not found at {gomod_file}")
            mod_content = synthesize_go_mod(module_path)

        with open(mod_path, 'wb') as f:
            f.write(mod_content)
        bb.debug(1, f"Created {mod_path}")

        license_blobs = []
        if effective_subdir:
            license_candidates = [
                "LICENSE",
                "LICENSE.txt",
                "LICENSE.md",
                "LICENCE",
                "COPYING",
                "COPYING.txt",
                "COPYING.md",
            ]
            for candidate in license_candidates:
                try:
                    content = subprocess.check_output(
                        ["git", "show", f"{commit}:{candidate}"],
                        cwd=vcs_path,
                        stderr=subprocess.DEVNULL,
                    )
                except subprocess.CalledProcessError:
                    continue
                license_blobs.append((Path(candidate).name, content))
                break

        # 3. Create .zip file using git archive + filtering
        zip_path = download_dir / f"{escaped_version}.zip"
        zip_prefix = f"{module_path}@{version}/"
        module_key = f"{module_path}@{version}"
        expected_hash = go_sum_hashes.get(module_key)

        import tarfile
        import tempfile

        def assemble_zip(include_vendor_modules: bool) -> bool:
            try:
                with tempfile.TemporaryDirectory(dir=str(download_dir)) as tmpdir:
                    tar_path = Path(tmpdir) / "archive.tar"
                    archive_cmd = ["git", "archive", "--format=tar", "-o", str(tar_path), commit]
                    if subdir:
                        archive_cmd.append(subdir)

                    subprocess.run(archive_cmd, cwd=str(vcs_path), check=True, capture_output=True)

                    with tarfile.open(tar_path, 'r') as tf:
                        tf.extractall(tmpdir)
                    tar_path.unlink(missing_ok=True)

                    extract_root = Path(tmpdir)
                    if subdir:
                        extract_root = extract_root / subdir

                    excluded_prefixes = []
                    for gomod_file in extract_root.rglob("go.mod"):
                        rel_path = gomod_file.relative_to(extract_root).as_posix()
                        if rel_path != "go.mod":
                            prefix = gomod_file.parent.relative_to(extract_root).as_posix()
                            if prefix and not prefix.endswith("/"):
                                prefix += "/"
                            excluded_prefixes.append(prefix)

                    if zip_path.exists():
                        zip_path.unlink()

                def add_zip_entry(zf, arcname, data, mode=None):
                    info = zipfile.ZipInfo(arcname)
                    info.date_time = (1980, 1, 1, 0, 0, 0)
                    info.compress_type = zipfile.ZIP_DEFLATED
                    info.create_system = 3  # Unix
                    if mode is None:
                        mode = stat.S_IFREG | 0o644
                    info.external_attr = ((mode & 0xFFFF) << 16)
                    zf.writestr(info, data)

                with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
                    for file_path in sorted(extract_root.rglob("*")):
                        if file_path.is_dir():
                            continue

                        rel_path = file_path.relative_to(extract_root).as_posix()

                        if file_path.is_symlink():
                            continue

                        if is_vendored_package(rel_path):
                            continue

                        if rel_path == "vendor/modules.txt" and not include_vendor_modules:
                            continue

                        if any(rel_path.startswith(prefix) for prefix in excluded_prefixes):
                            continue
                        if rel_path.endswith("go.mod") and rel_path != "go.mod":
                            continue

                        if rel_path == "go.mod":
                            data = mod_content
                            mode = stat.S_IFREG | 0o644
                        else:
                            data = file_path.read_bytes()
                            try:
                                mode = file_path.stat().st_mode
                            except FileNotFoundError:
                                mode = stat.S_IFREG | 0o644

                        add_zip_entry(zf, zip_prefix + rel_path, data, mode)

                    for license_name, content in license_blobs:
                        if (extract_root / license_name).exists():
                            continue
                        add_zip_entry(zf, zip_prefix + license_name, content, stat.S_IFREG | 0o644)
                return True
            except subprocess.CalledProcessError as e:
                bb.error(f"Failed to create zip for {module_path}@{version}: {e.stderr.decode()}")
                return False
            except Exception as e:
                bb.error(f"Failed to assemble zip for {module_path}@{version}: {e}")
                return False

        if not assemble_zip(include_vendor_modules=True):
            return False

        def calculate_hash() -> str:
            result = subprocess.run(
                [str(go_helper), str(zip_path)],
                capture_output=True,
                text=True,
                check=False,
                timeout=60
            )
            if result.returncode != 0:
                raise RuntimeError(result.stderr.strip() or "dirhash helper failed")
            hash_value = result.stdout.strip()
            if not hash_value.startswith("h1:"):
                raise RuntimeError(f"unexpected dirhash output: {hash_value}")
            return hash_value

        try:
            hash_value = calculate_hash()
        except Exception as e:
            bb.warn(f"Failed to create ziphash for {module_path}@{version}: {e}")
            hash_value = None

        if expected_hash and hash_value and hash_value != expected_hash:
            bb.debug(1, f"Hash mismatch for {module_key} ({hash_value} != {expected_hash}), retrying without vendor/modules.txt")
            if not assemble_zip(include_vendor_modules=False):
                return False
            try:
                hash_value = calculate_hash()
            except Exception as e:
                bb.warn(f"Failed to create ziphash for {module_path}@{version}: {e}")
                hash_value = None

            if hash_value and hash_value != expected_hash:
                bb.warn(f"{module_key} still mismatches expected hash after retry ({hash_value} != {expected_hash})")

        if hash_value:
            ziphash_path = download_dir / f"{escaped_version}.ziphash"
            with open(ziphash_path, 'w') as f:
                f.write(f"{hash_value}\n")
            bb.debug(1, f"Created {ziphash_path}")
        else:
            bb.warn(f"Skipping ziphash for {module_key} due to calculation errors")

        # 5. Extract zip to pkg/mod for offline builds
        extract_dir = s / "pkg" / "mod"
        try:
            with zipfile.ZipFile(zip_path, 'r') as zip_ref:
                zip_ref.extractall(extract_dir)
            bb.debug(1, f"Extracted {module_path}@{version} to {extract_dir}")
        except Exception as e:
            bb.error(f"Failed to extract {module_path}@{version}: {e}")
            return False

        return True

    def regenerate_go_sum():
        s_path = Path(d.getVar('S'))
        cache_dir = s_path / "pkg" / "mod" / "cache" / "download"
        go_sum_path = s_path / "src" / "import" / "go.sum"

        if not cache_dir.exists():
            bb.warn("Module cache directory not found - skipping go.sum regeneration")
            return

        if not go_helper.exists():
            bb.warn("Go dirhash helper missing - skipping go.sum regeneration")
            return

        def calculate_zip_checksum(zip_file):
            result = subprocess.run(
                [str(go_helper), str(zip_file)],
                capture_output=True,
                text=True,
                check=False,
                timeout=60
            )
            if result.returncode != 0:
                bb.warn(f"Failed to calculate zip checksum for {zip_file}: {result.stderr}")
                return None
            hash_value = result.stdout.strip()
            if not hash_value.startswith("h1:"):
                bb.warn(f"Unexpected checksum format for {zip_file}: {hash_value}")
                return None
            return hash_value

        def calculate_mod_checksum(mod_path):
            try:
                mod_bytes = mod_path.read_bytes()
            except FileNotFoundError:
                return None

            import base64

            file_hash = hashlib.sha256(mod_bytes).hexdigest()
            summary = f"{file_hash}  go.mod\n".encode('ascii')
            digest = hashlib.sha256(summary).digest()
            return "h1:" + base64.b64encode(digest).decode('ascii')

        def unescape(value):
            import re

            return re.sub(r'!([a-z])', lambda m: m.group(1).upper(), value)

        existing_entries = {}

        if go_sum_path.exists():
            with open(go_sum_path, 'r') as f:
                for line in f:
                    parts = line.strip().split()
                    if len(parts) != 3:
                        continue
                    mod, ver, hash_value = parts
                    existing_entries[(mod, ver)] = hash_value

        new_entries = {}

        for zip_file in sorted(cache_dir.rglob("*.zip")):
            zip_hash = calculate_zip_checksum(zip_file)
            if not zip_hash:
                continue

            parts = zip_file.parts
            try:
                v_index = parts.index('@v')
                download_index = parts.index('download')
            except ValueError:
                bb.warn(f"Unexpected cache layout for {zip_file}")
                continue

            escaped_module_parts = parts[download_index + 1:v_index]
            escaped_module = '/'.join(escaped_module_parts)
            escaped_version = zip_file.stem

            module_path = unescape(escaped_module)
            version = unescape(escaped_version)

            new_entries[(module_path, version)] = zip_hash

            mod_checksum = calculate_mod_checksum(zip_file.with_suffix('.mod'))
            if mod_checksum:
                new_entries[(module_path, f"{version}/go.mod")] = mod_checksum

        if not new_entries and not existing_entries:
            bb.warn("No go.sum entries available - skipping regeneration")
            return

        final_entries = existing_entries.copy()
        final_entries.update(new_entries)

        go_sum_path.parent.mkdir(parents=True, exist_ok=True)
        with open(go_sum_path, 'w') as f:
            for (mod, ver) in sorted(final_entries.keys()):
                f.write(f"{mod} {ver} {final_entries[(mod, ver)]}\n")

        bb.debug(1, f"Regenerated go.sum with {len(final_entries)} entries")

    # Process all modules
    workdir = Path(d.getVar('WORKDIR'))
    modules_data = json.loads(d.getVar('GO_MODULE_CACHE_DATA'))

    bb.note(f"Building module cache for {len(modules_data)} modules")

    success_count = 0
    fail_count = 0

    for module in modules_data:
        vcs_hash = module['vcs_hash']
        vcs_path = workdir / "sources" / "vcs_cache" / vcs_hash

        # Checkout the exact commit
        try:
            subprocess.run(
                ['git', 'checkout', '-q', module['commit']],
                cwd=str(vcs_path),
                check=True,
                capture_output=True
            )
        except subprocess.CalledProcessError as e:
            bb.error(f"Failed to checkout {module['commit']} in {vcs_path}: {e.stderr.decode()}")
            fail_count += 1
            continue

        # Create module cache files
        if create_module_zip(
            module['module'],
            module['version'],
            vcs_path,
            module.get('subdir', ''),
            module['timestamp'],
            module['commit']
        ):
            success_count += 1
        else:
            fail_count += 1

    if fail_count == 0:
        regenerate_go_sum()
    else:
        bb.warn("Skipping go.sum regeneration due to module cache failures")

    bb.note(f"Module cache complete: {success_count} succeeded, {fail_count} failed")

    if fail_count > 0:
        bb.fatal(f"Failed to create cache for {fail_count} modules")
}

addtask create_module_cache after do_unpack before do_configure
''')

MODULE_CACHE_TASK_FOOTER = ""

# =============================================================================
# Utility Functions
# =============================================================================

def unescape_module_path(path: str) -> str:
    """
    Unescape Go module paths that use ! for uppercase letters.
    Example: github.com/!sirupsen/logrus -> github.com/Sirupsen/logrus
    """
    import re
    return re.sub(r'!([a-z])', lambda m: m.group(1).upper(), path)

def escape_module_path(path: str) -> str:
    """
    Escape Go module paths by converting uppercase to !lowercase.
    Example: github.com/Sirupsen/logrus -> github.com/!sirupsen/logrus
    """
    import re
    return re.sub(r'([A-Z])', lambda m: '!' + m.group(1).lower(), path)

# =============================================================================
# Phase 1: Discovery
# =============================================================================

def discover_modules(source_dir: Path, gomodcache: Optional[str] = None) -> List[Dict]:
    """
    Phase 1: Discovery

    Let Go download modules to discover correct paths and metadata.
    This is ONLY for discovery - we build from git sources.

    Returns list of modules with:
    - module_path: CORRECT path from filesystem (no /v3 stripping!)
    - version: Module version
    - vcs_url: Git repository URL
    - vcs_hash: Git commit hash
    - vcs_ref: Git reference (tag/branch)
    - timestamp: Commit timestamp
    - subdir: Subdirectory within repo (for submodules)
    """
    print("\n" + "=" * 70)
    print("PHASE 1: DISCOVERY - Using Go to discover module metadata")
    print("=" * 70)

    # Create temporary or use provided GOMODCACHE
    if gomodcache:
        temp_cache = Path(gomodcache)
        print(f"Using existing GOMODCACHE: {temp_cache}")
        cleanup_cache = False
    else:
        temp_cache = Path(tempfile.mkdtemp(prefix="go-discover-"))
        print(f"Created temporary cache: {temp_cache}")
        cleanup_cache = True

    try:
        # Set up environment for Go
        env = os.environ.copy()
        env['GOMODCACHE'] = str(temp_cache)
        env['GOPROXY'] = 'https://proxy.golang.org'

        print(f"\nDownloading modules to discover metadata...")
        print(f"Source: {source_dir}")

        # Let Go download everything
        result = subprocess.run(
            ['go', 'mod', 'download'],
            cwd=source_dir,
            env=env,
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            print(f"Warning: go mod download had errors:\n{result.stderr}")
            # Continue anyway - some modules may have been downloaded

        # Walk filesystem to discover what Go created
        modules = []
        download_dir = temp_cache / "cache" / "download"

        if not download_dir.exists():
            print(f"Error: Download directory not found: {download_dir}")
            return []

        print(f"\nScanning {download_dir} for modules...")

        for dirpath, _, filenames in os.walk(download_dir):
            path_parts = Path(dirpath).relative_to(download_dir).parts

            # Look for @v directories
            if not path_parts or path_parts[-1] != '@v':
                continue

            # Module path is everything before @v
            module_path = '/'.join(path_parts[:-1])
            module_path = unescape_module_path(module_path)  # Unescape !-encoding

            # Process each .info file
            for filename in filenames:
                if not filename.endswith('.info'):
                    continue

                version = filename[:-5]  # Strip .info extension
                info_path = Path(dirpath) / filename

                try:
                    # Read metadata from .info file
                    with open(info_path) as f:
                        info = json.load(f)

                    # Extract VCS information
                    origin = info.get('Origin', {})
                    vcs_url = origin.get('URL')
                    vcs_hash = origin.get('Hash')
                    vcs_ref = origin.get('Ref', '')

                    if not vcs_url or not vcs_hash:
                        print(f"  ⚠️  Skipping {module_path}@{version}: No VCS info")
                        continue

                    # BitBake requires full 40-character commit hashes
                    if len(vcs_hash) != 40:
                        print(f"  ⚠️  Skipping {module_path}@{version}: Short commit hash ({vcs_hash})")
                        continue

                    # Detect subdir for submodules
                    # This is a simple heuristic - may need refinement
                    subdir = origin.get('Subdir', '')

                    modules.append({
                        'module_path': module_path,
                        'version': version,
                        'vcs_url': vcs_url,
                        'vcs_hash': vcs_hash,
                        'vcs_ref': vcs_ref,
                        'timestamp': info.get('Time', ''),
                        'subdir': subdir,
                    })

                    print(f"  ✓ {module_path}@{version}")

                except Exception as e:
                    print(f"  ✗ Error processing {info_path}: {e}")
                    continue

        print(f"\nDiscovered {len(modules)} modules with VCS info")
        return modules

    finally:
        # Clean up temp cache if we created it
        if cleanup_cache and temp_cache.exists():
            print(f"\nCleaning up temporary cache: {temp_cache}")
            shutil.rmtree(temp_cache)

# =============================================================================
# Phase 2: Recipe Generation
# =============================================================================

def generate_recipe(modules: List[Dict], source_dir: Path, output_dir: Path,
                   git_repo: str, git_ref: str) -> bool:
    """
    Phase 2: Recipe Generation

    Generate BitBake recipe with git:// SRC_URI entries.
    No file:// entries - we'll build cache from git during do_create_module_cache.

    Creates:
    - go-mod-git.inc: SRC_URI with git:// entries
    - go-mod-cache.inc: BitBake task to build module cache
    """
    print("\n" + "=" * 70)
    print("PHASE 2: RECIPE GENERATION - Creating BitBake recipe files")
    print("=" * 70)

    src_uri_entries = []
    modules_data = []
    vcs_repos = {}  # Track unique VCS repos to avoid duplicates

    for module in modules:
        vcs_url = module['vcs_url']
        vcs_hash = module['vcs_hash']

        # Calculate VCS hash for destsuffix (unique per repo URL)
        vcs_key = f"git3:{vcs_url}"
        vcs_sha = hashlib.sha256(vcs_key.encode()).hexdigest()
        module['vcs_sha'] = vcs_sha

        # Track this repo (may be shared by multiple modules)
        if vcs_sha not in vcs_repos:
            vcs_repos[vcs_sha] = {
                'url': vcs_url,
                'hash': vcs_hash,
                'modules': []
            }
        vcs_repos[vcs_sha]['modules'].append(module)

    print(f"\nFound {len(vcs_repos)} unique git repositories")
    print(f"Supporting {len(modules)} modules")

    # Generate SRC_URI entries for each unique repo
    for idx, (vcs_sha, repo_info) in enumerate(vcs_repos.items()):
        git_url = repo_info['url']
        commit_hash = repo_info['hash']
        fetch_name = f"git_{vcs_sha[:12]}"

        # Convert https:// to git:// for BitBake
        if git_url.startswith('https://'):
            git_url_bb = 'git://' + git_url[8:]
            protocol = 'https'
        elif git_url.startswith('http://'):
            git_url_bb = 'git://' + git_url[7:]
            protocol = 'http'
        else:
            git_url_bb = git_url
            protocol = 'https'  # default

        src_uri_entries.append(
            f'{git_url_bb};protocol={protocol};nobranch=1;'
            f'rev={commit_hash};'
            f'name={fetch_name};'
            f'destsuffix=vcs_cache/{vcs_sha}'
        )

        print(f"  {fetch_name}: {repo_info['url'][:60]}...")

    # Prepare modules data for do_create_module_cache
    for module in modules:
        vcs_key = f"git3:{module['vcs_url']}"
        vcs_sha = hashlib.sha256(vcs_key.encode()).hexdigest()

        update_metadata_cache(
            module['module_path'],
            module['version'],
            module['vcs_url'],
            module['vcs_hash'],
            module.get('timestamp', ''),
            module.get('subdir', ''),
            dirty=True,
        )

        modules_data.append({
            'module': module['module_path'],
            'version': module['version'],
            'vcs_hash': module['vcs_sha'],
            'commit': module['vcs_hash'],
            'timestamp': module['timestamp'],
            'subdir': module.get('subdir', ''),
        })

    # Write go-mod-git.inc
    git_inc_path = output_dir / "go-mod-git.inc"
    print(f"\nWriting {git_inc_path}")

    with open(git_inc_path, 'w') as f:
        f.write("# Generated by oe-go-mod-fetcher.py v" + VERSION + "\n")
        f.write("# Git repositories for Go module dependencies\n\n")
        for entry in src_uri_entries:
            f.write(f'SRC_URI += "{entry}"\n')
        f.write('\n')

        # Write checksums (empty for now - BitBake will fill these in)
        f.write("# SRCREVs for git repositories\n")
        for vcs_sha, repo_info in vcs_repos.items():
            fetch_name = f"git_{vcs_sha[:12]}"
            f.write(f'SRCREV_{fetch_name} = "{repo_info["hash"]}"\n')

    # Write go-mod-cache.inc
    cache_inc_path = output_dir / "go-mod-cache.inc"
    print(f"Writing {cache_inc_path}")

    with open(cache_inc_path, 'w') as f:
        f.write("# Generated by oe-go-mod-fetcher.py v" + VERSION + "\n")
        f.write("# Module cache builder for Go dependencies\n\n")

        # Write modules data as JSON
        f.write("# Module metadata for cache building\n")
        f.write("GO_MODULE_CACHE_DATA = '")
        json.dump(modules_data, f, separators=(',', ':'))
        f.write("'\n\n")

        # Write the BitBake task
        f.write(MODULE_CACHE_TASK_HEADER)
        f.write(MODULE_CACHE_TASK_FOOTER)

    print(f"\n✅ Generated recipe files:")
    print(f"   {git_inc_path}")
    print(f"   {cache_inc_path}")
    print(f"\nTo use these files, add to your recipe:")
    print(f"   require go-mod-git.inc")
    print(f"   require go-mod-cache.inc")

    return True

# =============================================================================
# Main Entry Point
# =============================================================================

def main():
    print(f"Go Module Git Fetcher v{VERSION}")
    print("Hybrid Architecture: Discovery from Go + Build from Git")
    print("=" * 70)

    parser = argparse.ArgumentParser(
        description=f"Generate BitBake recipes for Go modules using hybrid approach (v{VERSION})",
        epilog="""
This tool uses a 3-phase hybrid approach:
  1. Discovery: Run 'go mod download' to get correct module paths
  2. Recipe Generation: Create git:// SRC_URI entries for BitBake
  3. Cache Building: Build module cache from git during do_create_module_cache

Persistent Caches:
  The generator maintains two caches in the scripts directory:
  - .oe-go-mod-fetcher.module-cache.json: Module metadata (commit, subdir, etc.)
  - .oe-go-mod-fetcher.ls-remote-cache.json: Git ls-remote results

  These caches speed up regeneration but may need cleaning when:
  - Derivation logic changes (e.g., subdir calculation fixes)
  - Cached data becomes stale or incorrect

  Use --clean-cache to remove metadata cache before regeneration.
  Use --clean-ls-remote-cache to remove both caches (slower, but fully fresh).

Examples:
  # Normal regeneration (fast, uses caches)
  %(prog)s --recipedir /path/to/recipe/output

  # Clean metadata cache (e.g., after fixing subdir derivation)
  %(prog)s --recipedir /path/to/recipe/output --clean-cache

  # Fully clean regeneration (slow, calls git ls-remote for everything)
  %(prog)s --recipedir /path/to/recipe/output --clean-ls-remote-cache
        """,
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    parser.add_argument(
        "--recipedir",
        required=True,
        help="Output directory for generated .inc files"
    )

    parser.add_argument(
        "--gomodcache",
        help="Directory to use for Go module cache (for discovery phase)"
    )

    parser.add_argument(
        "--source-dir",
        help="Source directory containing go.mod (default: current directory)"
    )

    parser.add_argument(
        "--git-repo",
        help="Git repository URL (for documentation purposes)"
    )

    parser.add_argument(
        "--git-ref",
        help="Git reference (for documentation purposes)"
    )

    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Verbose output"
    )

    parser.add_argument(
        "--clean-cache",
        action="store_true",
        help="Clear metadata cache before regeneration (useful when derivation logic changes)"
    )

    parser.add_argument(
        "--clean-ls-remote-cache",
        action="store_true",
        help="Clear git ls-remote cache in addition to metadata cache (implies --clean-cache)"
    )

    parser.add_argument(
        "--version",
        action="version",
        version=f"%(prog)s {VERSION}"
    )

    # Add compatibility args that we ignore (for backward compatibility)
    parser.add_argument("--use-hybrid", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("go_mod_file", nargs='?', help=argparse.SUPPRESS)

    args = parser.parse_args()

    # Determine source directory
    if args.source_dir:
        source_dir = Path(args.source_dir).resolve()
    else:
        source_dir = Path.cwd()

    # Validate source directory has go.mod
    if not (source_dir / "go.mod").exists():
        print(f"❌ Error: go.mod not found in {source_dir}")
        sys.exit(1)

    print(f"Source directory: {source_dir}")

    # Validate output directory
    output_dir = Path(args.recipedir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    print(f"Output directory: {output_dir}")

    exit_code = 0

    # Handle cache cleaning flags
    if args.clean_ls_remote_cache:
        print("\n🗑️  Cleaning git ls-remote cache...")
        if LS_REMOTE_CACHE_PATH.exists():
            LS_REMOTE_CACHE_PATH.unlink()
            print(f"   Removed {LS_REMOTE_CACHE_PATH}")
        else:
            print(f"   Cache file not found: {LS_REMOTE_CACHE_PATH}")
        # Also clean metadata cache when cleaning ls-remote
        args.clean_cache = True

    if args.clean_cache:
        print("\n🗑️  Cleaning module metadata cache...")
        if MODULE_METADATA_CACHE_PATH.exists():
            MODULE_METADATA_CACHE_PATH.unlink()
            print(f"   Removed {MODULE_METADATA_CACHE_PATH}")
        else:
            print(f"   Cache file not found: {MODULE_METADATA_CACHE_PATH}")
        print("   Note: Bootstrap from .inc files still enabled. Use --help for details.")

    bootstrap_metadata_cache(output_dir)
    load_ls_remote_cache()

    try:
        # Phase 1: Discovery
        modules = discover_modules(source_dir, args.gomodcache)

        discovered_keys = {(m['module_path'], m['version']) for m in modules}
        go_sum_modules = parse_go_sum(source_dir / "go.sum")

        print(f"\nResolving {len(go_sum_modules - discovered_keys)} additional modules from go.sum...")

        # Build index of discovered modules by module_path for fallback lookups
        modules_by_path = {}
        for m in modules:
            path = m['module_path']
            if path not in modules_by_path:
                modules_by_path[path] = []
            modules_by_path[path].append(m)

        for module_path, version in sorted(go_sum_modules):
            if (module_path, version) in discovered_keys:
                continue

            # Try to resolve module metadata
            fallback = resolve_module_metadata(module_path, version)
            if fallback:
                modules.append(fallback)
                discovered_keys.add((module_path, version))
                # Also add to index for future fallbacks
                if module_path not in modules_by_path:
                    modules_by_path[module_path] = []
                modules_by_path[module_path].append(fallback)
            else:
                # If resolution failed, try to use VCS info from another version of same module
                if module_path in modules_by_path:
                    # Found other versions of this module - use their VCS URL
                    reference_module = modules_by_path[module_path][0]
                    vcs_url = reference_module['vcs_url']

                    # Try to resolve using known VCS URL
                    tag = version.split('+')[0]
                    commit = None

                    # Check if this is a pseudo-version with short commit
                    pseudo_match = re.match(r'v\d+\.\d+\.\d+-(\d{14})-([0-9a-fA-F]+)', tag)

                    if pseudo_match:
                        # Pseudo-version with short commit - need to clone and search
                        timestamp_str = pseudo_match.group(1)
                        short_commit = pseudo_match.group(2)

                        # Use clone cache directory
                        clone_cache_dir = Path.home() / '.cache' / 'oe-go-mod-fetcher' / 'repos'

                        commit = resolve_pseudo_version_commit(
                            vcs_url,
                            timestamp_str,
                            short_commit,
                            clone_cache_dir=clone_cache_dir
                        )

                        if commit:
                            print(f"  ✓ {module_path}@{version} (resolved pseudo-version via repository clone)")
                    else:
                        # Regular tagged version - use git ls-remote
                        commit = git_ls_remote(vcs_url, f"refs/tags/{tag}") or git_ls_remote(vcs_url, tag)

                        if commit:
                            print(f"  ✓ {module_path}@{version} (resolved using VCS URL from sibling version)")

                    if commit:
                        # Successfully resolved!
                        timestamp = derive_timestamp_from_version(version)
                        subdir = reference_module.get('subdir', '')

                        update_metadata_cache(module_path, version, vcs_url, commit, timestamp, subdir, dirty=True)

                        fallback = {
                            "module_path": module_path,
                            "version": version,
                            "vcs_url": vcs_url,
                            "vcs_hash": commit,
                            "vcs_ref": "",
                            "timestamp": timestamp,
                            "subdir": subdir,
                        }
                        modules.append(fallback)
                        discovered_keys.add((module_path, version))
                        modules_by_path[module_path].append(fallback)
                        continue

                # Module couldn't be resolved - likely an indirect-only dependency
                # that only needs go.mod file (no source code)
                print(f"  ⚠️  Skipping {module_path}@{version} (indirect-only dependency)")
                continue

        if not modules:
            print("❌ No modules discovered")
            exit_code = 1
        else:
            # Phase 2: Recipe Generation
            success = generate_recipe(
                modules,
                source_dir,
                output_dir,
                args.git_repo or "unknown",
                args.git_ref or "unknown"
            )

            if success:
                print("\n" + "=" * 70)
                print("✅ SUCCESS - Recipe generation complete")
                print("=" * 70)
                exit_code = 0
            else:
                print("\n❌ FAILED - Recipe generation failed")
                exit_code = 1

    except KeyboardInterrupt:
        print("\n\nOperation cancelled by user")
        exit_code = 1
    except Exception as e:
        print(f"\n❌ Unexpected error: {e}")
        if args.verbose:
            import traceback
            traceback.print_exc()
        exit_code = 1
    finally:
        save_ls_remote_cache()
        save_metadata_cache()

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
