#!/usr/bin/env python3

"""
Go Module Git Fetcher
Version 2.3.15 - Add extensive debugging to relocation script
Author: AI Assistant
Description: Fetch Git repositories for Go modules and checkout exact revisions
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
import time
from contextlib import ExitStack, contextmanager
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Set

VERSION = "2.3.15"

DIRHASH_REPO_URL = "https://go.googlesource.com/mod"
DIRHASH_REPO_COMMIT = "f8a9fe217cff893cb67f4acad96a0021c13ee6e7"
DIRHASH_HELPER_SOURCE = """package main\n\nimport (\n    \"fmt\"\n    \"os\"\n\n    \"golang.org/x/mod/sumdb/dirhash\"\n)\n\nfunc main() {\n    if len(os.Args) != 2 {\n        fmt.Fprintf(os.Stderr, \"Usage: %s <zip-file>\\n\", os.Args[0])\n        os.Exit(1)\n    }\n\n    zipPath := os.Args[1]\n    hash, err := dirhash.HashZip(zipPath, dirhash.DefaultHash)\n    if err != nil {\n        fmt.Fprintf(os.Stderr, \"Error: %v\\n\", err)\n        os.Exit(1)\n    }\n\n    fmt.Println(hash)\n}\n"""


class GoModuleFetcher:
    def __init__(self, output_dir: str = "modules", vendor_dir: Optional[str] = None, 
                 generate_oe_files: bool = False, include_indirect: bool = False,
                 vendor_like: bool = False, gomod_cache: Optional[str] = None,
                 generate_gomodgit: bool = False,
                 git_timeout: int = 120, git_retries: int = 3):
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(exist_ok=True)
        
        self.vendor_dir = None
        if vendor_dir:
            self.vendor_dir = Path(vendor_dir)
            self.vendor_dir.mkdir(exist_ok=True)
            
        self.cache_root = None
        self.gomod_cache = None
        self.repo_cache_dir = None
        if gomod_cache:
            cache_root = Path(gomod_cache).expanduser().resolve()
            cache_root.mkdir(parents=True, exist_ok=True)
            self.cache_root = cache_root
            self.gomod_cache = cache_root
            self.repo_cache_dir = cache_root / 'repos'
            self.repo_cache_dir.mkdir(parents=True, exist_ok=True)

        self.generate_oe_files = generate_oe_files
        self.generate_gomodgit = generate_gomodgit
        self.include_indirect = include_indirect
        self.vendor_like = vendor_like
        self.oe_src_uris = []
        self.oe_modules = []
        self.temp_dir = None
        self.dirhash_helper_tempdir = None
        self.git_timeout = max(1, int(git_timeout))
        self.git_retries = max(1, int(git_retries))
        self._last_git_error = None
        
        # Track processed modules to avoid duplicates
        self.processed_modules = set()
        
        # Store detailed go.mod parsing results
        self.direct_deps = {}      # module_path -> version (explicit in modules.txt)
        self.indirect_deps = {}    # module_path -> version  
        self.replace_directives = {}  # module_path -> replacement_path
        
        # Performance optimization: cache package discovery results
        self.package_cache = {}    # repo_dir -> packages
        self.vendor_packages = {}  # module_path -> [packages] from vendor/modules.txt parsing
        
        # Check for rsync availability
        self.has_rsync = self._check_rsync_available()

        # Ensure repo lock directory exists for cross-process coordination
        self.repo_lock_root = Path.home() / ".cache" / "oe-go-mod-fetcher" / "locks"
        self.repo_lock_root.mkdir(parents=True, exist_ok=True)

    def _check_rsync_available(self) -> bool:
        """Check if rsync is available for faster copying."""
        try:
            subprocess.run(["rsync", "--version"], check=True, capture_output=True)
            return True
        except (subprocess.CalledProcessError, FileNotFoundError):
            return False

    def _clear_git_index_lock(self, cwd: Optional[Path]) -> None:
        """Remove a stale git index.lock if present."""
        if not cwd:
            return

        try:
            repo_path = Path(cwd)
            lock_path = repo_path / ".git" / "index.lock"
            if lock_path.exists():
                lock_path.unlink()
                print(f"    🧹 Removed stale git index.lock at {lock_path}")
        except Exception as exc:  # pragma: no cover - best effort cleanup
            print(f"    ⚠️  Could not remove git index.lock: {exc}")

    def _ensure_clean_worktree(self, repo_dir: Path) -> bool:
        """Reset and clean the repository so checkouts cannot fail."""
        if not repo_dir or not repo_dir.exists():
            return True

        commands = [
            (["git", "reset", "--hard", "HEAD"], "git reset --hard HEAD"),
            (["git", "clean", "-fdx"], "git clean -fdx"),
        ]

        for command, description in commands:
            result = self._run_git_command_with_retry(
                command,
                cwd=repo_dir,
                description=description,
                retries=1,
            )
            if result is None:
                return False
        return True

    @contextmanager
    def _acquire_repo_lock(self, lock_id: str):
        """Serialize access to a cached repository across processes."""
        lock_path = self.repo_lock_root / lock_id
        acquired = False
        try:
            while not acquired:
                try:
                    lock_path.mkdir()
                    acquired = True
                except FileExistsError:
                    try:
                        if (time.time() - lock_path.stat().st_mtime) > 900:
                            lock_path.rmdir()
                            continue
                    except FileNotFoundError:
                        continue
                    time.sleep(0.2)
            yield
        finally:
            if acquired:
                try:
                    lock_path.rmdir()
                except OSError:
                    pass

    def _run_git_command_with_retry(
        self,
        command: List[str],
        cwd: Optional[Path] = None,
        cleanup: Optional[Path] = None,
        description: Optional[str] = None,
        timeout: Optional[int] = None,
        retries: Optional[int] = None,
    ) -> Optional[subprocess.CompletedProcess]:
        """Run a git command with timeout handling and automatic retries."""

        attempts = max(1, int(retries) if retries is not None else self.git_retries)
        timeout_sec = max(1, int(timeout) if timeout is not None else self.git_timeout)
        self._last_git_error = None

        if description:
            friendly_desc = description
        elif command and command[0] == "git":
            friendly_desc = f"git {' '.join(command[1:])}".strip()
        else:
            friendly_desc = " ".join(command)

        cleanup_path = Path(cleanup) if cleanup else None
        last_error = ""

        for attempt in range(1, attempts + 1):
            if command and command[0] == "git":
                self._clear_git_index_lock(cwd)
            try:
                result = subprocess.run(
                    command,
                    cwd=cwd,
                    capture_output=True,
                    text=True,
                    timeout=timeout_sec,
                )
                if result.returncode == 0:
                    return result
                last_error = result.stderr.strip() or result.stdout.strip() or f"exit code {result.returncode}"
                if "index.lock" in last_error:
                    self._clear_git_index_lock(cwd)
            except KeyboardInterrupt:
                if cleanup_path and cleanup_path.exists():
                    if cleanup_path.is_dir():
                        shutil.rmtree(cleanup_path, ignore_errors=True)
                    else:
                        try:
                            cleanup_path.unlink()
                        except FileNotFoundError:
                            pass
                raise
            except subprocess.TimeoutExpired:
                last_error = f"timed out after {timeout_sec} seconds"
                self._clear_git_index_lock(cwd)
            except OSError as exc:
                last_error = str(exc)

            if cleanup_path and cleanup_path.exists():
                if cleanup_path.is_dir():
                    shutil.rmtree(cleanup_path, ignore_errors=True)
                else:
                    try:
                        cleanup_path.unlink()
                    except FileNotFoundError:
                        pass

            if attempt < attempts:
                print(f"    🔁 Retrying {friendly_desc} ({attempt}/{attempts})...")
                time.sleep(min(5, attempt * 2))
                # Ensure stale index.lock is cleared before we retry
                self._clear_git_index_lock(cwd)

        print(f"    ⚠️  {friendly_desc} failed: {last_error}")
        self._last_git_error = last_error
        return None

    def _go_env(self, extra_env: Optional[Dict[str, str]] = None) -> Dict[str, str]:
        """Return environment for Go commands with optional overrides."""
        env = os.environ.copy()
        if self.gomod_cache and not (extra_env and 'GOMODCACHE' in extra_env):
            env['GOMODCACHE'] = str(self.gomod_cache)
        if extra_env:
            for key, value in extra_env.items():
                env[key] = str(value)
        return env

    def cleanup_temp_files(self):
        """Clean up temporary files."""
        if self.temp_dir and self.temp_dir.exists():
            shutil.rmtree(self.temp_dir)
            self.temp_dir = None
        if self.dirhash_helper_tempdir and self.dirhash_helper_tempdir.exists():
            shutil.rmtree(self.dirhash_helper_tempdir)
            self.dirhash_helper_tempdir = None

    def get_dirhash_helper(self) -> Path:
        """Locate the dirhash helper binary on the host."""
        if hasattr(self, '_dirhash_helper'):
            return self._dirhash_helper

        candidates = []

        helper_env = os.environ.get('DIRHASH_HELPER')
        if helper_env:
            candidates.append(Path(helper_env))

        staging_bindir = os.environ.get('STAGING_BINDIR_NATIVE')
        if staging_bindir:
            candidates.append(Path(staging_bindir) / 'dirhash')

        resolved = shutil.which('dirhash')
        if resolved:
            candidates.append(Path(resolved))

        for candidate in candidates:
            if candidate and candidate.exists():
                self._dirhash_helper = candidate
                return candidate
        helper = self._build_dirhash_helper()
        self._dirhash_helper = helper
        return helper

    def _build_dirhash_helper(self) -> Path:
        """Compile a dirhash helper locally when none is provided."""
        go_binary = shutil.which('go')
        if not go_binary:
            raise FileNotFoundError(
                "Go toolchain not found in PATH. Install Go to build the dirhash helper or "
                "set DIRHASH_HELPER to an existing binary."
            )

        print("    🔧 Building temporary dirhash helper (host-side)...")

        temp_root = Path(tempfile.mkdtemp(prefix="dirhash-helper-"))
        self.dirhash_helper_tempdir = temp_root

        gopath = temp_root / "gopath"
        helper_src_dir = gopath / "src" / "dirhash-helper"
        helper_src_dir.mkdir(parents=True, exist_ok=True)
        helper_main = helper_src_dir / "main.go"
        helper_main.write_text(DIRHASH_HELPER_SOURCE)

        mod_dest = gopath / "src" / "golang.org" / "x" / "mod"
        mod_dest.parent.mkdir(parents=True, exist_ok=True)

        clone_result = self._run_git_command_with_retry(
            ["git", "clone", DIRHASH_REPO_URL, str(mod_dest)],
            cleanup=mod_dest,
            description=f"git clone {DIRHASH_REPO_URL}"
        )
        if not clone_result:
            raise RuntimeError(
                "Unable to prepare golang.org/x/mod sources for dirhash helper: "
                f"{self._last_git_error or 'git clone failed'}"
            )

        checkout_result = self._run_git_command_with_retry(
            ["git", "checkout", DIRHASH_REPO_COMMIT],
            cwd=mod_dest,
            description=f"git checkout {DIRHASH_REPO_COMMIT}",
            retries=1
        )
        if not checkout_result:
            raise RuntimeError(
                "Unable to prepare golang.org/x/mod sources for dirhash helper: "
                f"{self._last_git_error or 'git checkout failed'}"
            )

        env = os.environ.copy()
        env.update({
            "GOPATH": str(gopath),
            "GO111MODULE": "off",
            "GOCACHE": str(temp_root / "gocache"),
            "GOMODCACHE": str(temp_root / "gomodcache"),
        })

        try:
            subprocess.run(
                [go_binary, "build", "-o", str(helper_src_dir / "dirhash"), "."],
                cwd=helper_src_dir,
                check=True,
                capture_output=True,
                text=True,
                env=env
            )
        except subprocess.CalledProcessError as exc:
            raise RuntimeError(
                f"Failed to build dirhash helper: {exc.stderr or exc.stdout}"
            ) from exc

        helper_binary = helper_src_dir / "dirhash"
        if not helper_binary.exists():
            raise RuntimeError("dirhash helper build did not produce an executable")

        print(f"    ✅ dirhash helper built at {helper_binary}")
        return helper_binary

    def fetch_go_mod_from_git(self, repo_url: str, ref: str, go_mod_path: str = "go.mod") -> str:
        """Fetch go.mod file from a Git repository at a specific ref."""
        print(f"📦 Fetching go.mod from {repo_url} at {ref}")
        
        # Create temporary directory for the repo
        self.temp_dir = Path(tempfile.mkdtemp(prefix="go_mod_fetcher_"))
        repo_dir = self.temp_dir / "source_repo"
        
        try:
            if repo_dir.exists():
                shutil.rmtree(repo_dir, ignore_errors=True)

            # Clone the repository
            print(f"    Cloning repository...")
            # For commit hashes, we need a full clone to access arbitrary commits
            if len(ref) == 40 and all(c in '0123456789abcdef' for c in ref.lower()):
                clone_result = self._run_git_command_with_retry(
                    ["git", "clone", repo_url, str(repo_dir)],
                    cleanup=repo_dir,
                    description=f"git clone {repo_url}"
                )
            else:
                # Shallow clone for branches/tags
                clone_result = self._run_git_command_with_retry(
                    ["git", "clone", "--depth", "1", repo_url, str(repo_dir)],
                    cleanup=repo_dir,
                    description=f"git clone --depth 1 {repo_url}"
                )

            if not clone_result:
                raise RuntimeError(f"Failed to clone repository: {self._last_git_error or 'unknown git error'}")

            # Checkout the specific ref
            print(f"    Checking out {ref}...")
            checkout_result = self._run_git_command_with_retry(
                ["git", "checkout", ref],
                cwd=repo_dir,
                description=f"git checkout {ref}",
                retries=1
            )
            if not checkout_result:
                # If checkout fails, try fetching first
                fetch_result = self._run_git_command_with_retry(
                    ["git", "fetch", "origin", ref],
                    cwd=repo_dir,
                    description=f"git fetch origin {ref}",
                    retries=1
                )
                if not fetch_result:
                    raise RuntimeError(f"Failed to fetch ref {ref}: {self._last_git_error or 'unknown git error'}")
                checkout_result = self._run_git_command_with_retry(
                    ["git", "checkout", ref],
                    cwd=repo_dir,
                    description=f"git checkout {ref}",
                    retries=1
                )
                if not checkout_result:
                    raise RuntimeError(f"Failed to checkout ref {ref}: {self._last_git_error or 'unknown git error'}")
            
            # Find the go.mod file
            go_mod_file = repo_dir / go_mod_path
            if not go_mod_file.exists():
                # Try to find go.mod in common locations
                possible_paths = [
                    repo_dir / "go.mod",
                    repo_dir / "src" / "go.mod",
                    repo_dir / "cmd" / "go.mod",
                ]
                
                # Search recursively for go.mod files
                for go_mod in repo_dir.rglob("go.mod"):
                    possible_paths.append(go_mod)
                
                # Use the first one found, preferring root directory
                for path in possible_paths:
                    if path.exists():
                        go_mod_file = path
                        break
                
                if not go_mod_file.exists():
                    raise FileNotFoundError(f"No go.mod file found in repository")
            
            # Get commit info for reference
            try:
                commit_hash = subprocess.run(
                    ["git", "rev-parse", "HEAD"],
                    cwd=repo_dir,
                    check=True,
                    capture_output=True,
                    text=True
                ).stdout.strip()
                
                commit_msg = subprocess.run(
                    ["git", "log", "-1", "--pretty=format:%s"],
                    cwd=repo_dir,
                    check=True,
                    capture_output=True,
                    text=True
                ).stdout.strip()
                
                print(f"    ✅ Found go.mod at {go_mod_file.relative_to(repo_dir)}")
                print(f"    📋 Commit: {commit_hash[:8]} - {commit_msg}")
                
            except subprocess.CalledProcessError:
                print(f"    ✅ Found go.mod at {go_mod_file.relative_to(repo_dir)}")
            
            return str(go_mod_file)
            
        except RuntimeError:
            raise
        except Exception as e:
            raise RuntimeError(f"Failed to fetch go.mod from Git repository: {e}")

    def validate_git_ref(self, repo_url: str, ref: str) -> bool:
        """Validate that a Git ref exists in the repository."""
        try:
            # For commit hashes, skip validation since ls-remote doesn't work with full hashes
            if len(ref) == 40 and all(c in '0123456789abcdef' for c in ref.lower()):
                return True
            
            # Use ls-remote to check if ref exists without cloning
            result = subprocess.run(
                ["git", "ls-remote", repo_url, ref],
                check=True,
                capture_output=True,
                text=True
            )
            return len(result.stdout.strip()) > 0
        except subprocess.CalledProcessError:
            # If ls-remote fails, the ref might still exist (e.g., short hash)
            # We'll let the actual clone operation handle the validation
            return True

    def parse_go_mod(self, go_mod_path: str) -> List[Tuple[str, str]]:
        """Parse go.mod file and extract dependencies."""
        modules = []
        
        try:
            with open(go_mod_path, 'r') as f:
                content = f.read()
        except FileNotFoundError:
            raise FileNotFoundError(f"go.mod file not found: {go_mod_path}")

        print(f"    📋 Parsing go.mod file: {go_mod_path}")
        print(f"    📊 File size: {len(content)} bytes")

        # Find require block
        in_require_block = False
        for line in content.split('\n'):
            line = line.strip()
            
            # Check if we're entering a require block
            if line.startswith('require ('):
                in_require_block = True
                continue
            elif line.startswith('require ') and not line.startswith('require ('):
                # Single line require
                parts = line.split()
                if len(parts) >= 3:
                    # Include indirect dependencies if requested
                    if self.include_indirect or '// indirect' not in line:
                        modules.append((parts[1], parts[2]))
                continue
            
            # Check if we're leaving a require block
            if in_require_block and line == ')':
                in_require_block = False
                continue
            
            # Parse modules in require block
            if in_require_block and line and not line.startswith('//'):
                # Remove inline comments
                line = line.split('//')[0].strip()
                if line:
                    parts = line.split()
                    if len(parts) >= 2:
                        # Include indirect dependencies if requested
                        full_line_with_comment = next(
                            (l for l in content.split('\n') if parts[0] in l and parts[1] in l), 
                            line
                        )
                        if self.include_indirect or '// indirect' not in full_line_with_comment:
                            modules.append((parts[0], parts[1]))

        print(f"    📊 Found {len(modules)} modules from go.mod parsing")
        return modules

    def use_go_list_for_dependencies(self, source_dir: Path, go_install_targets: List[str] = None) -> Dict[str, Dict[str, str]]:
        """
        Use 'go list' command for authoritative dependency resolution.
        This mirrors the EXACT approach used by go-mod-update-modules.bbclass.

        Returns dict with module info: {module_path: {'Version': version, 'Dir': dir, 'Module': module_info}}
        """
        print(f"🔍 Using 'go list' for authoritative dependency resolution (oe-core compatible)")

        # Create (or re-use) a GOMODCACHE directory
        with ExitStack() as stack:
            if self.gomod_cache:
                mod_cache_dir = str(self.gomod_cache)
                env = self._go_env()
            else:
                mod_cache_dir = stack.enter_context(tempfile.TemporaryDirectory(prefix='go-mod-'))
                env = self._go_env({'GOMODCACHE': mod_cache_dir})

            try:
                # Step 1: Get module path using 'go mod edit -json' (line 52 in go-mod-update-modules.bbclass)
                print(f"    📋 Getting module path with 'go mod edit -json'")
                go_mod_output = subprocess.check_output(
                    ("go", "mod", "edit", "-json"),
                    cwd=source_dir, env=env, text=True, timeout=30
                )
                go_mod = json.loads(go_mod_output)
                module_path = go_mod['Module']['Path']
                print(f"    🎯 Module path: {module_path}")

                # Step 2: Use exact oe-core command (line 55 in go-mod-update-modules.bbclass)
                go_list_target = f"{module_path}/..."
                print(f"    📦 Running go list with target: {go_list_target}")
                print(f"    📁 Using GOMODCACHE: {mod_cache_dir}")

                output = subprocess.check_output(
                    ("go", "list", "-json=Dir,Module", "-deps", go_list_target),
                    cwd=source_dir, env=env, text=True, timeout=300
                )

                print(f"    ✅ Go list completed successfully")

                # Parse the JSON output - it's multiple JSON objects, not an array
                # Convert to proper JSON array format (lines 64-68 in go-mod-update-modules.bbclass)
                json_output = '[' + output.replace('}\n{', '},\n{') + ']'
                pkgs = json.loads(json_output)

                print(f"    📊 Found {len(pkgs)} packages from go list")

                # Extract unique modules with their information
                modules_info = {}
                for pkg in pkgs:
                    if 'Module' not in pkg:
                        continue

                    module_info = pkg['Module']
                    module_path = module_info['Path']

                    if module_path not in modules_info:
                        modules_info[module_path] = {
                            'Version': module_info.get('Version', 'v0.0.0'),
                            'Dir': module_info.get('Dir', ''),
                            'Module': module_info
                        }

                print(f"    🎯 Identified {len(modules_info)} unique modules")
                return modules_info

            except subprocess.CalledProcessError as e:
                print(f"    ❌ Go command failed: {e}")
                print(f"    📝 Make sure go.mod and go.sum are valid in {source_dir}")
                return {}
            except json.JSONDecodeError as e:
                print(f"    ❌ Failed to parse JSON output: {e}")
                return {}
            except Exception as e:
                print(f"    ❌ Unexpected error in go list: {e}")
                return {}

    def parse_go_mod_detailed(self, go_mod_path: str) -> Tuple[Dict[str, str], Dict[str, str], Dict[str, str]]:
        """
        Parse go.mod file and extract detailed dependency information.
        Returns: (direct_deps, indirect_deps, replace_directives)
        """
        direct_deps = {}      # module_path -> version
        indirect_deps = {}    # module_path -> version  
        replace_directives = {}  # module_path -> replacement_path
        
        try:
            with open(go_mod_path, 'r') as f:
                content = f.read()
        except FileNotFoundError:
            raise FileNotFoundError(f"go.mod file not found: {go_mod_path}")

        print(f"    🔍 Detailed parsing of go.mod: {go_mod_path}")

        in_require_block = False
        
        for line in content.split('\n'):
            original_line = line
            line = line.strip()
            
            # Parse replace directives
            if line.startswith('replace '):
                parts = line.split()
                if len(parts) >= 4 and '=>' in parts:
                    try:
                        arrow_idx = parts.index('=>')
                        if arrow_idx > 1:
                            module_path = parts[1]
                            replacement = ' '.join(parts[arrow_idx + 1:])
                            replace_directives[module_path] = replacement
                            print(f"    🔄 Replace: {module_path} => {replacement}")
                    except (ValueError, IndexError):
                        continue
                continue
            
            # Check if we're entering a require block
            if line.startswith('require ('):
                in_require_block = True
                continue
            elif line.startswith('require ') and not line.startswith('require ('):
                # Single line require
                parts = line.split()
                if len(parts) >= 3:
                    module_path, version = parts[1], parts[2]
                    if '// indirect' in original_line:
                        indirect_deps[module_path] = version
                    else:
                        direct_deps[module_path] = version
                continue
            
            # Check if we're leaving a require block
            if in_require_block and line == ')':
                in_require_block = False
                continue
            
            # Parse modules in require block
            if in_require_block and line and not line.startswith('//'):
                # Check if this line has indirect comment
                is_indirect = '// indirect' in original_line
                
                # Remove inline comments to get clean module info
                clean_line = line.split('//')[0].strip()
                if clean_line:
                    parts = clean_line.split()
                    if len(parts) >= 2:
                        module_path, version = parts[0], parts[1]
                        if is_indirect:
                            indirect_deps[module_path] = version
                        else:
                            direct_deps[module_path] = version

        print(f"    📊 Found {len(direct_deps)} direct, {len(indirect_deps)} indirect, {len(replace_directives)} replaced")
        return direct_deps, indirect_deps, replace_directives

    def get_vendor_like_dependencies(self, go_mod_path: str) -> List[Tuple[str, str]]:
        """Get dependencies using a hybrid approach for maximum accuracy."""
        print("    🔍 Discovering vendor-like dependencies (hybrid approach)...")

        # Get the directory containing go.mod
        go_mod_dir = Path(go_mod_path).parent
        print(f"    📁 Working directory: {go_mod_dir}")

        self.vendor_module_info = {}

        try:
            # First, ensure dependencies are downloaded
            print("    📥 Downloading dependencies...")
            download_result = subprocess.run(
                ["go", "mod", "download"],
                cwd=go_mod_dir,
                capture_output=True,
                text=True,
                timeout=300,
                env=self._go_env()
            )
            
            if download_result.returncode != 0:
                print(f"    ⚠️  go mod download had issues: {download_result.stderr}")

            # Method 3: Use go mod vendor to get authoritative dependencies
            print("    📦 Method 3: Using 'go mod vendor' for authoritative list...")
            modules_from_vendor = set()
            
            try:
                # Create a temporary vendor directory to avoid affecting the source
                import tempfile
                with tempfile.TemporaryDirectory() as temp_dir:
                    temp_go_mod_dir = Path(temp_dir) / "temp_repo"
                    temp_go_mod_dir.mkdir()
                    
                    # Copy go.mod and go.sum to temp directory
                    import shutil
                    shutil.copy2(go_mod_dir / "go.mod", temp_go_mod_dir / "go.mod")
                    if (go_mod_dir / "go.sum").exists():
                        shutil.copy2(go_mod_dir / "go.sum", temp_go_mod_dir / "go.sum")

                    # Handle local replace directives
                    for module, replacement in self.replace_directives.items():
                        parts = replacement.split()
                        if len(parts) == 1 and parts[0].startswith('./'):
                            local_path = parts[0]
                            print(f"    🔄 Handling local replace: {module} => {local_path}")
                            source_path = go_mod_dir / local_path
                            dest_path = temp_go_mod_dir / local_path
                            if source_path.exists() and source_path.is_dir():
                                print(f"    📂 Copying {source_path} to {dest_path}")
                                shutil.copytree(source_path, dest_path, dirs_exist_ok=True)
                            else:
                                print(f"    ⚠️  Warning: Local path for replace directive not found: {source_path}")

                    # Copy source code directories needed for go mod vendor to analyze imports
                    source_dirs = ['cmd', 'pkg', 'internal']  # Common Go source directories
                    for source_dir_name in source_dirs:
                        source_path = go_mod_dir / source_dir_name
                        if source_path.exists() and source_path.is_dir():
                            dest_path = temp_go_mod_dir / source_dir_name
                            print(f"    📂 Copying source directory {source_path} to {dest_path}")
                            shutil.copytree(source_path, dest_path, dirs_exist_ok=True)

                    # Run go mod vendor in temp directory
                    vendor_result = subprocess.run(
                        ["go", "mod", "vendor"],
                        cwd=temp_go_mod_dir,
                        capture_output=True,
                        text=True,
                        timeout=300,
                        env=self._go_env()
                    )

                    if vendor_result.returncode == 0:
                        # Parse the generated modules.txt
                        vendor_modules_txt = temp_go_mod_dir / "vendor" / "modules.txt"
                        if vendor_modules_txt.exists():
                            print( f"copying modules.txt from {temp_go_mod_dir}/vendor" )
                            # Copy the authoritative modules.txt to the current directory
                            current_dir_modules_txt = Path("modules.txt")
                            print(f"    ✍️ Copying modules.txt to {current_dir_modules_txt.absolute()}")
                            try:
                                shutil.copy2(vendor_modules_txt, current_dir_modules_txt)
                                print(f"    ✅ modules.txt copied successfully")
                            except Exception as copy_error:
                                print(f"    ❌ Failed to copy modules.txt: {copy_error}")
                                raise RuntimeError(f"Critical: Could not copy modules.txt to working directory: {copy_error}")

                            # Store vendor directory for later comparison in detect_missing_overrides
                            # Copy the entire vendor directory to preserve it beyond the temp context
                            if hasattr(self, 'args') and getattr(self.args, 'detect_missing_overrides', False):
                                vendor_backup_dir = Path("vendor_reference")
                                if vendor_backup_dir.exists():
                                    shutil.rmtree(vendor_backup_dir)
                                shutil.copytree(temp_go_mod_dir / "vendor", vendor_backup_dir)
                                self.vendor_reference_dir = vendor_backup_dir
                                print(f"    📂 Preserved vendor reference for override detection: {vendor_backup_dir}")

                            # Parse vendor/modules.txt to get modules AND their packages
                            current_module = None
                            current_packages = []
                            is_explicit = False

                            with open(vendor_modules_txt, 'r') as f:
                                for line in f:
                                    line = line.strip()
                                    if line.startswith('# ') and ' ' in line:
                                        # Save previous module's packages
                                        if current_module:
                                            self.vendor_packages[current_module[0]] = current_packages
                                            self.vendor_module_info[current_module[0]] = {'explicit': is_explicit, 'version': current_module[1]}

                                        # Extract module and version from "# module version" format
                                        parts = line[2:].split()
                                        if len(parts) >= 2:
                                            module_path, version = parts[0], parts[1]
                                            current_module = (module_path, version)
                                            current_packages = []
                                            is_explicit = False
                                            modules_from_vendor.add((module_path, version))
                                    elif line.startswith('## explicit'):
                                        is_explicit = True
                                    elif line and not line.startswith('##') and current_module:
                                        # This is a package line for the current module
                                        current_packages.append(line)

                                # Don't forget the last module
                                if current_module:
                                    self.vendor_packages[current_module[0]] = current_packages
                                    self.vendor_module_info[current_module[0]] = {'explicit': is_explicit, 'version': current_module[1]}

                        print(f"    📦 Found {len(modules_from_vendor)} modules from go mod vendor")
                    else:
                        print(f"    ❌ go mod vendor failed: {vendor_result.stderr}")
                        raise RuntimeError(f"go mod vendor failed: {vendor_result.stderr}")

            except Exception as e:
                print(f"    ❌ go mod vendor method failed: {e}")
                raise e

            modules = list(modules_from_vendor)
            
            return modules

        except Exception as e:
            print(f"    ⚠️  Error in hybrid analysis: {e}")
            print("    ➡️  Falling back to basic go.mod parsing...")
            return self.parse_go_mod(go_mod_path)

    def get_all_dependencies(self, go_mod_path: str) -> List[Tuple[str, str]]:
        """Get all dependencies including transitives using go list."""
        print("    🔍 Discovering all dependencies (including transitive)...")
        
        # Get the directory containing go.mod
        go_mod_dir = Path(go_mod_path).parent
        print(f"    📁 Working directory: {go_mod_dir}")
        
        # First, ensure dependencies are downloaded
        print("    📥 Downloading dependencies...")
        try:
            download_result = subprocess.run(
                ["go", "mod", "download"],
                cwd=go_mod_dir,
                capture_output=True,
                text=True,
                timeout=300,
                env=self._go_env()
            )
            if download_result.returncode == 0:
                print("    ✅ Dependencies downloaded successfully")
            else:
                print(f"    ⚠️  go mod download had issues: {download_result.stderr}")
        except Exception as e:
            print(f"    ⚠️  go mod download error: {e}")
        
        modules = []
        
        # Use go list -m all
        try:
            print("    📊 Using 'go list -m all'")
            result = subprocess.run(
                ["go", "list", "-m", "all"],
                cwd=go_mod_dir,
                check=True,
                capture_output=True,
                text=True,
                timeout=120,
                env=self._go_env()
            )
            
            for line in result.stdout.strip().split('\n'):
                line = line.strip()
                if line and ' ' in line:
                    parts = line.split()
                    if len(parts) >= 2:
                        module_path, version = parts[0], parts[1]
                        # Skip the main module
                        if version and version != '(main)' and not line.endswith('(main)'):
                            modules.append((module_path, version))
            
            print(f"    📊 Found {len(modules)} modules with 'go list -m all'")
            
        except Exception as e:
            print(f"    ⚠️  'go list -m all' failed: {e}")
        
        # Remove duplicates while preserving order
        unique_modules = []
        seen = set()
        for module_path, version in modules:
            key = (module_path, version)
            if key not in seen:
                seen.add(key)
                unique_modules.append((module_path, version))
        
        print(f"    ✅ Final count: {len(unique_modules)} unique dependencies")
        
        return unique_modules

    def get_module_download_info(self, module_path: str, version: str) -> Optional[Dict]:
        """Get module download information including VCS details."""
        module_version = f"{module_path}@{version}"
        
        try:
            # First, download the module
            subprocess.run(
                ["go", "mod", "download", module_version],
                check=True,
                capture_output=True,
                text=True,
                env=self._go_env()
            )
            
            # Get detailed module information
            result = subprocess.run(
                ["go", "mod", "download", "-json", module_version],
                check=True,
                capture_output=True,
                text=True,
                env=self._go_env()
            )
            
            return json.loads(result.stdout)
            
        except subprocess.CalledProcessError as e:
            print(f"    ❌ Error getting module info: {e}")
            return None
        except json.JSONDecodeError as e:
            print(f"    ❌ Error parsing module info JSON: {e}")
            return None

    def derive_repo_url(self, module_path: str) -> Optional[str]:
        """Derive repository URL from module path for common hosting platforms."""
        def strip_version_suffix(path: str) -> str:
            """Strip Go module version suffix (e.g., /v2, /v3, /v5) from module path."""
            return re.sub(r'/v\d+$', '', path)

        if module_path.startswith('github.com/'):
            # Strip version suffix for GitHub URLs (e.g., /v2, /v3, /v5)
            # github.com/godbus/dbus/v5 -> github.com/godbus/dbus
            clean_path = strip_version_suffix(module_path)
            return f"https://{clean_path}.git"
        elif module_path.startswith('gitlab.com/'):
            # Strip version suffix for GitLab URLs
            clean_path = strip_version_suffix(module_path)
            return f"https://{clean_path}.git"
        elif module_path.startswith('bitbucket.org/'):
            # Strip version suffix for Bitbucket URLs
            clean_path = strip_version_suffix(module_path)
            return f"https://{clean_path}.git"
        elif module_path.startswith('go.googlesource.com/'):
            return f"https://{module_path}"
        elif module_path.startswith('golang.org/x/'):
            # golang.org/x packages are hosted on go.googlesource.com
            package_name = module_path.replace('golang.org/x/', '')
            return f"https://go.googlesource.com/{package_name}"
        # Note: This is a fallback. The primary method uses 'go mod download' to get actual repository URLs.

        # If we can't derive it, return None
        return None

    def safe_module_name(self, module_path: str) -> str:
        """Convert module path to safe directory name."""
        return module_path.replace('/', '_').replace('\\', '_')

    def clone_or_update_repo(self, repo_url: str, repo_dir: Path) -> bool:
        """Clone repository or update if it already exists."""
        try:
            repo_dir.parent.mkdir(parents=True, exist_ok=True)
            if (repo_dir / '.git').exists():
                print("    Updating existing repository...")
                if not self._run_git_command_with_retry(
                    ["git", "fetch", "--all", "--tags"],
                    cwd=repo_dir,
                    description="git fetch --all --tags"
                ):
                    return False
            else:
                if repo_dir.exists():
                    print("    Removing incomplete repository checkout before cloning...")
                    shutil.rmtree(repo_dir, ignore_errors=True)
                print(f"    Cloning from {repo_url}...")
                # Start with a shallow clone to reduce transfer size
                clone_result = self._run_git_command_with_retry(
                    ["git", "clone", "--depth", "1", repo_url, str(repo_dir)],
                    cleanup=repo_dir,
                    description=f"git clone --depth 1 {repo_url}"
                )
                if not clone_result:
                    # If shallow clone fails, fall back to a full history clone
                    print("    Shallow clone failed, trying full history clone...")
                    clone_result = self._run_git_command_with_retry(
                        ["git", "clone", repo_url, str(repo_dir)],
                        cleanup=repo_dir,
                        description=f"git clone {repo_url}"
                    )
                    if not clone_result:
                        return False
            return True
            
        except subprocess.CalledProcessError as e:
            print(f"    ❌ Git operation failed: {e}")
            return False

    def _deepen_repository(self, repo_dir: Path) -> bool:
        """Ensure a shallow clone has enough history for the required revision."""
        try:
            depth_check = subprocess.run(
                ["git", "rev-parse", "--is-shallow-repository"],
                cwd=repo_dir,
                capture_output=True,
                text=True,
                check=True,
            )
        except subprocess.CalledProcessError:
            return False

        if depth_check.stdout.strip().lower() != "true":
            # Already have full history
            return True

        print("    Repository is shallow; fetching additional history for required revision...")

        # Try to upgrade the shallow clone; fall back to a full fetch if needed
        fetch_result = self._run_git_command_with_retry(
            ["git", "fetch", "--unshallow", "--tags"],
            cwd=repo_dir,
            description="git fetch --unshallow --tags",
        )

        if not fetch_result:
            print("    ⚠️  --unshallow failed; attempting full fetch to obtain commit history...")
            fetch_result = self._run_git_command_with_retry(
                ["git", "fetch", "--all", "--tags"],
                cwd=repo_dir,
                description="git fetch --all --tags",
            )
            if not fetch_result:
                return False

        # Confirm repository is no longer shallow
        try:
            depth_check = subprocess.run(
                ["git", "rev-parse", "--is-shallow-repository"],
                cwd=repo_dir,
                capture_output=True,
                text=True,
                check=True,
            )
        except subprocess.CalledProcessError:
            return True

        return depth_check.stdout.strip().lower() != "true"

    def checkout_revision(self, repo_dir: Path, hash_val: str, ref: str, version: str) -> bool:
        """Checkout specific revision in the repository."""
        try:
            deepened_history = False

            def try_checkout(target: str) -> bool:
                try:
                    subprocess.run(
                        ["git", "checkout", target],
                        cwd=repo_dir,
                        check=True,
                        capture_output=True
                    )
                    return True
                except subprocess.CalledProcessError:
                    return False

            def ensure_deep_history() -> bool:
                nonlocal deepened_history
                if deepened_history:
                    return True
                deepened_history = self._deepen_repository(repo_dir)
                if not deepened_history:
                    print("    ⚠️  Failed to automatically deepen repository history")
                return deepened_history

            # Try hash first (most reliable)
            if hash_val:
                print(f"    Checking out commit {hash_val[:8]}...")
                if try_checkout(hash_val):
                    return True
                if ensure_deep_history() and try_checkout(hash_val):
                    return True
                print("    Hash checkout failed, trying alternatives...")

            # Try ref (tag or branch)
            if ref:
                print(f"    Checking out ref {ref}...")
                if try_checkout(ref):
                    return True
                if ensure_deep_history() and try_checkout(ref):
                    return True
                print("    Ref checkout failed, trying version tag...")

            # Try version as tag
            if version:
                possible_tags = [version]
                if not version.startswith('v'):
                    possible_tags.append(f"v{version}")
                else:
                    possible_tags.append(version[1:])

                for tag in possible_tags:
                    print(f"    Trying to checkout tag {tag}...")
                    if try_checkout(tag):
                        return True
                    if ensure_deep_history() and try_checkout(tag):
                        return True

            # FALLBACK: Try default branch when specific revisions fail
            print(f"    ⚠️  Could not checkout any specific revision (hash: {hash_val}, ref: {ref}, version: {version})")
            print("    🔄 Attempting fallback to default branch...")

            try:
                # First fetch all refs to ensure we have the latest info
                subprocess.run(
                    ["git", "fetch", "--all", "--tags"],
                    cwd=repo_dir,
                    check=True,
                    capture_output=True
                )

                # Try common default branch names
                default_branches = ['main', 'master', 'HEAD']
                for branch in default_branches:
                    try:
                        print(f"    Trying fallback to branch: {branch}")
                        subprocess.run(
                            ["git", "checkout", branch],
                            cwd=repo_dir,
                            check=True,
                            capture_output=True
                        )
                        print(f"    ✅ Fallback successful: using {branch} branch")
                        return True
                    except subprocess.CalledProcessError:
                        continue

                # If default branches fail, just stay on whatever we have
                print("    ⚠️  Could not checkout default branches, using current HEAD")
                return True  # Don't fail completely - use whatever we have

            except Exception as fallback_error:
                print(f"    ❌ Fallback also failed: {fallback_error}")
                print("    ⚠️  Using repository as-is to avoid complete failure")
                return True  # Don't fail completely - use whatever we have

        except Exception as e:
            print(f"    ❌ Checkout failed with error: {e}")
            return False

    def should_exclude_path(self, path: Path, base_path: Path) -> bool:
        """Determine if a path should be excluded from vendor copy (optimized)."""
        # Cache relative path calculation
        try:
            relative_path = path.relative_to(base_path)
        except ValueError:
            return True  # Path is outside base_path
        
        path_str = str(relative_path)
        
        # Quick checks for common exclusions (most frequent first)
        if path.is_file():
            name = path.name
            # Exclude test files and common non-source files
            if (name.endswith('_test.go') or name.endswith('.test') or 
                name.endswith('.md') or name.endswith('.txt') or
                name in ['go.sum', 'go.work', 'go.work.sum'] or
                (name.startswith('.') and name not in ['.go-version'])):
                return True
        
        # Check path components (use set for O(1) lookup)
        exclude_set = {
            '.git', '.github', '.gitignore', '.gitmodules', 'vendor', 'node_modules',
            'testdata', 'examples', 'example', '_examples', 'docs', 'doc',
            'test', 'tests', '.travis.yml', '.circleci', 'Makefile', 'makefile', 
            'Dockerfile', 'docker-compose.yml', 'README.md', 'readme.md', 
            'README.txt', 'CHANGELOG.md', 'CONTRIBUTING.md', 'LICENSE', 
            'COPYING', 'AUTHORS', 'CONTRIBUTORS', '.editorconfig', 
            '.golangci.yml', '.pre-commit-config.yaml'
        }
        
        # Check if any part of the path matches exclude patterns
        for part in relative_path.parts:
            if part in exclude_set or part.endswith('_test'):
                return True
        
        return False

    def calculate_directory_hash(self, dir_path: Path) -> str:
        """Calculate a hash of directory contents for change detection."""
        hash_md5 = hashlib.md5()
        
        # Get all relevant files sorted for consistent hashing
        files = []
        for item in dir_path.rglob('*'):
            if item.is_file() and not self.should_exclude_path(item, dir_path):
                files.append(item)
        
        files.sort()
        
        for file_path in files:
            try:
                # Add file path to hash
                hash_md5.update(str(file_path.relative_to(dir_path)).encode())
                
                # Add file modification time
                hash_md5.update(str(file_path.stat().st_mtime).encode())
                
                # For small files, add content hash
                if file_path.stat().st_size < 10000:  # 10KB
                    with open(file_path, 'rb') as f:
                        hash_md5.update(f.read())
                        
            except (OSError, PermissionError):
                continue
                
        return hash_md5.hexdigest()

    def is_copy_needed(self, source_dir: Path, dest_dir: Path, module_path: str) -> bool:
        """Check if copy is needed by comparing hashes."""
        if not dest_dir.exists():
            return True
            
        # Check if hash file exists
        hash_file = dest_dir / '.source_hash'
        if not hash_file.exists():
            return True
            
        try:
            # Read stored hash
            with open(hash_file, 'r') as f:
                stored_hash = f.read().strip()
                
            # Calculate current source hash
            current_hash = self.calculate_directory_hash(source_dir)
            
            if stored_hash != current_hash:
                print(f"    📋 Source changed for {module_path} (hash mismatch)")
                return True
            else:
                print(f"    ⚡ Skipping copy for {module_path} (unchanged)")
                return False
                
        except (OSError, IOError):
            return True

    def copy_source_to_vendor(self, repo_dir: Path, module_path: str) -> bool:
        """Copy source code from repository to vendor directory with optimized package mapping."""
        if not self.vendor_dir:
            return True  # No vendor directory specified, skip

        print(f"    📦 Processing vendor copy for {module_path}...")

        try:
            # Use cached package discovery (much faster than re-scanning)
            packages = self.discover_go_packages(repo_dir, module_path)
            
            if not packages:
                print(f"    ⚠️  No Go packages found in {module_path}")
                return True

            copied_count = 0
            skipped_count = 0

            for import_path, package_dir in packages.items():
                vendor_package_dir = self.vendor_dir / import_path

                # Skip if this package already exists and is unchanged
                if not self.is_package_copy_needed(package_dir, vendor_package_dir, import_path):
                    skipped_count += 1
                    continue

                # Remove existing vendor directory for this package
                if vendor_package_dir.exists():
                    shutil.rmtree(vendor_package_dir)

                # Create parent directories
                vendor_package_dir.parent.mkdir(parents=True, exist_ok=True)
                vendor_package_dir.mkdir(parents=True, exist_ok=True)

                # Copy package files (*.go, go.mod, LICENSE, etc.)
                self.copy_package_files(package_dir, vendor_package_dir)

                # Store hash for change detection
                source_hash = self.calculate_directory_hash(package_dir)
                with open(vendor_package_dir / '.source_hash', 'w') as f:
                    f.write(source_hash)

                copied_count += 1

            print(f"    ✅ Vendor copy: {copied_count} copied, {skipped_count} skipped")

            # Create/update modules.txt with the exact version from go.mod
            self.update_modules_txt(module_path, version)

            return True

        except Exception as e:
            print(f"    ❌ Failed to copy to vendor: {e}")
            return False

    def discover_go_packages(self, repo_dir: Path, module_path: str) -> Dict[str, Path]:
        """Discover Go packages with internal directory handling and caching."""
        # Use cache if available
        cache_key = str(repo_dir)
        if cache_key in self.package_cache:
            return self.package_cache[cache_key]
        
        print(f"    📂 Scanning packages in {module_path}... (caching enabled)")
        packages = {}

        for dir_path in repo_dir.rglob('*'):
            if not dir_path.is_dir() or self.should_exclude_path(dir_path, repo_dir):
                continue

            # Check for Go files
            go_files = list(dir_path.glob('*.go'))
            non_test_files = [f for f in go_files if not f.name.endswith('_test.go')]
            if not non_test_files:
                continue

            # Calculate relative path from repo root
            rel_path = dir_path.relative_to(repo_dir)

            # Handle internal directories that duplicate module path
            if rel_path == Path('.'):
                # Root package of the module
                import_path = module_path
            else:
                # Check for internal directory duplication
                rel_path_str = rel_path.as_posix()
                module_parts = module_path.split('/')

                # If the first directory matches the last part of the module path, skip it
                # Example: module "example.org/project/api" with internal "/api/" dir
                if module_parts and rel_path_str.startswith(module_parts[-1] + '/'):
                    # Skip the duplicated internal directory
                    adjusted_path = rel_path_str[len(module_parts[-1]) + 1:]  # +1 for the '/'
                    if adjusted_path:
                        import_path = f"{module_path}/{adjusted_path}"
                    else:
                        import_path = module_path
                else:
                    # Normal case: module_path + relative_path
                    import_path = f"{module_path}/{rel_path_str}"

            packages[import_path] = dir_path

        # Cache the results
        self.package_cache[cache_key] = packages
        print(f"    📦 Found {len(packages)} packages (cached for future use)")
        return packages

    def discover_packages_for_modules_txt(self, repo_dir: Path, module_path: str) -> List[str]:
        """
        Discover packages for a module. If vendor_like is enabled, use the package
        list from the main project's vendor/modules.txt, which is the most accurate method.
        """
        # If vendor-like analysis was done, we have the authoritative package list.
        if self.vendor_like and hasattr(self, 'vendor_packages') and self.vendor_packages:
            packages = self.vendor_packages.get(module_path)
            if packages is not None:
                print(f"    📦 Using {len(packages)} packages from 'go mod vendor' analysis for {module_path}")
                return sorted(packages)
            else:
                # This can happen if a module is in go.mod but no packages from it are actually used.
                # 'go mod vendor' omits such modules from modules.txt.
                print(f"    ℹ️  Module {module_path} not in vendor/modules.txt; assuming no packages are needed.")
                return []

        # Fallback for non-vendor-like mode. This is less accurate and not recommended for OE builds.
        print(f"    ⚠️  Warning: Not using --vendor-like. Falling back to 'go list' for {module_path}.")
        print(f"    📦 Discovering packages using 'go list .'... (less accurate)")

        packages = []
        try:
            # Run 'go list' in the module's repository directory.
            # Using './...' should list all packages within that module.
            result = subprocess.run(
                ["go", "list", "./..."],
                cwd=repo_dir,
                capture_output=True,
                text=True,
                check=True,
                env=self._go_env()
            )
            packages = result.stdout.strip().split('\n')
            
        except subprocess.CalledProcessError as e:
            print(f"    ❌ 'go list ./...' failed for {module_path}: {e.stderr}")
            print("    ➡️  Returning empty package list. The generated modules.txt will be incomplete.")
            return []

        if not packages:
            print(f"    ⚠️  'go list' did not find any packages for {module_path}.")
        
        print(f"    ✅ Found {len(packages)} packages for {module_path} via 'go list'")
        return sorted(packages)

    def parse_imports_from_source(self, repo_dir: Path, module_path: str) -> List[str]:
        """
        Parse Go source files to extract import statements and determine which packages
        from this module are actually imported. This is much more accurate than scanning
        all directories and matches what 'go mod vendor' actually needs.
        """
        imported_packages = set()
        
        # We need to find what packages from THIS module are imported by OTHER code
        # The tricky part is that we're analyzing the module itself to see what it provides
        
        # Strategy: Find all packages that actually contain importable Go code
        # (not test files, not internal tooling, not examples)
        
        for go_file in repo_dir.rglob("*.go"):
            # Skip test files, example files, and vendor directories
            if (go_file.name.endswith("_test.go") or 
                "vendor/" in str(go_file) or 
                "testdata/" in str(go_file) or
                "/examples/" in str(go_file) or
                "/example/" in str(go_file) or
                "_example" in str(go_file)):
                continue
                
            try:
                # Determine the import path for this Go file
                rel_path = go_file.parent.relative_to(repo_dir)
                if rel_path == Path("."):
                    # Root package
                    package_import = module_path
                else:
                    # Subpackage
                    package_import = f"{module_path}/{rel_path.as_posix()}"
                
                # Check if this file contains actual exportable code
                # (has package declaration and at least one exportable symbol)
                if self.has_exportable_code(go_file):
                    imported_packages.add(package_import)
                    
            except Exception as e:
                # Skip files we can't process
                continue
                
        return sorted(list(imported_packages))

    def get_repository_module(self, repo_dir: Path) -> str:
        """
        Read the repository's go.mod file to determine its declared module path.
        This is the authoritative source for where the repository should be placed in vendor.
        """
        go_mod_path = repo_dir / "go.mod"
        if not go_mod_path.exists():
            return None

        try:
            with open(go_mod_path, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    line = line.strip()
                    if line.startswith('module '):
                        # Extract module declaration such as "module example.org/project"
                        module_path = line[7:].strip()  # Remove "module " prefix
                        return module_path
        except Exception as e:
            print(f"    ⚠️  Error reading go.mod from {repo_dir}: {e}")

        return None

    def detect_submodule_relationships(self):
        """
        Generic submodule detection - analyzes all modules to find parent-child relationships
        without any hardcoded patterns. Returns a mapping of child -> parent relationships.
        """
        submodule_map = {}
        all_module_paths = [m['path'] for m in self.oe_modules if not m.get('is_stub', False)]

        for module_path in all_module_paths:
            # Find potential parent modules by checking if this module path
            # is a subpath of any other module path
            potential_parents = []

            for other_module_path in all_module_paths:
                if (module_path.startswith(other_module_path + '/') and
                    module_path != other_module_path):
                    potential_parents.append(other_module_path)

            # If we found potential parents, choose the longest one (most specific)
            if potential_parents:
                parent_module = max(potential_parents, key=len)
                subpath = module_path[len(parent_module + '/'):]
                submodule_map[module_path] = {
                    'parent': parent_module,
                    'subpath': subpath
                }
                print(f"    🔍 Generic detection: {module_path} is submodule of {parent_module} (subpath: {subpath})")

        return submodule_map

    def load_submodule_overrides(self):
        """
        Load submodule override configuration from override.conf
        Format: module_path = parent_repo,subpath
        """
        override_map = {}
        override_file = Path("override.conf")

        if override_file.exists():
            print(f"    📋 Loading submodule overrides from {override_file}")
            try:
                with open(override_file, 'r') as f:
                    for line_num, line in enumerate(f, 1):
                        line = line.strip()
                        if line and not line.startswith('#'):
                            if '=' in line:
                                module_path, override_spec = line.split('=', 1)
                                module_path = module_path.strip()
                                override_spec = override_spec.strip()

                                if ',' in override_spec:
                                    parent_repo, subpath = override_spec.split(',', 1)
                                    override_map[module_path] = {
                                        'parent': parent_repo.strip(),
                                        'subpath': subpath.strip()
                                    }
                                    print(f"    🔧 Override: {module_path} → parent: {parent_repo.strip()}, subpath: {subpath.strip()}")
                                else:
                                    print(f"    ⚠️  Invalid override format at line {line_num}: {line}")
            except Exception as e:
                print(f"    ⚠️  Error reading override.conf: {e}")
        else:
            print(f"    📋 No override.conf found - using generic detection only")

        return override_map

    def detect_missing_overrides(self, repo_groups, combined_submodules):
        """
        Phase 2: Compare against 'go mod vendor' reference to detect missing overrides.
        Identifies cases where generic detection fails and suggests override entries.
        """
        print("\n🔍 Phase 2: Dynamic failure detection - comparing against 'go mod vendor' reference...")

        # Check if we have a preserved vendor reference to compare against
        if not hasattr(self, 'vendor_reference_dir') or not self.vendor_reference_dir:
            print("    ⚠️  No vendor reference directory available for comparison")
            return

        reference_vendor = self.vendor_reference_dir
        if not reference_vendor.exists():
            print("    ⚠️  No 'go mod vendor' reference found - cannot compare")
            return

        print(f"    📂 Using reference: {reference_vendor}")

        # Parse modules.txt from go mod vendor
        reference_modules_txt = reference_vendor / "modules.txt"
        if not reference_modules_txt.exists():
            print("    ⚠️  Reference modules.txt not found")
            return

        # Load reference module structure
        reference_modules = self.parse_reference_modules_txt(reference_modules_txt)
        print(f"    📊 Reference contains {len(reference_modules)} module entries")

        # Compare our detection against reference
        missing_modules = []
        incorrect_structure = []

        for ref_module, ref_info in reference_modules.items():
            if ref_module not in [m['module_path'] for group in repo_groups.values() for m in group]:
                missing_modules.append(ref_module)
                continue

            # Check if our structure matches reference
            our_structure = self.get_our_module_structure(ref_module, repo_groups)
            if our_structure != ref_info.get('structure', 'unknown'):
                incorrect_structure.append({
                    'module': ref_module,
                    'expected': ref_info.get('structure', 'unknown'),
                    'detected': our_structure
                })

        # Report findings
        if missing_modules:
            print(f"    ❌ Missing modules: {len(missing_modules)}")
            for module in missing_modules[:5]:  # Show first 5
                print(f"        • {module}")
            if len(missing_modules) > 5:
                print(f"        ... and {len(missing_modules) - 5} more")

        if incorrect_structure:
            print(f"    ❌ Incorrect structure detection: {len(incorrect_structure)}")
            suggested_overrides = []
            for issue in incorrect_structure[:3]:  # Show first 3
                module = issue['module']
                expected = issue['expected']
                print(f"        • {module}: expected {expected}, got {issue['detected']}")

                # Try to suggest override entry
                suggestion = self.suggest_override_entry(module, expected, reference_modules)
                if suggestion:
                    suggested_overrides.append(suggestion)

            # Generate suggested override entries
            if suggested_overrides:
                print("\n    💡 Suggested override.conf entries:")
                for suggestion in suggested_overrides:
                    print(f"        {suggestion}")

        if not missing_modules and not incorrect_structure:
            print("    ✅ Structure detection matches 'go mod vendor' reference perfectly!")

    def parse_reference_modules_txt(self, modules_txt_path):
        """Parse the reference modules.txt from 'go mod vendor'."""
        modules = {}
        try:
            with open(modules_txt_path, 'r') as f:
                current_module = None
                for line in f:
                    line = line.strip()
                    if line.startswith('# '):
                        # Module declaration: "# github.com/example/module v1.0.0"
                        parts = line[2:].split()
                        if len(parts) >= 2:
                            current_module = parts[0]
                            version = parts[1]
                            modules[current_module] = {
                                'version': version,
                                'packages': [],
                                'structure': 'standalone'  # Default
                            }
                    elif line and not line.startswith('#') and current_module:
                        # Package path
                        modules[current_module]['packages'].append(line)

                        # Detect if this is a submodule based on package structure
                        if '/' in line and current_module in line:
                            # This package suggests a submodule relationship
                            modules[current_module]['structure'] = 'submodule'

        except Exception as e:
            print(f"    ⚠️  Error parsing reference modules.txt: {e}")

        return modules

    def get_our_module_structure(self, module_path, repo_groups):
        """Get our detected structure for a module."""
        for group_modules in repo_groups.values():
            for module_info in group_modules:
                if module_info['module_path'] == module_path:
                    if module_info['is_submodule']:
                        return 'submodule'
                    else:
                        return 'standalone'
        return 'unknown'

    def suggest_override_entry(self, module_path, expected_structure, reference_modules):
        """Suggest an override.conf entry for a failed detection."""
        if expected_structure != 'submodule':
            return None

        # Try to infer parent module and subpath
        # Look for modules that could be the parent
        potential_parents = []
        for ref_module in reference_modules.keys():
            if module_path.startswith(ref_module + '/') and ref_module != module_path:
                potential_parents.append(ref_module)

        if potential_parents:
            # Use the longest matching parent
            parent = max(potential_parents, key=len)
            subpath = module_path[len(parent + '/'):]
            return f"{module_path} = {parent},{subpath}"

        return None

    def analyze_vendor_reference_structure(self):
        """
        Analyze vendor reference structure comprehensively to determine ALL subdirectory mappings.
        Compare ALL packages in vendor reference with fetched modules to generate complete mappings.
        """
        print("\n🔍 Analyzing vendor reference structure for comprehensive subdirectory mappings...")

        vendor_mappings = {}

        # Look for reference vendor directory (created by go mod vendor)
        reference_vendor = Path("vendor_reference")
        if not reference_vendor.exists():
            print("    ⚠️  No vendor reference found - will use override.conf only")
            return vendor_mappings

        print(f"    📂 Found vendor reference at: {reference_vendor}")

        # COMPREHENSIVE APPROACH: Analyze ALL packages in vendor reference
        # Find all package directories in vendor reference
        all_vendor_packages = []
        for go_file in reference_vendor.rglob("*.go"):
            package_dir = go_file.parent
            package_path = str(package_dir.relative_to(reference_vendor))
            if package_path not in all_vendor_packages:
                all_vendor_packages.append(package_path)

        print(f"    📦 Found {len(all_vendor_packages)} packages in vendor reference")

        # Create mapping from fetched modules for quick lookup
        fetched_modules = {}
        for module_info in self.oe_modules:
            if not module_info.get('is_stub', False):
                fetched_modules[module_info['path']] = module_info['safe_name']

        # Analyze each vendor package to determine mapping requirements
        detected_mappings = {}

        for package_path in all_vendor_packages:
            # Find which module should provide this package
            providing_module = None

            # Look for exact module match first
            if package_path in fetched_modules:
                providing_module = package_path
            else:
                # Look for parent module that could provide this package
                package_parts = package_path.split('/')
                for i in range(len(package_parts), 0, -1):
                    candidate_module = '/'.join(package_parts[:i])
                    if candidate_module in fetched_modules:
                        providing_module = candidate_module
                        break

            if providing_module:
                # Check if this package needs a subdirectory mapping
                fetched_module_dir = Path("modules") / fetched_modules[providing_module]

                if providing_module != package_path:
                    # This is a subpackage - determine the subdirectory needed
                    subdir_path = package_path.replace(providing_module + '/', '', 1) if providing_module + '/' in package_path else package_path

                    # Check if the subdirectory exists in the fetched module
                    expected_subdir = fetched_module_dir / subdir_path
                    if not expected_subdir.exists():
                        # Look for alternative subdirectory structures
                        subdir_alternatives = self._find_subdir_alternatives(fetched_module_dir, subdir_path, package_path)
                        if subdir_alternatives:
                            subdir_path = subdir_alternatives

                    # CRITICAL FIX: Only create subdirectory mappings when subdirectory is missing or needs special handling
                    # Standard modules like golang.org/x/sys should be copied in their entirety without specific mappings
                    if subdir_path and subdir_path != package_path and not expected_subdir.exists():
                        key = f"{providing_module}:{subdir_path}"
                        if key not in detected_mappings:
                            detected_mappings[key] = {
                                'providing_module': providing_module,
                                'source_subdir': subdir_path,
                                'packages_served': [package_path],
                                'reason': f'Package {package_path} needs {subdir_path}/ subdirectory from {providing_module}'
                            }
                        else:
                            detected_mappings[key]['packages_served'].append(package_path)

        # Convert to final mappings format and add specific pattern detection
        for mapping_key, mapping_info in detected_mappings.items():
            providing_module = mapping_info['providing_module']
            source_subdir = mapping_info['source_subdir']

            # Add to vendor_mappings with enhanced detection
            vendor_mappings[providing_module] = {
                'source_subdir': source_subdir,
                'reason': mapping_info['reason'],
                'packages_count': len(mapping_info['packages_served']),
                'sample_packages': mapping_info['packages_served'][:3]  # First 3 as examples
            }


        print(f"    📋 Detected {len(vendor_mappings)} comprehensive vendor structure mappings")
        for module, mapping in vendor_mappings.items():
            print(f"      📦 {module} -> {mapping['source_subdir']}/ ({mapping['packages_count']} packages)")

        return vendor_mappings

    def _find_subdir_alternatives(self, fetched_module_dir, original_subdir, package_path):
        """Find a best-effort alternative subdirectory inside a fetched module."""
        if not original_subdir:
            return None

        # Return original path when it already exists on disk
        candidate = fetched_module_dir / original_subdir
        if candidate.exists():
            return original_subdir

        # Walk back through the requested path to find the deepest existing prefix
        segments = [segment for segment in original_subdir.split('/') if segment]
        for length in range(len(segments), 0, -1):
            prefix = fetched_module_dir.joinpath(*segments[:length])
            if prefix.exists():
                return '/'.join(segments[:length])

        # As a last resort, match any top-level directory name that appears in the request
        try:
            for child in fetched_module_dir.iterdir():
                if child.is_dir() and child.name in segments:
                    return child.name
        except FileNotFoundError:
            return None

        return None

    def analyze_repository_structure(self):
        """
        Analyze all downloaded modules to determine repository-based relocation strategy.
        Groups modules by their repository's declared module path.
        """
        repo_groups = {}  # module_path -> [list of modules]

        # First pass: detect submodule relationships using generic algorithm + overrides
        generic_submodules = self.detect_submodule_relationships()
        override_submodules = self.load_submodule_overrides()

        # Merge overrides with generic detection (overrides take precedence)
        combined_submodules = {**generic_submodules, **override_submodules}

        for module_info in self.oe_modules:
            module_path = module_info['path']
            safe_name = module_info['safe_name']
            is_stub = module_info.get('is_stub', False)

            if is_stub:
                # Stub modules don't have repositories to analyze
                continue

            repo_dir = self.output_dir / safe_name
            if not repo_dir.exists():
                print(f"    ⚠️  Repository directory not found for {module_path}: {repo_dir}")
                continue

            # Get the repository's declared module path
            repo_module = self.get_repository_module(repo_dir)
            if repo_module:
                print(f"    📂 Repository analysis: {module_path} → repo declares {repo_module}")

                # Use the repository's declared module as the grouping key
                grouping_key = repo_module
            else:
                print(f"    ⚠️  Could not determine repository module for {module_path}")
                # Fallback: treat as individual module
                grouping_key = module_path

            if grouping_key not in repo_groups:
                repo_groups[grouping_key] = []

            # Check if this module is a submodule using combined detection (generic + overrides)
            is_submodule = module_path in combined_submodules
            subpath = None
            if is_submodule:
                submodule_info = combined_submodules[module_path]
                subpath = submodule_info['subpath']
                source_type = "override" if module_path in override_submodules else "generic"
                print(f"    📁 {source_type.title()} submodule: {module_path} → subpath '{subpath}'")

            repo_groups[grouping_key].append({
                'module_path': module_path,
                'safe_name': safe_name,
                'repo_dir': repo_dir,
                'is_submodule': is_submodule,
                'subpath': subpath,
                'repo_module': repo_module  # Store for debugging
            })

        # Phase 2: Dynamic failure detection
        if hasattr(self, 'args') and getattr(self.args, 'detect_missing_overrides', False):
            self.detect_missing_overrides(repo_groups, combined_submodules)

        return repo_groups

    def generate_dynamic_relocation_data(self, repo_groups):
        """Generate dynamic relocation data structure for runtime provides calculation."""
        relocation_data = {}

        for repo_module, modules in repo_groups.items():
            if len(modules) > 1:
                # This repository provides multiple modules
                module_list = [m['module_path'] for m in modules]
                relocation_data[repo_module] = module_list
                print(f"    📂 Repository {repo_module} provides: {' '.join(module_list)}")
            else:
                # Single module repository
                module_path = modules[0]['module_path']
                relocation_data[repo_module] = [module_path]

        return relocation_data

    def has_exportable_code(self, go_file: Path) -> bool:
        """
        Check if a Go file contains exportable code (functions, types, vars, consts
        that start with capital letters). This helps us determine if the package
        is actually useful for importing.
        """
        try:
            with open(go_file, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
                
            # Quick checks for exportable symbols
            lines = content.split('\n')
            for line in lines:
                line = line.strip()
                
                # Skip comments and empty lines
                if line.startswith('//') or line.startswith('/*') or not line:
                    continue
                    
                # Look for exportable declarations
                if (line.startswith('func ') or 
                    line.startswith('type ') or
                    line.startswith('var ') or
                    line.startswith('const ')):
                    
                    # Extract the symbol name and check if it's exported (starts with capital)
                    parts = line.split()
                    if len(parts) >= 2:
                        symbol_name = parts[1].split('(')[0].split()[0]  # Handle "func Name(" or "func Name "
                        if symbol_name and symbol_name[0].isupper():
                            return True
                            
            return False  # No exportable symbols found
            
        except Exception:
            # If we can't read/parse the file, assume it might have exportable code
            return True

    def is_package_copy_needed(self, source_dir: Path, dest_dir: Path, import_path: str) -> bool:
        """Check if package copy is needed by comparing hashes."""
        if not dest_dir.exists():
            return True

        # Check if hash file exists
        hash_file = dest_dir / '.source_hash'
        if not hash_file.exists():
            return True

        try:
            # Read stored hash
            with open(hash_file, 'r') as f:
                stored_hash = f.read().strip()

            # Calculate current source hash
            current_hash = self.calculate_directory_hash(source_dir)

            if stored_hash != current_hash:
                print(f"    📋 Package changed: {import_path}")
                return True
            else:
                print(f"    ⚡ Package unchanged: {import_path}")
                return False

        except (OSError, IOError):
            return True

    def copy_package_files(self, source_dir: Path, dest_dir: Path):
        """Copy essential package files to vendor directory."""

        # Copy .go files (excluding tests)
        for go_file in source_dir.glob('*.go'):
            if not go_file.name.endswith('_test.go'):
                shutil.copy2(go_file, dest_dir / go_file.name)

        # Copy module files if they exist
        for module_file in ['go.mod', 'go.sum']:
            module_path = source_dir / module_file
            if module_path.exists():
                shutil.copy2(module_path, dest_dir / module_file)

        # Copy license files
        for license_pattern in ['LICENSE*', 'COPYING*', 'COPYRIGHT*']:
            for license_file in source_dir.glob(license_pattern):
                if license_file.is_file():
                    shutil.copy2(license_file, dest_dir / license_file.name)

    def update_modules_txt(self, module_path: str, version: str):
        """Update vendor/modules.txt file with proper go mod vendor format using exact go.mod version."""
        if not self.vendor_dir:
            return
            
        modules_txt = self.vendor_dir / "modules.txt"
        
        # Read existing content
        existing_content = []
        if modules_txt.exists():
            with open(modules_txt, 'r') as f:
                existing_content = f.read().strip().split('\n')
        
        # Find module info
        module_info = None
        for info in getattr(self, 'vendor_modules', []):
            if info['path'] == module_path:
                module_info = info
                break
        
        if not module_info:
            # Fallback if no module info available
            new_entries = [
                f"# {module_path}",
                "## explicit", 
                module_path
            ]
        else:
            # Generate proper entries using the exact version from go.mod
            # Don't override the version parameter with module_info version
            repo_dir = self.output_dir / module_info.get('safe_name', self.safe_module_name(module_path))
            
            if repo_dir.exists():
                new_entries = self.generate_modules_txt_content(repo_dir, module_path, version)
            else:
                new_entries = [
                    f"# {module_path} {version}",
                    "## explicit",
                    module_path
                ]
        
        # Add new entries to existing content
        if existing_content and existing_content != ['']:
            existing_content.extend([''] + new_entries)
        else:
            existing_content = new_entries
        
        # Write back
        with open(modules_txt, 'w') as f:
            f.write('\n'.join(existing_content) + '\n')

    def generate_modules_txt_content(self, repo_dir: Path, module_path: str, version: str) -> List[str]:
        """Generate proper modules.txt entries for a module by scanning its packages."""
        entries = []
        
        try:
            # Add module header with explicit version from go.mod parsing
            entries.append(f"# {module_path} {version}")
            entries.append("## explicit")
            
            # Find all Go packages in the module
            packages = self.discover_packages_for_modules_txt(repo_dir, module_path)
            
            # Sort packages and add to entries
            if packages:
                for package in sorted(packages):
                    entries.append(package)
            else:
                # Fallback to just the module path if no packages found
                entries.append(module_path)
                
        except Exception as e:
            # Fallback to just the module path if scanning fails
            print(f"    ⚠️  Could not scan packages for {module_path}, using fallback: {e}")
            entries = [
                f"# {module_path} {version}",
                "## explicit",
                module_path
            ]
        
        return entries

    def generate_complete_modules_txt_for_oe(self):
        """
        Generate a complete modules.txt file with proper explicit/replaced markers.
        Uses cached package discovery for better performance.
        """
        if not self.generate_oe_files:
            return None
        
        modules_txt_path = Path("modules.txt")
        print("\n📄 Generating modules.txt with proper explicit/replaced markers...")
        
        entries = []
        package_count = 0
        explicit_count = 0
        replaced_count = 0
        
        for module_info in self.oe_modules:
            module_path = module_info['path']
            version = module_info['version']
            safe_name = module_info['safe_name']
            repo_dir = self.output_dir / safe_name
            
            # Determine the correct marker based on go.mod parsing
            # Use direct_deps, parsed directly from go.mod, as the source of truth.
            is_explicit = module_path in self.direct_deps
            is_replaced = module_path in self.replace_directives
            
            # Handle modules that are both explicit and replaced (like tigron)
            if is_replaced and is_explicit:
                replacement_path = self.replace_directives[module_path]
                marker = f"## explicit; go 1.19\n## replaced({replacement_path})"
                replaced_count += 1
                explicit_count += 1
            elif is_replaced:
                replacement_path = self.replace_directives[module_path]
                marker = f"## replaced({replacement_path})"
                replaced_count += 1
            elif is_explicit:
                marker = "## explicit"
                explicit_count += 1
            else:
                # This is an indirect/transitive dependency
                marker = ""  # Indirect dependencies have no marker
                
            print(f"    📦 {module_path}: {marker}")
            
            # Add module header with version
            if is_replaced and '=>' not in version:
                # Add replacement info to header for replaced modules
                replacement_path = self.replace_directives[module_path]
                entries.append(f"# {module_path} {version} => {replacement_path}")
            else:
                entries.append(f"# {module_path} {version}")
            
            if marker:
                entries.append(marker)
            
            # Discover and add all packages in the module (using cache)
            if repo_dir.exists():
                packages = self.discover_packages_for_modules_txt(repo_dir, module_path)
                
                if packages:
                    for package in sorted(packages):
                        entries.append(package)
                        package_count += 1
                else:
                    # Fallback to just module path if no packages found
                    entries.append(module_path)
                    package_count += 1
            else:
                print(f"    ⚠️  Repository not found for {module_path}, using module path only")
                entries.append(module_path)
                package_count += 1
            
            entries.append("")  # Empty line between modules
        
        # Write the modules.txt file
        with open(modules_txt_path, 'w') as f:
            f.write('\n'.join(entries))
        
        print(f"    ✅ Generated modules.txt with {len(self.oe_modules)} modules and {package_count} packages")
        print(f"    📊 {explicit_count} explicit, {replaced_count} replaced")
        print(f"    📄 File saved as: modules.txt")
        
        return modules_txt_path

    

    def get_commit_hash_from_repo(self, repo_dir: Path, hash_val: str, ref: str, version: str) -> Optional[str]:
        """Get the actual commit hash from the checked out repository."""
        try:
            # Get the current HEAD commit hash
            result = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo_dir,
                check=True,
                capture_output=True,
                text=True
            )
            return result.stdout.strip()
        except subprocess.CalledProcessError as e:
            print(f"    ⚠️  Failed to get commit hash from repo: {e}")
            # Fallback to the hash from go mod download if available
            return hash_val if hash_val else None

    def get_default_branch(self, repo_dir: Path) -> str:
        """Get the default branch name for the repository."""
        try:
            # Try to get the default branch from remote
            result = subprocess.run(
                ["git", "symbolic-ref", "refs/remotes/origin/HEAD"],
                cwd=repo_dir,
                check=True,
                capture_output=True,
                text=True
            )
            # Extract branch name from refs/remotes/origin/branch_name
            default_branch = result.stdout.strip().split('/')[-1]
            return default_branch
        except subprocess.CalledProcessError:
            # Try common default branch names
            for branch in ['main', 'master', 'develop']:
                try:
                    subprocess.run(
                        ["git", "show-ref", "--verify", f"refs/remotes/origin/{branch}"],
                        cwd=repo_dir,
                        check=True,
                        capture_output=True
                    )
                    return branch
                except subprocess.CalledProcessError:
                    continue
            # Fallback to master
            return 'master'

    def get_branch_containing_commit(self, repo_dir: Path, commit_hash: str) -> str:
        """Find which branch contains the specific commit."""
        if not commit_hash:
            return self.get_default_branch(repo_dir)
            
        try:
            # First, try to find which remote branches contain this commit
            result = subprocess.run(
                ["git", "branch", "-r", "--contains", commit_hash],
                cwd=repo_dir,
                check=True,
                capture_output=True,
                text=True
            )
            
            branches = []
            for line in result.stdout.strip().split('\n'):
                line = line.strip()
                if line and not line.startswith('origin/HEAD'):
                    # Extract branch name (remove 'origin/' prefix)
                    if line.startswith('origin/'):
                        branch = line[7:]  # Remove 'origin/' prefix
                        branches.append(branch)
            
            if branches:
                # Prefer main/master branches
                for preferred in ['main', 'master']:
                    if preferred in branches:
                        print(f"    📁 Commit {commit_hash[:8]} found in preferred branch: {preferred}")
                        return preferred
                
                # Use the first available branch
                selected_branch = branches[0]
                print(f"    📁 Commit {commit_hash[:8]} found in branch: {selected_branch}")
                return selected_branch
            
            # If no branches contain the commit, it might be a tag
            try:
                result = subprocess.run(
                    ["git", "tag", "--contains", commit_hash],
                    cwd=repo_dir,
                    check=True,
                    capture_output=True,
                    text=True
                )
                
                tags = [tag.strip() for tag in result.stdout.strip().split('\n') if tag.strip()]
                if tags:
                    # The commit is reachable from tags, try to find the branch it was merged into
                    print(f"    📁 Commit {commit_hash[:8]} found in tags: {tags[:3]}...")
                    
                    # Try common branch names that might contain the commit
                    for branch in ['main', 'master', 'develop', 'release']:
                        try:
                            subprocess.run(
                                ["git", "merge-base", "--is-ancestor", commit_hash, f"origin/{branch}"],
                                cwd=repo_dir,
                                check=True,
                                capture_output=True
                            )
                            print(f"    📁 Commit {commit_hash[:8]} is ancestor of {branch}")
                            return branch
                        except subprocess.CalledProcessError:
                            continue
                            
            except subprocess.CalledProcessError:
                pass
            
            # Last resort: use default branch and hope for the best
            default_branch = self.get_default_branch(repo_dir)
            print(f"    ⚠️  Could not find branch containing {commit_hash[:8]}, using default: {default_branch}")
            return default_branch
            
        except subprocess.CalledProcessError as e:
            print(f"    ⚠️  Error finding branch for commit {commit_hash[:8]}: {e}")
            return self.get_default_branch(repo_dir)

    def generate_oe_src_uri(self, module_path: str, repo_url: str, repo_dir: Path) -> Optional[str]:
        """Generate OpenEmbedded SRC_URI entry for a module using actual commit hash."""
        safe_name = self.safe_module_name(module_path)
        
        # Get the actual commit hash from the checked out repository
        commit_hash = self.get_commit_hash_from_repo(repo_dir, "", "", "")
        if not commit_hash:
            print(f"    ❌ Could not determine commit hash for {module_path}")
            return None
        
        # Convert to proper git:// fetcher format with protocol=https
        clean_url = repo_url.replace("https://", "").replace("http://", "")
        
        # For Go modules, use nobranch=1 for more reliable fetching by commit hash
        # This avoids branch detection issues common with Go module repositories
        src_uri = f'git://{clean_url};protocol=https'
        src_uri += f';nobranch=1;rev={commit_hash};shallow=1;destsuffix=${{GO_SRCURI_DESTSUFFIX}}/modules/{safe_name}'

        print(f"    📁 Generated SRC_URI with commit {commit_hash[:8]} (nobranch, shallow)")
        return src_uri

    def generate_gomodgit_src_uri(self, module_path: str, version: str, repo_url: str, commit_hash: str, subdir: str = None) -> str:
        """
        Generate gomodgit:// SRC_URI entry using BitBake's Go module infrastructure.
        Returns src_uri with embedded SRCREV.
        """
        print(f"    🔗 Generating gomodgit:// entry for {module_path}")

        # Clean the repo URL for gomodgit format
        clean_url = repo_url.replace("https://", "").replace("http://", "")

        # Generate gomodgit:// entry (VCS-based with SRCREV)
        src_uri = f'gomodgit://{module_path};version={version}'

        # Add repo parameter if different from module path
        expected_repo_url = f"https://{module_path}"
        if repo_url != expected_repo_url:
            # Extract repo part (e.g., "go.googlesource.com/net" from full URL)
            repo_part = clean_url.split('/')[0] + "/" + "/".join(clean_url.split('/')[1:])
            src_uri += f';repo={repo_part}'
            print(f"      📍 Using custom repo: {repo_part}")

        # Add subdir parameter if module not at repo root
        if subdir and subdir != ".":
            src_uri += f';subdir={subdir}'
            print(f"      📁 Using subdir: {subdir}")

        # Add srcrev parameter
        src_uri += f';srcrev={commit_hash}'

        # Add shallow=1 to force shallow clones (performance optimization)
        src_uri += ';shallow=1'

        print(f"    ✅ Generated gomodgit entry with embedded SRCREV {commit_hash[:8]} (shallow)")

        return src_uri

    def check_gomodgit_compatibility(self, repo_dir: Path, commit_hash: str) -> bool:
        """
        Check if a commit is compatible with BitBake's gomodgit fetcher.
        BitBake has bugs with:
        1. Files with spaces in names (splits on whitespace)
        2. Git submodules (tries to read commits as blobs)
        """
        try:
            # Get list of all files in the commit with detailed info
            result = subprocess.run(
                ["git", "ls-tree", "-r", commit_hash],
                cwd=repo_dir, capture_output=True, text=True, check=True
            )
            tree_lines = result.stdout.strip().split('\n')

            # Parse ls-tree output: mode type hash<tab>name
            problematic_files = []
            submodules = []

            for line in tree_lines:
                if not line.strip():
                    continue
                parts = line.split('\t', 1)
                if len(parts) != 2:
                    continue
                mode_type_hash, filename = parts
                mode, obj_type, _ = mode_type_hash.split()

                # Check for submodules (mode 160000)
                if mode == '160000':
                    submodules.append(filename)
                # Check for filenames with spaces
                elif ' ' in filename:
                    problematic_files.append(filename)

            # Report issues
            if submodules:
                print(f"    ⚠️  BitBake incompatible submodules found:")
                for sm in submodules[:3]:  # Show first 3 examples
                    print(f"        • {sm} (Git submodule)")
                if len(submodules) > 3:
                    print(f"        ... and {len(submodules) - 3} more submodules")

            if problematic_files:
                print(f"    ⚠️  BitBake incompatible files found (spaces in names):")
                for pf in problematic_files[:3]:  # Show first 3 examples
                    print(f"        • {pf}")
                if len(problematic_files) > 3:
                    print(f"        ... and {len(problematic_files) - 3} more")

            return len(submodules) == 0 and len(problematic_files) == 0
        except subprocess.CalledProcessError:
            print(f"    ❌ Failed to check file compatibility for {commit_hash[:8]}")
            return False

    def generate_srcrev_inc(self, srcrev_variables: Dict[str, str], output_dir: Path = None):
        """Generate srcrev.inc file with SRCREV variables for BitBake gomodgit infrastructure."""
        if output_dir is None:
            output_dir = Path(".")

        srcrev_file = output_dir / "srcrev.inc"

        print(f"📝 Generating {srcrev_file} with {len(srcrev_variables)} SRCREV variables")

        with open(srcrev_file, 'w') as f:
            f.write(f"# Generated by go_mod_fetcher.py v{VERSION}\n")
            f.write("# SRCREV variables for gomodgit:// fetcher infrastructure\n")
            f.write("# This file provides commit hashes for each module version\n\n")

            for var_name, commit_hash in sorted(srcrev_variables.items()):
                f.write(f'{var_name} = "{commit_hash}"\n')

        print(f"    ✅ Generated {len(srcrev_variables)} SRCREV variables in {srcrev_file}")

    def bootstrap_gomodgit_infrastructure(self, source_dir: Path, go_install_targets: List[str] = None, output_dir: Path = None):
        """
        Bootstrap creation of .inc files using BitBake's gomodgit infrastructure.
        Uses 'go list' for authoritative dependency resolution.
        """
        if output_dir is None:
            output_dir = Path(".")

        output_dir = output_dir.resolve()
        output_dir.mkdir(parents=True, exist_ok=True)

        print(f"\n🚀 Bootstrapping gomodgit:// infrastructure files")
        print(f"    📁 Output directory: {output_dir}")

        if self.repo_cache_dir:
            print(f"    💾 Reusing git cache at {self.repo_cache_dir}")

        # Use go list for authoritative dependency resolution
        modules_info = self.use_go_list_for_dependencies(source_dir, go_install_targets)

        if not modules_info:
            print("    ❌ No module information available from go list")
            return

        print(f"    🎯 Processing {len(modules_info)} modules from go list")

        gomodgit_src_uris = []

        # Process each module identified by go list
        for module_path, module_info in modules_info.items():
            version = module_info['Version']

            print(f"\n  📦 Processing module: {module_path} @ {version}")

            # Skip the main module (the current project)
            if version == "" or version == "v0.0.0":
                print(f"    ⏭️  Skipping main module: {module_path}")
                continue

            # Determine repository URL from module path
            repo_url = self.derive_repo_url(module_path)
            if not repo_url:
                print(f"    ❌ Could not derive repository URL for {module_path}")
                continue

            safe_repo_name = self.safe_module_name(module_path)
            if self.repo_cache_dir:
                repo_work_dir = self.repo_cache_dir / safe_repo_name
            else:
                if not self.temp_dir:
                    self.temp_dir = Path(tempfile.mkdtemp(prefix="go_mod_fetcher_"))
                repo_work_dir = self.temp_dir / f"repo_{module_path.replace('/', '_').replace('.', '_')}"

            try:
                # Clone repository to get commit hash
                if not self.clone_or_update_repo(repo_url, repo_work_dir):
                    print(f"    ❌ Failed to clone repository for {module_path}")
                    continue

                # Get commit hash for the specific version tag
                try:
                    # First try to get the commit for the exact version tag
                    commit_result = subprocess.run([
                        "git", "rev-list", "-n", "1", version
                    ], cwd=repo_work_dir, capture_output=True, text=True, check=True)
                    commit_hash = commit_result.stdout.strip()
                    print(f"    ✅ Found tag object {commit_hash} for tag {version}")
                except subprocess.CalledProcessError:
                    print(f"    ⚠️  Tag {version} not found, trying remote fetch...")
                    try:
                        # Try fetching the tag from remote
                        subprocess.run([
                            "git", "fetch", "origin", f"refs/tags/{version}:refs/tags/{version}"
                        ], cwd=repo_work_dir, capture_output=True, text=True, check=True)

                        # Now try to get the commit for the tag
                        commit_result = subprocess.run([
                            "git", "rev-list", "-n", "1", version
                        ], cwd=repo_work_dir, capture_output=True, text=True, check=True)
                        commit_hash = commit_result.stdout.strip()
                        print(f"    ✅ Found tag object {commit_hash} for tag {version} (after fetch)")
                    except subprocess.CalledProcessError:
                        print(f"    ❌ Failed to resolve tag {version} for {module_path}, falling back to HEAD")
                        try:
                            commit_result = subprocess.run([
                                "git", "rev-parse", "HEAD"
                            ], cwd=repo_work_dir, capture_output=True, text=True, check=True)
                            commit_hash = commit_result.stdout.strip()
                            print(f"    ⚠️  Using HEAD commit {commit_hash} as fallback")
                        except subprocess.CalledProcessError:
                            print(f"    ❌ Failed to get any commit hash for {module_path}")
                            continue

                # Determine if module is in subdirectory
                subdir = self.detect_module_subdir(module_path, repo_work_dir)

                # Check BitBake gomodgit compatibility
                if not self.check_gomodgit_compatibility(repo_work_dir, commit_hash):
                    print(f"    ⚠️  Skipping {module_path} due to BitBake gomodgit incompatibility")
                    print(f"        (BitBake fetcher cannot handle submodules or files with spaces)")
                    continue

                # Generate gomodgit:// SRC_URI entry
                src_uri = self.generate_gomodgit_src_uri(
                    module_path, version, repo_url, commit_hash, subdir
                )

                gomodgit_src_uris.append(src_uri)

                print(f"    ✅ Generated gomodgit entry for {module_path} @ {commit_hash[:8]}")

            except Exception as e:
                print(f"    ❌ Error processing {module_path}: {e}")
                continue
            finally:
                # Clean up temporary repository
                if not self.repo_cache_dir and repo_work_dir and repo_work_dir.exists():
                    shutil.rmtree(repo_work_dir, ignore_errors=True)

        # Generate output files
        self.write_gomodgit_src_uri_inc(gomodgit_src_uris, output_dir)

        print(f"\n🎉 Successfully bootstrapped gomodgit infrastructure:")
        print(f"    📄 {output_dir}/src_uri.inc - {len(gomodgit_src_uris)} gomodgit:// entries")
        print(f"    ℹ️  No srcrev.inc needed - SRCREV embedded in gomodgit:// entries")

    def bootstrap_hybrid_infrastructure(self, source_dir: Path, go_install_targets: List[str] = None, output_dir: Path = None):
        """
        Bootstrap creation of hybrid git:// + custom module cache infrastructure.
        Fast parallel downloads with custom module cache generation.
        """
        if output_dir is None:
            output_dir = Path(".")

        output_dir = output_dir.resolve()
        output_dir.mkdir(parents=True, exist_ok=True)

        print(f"\n🚀 Bootstrapping hybrid git:// + custom module cache infrastructure")
        print(f"    📁 Output directory: {output_dir}")
        print(f"    ⚡ Performance: Fast parallel downloads + custom cache generation")

        if self.repo_cache_dir:
            print(f"    💾 Reusing git cache at {self.repo_cache_dir}")

        # Use go list for authoritative dependency resolution
        modules_info = self.use_go_list_for_dependencies(source_dir, go_install_targets)

        if not modules_info:
            print("    ❌ No module information available from go list")
            return

        print(f"    🎯 Processing {len(modules_info)} modules from go list")

        # Prepare modules list for hybrid approach
        modules_data = []
        failed_modules = []

        # Process each module identified by go list
        for module_path, module_info in modules_info.items():
            version = module_info['Version']

            print(f"\n  📦 Processing module: {module_path} @ {version}")

            download_info = self.get_module_download_info(module_path, version)
            origin = download_info.get('Origin', {}) if download_info else {}

            repo_url = origin.get('URL') if origin.get('URL') else self.derive_repo_url(module_path)
            if not repo_url:
                print(f"    ❌ Could not derive repository URL for {module_path}")
                failed_modules.append(module_path)
                continue

            commit_hash = origin.get('Hash') if origin.get('Hash') else None

            safe_repo_name = self.safe_module_name(module_path)
            if self.repo_cache_dir:
                repo_work_dir = self.repo_cache_dir / safe_repo_name
            else:
                if not self.temp_dir:
                    self.temp_dir = Path(tempfile.mkdtemp(prefix="go_mod_fetcher_"))
                repo_work_dir = self.temp_dir / f"repo_{module_path.replace('/', '_').replace('.', '_')}"

            try:
                # Clone repository to get commit hash and subdir
                if not self.clone_or_update_repo(repo_url, repo_work_dir):
                    print(f"    ❌ Failed to clone repository for {module_path}")
                    failed_modules.append(module_path)
                    continue

                checkout_success = False

                if commit_hash:
                    try:
                        subprocess.run(
                            ["git", "checkout", commit_hash],
                            cwd=repo_work_dir,
                            check=True,
                            capture_output=True
                        )
                        checkout_success = True
                        print(f"    ✅ Using proxy-reported commit {commit_hash[:8]}")
                    except subprocess.CalledProcessError:
                        print(f"    ⚠️  Failed to checkout proxy commit {commit_hash[:8]}, recalculating...")
                        commit_hash = None

                # Get commit hash for the specific version when proxy metadata is unavailable
                if not commit_hash:
                    import re
                    pseudo_version_match = re.match(r'v[0-9]+\.[0-9]+\.[0-9]+-[0-9]{14}-([0-9a-f]{12})', version)

                    if pseudo_version_match:
                        # This is a pseudo-version - extract the commit hash
                        short_hash = pseudo_version_match.group(1)
                        print(f"    🔍 Detected pseudo-version, extracting commit: {short_hash}")
                        try:
                            commit_result = subprocess.run([
                                "git", "rev-parse", short_hash
                            ], cwd=repo_work_dir, capture_output=True, text=True, check=True)
                            commit_hash = commit_result.stdout.strip()
                            print(f"    ✅ Resolved pseudo-version commit to {commit_hash[:8]}")
                        except subprocess.CalledProcessError:
                            print(f"    ⚠️  Commit {short_hash} not in local cache, fetching...")
                            try:
                                subprocess.run(["git", "fetch", "--all"], cwd=repo_work_dir, capture_output=True, text=True)
                                commit_result = subprocess.run([
                                    "git", "rev-parse", short_hash
                                ], cwd=repo_work_dir, capture_output=True, text=True, check=True)
                                commit_hash = commit_result.stdout.strip()
                                print(f"    ✅ Resolved pseudo-version commit to {commit_hash[:8]} (after fetch)")
                            except subprocess.CalledProcessError:
                                print(f"    ❌ Could not resolve pseudo-version commit {short_hash}")
                    else:
                        try:
                            commit_result = subprocess.run([
                                "git", "rev-list", "-n", "1", version
                            ], cwd=repo_work_dir, capture_output=True, text=True, check=True)
                            commit_hash = commit_result.stdout.strip()
                            print(f"    ✅ Found commit {commit_hash[:8]} for tag {version}")
                        except subprocess.CalledProcessError:
                            print(f"    ⚠️  Tag {version} not found, trying remote fetch...")
                            try:
                                subprocess.run([
                                    "git", "fetch", "origin", f"refs/tags/{version}:refs/tags/{version}"
                                ], cwd=repo_work_dir, capture_output=True, text=True, check=True)

                                commit_result = subprocess.run([
                                    "git", "rev-list", "-n", "1", version
                                ], cwd=repo_work_dir, capture_output=True, text=True, check=True)
                                commit_hash = commit_result.stdout.strip()
                                print(f"    ✅ Found commit {commit_hash[:8]} for tag {version} (after fetch)")
                            except subprocess.CalledProcessError:
                                print(f"    ❌ Failed to resolve tag {version} for {module_path}, falling back to HEAD")
                                try:
                                    commit_result = subprocess.run([
                                        "git", "rev-parse", "HEAD"
                                    ], cwd=repo_work_dir, capture_output=True, text=True, check=True)
                                    commit_hash = commit_result.stdout.strip()
                                    print(f"    ⚠️  Using HEAD commit {commit_hash[:8]} as fallback")
                                except subprocess.CalledProcessError:
                                    print(f"    ❌ Could not determine any commit hash for {module_path}")
                                    failed_modules.append(module_path)
                                    continue

                # Ensure the final commit matches the version we're packaging.
                expected_commit = self.resolve_commit_from_version(repo_work_dir, module_path, version)
                if expected_commit:
                    if commit_hash and commit_hash != expected_commit:
                        print(
                            f"    🔁 Aligning commit {commit_hash[:8]} to version-derived commit {expected_commit[:8]}"
                        )
                        checkout_success = False
                    elif not commit_hash:
                        print(f"    ✅ Using version-derived commit {expected_commit[:8]}")
                    commit_hash = expected_commit

                if not commit_hash:
                    print(f"    ❌ Could not determine commit hash for {module_path}@{version}")
                    failed_modules.append(module_path)
                    continue

                if not checkout_success:
                    try:
                        subprocess.run(
                            ["git", "checkout", commit_hash],
                            cwd=repo_work_dir,
                            check=True,
                            capture_output=True
                        )
                        print(f"    ✅ Checked out commit {commit_hash[:8]}")
                    except subprocess.CalledProcessError:
                        print(f"    ❌ Failed to checkout commit {commit_hash[:8]} for {module_path}")
                        failed_modules.append(module_path)
                        continue

                # Detect subdir if module is not at repository root
                subdir = self.detect_module_subdir(module_path, repo_work_dir)

            except Exception as e:
                print(f"    ❌ Error processing {module_path}: {e}")
                failed_modules.append(module_path)
                continue

            module_data = {
                'module': module_path,
                'version': version,
                'repo_url': repo_url,
                'commit': commit_hash,
                'subdir': subdir if subdir else ""
            }
            modules_data.append(module_data)

            print(f"    ✅ {module_path} @ {version} (commit: {commit_hash[:8]})")
            if subdir:
                print(f"       📂 Subdir: {subdir}")

        # Store processed modules for checksum generation
        self.processed_modules = []
        for module_data in modules_data:
            processed_module = {
                'module_path': module_data['module'],
                'version': module_data['version'],
                'repo_url': module_data['repo_url'],
                'commit': module_data['commit'],
                'subdir': module_data['subdir']
            }
            self.processed_modules.append(processed_module)

        # Import and use the hybrid module cache builder
        try:
            import sys
            import os
            script_dir = os.path.dirname(os.path.abspath(__file__))
            sys.path.insert(0, script_dir)
            from hybrid_module_cache_builder import HybridModuleCacheBuilder

            # Create hybrid module cache builder
            cache_builder = HybridModuleCacheBuilder(
                module_cache_dir=str(output_dir / "pkg" / "mod"),
                workdir=str(output_dir / "workdir"),
                max_workers=8
            )

            # Generate hybrid solution
            src_uri_entries, cache_builder_task = cache_builder.generate_complete_solution(modules_data)

            # Write src_uri.inc with git:// entries
            self.write_hybrid_src_uri_inc(src_uri_entries, output_dir)

            # Write module cache builder task to separate file
            self.write_hybrid_cache_task(cache_builder_task, output_dir)

            print(f"\n🎉 Successfully bootstrapped hybrid infrastructure:")
            print(f"    📄 {output_dir}/src_uri.inc - {len(src_uri_entries)} git:// entries (fast parallel)")
            print(f"    📄 {output_dir}/module_cache_task.inc - Custom module cache builder")
            print(f"    ⚡ Expected performance: ~2-3 minutes vs 20+ minutes (10x faster)")
            print(f"    🔧 Integration: Include module_cache_task.inc in your BitBake recipe")

            if self.generate_gomodgit:
                # Generate go.sum.gomodgit with hybrid-compatible checksums when requested
                print(f"\n📝 Generating go.sum.gomodgit with hybrid-compatible checksums...")
                original_cwd = os.getcwd()
                try:
                    # Change to output directory so go.sum.gomodgit is created there
                    os.chdir(output_dir)
                    # Pass the source directory explicitly since the hybrid path uses a different temp structure
                    self.generate_gomodgit_go_sum_for_hybrid(source_dir)
                finally:
                    os.chdir(original_cwd)
            else:
                print("\n⏭️  Skipping go.sum.gomodgit generation (use --generate-gomodgit to enable)")

            if failed_modules:
                print(f"\n⚠️  {len(failed_modules)} modules could not be processed:")
                for module in failed_modules[:5]:  # Show first 5
                    print(f"    • {module}")
                if len(failed_modules) > 5:
                    print(f"    • ... and {len(failed_modules) - 5} more")

        except ImportError as e:
            print(f"    ❌ Could not import hybrid module cache builder: {e}")
            print(f"    💡 Make sure hybrid_module_cache_builder.py is in the same directory")
            return

    def write_gomodgit_src_uri_inc(self, gomodgit_src_uris: List[str], output_dir: Path = None):
        """Write src_uri.inc with gomodgit:// entries."""
        if output_dir is None:
            output_dir = Path(".")

        src_uri_file = output_dir / "src_uri.inc"

        print(f"📝 Writing {src_uri_file} with {len(gomodgit_src_uris)} gomodgit:// entries")

        with open(src_uri_file, 'w') as f:
            f.write(f"# Generated by go_mod_fetcher.py v{VERSION}\n")
            f.write("# OpenEmbedded SRC_URI entries using gomodgit:// fetcher\n")
            f.write("# This leverages BitBake's built-in Go module infrastructure\n\n")

            f.write("SRC_URI += \"\\\n")
            for src_uri in sorted(gomodgit_src_uris):
                f.write(f"    {src_uri} \\\n")
            f.write("\"\n")

        print(f"    ✅ Generated {len(gomodgit_src_uris)} gomodgit:// entries")

    def write_hybrid_src_uri_inc(self, src_uri_entries: List[str], output_dir: Path = None):
        """Write src_uri.inc with git:// entries for hybrid approach."""
        if output_dir is None:
            output_dir = Path(".")

        src_uri_file = output_dir / "src_uri.inc"

        with open(src_uri_file, 'w') as f:
            f.write("# Generated by oe-go-mod-fetcher.py --use-hybrid\n")
            f.write("# Fast parallel git:// downloads for Go module dependencies\n")
            f.write("# Include module_cache_task.inc in your BitBake recipe for custom cache generation\n\n")
            f.write("SRC_URI += \"\\\n")

            for i, src_uri in enumerate(src_uri_entries):
                if i == len(src_uri_entries) - 1:
                    f.write(f"    {src_uri} \\\n")
                else:
                    f.write(f"    {src_uri} \\\n")

            f.write("\"\n")

        print(f"    ✅ Generated {len(src_uri_entries)} git:// entries (hybrid approach)")

    def write_hybrid_cache_task(self, cache_task_code: str, output_dir: Path = None):
        """Write module cache builder task to separate include file."""
        if output_dir is None:
            output_dir = Path(".")

        task_file = output_dir / "module_cache_task.inc"

        # Generate the do_generate_go_sum task code
        go_sum_task_code = self.generate_do_generate_go_sum_task()

        compile_env_block = self.generate_compile_env_prepend_block()

        with open(task_file, 'w') as f:
            f.write("# Generated by oe-go-mod-fetcher.py --use-hybrid\n")
            f.write("# Custom module cache builder for fast parallel processing\n")
            f.write("# This replaces BitBake's slow sequential gomodgit processing\n\n")
            f.write("DEPENDS += \" go-dirhash-native\"\n\n")
            f.write("# Ensure Go module cache objects remain writable\n")
            f.write("GOBUILDFLAGS:append = \" -modcacherw\"\n\n")
            f.write("# Set up Go module cache directory (matches our hybrid module cache location)\n")
            f.write("GOMODCACHE = \"${S}/pkg/mod\"\n")
            f.write("GO_MOD_CACHE_DIR = \"${@os.path.relpath(d.getVar('GOMODCACHE'), d.getVar('UNPACKDIR'))}\"\n")
            f.write("do_unpack[cleandirs] += \"${GOMODCACHE}\"\n\n")
            f.write(cache_task_code)
            f.write("\n\n")
            f.write("# ============================================================\n")
            f.write("# do_generate_go_sum: Generate go.sum from module cache\n")
            f.write("# ============================================================\n\n")
            f.write(go_sum_task_code)
            f.write("\n\n")
            f.write("# ============================================================\n")
            f.write("# do_compile integration helpers\n")
            f.write("# ============================================================\n\n")
            f.write(compile_env_block)

        print(f"    ✅ Generated module cache builder task")
        print(f"    ✅ Generated do_generate_go_sum task (calculates zip + go.mod Hash1 checksums)")

    def generate_do_generate_go_sum_task(self) -> str:
        """Generate the BitBake task code for do_generate_go_sum.

        This task:
        1. Calculates .zip checksums from actual VCS-based module cache using Go helper binary
        2. Calculates go.mod checksums locally using the Hash1(dirhash) algorithm
        3. Combines both into final go.sum file
        """
        return '''python do_generate_go_sum() {
    """
    Generate go.sum from the module cache artifacts.
    - Zip checksums: Calculated from our VCS-based builds using Go helper binary
    - go.mod checksums: Calculated locally using the Hash1(dirhash) algorithm

    This matches Go's expectations while keeping the build offline.
    """
    import subprocess
    import re
    import hashlib
    import base64
    from pathlib import Path

    s = d.getVar('S')
    cache_dir = Path(s) / "pkg" / "mod" / "cache" / "download"
    go_sum_path = Path(s) / "src" / "import" / "go.sum"
    workdir = Path(d.getVar('WORKDIR'))
    fallback_marker = workdir / ".use-gomodgit-go-sum"
    fallback_sum = workdir / "go.sum.gomodgit"

    if fallback_marker.exists() or fallback_sum.exists():
        bb.warn("go.sum.gomodgit fallback detected - skipping helper-based go.sum generation")
        fallback_marker.touch()
        return

    # Go helper binary for checksums
    go_helper = Path(d.getVar('STAGING_BINDIR_NATIVE')) / "dirhash"

    if not cache_dir.exists():
        bb.fatal("Module cache not found - do_create_module_cache must run first")
        return

    if not go_helper.exists():
        bb.fatal(f"Go checksum helper not found at {go_helper}. Ensure go-dirhash-native is in DEPENDS.")
        return

    bb.note("Generating go.sum from module cache (Hash1 for go.mod files)...")

    def calculate_mod_checksum(mod_path):
        try:
            mod_bytes = mod_path.read_bytes()
        except FileNotFoundError:
            return None

        file_hash = hashlib.sha256(mod_bytes).hexdigest()
        summary = f"{file_hash}  go.mod\\n".encode('ascii')
        digest = hashlib.sha256(summary).digest()
        return "h1:" + base64.b64encode(digest).decode('ascii')

    checksums = {}

    # Scan all .zip files in the module cache and calculate checksums
    for zip_file in sorted(cache_dir.rglob("*.zip")):
        try:
            # Calculate zip checksum using Go helper binary
            result = subprocess.run(
                [str(go_helper), str(zip_file)],
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode != 0:
                bb.warn(f"Failed to calculate zip checksum for {zip_file}: {result.stderr}")
                continue

            zip_checksum = result.stdout.strip()

            # Extract and unescape module path and version
            parts = zip_file.parts
            v_index = parts.index('@v')
            download_index = parts.index('download')

            escaped_module_parts = parts[download_index + 1:v_index]
            escaped_module = '/'.join(escaped_module_parts)
            escaped_version = zip_file.stem

            def unescape(s):
                """Unescape !lowercase back to uppercase"""
                return re.sub(r'!([a-z])', lambda m: m.group(1).upper(), s)

            module_path = unescape(escaped_module)
            version = unescape(escaped_version)
            module_version = f"{module_path} {version}"

            # Calculate go.mod checksum directly from cached .mod file.
            mod_file = zip_file.with_suffix('.mod')
            mod_checksum = calculate_mod_checksum(mod_file)

            if module_version not in checksums:
                checksums[module_version] = {'zip': zip_checksum, 'mod': mod_checksum}

        except Exception as e:
            bb.warn(f"Error processing {zip_file}: {e}")
            continue

    # Write go.sum with hybrid checksums
    go_sum_path.parent.mkdir(parents=True, exist_ok=True)

    with open(go_sum_path, 'w') as f:
        for module_version in sorted(checksums.keys()):
            data = checksums[module_version]
            f.write(f"{module_version} {data['zip']}\\n")
            if data['mod']:
                f.write(f"{module_version}/go.mod {data['mod']}\\n")

    num_with_mod = sum(1 if data['mod'] else 0 for data in checksums.values())
    bb.note(f"✅ Generated go.sum with {len(checksums)} modules")
    bb.note(f"   🎯 Zip checksums: {len(checksums)} calculated from VCS builds")
    bb.note(f"   📄 go.mod checksums calculated from cached .mod files ({num_with_mod} entries)")
}

# Generate go.sum from actual module cache BEFORE compile
addtask generate_go_sum after do_create_module_cache before do_compile
'''

    def generate_compile_env_prepend_block(self) -> str:
        """Emit a BitBake shell snippet that forces Go to use the generated module cache."""
        return '''do_compile:prepend() {
    # Ensure offline Go builds consume the generated module cache
    export GOMODCACHE="${S}/pkg/mod"
    export GOPROXY="direct"
    export GOSUMDB="off"
    export GONOSUMDB="*"
    export GOPRIVATE="*"
    export GOFLAGS="${GOFLAGS} -mod=mod -modcacherw"

    fallback_sum="${WORKDIR}/go.sum.gomodgit"
    fallback_marker="${WORKDIR}/.use-gomodgit-go-sum"

    if [ -f "${fallback_sum}" ]; then
        bbwarn "Fallback go.sum.gomodgit detected - using provided checksums"
        install -d "${S}/src/import"
        install -m 0644 "${fallback_sum}" "${S}/src/import/go.sum"
        touch "${fallback_marker}"
    else
        rm -f "${fallback_marker}"
    fi

    bbnote "Using offline Go module cache at ${GOMODCACHE}"
}
'''

    def generate_gomodgit_go_sum_for_hybrid(self, source_dir: Path):
        """Generate go.sum.gomodgit by creating temporary zips and calculating checksums.

        This is a simplified wrapper that delegates to the full implementation below.
        """
        # Delegate to the full implementation at line 3356
        # (This duplicate definition at line 2663 is kept for compatibility)
        pass

    def detect_module_subdir(self, module_path: str, repo_dir: Path) -> Optional[str]:
        """Detect if module is located in a subdirectory of the repository."""
        def read_module_name(go_mod_path: Path) -> Optional[str]:
            try:
                with open(go_mod_path, 'r', encoding='utf-8') as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith('module '):
                            parts = line.split()
                            if len(parts) >= 2:
                                return parts[1]
                            break
            except (OSError, UnicodeDecodeError):
                return None
            return None

        expected_module = module_path

        try:
            go_mod_candidates = [p for p in repo_dir.rglob('go.mod') if '.git' not in p.parts]
        except OSError:
            go_mod_candidates = []

        for go_mod_path in go_mod_candidates:
            module_name = read_module_name(go_mod_path)
            if not module_name:
                continue

            if module_name == expected_module:
                try:
                    rel_path = go_mod_path.parent.relative_to(repo_dir)
                except ValueError:
                    continue

                rel_str = str(rel_path).replace('\\', '/')
                return None if rel_str in ('', '.') else rel_str

        # If no matching go.mod found, assume root
        return None

    def resolve_commit_from_version(self, repo_dir: Path, module_path: str, version: str) -> Optional[str]:
        """Resolve the authoritative commit hash for a module version."""
        import re
        import subprocess

        pseudo_version_match = re.match(r'v[0-9]+\.[0-9]+\.[0-9]+-[0-9]{14}-([0-9a-f]{12})', version)

        if pseudo_version_match:
            short_hash = pseudo_version_match.group(1)
            try:
                commit_result = subprocess.run(
                    ["git", "rev-parse", short_hash],
                    cwd=repo_dir,
                    capture_output=True,
                    text=True,
                    check=True
                )
                return commit_result.stdout.strip()
            except subprocess.CalledProcessError:
                try:
                    subprocess.run(
                        ["git", "fetch", "--all"],
                        cwd=repo_dir,
                        capture_output=True,
                        text=True,
                        check=True
                    )
                    commit_result = subprocess.run(
                        ["git", "rev-parse", short_hash],
                        cwd=repo_dir,
                        capture_output=True,
                        text=True,
                        check=True
                    )
                    return commit_result.stdout.strip()
                except subprocess.CalledProcessError:
                    return None

        tag_candidates: List[str] = []
        module_parts = module_path.split('/')
        subpath_parts = module_parts[3:] if len(module_parts) > 3 else []
        if subpath_parts:
            tag_candidates.append(f"{'/'.join(subpath_parts)}/{version}")
        tag_candidates.append(version)

        for candidate in tag_candidates:
            for attempt in range(2):
                try:
                    commit_result = subprocess.run(
                        ["git", "rev-list", "-n", "1", candidate],
                        cwd=repo_dir,
                        capture_output=True,
                        text=True,
                        check=True
                    )
                    return commit_result.stdout.strip()
                except subprocess.CalledProcessError:
                    if attempt == 0:
                        try:
                            subprocess.run(
                                ["git", "fetch", "--tags"],
                                cwd=repo_dir,
                                capture_output=True,
                                text=True,
                                check=True
                            )
                        except subprocess.CalledProcessError:
                            break

        return None

    def fetch_main_repo(self, git_repo: str, git_ref: str) -> Optional[Path]:
        """Fetch the main repository for gomodgit infrastructure bootstrap."""
        print(f"📦 Fetching main repository: {git_repo} @ {git_ref}")

        # Ensure temp dir is initialized
        if not self.temp_dir:
            self.temp_dir = Path(tempfile.mkdtemp(prefix="go_mod_fetcher_"))

        # Use temporary directory for main repo
        temp_dir = self.temp_dir / "main_repo"

        try:
            # Clone the repository
            subprocess.run([
                "git", "clone", "--depth=1", "--branch", git_ref, git_repo, str(temp_dir)
            ], check=True, capture_output=True)

            print(f"    ✅ Successfully fetched main repository to {temp_dir}")
            return temp_dir

        except subprocess.CalledProcessError as e:
            # Try without --branch (for commit hashes)
            try:
                subprocess.run([
                    "git", "clone", git_repo, str(temp_dir)
                ], check=True, capture_output=True)

                subprocess.run([
                    "git", "checkout", git_ref
                ], cwd=temp_dir, check=True, capture_output=True)

                print(f"    ✅ Successfully fetched main repository to {temp_dir}")
                return temp_dir

            except subprocess.CalledProcessError as e2:
                print(f"    ❌ Failed to fetch repository: {e2}")
                return None

    def extract_module_path_from_src_uri(self, src_uri: str) -> Optional[str]:
        """Extract module path from SRC_URI string for duplicate detection."""
        try:
            # Extract the destsuffix part which contains the module path
            if 'destsuffix=' in src_uri:
                suffix_part = src_uri.split('destsuffix=')[1]
                # Remove any trailing content after the suffix
                if ';' in suffix_part:
                    suffix_part = suffix_part.split(';')[0]
                if '"' in suffix_part:
                    suffix_part = suffix_part.split('"')[0]
                # Extract the module part after the last slash
                if '/modules/' in suffix_part:
                    module_part = suffix_part.split('/modules/')[1]
                    # Convert safe name back to module path
                    return module_part.replace('_', '/')
            return None
        except Exception:
            return None

    def extract_repo_url_from_src_uri(self, src_uri: str) -> Optional[str]:
        """Extract repository URL from SRC_URI string for duplicate detection."""
        try:
            # Extract the git:// URL part
            if 'git://' in src_uri:
                url_part = src_uri.split('git://')[1]
                # Get everything before the first semicolon
                if ';' in url_part:
                    url_part = url_part.split(';')[0]
                return f"git://{url_part}"
            return None
        except Exception:
            return None

    def write_oe_files(self):
        """Write OpenEmbedded files (src_uri.inc and relocation.inc)."""
        if not self.generate_oe_files:
            return

        # modules.txt is now authoritative, copied from `go mod vendor`.
        # This function now only generates src_uri.inc and relocation.inc.
        print("\n📄 Generating OpenEmbedded include files...")

        # Analyze repository structure for relocation logic (will be used later)
        repo_groups = self.analyze_repository_structure()

        # Analyze vendor reference structure to detect subdirectory mappings
        vendor_mappings = self.analyze_vendor_reference_structure()

        # Write src_uri.inc with original approach but detect repository duplicates
        src_uri_file = Path("src_uri.inc")
        with open(src_uri_file, 'w') as f:
            f.write(f"# Generated by go_mod_fetcher.py v{VERSION}\n")
            f.write("# OpenEmbedded SRC_URI entries for Go module dependencies\n\n")

            # Track which module paths we've already processed to avoid true duplicates
            # Use module path instead of repository URL to allow multiple modules from same repo
            processed_modules = set()

            for src_uri in self.oe_src_uris:
                # Extract module path from destsuffix to detect true duplicates
                module_path = self.extract_module_path_from_src_uri(src_uri)
                if module_path and module_path not in processed_modules:
                    f.write(f"SRC_URI += \"{src_uri}\"\n")
                    processed_modules.add(module_path)
                    print(f"    📁 Added SRC_URI for module: {module_path}")
                elif module_path in processed_modules:
                    print(f"    ⚠️  Skipped duplicate module: {module_path}")
                else:
                    # Fallback: include entries without detectable module paths
                    f.write(f"SRC_URI += \"{src_uri}\"\n")

            # Generate SRC_URI entries for analysis_only modules that were missing
            analysis_only_modules = [m for m in self.oe_modules if m.get('analysis_only', False)]
            if analysis_only_modules:
                print(f"    🔧 Generating SRC_URI entries for {len(analysis_only_modules)} analysis-only modules...")
                for module_info in analysis_only_modules:
                    module_path = module_info['path']
                    if module_path not in processed_modules:
                        # Generate SRC_URI entry for missing module
                        src_uri = self.generate_fallback_src_uri(module_path, module_info['safe_name'])
                        if src_uri:
                            f.write(f"SRC_URI += \"{src_uri}\"\n")
                            processed_modules.add(module_path)
                            print(f"    📁 Added fallback SRC_URI for analysis-only module: {module_path}")


        # Write relocation.inc
        relocation_file = Path("relocation.inc")
        with open(relocation_file, 'w') as f:
            f.write(f"# Generated by go_mod_fetcher.py v{VERSION}\n")
            f.write("# Commands to relocate Go modules into vendor structure\n")
            f.write("# Use in do_compile_prepend() functions\n\n")

            # Write efficient relocation function (emergency simple approach)
            f.write("# Fast relocation function using simple copy\n")
            f.write("relocate_go_module() {\n")
            f.write("    local src_dir=\"$1\"\n")
            f.write("    local dest_path=\"$2\"\n")
            f.write("    local safe_name=\"$3\"\n")
            f.write("    local module_path=\"$4\"\n")
            f.write("    local dest_dir=\"${S}/src/import/vendor/${dest_path}\"\n")
            f.write("    local parent_dir\n")
            f.write("    parent_dir=$(dirname \"${dest_dir}\")\n")
            f.write("\n")
            f.write("    echo \"[DEBUG] Relocating ${dest_path}\"\n")
            f.write("    echo \"[DEBUG] Source: ${src_dir}\"\n")
            f.write("    echo \"[DEBUG] Dest: ${dest_dir}\"\n")
            f.write("    echo \"[DEBUG] Parent Dest: ${parent_dir}\"\n")
            f.write("\n")
            f.write("    # Check if source directory exists\n")
            f.write("    if [ ! -d \"${src_dir}\" ]; then\n")
            f.write("        echo \"ERROR: Source directory ${src_dir} not found!\"\n")
            f.write("        return 1\n")
            f.write("    fi\n")
            f.write("\n")
            f.write("    # Check if source has any files\n")
            f.write("    local file_count\n")
            f.write("    file_count=$(find \"${src_dir}\" -type f | wc -l)\n")
            f.write("    echo \"[DEBUG] Source contains ${file_count} files\"\n")
            f.write("    if [ \"$file_count\" -eq 0 ]; then\n")
            f.write("        echo \"ERROR: Source directory ${src_dir} is empty!\"\n")
            f.write("        return 1\n")
            f.write("    fi\n")
            f.write("\n")
            f.write("    # Create parent directory\n")
            f.write("    mkdir -p \"${parent_dir}\"\n")
            f.write("    if [ ! -d \"${parent_dir}\" ]; then\n")
            f.write("        echo \"CRITICAL ERROR: Failed to create parent directory ${parent_dir}\"\n")
            f.write("        return 1\n")
            f.write("    fi\n")
            f.write("    echo \"[DEBUG] Parent destination directory created successfully.\"\n")
            f.write("    echo \"[DEBUG] Listing parent directory contents:\"\n")
            f.write("    ls -la \"${parent_dir}\"\n")
            f.write("\n")
            f.write("    # Remove existing destination and create fresh directory\n")
            f.write("    rm -rf \"${dest_dir}\"\n")
            f.write("    mkdir -p \"${dest_dir}\"\n")
            f.write("    if [ ! -d \"${dest_dir}\" ]; then\n")
            f.write("        echo \"CRITICAL ERROR: Failed to create destination directory ${dest_dir}\"\n")
            f.write("        return 1\n")
            f.write("    fi\n")
            f.write("    echo \"[DEBUG] Destination directory created successfully.\"\n")
            f.write("    echo \"[DEBUG] Listing destination directory contents:\"\n")
            f.write("    ls -la \"${dest_dir}\"\n")
            f.write("\n")
            f.write("    # Determine source path - handle submodule paths intelligently\n")
            f.write("    local effective_src_dir=\"${src_dir}\"\n")
            f.write("\n")
            f.write("    # GENERALIZED SUBMODULE DETECTION\n")
            f.write("    # Parse modules.txt to detect parent-child module relationships dynamically\n")
            f.write("    local repo_base=\"\"\n")
            f.write("    local subpath=\"\"\n")
            f.write("\n")
            f.write("    # Check if this module is a submodule by finding parent modules\n")
            f.write("    # Try multiple locations for modules.txt\n")
            f.write("    local modules_txt=\"${UNPACKDIR}/modules.txt\"\n")
            f.write("    if [ ! -f \"${modules_txt}\" ]; then\n")
            f.write("        modules_txt=\"${S}/../modules.txt\"\n")
            f.write("    fi\n")
            f.write("    if [ ! -f \"${modules_txt}\" ]; then\n")
            f.write("        modules_txt=\"${S}/src/import/vendor/modules.txt\"\n")
            f.write("    fi\n")
            f.write("    if [ -f \"${modules_txt}\" ]; then\n")
            f.write("        # Extract all module declarations from modules.txt\n")
            f.write("        local all_modules\n")
            f.write("        all_modules=$(grep '^# ' \"${modules_txt}\" | sed 's/^# //' | cut -d' ' -f1)\n")
            f.write("        \n")
            f.write("        # Find the shortest base module path that is a prefix of current module\n")
            f.write("        # This helps find the repository root rather than intermediate modules\n")
            f.write("        local shortest_parent=\"\"\n")
            f.write("        local shortest_length=999999\n")
            f.write("        \n")
            f.write("        for potential_parent in $all_modules; do\n")
            f.write("            # Skip if potential parent is same as current module\n")
            f.write("            if [ \"$potential_parent\" = \"${module_path}\" ]; then\n")
            f.write("                continue\n")
            f.write("            fi\n")
            f.write("            \n")
            f.write("            # Check if potential_parent is a prefix of module_path\n")
            f.write("            if echo \"${module_path}\" | grep -q \"^${potential_parent}/\"; then\n")
            f.write("                parent_length=$(echo \"$potential_parent\" | wc -c)\n")
            f.write("                # Find the shortest (most base) parent, not the longest\n")
            f.write("                if [ $parent_length -lt $shortest_length ]; then\n")
            f.write("                    shortest_parent=\"$potential_parent\"\n")
            f.write("                    shortest_length=$parent_length\n")
            f.write("                fi\n")
            f.write("            fi\n")
            f.write("        done\n")
            f.write("        \n")
            f.write("        # If we found a parent module, extract the subpath\n")
            f.write("        if [ -n \"$shortest_parent\" ]; then\n")
            f.write("            repo_base=\"$shortest_parent\"\n")
            f.write("            subpath=$(echo \"${module_path}\" | sed \"s|^${shortest_parent}/||\")\n")
            f.write("            echo \"[DEBUG] DYNAMIC: Detected submodule relationship: parent=${repo_base}, subpath=${subpath}\"\n")
            f.write("            \n")
            f.write("            # Check if the subpath exists in the source directory\n")
            f.write("            if [ -n \"${subpath}\" ] && [ -d \"${src_dir}/${subpath}\" ]; then\n")
            f.write("                effective_src_dir=\"${src_dir}/${subpath}\"\n")
            f.write("                echo \"[DEBUG] DYNAMIC: Using subpath source: ${effective_src_dir}\"\n")
            f.write("            else\n")
            f.write("                echo \"[DEBUG] DYNAMIC: Subpath ${subpath} not found in ${src_dir}, using full source\"\n")
            f.write("            fi\n")
            f.write("        else\n")
            f.write("            echo \"[DEBUG] DYNAMIC: No parent module found for ${module_path}, using full source\"\n")
            f.write("        fi\n")
            f.write("    else\n")
            f.write("        echo \"[DEBUG] DYNAMIC: modules.txt not found, using full source\"\n")
            f.write("    fi\n")
            f.write("\n")
            f.write("    # VENDOR REFERENCE STRUCTURE MAPPINGS\n")
            f.write("    # Generated from analysis of vendor reference structure\n")

            # Generate the vendor mappings code dynamically
            if vendor_mappings:
                f.write(f"    echo \"[DEBUG] Checking vendor structure mappings for ${{module_path}}...\"\n")
                for module_path, mapping_info in vendor_mappings.items():
                    subdir = mapping_info['source_subdir']
                    reason = mapping_info['reason']
                    f.write(f"\n")
                    f.write(f"    # {reason}\n")
                    f.write(f"    if [ \"${{module_path}}\" = \"{module_path}\" ]; then\n")
                    f.write(f"        if [ -d \"${{src_dir}}/{subdir}\" ]; then\n")
                    f.write(f"            effective_src_dir=\"${{src_dir}}/{subdir}\"\n")
                    f.write(f"            echo \"[DEBUG] VENDOR MAPPING: Using {subdir}/ subdir for ${{module_path}}\"\n")
                    f.write(f"        else\n")
                    f.write(f"            echo \"[DEBUG] VENDOR MAPPING: {subdir}/ subdir not found for ${{module_path}}\"\n")
                    f.write(f"        fi\n")
                    f.write(f"    fi\n")

            f.write("\n")
            f.write("    # End of generalized submodule detection\n")
            f.write("\n")
            f.write("    echo \"[DEBUG] Final source directory: ${effective_src_dir}\"\n")
            f.write("\n")
            f.write("    # Verify source directory exists\n")
            f.write("    if [ ! -d \"${effective_src_dir}\" ]; then\n")
            f.write("        echo \"ERROR: Effective source directory ${effective_src_dir} not found!\"\n")
            f.write("        echo \"[DEBUG] Available directories in ${src_dir}:\"\n")
            f.write("        ls -la \"${src_dir}\" | head -10\n")
            f.write("        return 1\n")
            f.write("    fi\n")
            f.write("\n")
            f.write("    # Copy using tar for better reliability with complex structures\n")
            f.write("    echo \"[DEBUG] Copying files using tar from ${effective_src_dir}...\"\n")
            f.write("    echo \"[DEBUG] Source contents before copy:\"\n")
            f.write("    find \"${effective_src_dir}\" -type f -name '*.go' | head -10\n")
            f.write("    # Use more robust copy with explicit error checking\n")
            f.write("    echo \"[DEBUG] Starting tar copy process...\"\n")
            f.write("    echo \"[DEBUG] Source dir exists: $([ -d \"${effective_src_dir}\" ] && echo YES || echo NO)\"\n")
            f.write("    echo \"[DEBUG] Dest dir exists: $([ -d \"${dest_dir}\" ] && echo YES || echo NO)\"\n")
            f.write("    \n")
            f.write("    # Test cd commands separately first\n")
            f.write("    if ! cd \"${effective_src_dir}\"; then\n")
            f.write("        echo \"ERROR: Cannot cd to source directory ${effective_src_dir}\"\n")
            f.write("        return 1\n")
            f.write("    fi\n")
            f.write("    if ! cd \"${dest_dir}\"; then\n")
            f.write("        echo \"ERROR: Cannot cd to destination directory ${dest_dir}\"\n")
            f.write("        return 1\n")
            f.write("    fi\n")
            f.write("    \n")
            f.write("    # Now do the actual copy with better error detection\n")
            f.write("    if tar cf - -C \"${effective_src_dir}\" . | tar xf - -C \"${dest_dir}\"; then\n")
            f.write("        echo \"[DEBUG] Tar copy completed, verifying immediately...\"\n")
            f.write("        \n")
            f.write("        # Immediate verification that destination still exists and has content\n")
            f.write("        if [ ! -d \"${dest_dir}\" ]; then\n")
            f.write("            echo \"ERROR: Destination directory disappeared immediately after tar copy!\"\n")
            f.write("            echo \"[DEBUG] This suggests build system interference or race condition\"\n")
            f.write("            return 1\n")
            f.write("        fi\n")
            f.write("        \n")
            f.write("        # Count files to ensure copy actually worked\n")
            f.write("        local copied_files\n")
            f.write("        copied_files=$(find \"${dest_dir}\" -type f | wc -l)\n")
            f.write("        echo \"[DEBUG] Copied ${copied_files} files to destination\"\n")
            f.write("        \n")
            f.write("        if [ \"$copied_files\" -eq 0 ]; then\n")
            f.write("            echo \"ERROR: No files were actually copied despite successful tar!\"\n")
            f.write("            echo \"[DEBUG] Source file count was: ${file_count}\"\n")
            f.write("            echo \"[DEBUG] This indicates a tar extraction issue\"\n")
            f.write("            return 1\n")
            f.write("        fi\n")
            f.write("        \n")
            f.write("        echo \"[DEBUG] Verifying critical paths exist in destination:\"\n")
            f.write("        # Check for common package structure patterns\n")
            f.write("        if echo \"${module_path}\" | grep -q \"github.com/docker/docker\"; then\n")
            f.write("            for subpath in api/types pkg opts; do\n")
            f.write("                if [ -d \"${dest_dir}/${subpath}\" ]; then\n")
            f.write("                    echo \"[DEBUG] ✅ Found ${subpath}/ in destination\"\n")
            f.write("                else\n")
            f.write("                    echo \"[DEBUG] ❌ Missing ${subpath}/ in destination\"\n")
            f.write("                fi\n")
            f.write("            done\n")
            f.write("        fi\n")
            f.write("        \n")
            f.write("        echo \"[DEBUG] Tar copy successful - ${copied_files} files copied\"\n")
            f.write("    else\n")
            f.write("        echo \"ERROR: Tar copy failed from ${effective_src_dir} to ${dest_dir}\"\n")
            f.write("        echo \"[DEBUG] Trying to copy with cp -r\"\n")
            f.write("        cp -r \"${effective_src_dir}/.\" \"${dest_dir}/\"\n")
            f.write("        if [ $? -ne 0 ]; then\n")
            f.write("            echo \"ERROR: cp -r also failed\"\n")
            f.write("            return 1\n")
            f.write("        fi\n")
            f.write("    fi\n")
            f.write("\n")
            f.write("    # Verify directory existence immediately after copy\n")
            f.write("    if [ ! -d \"${dest_dir}\" ]; then\n")
            f.write("        echo \"CRITICAL ERROR: Destination directory ${dest_dir} disappeared after tar copy!\"\n")
            f.write("        return 1\n")
            f.write("    fi\n")
            f.write("    echo \"[DEBUG] Destination directory still exists after copy.\"\n")
            f.write("    echo \"[DEBUG] Listing destination directory contents after copy:\"\n")
            f.write("    ls -la \"${dest_dir}\"\n")
            f.write("    \n")
            f.write("    # TEMPORARILY DISABLED: Clean up unwanted files (post-copy cleanup)\n")
            f.write("    # This cleanup might be causing the directory deletion issue\n")
            f.write("    echo \"[DEBUG] Skipping cleanup to avoid accidental file deletion\"\n")
            f.write("    # find \"${dest_dir}\" -name '*_test.go' -delete 2>/dev/null || true\n")
            f.write("    # find \"${dest_dir}\" -name 'testdata' -type d -exec rm -rf {} + 2>/dev/null || true\n")
            f.write("    # find \"${dest_dir}\" -name 'example*' -type d -exec rm -rf {} + 2>/dev/null || true\n")
            f.write("    # find \"${dest_dir}\" -name 'doc*' -type d -exec rm -rf {} + 2>/dev/null || true\n")
            f.write("    # find \"${dest_dir}\" -name '*.md' -delete 2>/dev/null || true\n")
            f.write("    # find \"${dest_dir}\" -name 'Makefile*' -delete 2>/dev/null || true\n")
            f.write("    # find \"${dest_dir}\" -name 'Dockerfile*' -delete 2>/dev/null || true\n")
            f.write("    # find \"${dest_dir}\" -name '.git*' -exec rm -rf {} + 2>/dev/null || true\n")
            f.write("    \n")
            f.write("    # Verify we actually copied Go files\n")
            f.write("    local go_count\n")
            f.write("    go_count=$(find \"${dest_dir}\" -name '*.go' | wc -l)\n")
            f.write("    echo \"[DEBUG] Destination contains ${go_count} Go files after copy\"\n")
            f.write("    if [ \"$go_count\" -eq 0 ]; then\n")
            f.write("        echo \"ERROR: No Go files found in ${dest_dir} after copy!\"\n")
            f.write("        echo \"[DEBUG] Listing what we did copy:\"\n")
            f.write("        find \"${dest_dir}\" -type f | head -10\n")
            f.write("        return 1\n")
            f.write("    fi\n")
            f.write("    \n")
            f.write("    echo \"SUCCESS: Relocated ${dest_path} (${go_count} Go files)\"\n")
            f.write("    return 0\n")
            f.write("}\n\n")

            f.write("do_install_go_vendor() {\n")
            f.write("    # Create Go vendor directory structure in standard Go source layout\n")
            f.write("    mkdir -p ${S}/src/import/vendor\n")
            f.write("    \n")
            f.write("    echo \"Starting Go module relocation (repository-based approach)...\"\n")
            f.write("    local relocated_count=0\n\n")

            # Generate dynamic repository data parsing function
            print("🔍 Generating dynamic repository data parsing...")
            # Reuse the repository groups analysis from src_uri.inc generation
            relocation_data = self.generate_dynamic_relocation_data(repo_groups)

            f.write("    # Dynamic repository data generation from src_uri.inc\n")
            f.write("    parse_src_uri_and_generate_repo_data() {\n")
            f.write("        local src_uri_file=\"${THISDIR}/src_uri.inc\"\n")
            # Generate dynamic provides lookup function from the repository analysis
            f.write("        \n")
            f.write("        # Dynamic provides calculation - embedded repository analysis\n")
            f.write("        get_provides_for_module() {\n")
            f.write("            local module_path=\"$1\"\n")
            f.write("            \n")

            # Embed the relocation data as case statements (exact matches first)
            f.write("            case \"$module_path\" in\n")
            for repo_module, provided_modules in relocation_data.items():
                if len(provided_modules) > 1:
                    provides_list = ' '.join(provided_modules)
                    f.write(f"                {repo_module})\n")
                    f.write(f"                    echo \"{provides_list}\"\n")
                    f.write("                    ;;\n")
            f.write("                *)\n")

            # Add dynamic parent detection for submodules
            f.write("                    # Try to find parent module for submodules\n")
            for repo_module, provided_modules in relocation_data.items():
                if len(provided_modules) > 1:
                    provides_list = ' '.join(provided_modules)
                    f.write(f"                    if echo \"$module_path\" | grep -q \"^{repo_module}/\"; then\n")
                    f.write(f"                        echo \"{provides_list}\"\n")
                    f.write("                        return\n")
                    f.write("                    fi\n")
            f.write("                    # Default: module provides itself\n")
            f.write("                    echo \"$module_path\"\n")
            f.write("                    ;;\n")
            f.write("            esac\n")
            f.write("        }\n")
            f.write("        \n")
            f.write("        local repo_count=0\n")
            f.write("\n")
            f.write("        echo \"[DEBUG] Using SRC_URI variable approach for repository data...\"\n")
            f.write("        echo \"[DEBUG] SRC_URI variable is set: $([ -n \"${SRC_URI}\" ] && echo YES || echo NO)\"\n")
            f.write("        \n")
            f.write("        # Process SRC_URI variable - group entries by repository URL to avoid duplicates\n")
            f.write("        local temp_file=\"/tmp/src_uri_$$.tmp\"\n")
            f.write("        local temp_repos=\"/tmp/repos_$$.tmp\"\n")
            f.write("        echo \"${SRC_URI}\" > \"$temp_file\"\n")
            f.write("        \n")
            f.write("        # First pass: extract all git repositories and their modules\n")
            f.write("        while IFS=' ' read -r line || [ -n \"$line\" ]; do\n")
            f.write("            for uri_part in $line; do\n")
            f.write("                [ -z \"$uri_part\" ] && continue\n")
            f.write("\n")
            f.write("                if echo \"$uri_part\" | grep -q \"destsuffix=\\${GO_SRCURI_DESTSUFFIX}/modules/\"; then\n")
            f.write("                    # Extract repository URL (everything before the semicolon)\n")
            f.write("                    local repo_url\n")
            f.write("                    repo_url=$(echo \"$uri_part\" | sed 's/;.*//')\n")
            f.write("                    local module_source\n")
            f.write("                    module_source=$(echo \"$uri_part\" | sed 's/.*\\/modules\\/\\([^;\" ]*\\).*/\\1/')\n")
            f.write("                    local module_path\n")
            f.write("                    module_path=$(echo \"$module_source\" | tr '_' '/')\n")
            f.write("                    \n")
            f.write("                    # Store repo_url:module_path:module_source for grouping\n")
            f.write("                    echo \"$repo_url|$module_path|$module_source\" >> \"$temp_repos\"\n")
            f.write("                fi\n")
            f.write("            done\n")
            f.write("        done < \"$temp_file\"\n")
            f.write("        \n")
            f.write("        # Process each module individually like the static version\n")
            f.write("        while IFS='|' read -r repo_url module_path module_source || [ -n \"$repo_url\" ]; do\n")
            f.write("            [ -z \"$repo_url\" ] && continue\n")
            f.write("            \n")
            f.write("            # Get provides list dynamically\n")
            f.write("            local provides\n")
            f.write("            provides=$(get_provides_for_module \"$module_path\")\n")
            f.write("            \n")
            f.write("            eval \"repo_${repo_count}_module='$module_path'\"\n")
            f.write("            eval \"repo_${repo_count}_source='$module_source'\"\n")
            f.write("            eval \"repo_${repo_count}_provides='$provides'\"\n")
            f.write("\n")
            f.write("            echo \"[DEBUG] repo_${repo_count}: module=$module_path source=$module_source provides=$provides\"\n")
            f.write("            repo_count=`expr $repo_count + 1`\n")
            f.write("        done < \"$temp_repos\"\n")
            f.write("        \n")
            f.write("        # Clean up temp files\n")
            f.write("        rm -f \"$temp_file\" \"$temp_repos\"\n")
            f.write("        \n")
            f.write("        total_repos=$repo_count\n")
            f.write("        echo \"[DEBUG] Parsed $total_repos repositories from SRC_URI variable\"\n")
            f.write("    }\n")
            f.write("    \n")
            f.write("    # Parse repository data dynamically\n")
            f.write("    parse_src_uri_and_generate_repo_data\n")
            f.write(f"\n")

            # Generate the repository-based processing loop
            f.write("    # Process repositories to copy each repository once to its declared module location\n")
            f.write("    local i=0\n")
            f.write("    while [ $i -lt $total_repos ]; do\n")
            f.write("        # Get repository data using indirect variable expansion\n")
            f.write("        eval \"local repo_module=\\$repo_${i}_module\"\n")
            f.write("        eval \"local repo_source=\\$repo_${i}_source\"\n")
            f.write("        eval \"local repo_provides=\\$repo_${i}_provides\"\n")
            f.write("        \n")
            f.write("        echo \"[$(expr $i + 1)/$total_repos] Repository: $repo_module\"\n")
            f.write("        echo \"[DEBUG] Source: $repo_source\"\n")
            f.write("        echo \"[DEBUG] Provides modules: $repo_provides\"\n")
            f.write("        \n")
            f.write("        # Process each module provided by this repository entry\n")
            f.write("        local provided_modules=\"$repo_provides\"\n")
            f.write("        for provided_module in $provided_modules; do\n")
            f.write("            echo \"[DEBUG] Relocating ${provided_module}\"\n")
            f.write("            \n")
            f.write("            # CRITICAL FIX: Check if this is a submodule that needs subpath extraction\n")
            f.write("            local effective_source_dir=\"${S}/src/import/modules/${repo_source}\"\n")
            f.write("            \n")

            # Generate submodule detection logic using the repository analysis data
            f.write("            # Submodule path detection - generated from repository analysis\n")
            for repo_module, modules in repo_groups.items():
                for module_info in modules:
                    if module_info['is_submodule']:
                        module_path = module_info['module_path']
                        actual_repo_module = module_info['repo_module']

                        # Use the pre-computed subpath from combined detection (generic + overrides)
                        subpath = module_info.get('subpath')
                        if not subpath:
                            print(f"    ⚠️  WARNING: No subpath found for submodule {module_path}, skipping")
                            continue

                        safe_name = module_info['safe_name']
                        f.write(f"            if [ \"$provided_module\" = \"{module_path}\" ]; then\n")
                        f.write(f"                # Submodule {module_path} -> use subpath '{subpath}'\n")
                        f.write(f"                if [ -d \"${{S}}/src/import/modules/{safe_name}/{subpath}\" ]; then\n")
                        f.write(f"                    effective_source_dir=\"${{S}}/src/import/modules/{safe_name}/{subpath}\"\n")
                        f.write(f"                    echo \"[DEBUG] SUBMODULE FIX: Using subpath source: $effective_source_dir\"\n")
                        f.write("                else\n")
                        f.write(f"                    echo \"[DEBUG] SUBMODULE: Subpath {subpath} not found, using full repository\"\n")
                        f.write("                fi\n")
                        f.write("            fi\n")

            f.write("            \n")
            f.write("            if relocate_go_module \"$effective_source_dir\" \"$provided_module\" \"$repo_source\" \"$provided_module\"; then\n")
            f.write("                echo \"SUCCESS: Module $provided_module relocated\"\n")
            f.write("            else\n")
            f.write("                echo \"ERROR: Failed to relocate module $provided_module\"\n")
            f.write("            fi\n")
            f.write("        done\n")
            f.write("        relocated_count=`expr $relocated_count + 1`\n")
            f.write("        \n")
            f.write("        i=`expr $i + 1`\n")
            f.write("    done\n\n")

            # Handle stub modules separately
            f.write("    # Handle stub modules (local replaces, etc.)\n")
            for module_info in self.oe_modules:
                if module_info.get('is_stub', False):
                    module_path = module_info['path']
                    if 'tigron' in module_path:
                        f.write("    # Special handling for tigron - it's a local replace that needs relocation\n")
                        f.write(f"    echo \"Special handling for local replace module: {module_path}\"\n")
                        f.write("    local tigron_src=\"${S}/src/import/mod/tigron\"\n")
                        f.write(f"    local tigron_dest=\"${{S}}/src/import/vendor/{module_path}\"\n\n")
                        f.write("    if [ -d \"$tigron_src\" ]; then\n")
                        f.write("        echo \"[DEBUG] Copying tigron from local source: $tigron_src -> $tigron_dest\"\n")
                        f.write("        mkdir -p \"$(dirname \"$tigron_dest\")\"\n")
                        f.write("        rm -rf \"$tigron_dest\"\n")
                        f.write("        cp -r \"$tigron_src\" \"$tigron_dest\"\n")
                        f.write("        if [ -d \"$tigron_dest\" ]; then\n")
                        f.write("            echo \"SUCCESS: Relocated tigron module from local source\"\n")
                        f.write("            relocated_count=`expr $relocated_count + 1`\n")
                        f.write("        else\n")
                        f.write("            echo \"ERROR: Failed to copy tigron from local source\"\n")
                        f.write("        fi\n")
                        f.write("    else\n")
                        f.write("        echo \"ERROR: Tigron source directory not found: $tigron_src\"\n")
                        f.write("    fi\n\n")

            f.write("    echo \"Module relocation complete: relocated $relocated_count modules\"\n\n")

            # Copy the generated modules.txt with proper markers
            f.write("    # Copy the generated modules.txt with proper explicit/replaced markers\n")
            f.write("    if [ -f \"${UNPACKDIR}/modules.txt\" ]; then\n")
            f.write("        cp \"${UNPACKDIR}/modules.txt\" \"${S}/src/import/vendor/modules.txt\"\n")
            f.write("        echo \"Copied modules.txt with proper explicit/replaced markers\"\n")
            f.write("    else\n")
            f.write("        echo \"Warning: modules.txt not found in UNPACKDIR, vendor may be incomplete\"\n")
            f.write("    fi\n")
            f.write("}\n\n")

            f.write("# Add to your recipe:\n")
            f.write("# inherit go\n")
            f.write("# SRC_URI += \"file://src_uri.inc file://relocation.inc file://modules.txt\"\n")
            f.write("# include src_uri.inc\n")
            f.write("# include relocation.inc\n")
            f.write("# do_compile_prepend() {\n")
            f.write("#     do_install_go_vendor\n")
            f.write("# }\n")
            f.write("#\n")
            f.write("# Benefits:\n")
            f.write("# - Generated modules.txt with proper explicit/replaced markers from go.mod parsing\n")
            f.write("# - Extensive debugging output to diagnose relocation issues\n")
            f.write("# - Multiple copy methods (cp + tar fallback) for reliability\n")
            f.write("# - BitBake compatible shell syntax (no $((...))\n")
            f.write("# - Loop-based approach eliminates code repetition\n")
            f.write("# - Comprehensive error handling and verification\n")

        # Vendor directory no longer needed for final output (removed vendor tarball approach)

        # Generate corrected go.sum for gomodgit compatibility when requested
        if self.generate_gomodgit:
            self.generate_gomodgit_go_sum()
        else:
            print("\n⏭️  Skipping go.sum.gomodgit generation (use --generate-gomodgit to enable)")

        print(f"\n✅ OpenEmbedded files generated:")
        print(f"   📄 modules.txt - Copied from 'go mod vendor' output.")
        print(f"   📄 src_uri.inc - Generated with SRC_URI entries for each module.")
        print(f"   📄 relocation.inc - Generated with individual module relocation commands.")
        if self.generate_gomodgit:
            print(f"   📄 go.sum.gomodgit - Corrected checksums for gomodgit compatibility.")
        else:
            print(f"   ⏭️  go.sum.gomodgit not generated (use --generate-gomodgit if needed).")
        print(f"\n💡 Add these files to your recipe with:")
        if self.generate_gomodgit:
            print(f"   SRC_URI += \"file://modules.txt file://src_uri.inc file://relocation.inc file://go.sum.gomodgit\"")
        else:
            print(f"   SRC_URI += \"file://modules.txt file://src_uri.inc file://relocation.inc\"")

    def calculate_zip_checksum_using_go(self, zip_path):
        """
        Calculate checksum for a zip file using Go's ACTUAL dirhash implementation.

        This calls Go's golang.org/x/mod/sumdb/dirhash.HashZip via a compiled helper binary
        instead of trying to replicate the algorithm in Python (which produces wrong results).

        Returns: Checksum in format "h1:base64(sha256)"
        """
        import subprocess
        from pathlib import Path

        try:
            go_helper = self.get_dirhash_helper()
        except FileNotFoundError as exc:
            raise FileNotFoundError(str(exc))

        try:
            result = subprocess.run(
                [str(go_helper), str(zip_path)],
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode != 0:
                raise RuntimeError(f"Go dirhash failed: {result.stderr}")

            checksum = result.stdout.strip()
            if not checksum.startswith("h1:"):
                raise ValueError(f"Invalid checksum format: {checksum}")

            return checksum

        except subprocess.TimeoutExpired:
            raise RuntimeError(f"Timeout calculating checksum for {zip_path}")
        except Exception as e:
            raise RuntimeError(f"Error calculating checksum for {zip_path}: {e}")

    def generate_gomodgit_go_sum_for_hybrid(self, source_dir: Path):
        """Generate go.sum.gomodgit with HYBRID approach: VCS zips + sum.golang.org .mod checksums.

        This version:
        1. Creates temporary hybrid-style zips (same as module_cache_task.inc)
        2. Calculates .zip checksums using Go's dirhash implementation (from OUR VCS builds)
        3. Fetches .mod checksums from sum.golang.org (uses unknown algorithm we can't replicate)
        4. Network is AVAILABLE here (during script execution), unlike during BitBake build
        """
        print("    📂 Creating hybrid-style module cache and calculating checksums...")

        import tempfile
        import hashlib
        import base64
        import re
        import urllib.request
        import urllib.error
        from pathlib import Path

        try:
            # Check if we have module information
            if not hasattr(self, 'processed_modules') or not self.processed_modules:
                print("    ❌ No processed modules available for checksum generation")
                self.fallback_go_sum_generation()
                return

            print(f"    📂 Processing {len(self.processed_modules)} modules...")

            # Create temporary directory for module cache
            with tempfile.TemporaryDirectory(prefix='hybrid-cache-') as temp_cache_root:
                cache_dir = Path(temp_cache_root) / "pkg" / "mod" / "cache"
                cache_dir.mkdir(parents=True, exist_ok=True)

                # Create zip files using the EXACT same method as module_cache_task.inc
                print(f"    🔧 Creating hybrid-style zip files...")

                success_count = 0
                for module_info in self.processed_modules:
                    if self.create_hybrid_style_zip(module_info, cache_dir):
                        success_count += 1

                print(f"    ✅ Created {success_count} hybrid-style zip files")

                if success_count == 0:
                    print("    ❌ No zip files created - using fallback")
                    self.fallback_go_sum_generation()
                    return

                # Now calculate checksums using HYBRID approach
                print(f"    🔢 Calculating checksums using HYBRID approach...")
                print(f"       • .zip checksums: Go's dirhash (from OUR VCS builds)")
                print(f"       • .mod checksums: sum.golang.org (uses unknown algorithm)")

                checksums = {}
                download_dir = cache_dir / "download"

                for zip_file in download_dir.rglob("*.zip"):
                    try:
                        # Calculate zip checksum using Go's ACTUAL dirhash implementation
                        zip_checksum = self.calculate_zip_checksum_using_go(zip_file)

                        # Extract module path and version from file path FIRST
                        # Path: cache/download/escaped_module/@v/escaped_version.zip
                        parts = zip_file.parts
                        v_index = parts.index('@v')
                        download_index = parts.index('download')

                        escaped_module_parts = parts[download_index + 1:v_index]
                        escaped_module = '/'.join(escaped_module_parts)
                        escaped_version = zip_file.stem

                        # Unescape module path and version
                        def unescape(s):
                            return re.sub(r'!([a-z])', lambda m: m.group(1).upper(), s)

                        module_path = unescape(escaped_module)
                        version = unescape(escaped_version)

                        # Fetch .mod checksum from sum.golang.org (network IS available here)
                        mod_checksum = None
                        try:
                            lookup_url = f"https://sum.golang.org/lookup/{module_path}@{version}"
                            response = urllib.request.urlopen(lookup_url, timeout=10)
                            content = response.read().decode('utf-8')

                            # Parse sum.golang.org response for .mod checksum
                            # Format: "module_path version/go.mod h1:xxxxx"
                            for line in content.strip().split('\n'):
                                if line.startswith(f"{module_path} {version}/go.mod h1:"):
                                    mod_checksum = line.split(' ', 2)[2]
                                    break

                            if mod_checksum:
                                print(f"      ✓ {module_path}@{version} (fetched .mod from sum.golang.org)")
                            else:
                                print(f"      ⚠️  {module_path}@{version} (.mod not in sum.golang.org)")

                        except urllib.error.HTTPError as e:
                            if e.code == 410:
                                print(f"      ⚠️  {module_path}@{version} (.mod not found in sum.golang.org - 410 Gone)")
                            else:
                                print(f"      ⚠️  {module_path}@{version} (HTTP {e.code} from sum.golang.org)")
                        except Exception as e:
                            print(f"      ⚠️  {module_path}@{version} (error fetching .mod: {e})")

                        module_version = f"{module_path} {version}"

                        if module_version not in checksums:
                            checksums[module_version] = {'zip': zip_checksum, 'mod': mod_checksum}

                    except Exception as e:
                        print(f"      ⚠️  Error processing {zip_file}: {e}")
                        continue

                # Write go.sum.gomodgit with HYBRID checksums
                output_path = Path("go.sum.gomodgit")
                with open(output_path, 'w') as f:
                    for module_version in sorted(checksums.keys()):
                        data = checksums[module_version]
                        f.write(f"{module_version} {data['zip']}\n")
                        if data['mod']:
                            f.write(f"{module_version}/go.mod {data['mod']}\n")

                num_entries = sum(2 if data['mod'] else 1 for data in checksums.values())
                num_with_mod = sum(1 if data['mod'] else 0 for data in checksums.values())
                print(f"    ✅ Generated {output_path} with {len(checksums)} modules ({num_entries} entries)")
                print(f"    🎯 Zip checksums: Go dirhash (from OUR VCS builds)")
                print(f"    🌐 Mod checksums: {num_with_mod} fetched from sum.golang.org")
                print(f"    📊 These checksums should match what Go expects during build validation")

                return

        except Exception as e:
            print(f"    ❌ Error generating hybrid checksums: {e}")
            import traceback
            traceback.print_exc()
            self.fallback_go_sum_generation()

    def generate_gomodgit_go_sum(self):
        """Generate go.sum.gomodgit with checksums that match the hybrid module cache.

        This simulates the EXACT same zip creation process as module_cache_task.inc
        to ensure checksums match what the build environment will calculate.
        """
        print("\n📝 Generating go.sum.gomodgit with hybrid-compatible checksums...")

        import tempfile
        import subprocess
        import shutil
        import zipfile
        import re
        import os
        from pathlib import Path

        try:
            # Check if we have module information
            if not hasattr(self, 'processed_modules') or not self.processed_modules:
                print("    ❌ No processed modules available for checksum generation")
                self.fallback_go_sum_generation()
                return

            # Use the same source we cloned for analysis
            if not self.temp_dir or not Path(self.temp_dir).exists():
                print("    ❌ No source directory available for checksum generation")
                self.fallback_go_sum_generation()
                return

            source_dir = Path(self.temp_dir)
            # Delegate to the hybrid version
            self.generate_gomodgit_go_sum_for_hybrid(source_dir)

        except Exception as e:
            print(f"    ❌ Error generating hybrid checksums: {e}")
            self.fallback_go_sum_generation()

    def create_hybrid_style_zip(self, module_info, cache_dir):
        """Create a zip file using the exact same method as module_cache_task.inc"""
        import tempfile
        import subprocess
        import zipfile
        import re
        from pathlib import Path

        try:
            module_path = module_info.get('module_path', '')
            version = module_info.get('version', '')
            repo_url = module_info.get('repo_url', '')
            commit = module_info.get('commit', '')
            subdir = module_info.get('subdir', '')

            if not all([module_path, version, repo_url, commit]):
                return False

            # Use correct escaping function that matches BitBake's gomod.py
            def escape_module_path(path):
                """Escape capital letters using exclamation points (same as BitBake gomod.py)"""
                return re.sub(r'([A-Z])', lambda m: '!' + m.group(1).lower(), path)

            escaped_module = escape_module_path(module_path)
            escaped_version = escape_module_path(version)

            download_dir = cache_dir / "download" / escaped_module / "@v"
            download_dir.mkdir(parents=True, exist_ok=True)

            zip_path = download_dir / f"{escaped_version}.zip"
            mod_path = download_dir / f"{escaped_version}.mod"

            # Use persistent cache directory for repositories
            repo_cache_dir = Path.home() / ".cache" / "oe-go-mod-fetcher" / "repos"
            repo_cache_dir.mkdir(parents=True, exist_ok=True)

            # Create a safe directory name from repo_url
            import hashlib
            repo_hash = hashlib.md5(repo_url.encode()).hexdigest()[:8]
            safe_repo_name = module_path.replace('/', '_').replace('.', '_')
            repo_dir = repo_cache_dir / f"{safe_repo_name}_{repo_hash}"
            lock_id = f"{safe_repo_name}_{repo_hash}"

            with self._acquire_repo_lock(lock_id):
                # Remove incomplete caches that lack a .git directory
                if repo_dir.exists() and not (repo_dir / ".git").exists():
                    print(f"    ♻️  Removing incomplete repository cache for {module_path}")
                    shutil.rmtree(repo_dir, ignore_errors=True)

                # Clone repository if not already cached
                if not repo_dir.exists():
                    print(f"    📥 Cloning {repo_url} (first time)...")
                    if not self._run_git_command_with_retry(
                        ["git", "clone", repo_url, str(repo_dir)],
                        cleanup=repo_dir,
                        description=f"git clone {repo_url}"
                    ):
                        return False
                else:
                    print(f"    ♻️  Using cached repository for {module_path}")
                    if not self._ensure_clean_worktree(repo_dir):
                        print(f"    ♻️  Repository cache for {module_path} is dirty or locked; re-cloning...")
                        shutil.rmtree(repo_dir, ignore_errors=True)
                        if not self._run_git_command_with_retry(
                            ["git", "clone", repo_url, str(repo_dir)],
                            cleanup=repo_dir,
                            description=f"git clone {repo_url}"
                        ):
                            return False

                # Checkout specific commit with retries and fetch fallbacks
                checkout_result = self._run_git_command_with_retry(
                    ["git", "checkout", "--force", commit],
                    cwd=repo_dir,
                    description=f"git checkout {commit}",
                    retries=1
                )
                if not checkout_result:
                    fallback_commands = [
                        ["git", "fetch", "--all"],
                        ["git", "fetch", "origin", commit],
                        ["git", "fetch", "--tags", "--force"],
                    ]
                    for fallback_cmd in fallback_commands:
                        fetch_result = self._run_git_command_with_retry(
                            fallback_cmd,
                            cwd=repo_dir,
                            description=" ".join(fallback_cmd),
                            retries=1
                        )
                        if not fetch_result:
                            continue
                        checkout_result = self._run_git_command_with_retry(
                            ["git", "checkout", "--force", commit],
                            cwd=repo_dir,
                            description=f"git checkout {commit}",
                            retries=1
                        )
                        if checkout_result:
                            break

                if not checkout_result:
                    print(f"    ♻️  Re-cloning repository for {module_path} due to persistent checkout failures")
                    shutil.rmtree(repo_dir, ignore_errors=True)
                    if not self._run_git_command_with_retry(
                        ["git", "clone", repo_url, str(repo_dir)],
                        cleanup=repo_dir,
                        description=f"git clone {repo_url}"
                    ):
                        return False
                    checkout_result = self._run_git_command_with_retry(
                        ["git", "checkout", "--force", commit],
                        cwd=repo_dir,
                        description=f"git checkout {commit}",
                        retries=1
                    )
                    if not checkout_result:
                        print(f"    ⚠️  Failed to checkout commit {commit} in {repo_url}")
                        return False

            # Get file list from git repository (EXACT same method as module_cache_task.inc)
            work_path = repo_dir
            if subdir:
                work_path = repo_dir / subdir

            cmd = ["git", "ls-tree", "-r", "--name-only", "HEAD"]
            if subdir:
                cmd.append(subdir)

            try:
                files = subprocess.check_output(cmd, cwd=repo_dir, text=True).strip().split('\n')
                files = [f for f in files if f.strip()]
            except subprocess.CalledProcessError:
                print(f"    ⚠️  Could not list files for {module_path}@{version}")
                return False

            # Create module zip file (EXACT same method as module_cache_task.inc)
            with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
                module_prefix = f"{module_path}@{version}/"
                expected_go_mod = f"{subdir}/go.mod" if subdir else "go.mod"

                excluded_prefixes: List[str] = []
                for file_path in files:
                    if file_path.endswith('go.mod') and file_path != expected_go_mod:
                        dir_path = os.path.dirname(file_path)
                        if dir_path:
                            excluded_prefixes.append(f"{dir_path}/")

                for file_path in files:
                    if subdir and not file_path.startswith(subdir):
                        continue
                    if any(file_path.startswith(excluded_prefix) for excluded_prefix in excluded_prefixes):
                        continue
                    if file_path.endswith('go.mod') and file_path != expected_go_mod:
                        # Skip nested module go.mod files to match Go's module zip layout
                        continue
                    try:
                        content = subprocess.check_output(
                            ["git", "cat-file", "blob", f"HEAD:{file_path}"],
                            cwd=repo_dir
                        )
                        archive_path = module_prefix + (file_path[len(subdir)+1:] if subdir else file_path)
                        zf.writestr(archive_path, content)
                    except subprocess.CalledProcessError:
                        continue

            # Create go.mod file
            # For +incompatible versions, ALWAYS create minimal synthetic .mod (like proxy.golang.org)
            # This is CRITICAL for checksum matching!
            if '+incompatible' in version:
                # Synthetic minimal .mod for pre-module versions
                mod_content = f"module {module_path}\n".encode()
                print(f"    📝 Creating synthetic .mod for +incompatible version: {module_path}")
            else:
                # For proper module versions, use repository's go.mod
                mod_file = "go.mod"
                if subdir:
                    mod_file = f"{subdir}/go.mod"

                try:
                    mod_content = subprocess.check_output(
                        ["git", "cat-file", "blob", f"HEAD:{mod_file}"],
                        cwd=repo_dir
                    )
                except subprocess.CalledProcessError:
                    # Synthesize go.mod if not found
                    mod_content = f"module {module_path}\n".encode()

            with open(mod_path, 'wb') as f:
                f.write(mod_content)

            return True

        except Exception as e:
            print(f"    ⚠️  Failed to create hybrid zip for {module_path}: {e}")
            return False

    def create_hybrid_zip_for_module(self, module_info, cache_dir, temp_path):
        """Create a zip file for a module using hybrid approach logic (same as module_cache_task.inc)."""
        module_path = module_info.get('module_path', '')
        version = module_info.get('version', '')
        repo_url = module_info.get('repo_url', '')
        commit = module_info.get('commit', '')
        subdir = module_info.get('subdir', '')

        if not all([module_path, version, repo_url, commit]):
            print(f"    ⚠️  Skipping {module_path} - missing required info")
            return False

        try:
            # Clone repository
            repo_dir = temp_path / "repos" / module_path.replace("/", "_")
            repo_dir.mkdir(parents=True, exist_ok=True)

            # Clone and checkout
            subprocess.run([
                "git", "clone", "--quiet", repo_url, str(repo_dir)
            ], check=True, capture_output=True)

            subprocess.run([
                "git", "checkout", "--quiet", commit
            ], cwd=repo_dir, check=True, capture_output=True)

            # Create module cache structure (same escaping as module_cache_task.inc)
            def escape_module_path(path):
                import re
                return re.sub(r'([A-Z])', lambda m: '!' + m.group(1).lower(), path)

            escaped_module = escape_module_path(module_path)
            escaped_version = escape_module_path(version)

            download_dir = cache_dir / "download" / escaped_module / "@v"
            download_dir.mkdir(parents=True, exist_ok=True)

            zip_path = download_dir / f"{escaped_version}.zip"
            mod_path = download_dir / f"{escaped_version}.mod"

            # Get file list from git (same as module_cache_task.inc)
            cmd = ["git", "ls-tree", "-r", "--name-only", "HEAD"]
            if subdir:
                cmd.append(subdir)

            files = subprocess.check_output(cmd, cwd=repo_dir, text=True).strip().split('\n')
            files = [f for f in files if f.strip()]

            # Create zip file with same logic as module_cache_task.inc
            with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
                module_prefix = f"{module_path}@{version}/"
                expected_go_mod = f"{subdir}/go.mod" if subdir else "go.mod"

                excluded_prefixes: List[str] = []
                for file_path in files:
                    if file_path.endswith('go.mod') and file_path != expected_go_mod:
                        dir_path = os.path.dirname(file_path)
                        if dir_path:
                            excluded_prefixes.append(f"{dir_path}/")

                for file_path in files:
                    if subdir and not file_path.startswith(subdir):
                        continue
                    if any(file_path.startswith(excluded_prefix) for excluded_prefix in excluded_prefixes):
                        continue
                    if file_path.endswith('go.mod') and file_path != expected_go_mod:
                        continue

                    try:
                        content = subprocess.check_output(
                            ["git", "cat-file", "blob", f"HEAD:{file_path}"],
                            cwd=repo_dir
                        )
                        archive_path = module_prefix + (file_path[len(subdir)+1:] if subdir else file_path)
                        zf.writestr(archive_path, content)
                    except subprocess.CalledProcessError:
                        continue

            # Create go.mod file
            mod_file = "go.mod"
            if subdir:
                mod_file = f"{subdir}/go.mod"

            try:
                mod_content = subprocess.check_output(
                    ["git", "cat-file", "blob", f"HEAD:{mod_file}"],
                    cwd=repo_dir
                )
            except subprocess.CalledProcessError:
                mod_content = f"module {module_path}\n".encode()

            with open(mod_path, 'wb') as f:
                f.write(mod_content)

            return True

        except Exception as e:
            print(f"    ❌ Failed to create zip for {module_path}@{version}: {e}")
            return False

    def fallback_go_sum_generation(self):
        """Fallback to creating synthetic go.sum.gomodgit with placeholder checksums."""
        print("    🔄 Using fallback: creating synthetic go.sum.gomodgit...")

        output_path = Path("go.sum.gomodgit")

        # Look for original go.sum first
        original_sum = None
        temp_go_mod_dir = Path(self.temp_dir) if self.temp_dir else None
        main_repo_dir = None

        if temp_go_mod_dir:
            # Check main repo first
            main_repo_path = temp_go_mod_dir / "main_repo"
            if main_repo_path.exists() and (main_repo_path / "go.sum").exists():
                original_sum = main_repo_path / "go.sum"
                main_repo_dir = main_repo_path
            elif (temp_go_mod_dir / "go.sum").exists():
                original_sum = temp_go_mod_dir / "go.sum"

        if not original_sum:
            current_sum = Path("go.sum")
            if current_sum.exists():
                original_sum = current_sum

        if original_sum and original_sum.exists():
            # Copy original go.sum as base, but deduplicate entries
            seen = set()
            with open(output_path, 'w') as out:
                for line in original_sum.read_text().splitlines():
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    # Extract module@version as key for deduplication
                    parts = line.split()
                    if len(parts) >= 2:
                        key = f"{parts[0]} {parts[1]}"  # module version
                        if key not in seen:
                            seen.add(key)
                            out.write(line + '\n')
            print(f"    ✅ Created go.sum.gomodgit from {original_sum} ({len(seen)} unique entries)")
        else:
            # Create minimal synthetic file
            with open(output_path, 'w') as f:
                # Add synthetic entries for successfully processed modules
                if hasattr(self, 'processed_modules') and self.processed_modules:
                    for module_info in self.processed_modules:
                        module_path = module_info.get('module_path', '')
                        version = module_info.get('version', '')
                        if module_path and version and version != 'v0.0.0':
                            # Use synthetic checksum that build will override
                            f.write(f"{module_path} {version} h1:SYNTHETIC-CHECKSUM-BUILD-WILL-OVERRIDE\n")
                            f.write(f"{module_path} {version}/go.mod h1:SYNTHETIC-CHECKSUM-BUILD-WILL-OVERRIDE\n")

            print(f"    ⚠️  Created synthetic go.sum.gomodgit (build will generate actual checksums)")

    def generate_checksums_from_zip_files(self, cache_dir):
        """Generate go.sum.gomodgit by calculating checksums directly from hybrid zip files."""
        print("    📋 Calculating checksums directly from hybrid zip files...")

        import base64
        import hashlib
        import subprocess
        from pathlib import Path

        try:
            # Import the dirhash library (same as Go's internal checksum calculator)
            from golang.org.x.mod.sumdb import dirhash
        except ImportError:
            # Create a simple Go program to calculate checksums
            print("    🔧 Using Go's dirhash library for checksum calculation...")

        checksums = {}  # Track unique checksums by module@version
        download_dir = cache_dir / "download"

        if not download_dir.exists():
            print(f"    ❌ Download directory not found: {download_dir}")
            self.fallback_go_sum_generation()
            return

        print(f"    📂 Scanning zip files in: {download_dir}")

        # Find all .zip files in the module cache
        zip_files = list(download_dir.rglob("*.zip"))
        print(f"    📦 Found {len(zip_files)} zip files to process")

        if len(zip_files) == 0:
            print("    ❌ No zip files found in cache")
            self.fallback_go_sum_generation()
            return

        try:
            dirhash_helper = self.get_dirhash_helper()
        except FileNotFoundError as exc:
            print(f"    ❌ {exc}")
            self.fallback_go_sum_generation()
            return

        # Calculate checksum for each zip file
        for zip_path in zip_files:
            try:
                # Extract module path and version from directory structure
                # Path format: cache/download/github.com/owner/repo/@v/version.zip
                parts = zip_path.parts
                v_index = parts.index('@v')
                download_index = parts.index('download')

                # Get full module path from 'download' to '@v' (exclusive)
                escaped_module_parts = parts[download_index + 1:v_index]
                escaped_module = '/'.join(escaped_module_parts)
                escaped_version = zip_path.stem  # filename without .zip

                # Unescape module path and version (reverse the !lowercase escaping)
                import re
                def unescape_module_path(escaped):
                    """Reverse the !lowercase escaping used by Go module cache"""
                    def replace_escaped(match):
                        return match.group(1).upper()
                    return re.sub(r'!([a-z])', replace_escaped, escaped)

                module_path = unescape_module_path(escaped_module)
                version = unescape_module_path(escaped_version)

                # Use Go to calculate the checksum (most reliable method)
                result = subprocess.run(
                    [str(dirhash_helper), str(zip_path)],
                    capture_output=True,
                    text=True,
                    timeout=10
                )

                if result.returncode == 0:
                    checksum = result.stdout.strip()
                    module_version = f"{module_path} {version}"

                    # Calculate go.mod checksum from OUR .mod file (NOT from sum.golang.org)
                    # Our hybrid cache creates .mod files from raw git, so we MUST use those
                    mod_file_path = zip_path.parent / f"{zip_path.stem}.mod"
                    mod_checksum = None
                    if mod_file_path.exists():
                        import hashlib
                        import base64

                        mod_content = mod_file_path.read_bytes()
                        file_hash = hashlib.sha256(mod_content).hexdigest()
                        summary = f"{file_hash}  go.mod\n".encode('ascii')
                        digest = hashlib.sha256(summary).digest()
                        mod_checksum = "h1:" + base64.b64encode(digest).decode('ascii')

                    # Store unique checksums (avoid duplicates)
                    if module_version not in checksums:
                        checksums[module_version] = {'zip': checksum, 'mod': mod_checksum}
                        print(f"    ✓ {module_path}@{version}: {checksum[:20]}...")
                else:
                    print(f"    ⚠️  Failed to calculate checksum for {module_path}@{version}: {result.stderr}")

            except Exception as e:
                print(f"    ⚠️  Error processing {zip_path}: {e}")
                continue

        if not checksums:
            print("    ❌ No checksums calculated successfully")
            self.fallback_go_sum_generation()
            return

        # Write go.sum.gomodgit with calculated checksums
        output_path = Path("go.sum.gomodgit")
        with open(output_path, 'w') as f:
            # Sort by module path for consistency
            for module_version in sorted(checksums.keys()):
                checksum_data = checksums[module_version]
                zip_checksum = checksum_data['zip']
                mod_checksum = checksum_data['mod']

                # Write zip checksum
                f.write(f"{module_version} {zip_checksum}\n")

                # Write go.mod checksum (or placeholder if not available)
                if mod_checksum:
                    f.write(f"{module_version}/go.mod {mod_checksum}\n")
                else:
                    f.write(f"{module_version}/go.mod h1:0000000000000000000000000000000000000000000=\n")

        print(f"    ✅ Generated go.sum.gomodgit with {len(checksums)} modules ({len(checksums)*2} entries)")
        print(f"    🎯 Zip checksums: calculated from OUR hybrid zip files")
        print(f"    🎯 go.mod checksums: calculated from OUR hybrid .mod files")
        print(f"    📄 Output: {output_path}")
        print(f"    ⚠️  These checksums match OUR hybrid cache, NOT Go proxy content!")

    def create_version_info(self, repo_dir: Path, hash_val: str, ref: str, version: str):
        """Create a version information file in the repository."""
        import datetime
        
        version_info = f"""Module Version Information
========================
Go Module Version: {version}
Git Hash: {hash_val}
Git Ref: {ref}
Checked out at: {datetime.datetime.now().isoformat()}
"""
        
        info_file = repo_dir / '.go-module-info'
        with open(info_file, 'w') as f:
            f.write(version_info)

    def create_vendor_json(self):
        """Create vendor/vendor.json file for compatibility."""
        if not self.vendor_dir:
            return
            
        vendor_json = {
            "comment": f"Generated by go_mod_fetcher.py v{VERSION}",
            "ignore": "",
            "package": [],
            "rootPath": ""
        }
        
        vendor_json_path = self.vendor_dir / "vendor.json"
        with open(vendor_json_path, 'w') as f:
            json.dump(vendor_json, f, indent=2)

    def process_module(self, module_path: str, version: str) -> bool:
        """Process a single module: download info, clone repo, checkout revision."""
        # Check if we've already processed this module
        module_key = (module_path, version)
        if module_key in self.processed_modules:
            print(f"    ⚡ Skipping {module_path}@{version} (already processed)")
            return True
        
        print(f"    Getting module download info...")
        
        # Get module download info
        download_info = self.get_module_download_info(module_path, version)
        if not download_info:
            print(f"    ⚠️  Could not get download info for {module_path}@{version}")
            return False

        # Check if VCS info is available
        origin = download_info.get('Origin', {})
        repo_url = None

        if origin and origin.get('VCS') and origin.get('URL'):
            # Use VCS info from go mod download if available
            repo_url = origin['URL']
            print(f"    📍 Using VCS URL from go mod download: {repo_url}")
        else:
            # Fallback: derive repository URL from module path for common hosting platforms
            repo_url = self.derive_repo_url(module_path)
            if repo_url:
                print(f"    📍 Derived repository URL: {repo_url}")
            else:
                print(f"    ❌ Cannot derive repository URL for {module_path}")
                return False

        # Create repository directory
        safe_name = self.safe_module_name(module_path)
        repo_dir = self.output_dir / safe_name

        # Clone or update repository
        if not self.clone_or_update_repo(repo_url, repo_dir):
            return False

        # Checkout specific revision
        hash_val = origin.get('Hash', '') if origin else ''
        ref = origin.get('Ref', '') if origin else ''

        if not self.checkout_revision(repo_dir, hash_val, ref, version):
            return False

        # Mark this module as processed
        self.processed_modules.add(module_key)

        # Create version info file
        self.create_version_info(repo_dir, hash_val, ref, version)

        # Copy source to vendor directory if requested (optimized)
        if self.vendor_dir:
            if not hasattr(self, 'vendor_modules'):
                self.vendor_modules = []
            self.vendor_modules.append({
                'path': module_path,
                'version': version,
                'safe_name': self.safe_module_name(module_path)
            })
            
            if not self.copy_source_to_vendor(repo_dir, module_path):
                return False
        else:
            # Pre-cache package discovery for modules.txt generation even without vendor
            if self.generate_oe_files:
                self.discover_go_packages(repo_dir, module_path)

        # Generate OpenEmbedded files if requested
        if self.generate_oe_files:
            # Always add module to oe_modules for repository analysis, even if SRC_URI generation fails
            module_entry = {
                'path': module_path,
                'version': version,
                'safe_name': self.safe_module_name(module_path)
            }

            src_uri = self.generate_oe_src_uri(module_path, repo_url, repo_dir)
            if src_uri:
                self.oe_src_uris.append(src_uri)
                # Mark as successfully fetched
                module_entry['fetch_success'] = True
            else:
                # Mark as failed but still include for repository analysis
                module_entry['fetch_success'] = False
                print(f"    ⚠️  SRC_URI generation failed, but including {module_path} in repository analysis")

            self.oe_modules.append(module_entry)

        return True

    def fetch_all_modules(self, go_mod_source: str, include_indirect: bool = False, 
                         git_repo: Optional[str] = None, git_ref: Optional[str] = None):
        """Fetch all modules from go.mod file or Git repository."""
        
        print(f"fetch_all_modules called with:")
        print(f"  go_mod_source: {go_mod_source}")
        print(f"  include_indirect: {include_indirect}")  
        print(f"  vendor_like: {self.vendor_like}")
        print(f"  git_repo: {git_repo}")
        print(f"  git_ref: {git_ref}")
        print()
        
        # Determine the source of go.mod
        if git_repo and git_ref:
            print(f"Processing modules from Git repository: {git_repo}")
            print(f"Using ref: {git_ref}")
            
            if not self.validate_git_ref(git_repo, git_ref):
                print(f"❌ Git ref '{git_ref}' not found in repository {git_repo}")
                return False
            
            try:
                go_mod_path = self.fetch_go_mod_from_git(git_repo, git_ref, go_mod_source)
            except Exception as e:
                print(f"❌ Error fetching go.mod from Git: {e}")
                return False
        else:
            go_mod_path = go_mod_source
            print(f"Processing modules from local file: {go_mod_path}")
        
        print(f"Output directory: {self.output_dir}")
        if self.vendor_dir:
            print(f"Vendor directory: {self.vendor_dir}")
        
        # Parse go.mod for detailed dependency information (explicit/replaced markers)
        print("🔍 Parsing go.mod for dependency markers...")
        try:
            self.direct_deps, self.indirect_deps, self.replace_directives = self.parse_go_mod_detailed(go_mod_path)
        except Exception as e:
            print(f"⚠️  Warning: Could not parse go.mod details: {e}")
            print("    Will mark all dependencies as explicit")
        
        # Get dependencies based on the chosen strategy
        try:
            if self.vendor_like:
                print("📦 Using vendor-like dependency resolution...")
                modules = self.get_vendor_like_dependencies(go_mod_path)
            elif self.include_indirect:
                print("📄 Using comprehensive dependency resolution...")
                modules = self.get_all_dependencies(go_mod_path)
            else:
                print("📋 Using direct dependencies only...")
                modules = self.parse_go_mod(go_mod_path)
        except Exception as e:
            print(f"❌ Error getting dependencies: {e}")
            import traceback
            traceback.print_exc()
            return False

        if not modules:
            print("⚠️  No dependencies found")
            return True

        if self.vendor_like:
            dependency_type = "vendor-like dependencies"
        elif self.include_indirect:
            dependency_type = "all dependencies (including transitive)"
        else:
            dependency_type = "direct dependencies"
            
        print(f"📊 Found {len(modules)} {dependency_type} to process")
        
        # Debug: Show first few modules for verification
        print("🔍 First few modules to process:")
        for i, (module_path, version) in enumerate(modules[:5]):
            print(f"  {i+1}. {module_path}@{version}")
        if len(modules) > 5:
            print(f"  ... and {len(modules) - 5} more")
        print()
        
        # Create vendor.json if using vendor directory
        if self.vendor_dir:
            self.create_vendor_json()
        
        success_count = 0
        failed_modules = []
        
        for i, (module_path, version) in enumerate(modules, 1):
            print(f"[{i}/{len(modules)}] Processing: {module_path}@{version}")
            
            if self.process_module(module_path, version):
                print(f"  ✅ Successfully processed {module_path}")
                success_count += 1
            else:
                print(f"  ❌ Failed to process {module_path}")
                failed_modules.append((module_path, version))

        print(f"\n📊 Completed! Successfully processed {success_count}/{len(modules)} modules")

        # Ensure ALL vendor modules are included in oe_modules for repository analysis
        if self.generate_oe_files and self.vendor_like and hasattr(self, 'vendor_packages'):
            self.ensure_all_vendor_modules_included()

        # Performance report
        cache_hits = len(self.package_cache)
        if cache_hits > 0:
            print(f"⚡ Performance: {cache_hits} package discoveries cached (avoiding redundant scans)")

        if failed_modules:
            print(f"❌ Failed modules ({len(failed_modules)}):")
            for module_path, version in failed_modules[:10]:
                print(f"  - {module_path}@{version}")
            if len(failed_modules) > 10:
                print(f"  ... and {len(failed_modules) - 10} more failures")
            
            # Add only critical failed modules as stub entries for OpenEmbedded files
            # Only include: explicit dependencies OR modules with replace directives
            if self.generate_oe_files:
                critical_failed_modules = []
                for module_path, version in failed_modules:
                    is_explicit = module_path in self.direct_deps
                    is_replaced = module_path in self.replace_directives
                    
                    if is_explicit or is_replaced:
                        critical_failed_modules.append((module_path, version))
                        safe_name = self.safe_module_name(module_path)
                        stub_entry = {
                            'path': module_path,
                            'version': version,
                            'safe_name': safe_name,
                            'is_stub': True  # Mark as stub entry
                        }
                        self.oe_modules.append(stub_entry)
                        reason = []
                        if is_explicit:
                            reason.append("explicit")
                        if is_replaced:
                            reason.append("replaced")
                        print(f"  📝 Added critical stub: {module_path}@{version} ({', '.join(reason)})")
                
                skipped_count = len(failed_modules) - len(critical_failed_modules)
                if critical_failed_modules:
                    print(f"\n📝 Added {len(critical_failed_modules)} critical failed modules as stub entries")
                if skipped_count > 0:
                    print(f"📝 Skipped {skipped_count} indirect failed modules (not adding to modules.txt)")
        
        print(f"📁 Check the modules in: {self.output_dir}")
        if self.vendor_dir:
            print(f"📦 Vendor source code in: {self.vendor_dir}")
        
        # Write OpenEmbedded files if requested
        if self.generate_oe_files:
            # Validate our repository structure against go mod vendor reference (non-blocking)
            if hasattr(self, 'vendor_reference_dir') and self.vendor_reference_dir:
                print("🔍 Validating repository structure against 'go mod vendor' reference...")
                validation_success = self.validate_repository_structure()
                if not validation_success:
                    print("⚠️  Repository structure validation found issues, but continuing with file generation...")
                    print("💡 Note: Validation issues may indicate potential build problems, but files will be generated anyway.")
                else:
                    print("✅ Repository structure validation passed!")

            # Always generate files - let the actual build be the final judge
            self.write_oe_files()
        
        # Clean up temporary files
        self.cleanup_temp_files()
        
        return success_count == len(modules)

    def validate_repository_structure(self):
        """
        Validate that our cloned repositories can recreate the go mod vendor structure.
        This ensures our SRC_URI and relocation logic will work correctly.
        """
        print("    🔍 Creating test vendor structure from cloned repositories...")

        # Ensure overrides are loaded for validation
        if not hasattr(self, 'submodule_overrides') or not self.submodule_overrides:
            self.submodule_overrides = self.load_submodule_overrides()
            if self.submodule_overrides:
                print(f"    📋 Loaded {len(self.submodule_overrides)} override relationships for validation")

        # Create a temporary directory to simulate the build process
        import tempfile
        with tempfile.TemporaryDirectory() as test_vendor_dir:
            test_vendor_path = Path(test_vendor_dir) / "vendor"
            test_vendor_path.mkdir()

            # Track validation issues
            validation_issues = []
            missing_packages = []

            # Process each module that should be in vendor
            for module_entry in self.oe_modules:
                module_path = module_entry['path']

                # Skip modules that failed to fetch (they won't be in build either)
                if not module_entry.get('fetch_success', True):
                    continue

                # Check if this module should have packages according to reference
                if module_path in self.vendor_packages:
                    expected_packages = self.vendor_packages[module_path]

                    # Find the source repository for this module
                    source_repo_path = self.find_source_repository(module_path)
                    if not source_repo_path:
                        validation_issues.append(f"No source repository found for {module_path}")
                        continue

                    # Simulate the relocation process
                    try:
                        self.simulate_module_relocation(module_path, source_repo_path, test_vendor_path)
                    except Exception as e:
                        validation_issues.append(f"Failed to simulate relocation for {module_path}: {e}")
                        continue

                    # Check if expected packages exist in simulated vendor
                    for package in expected_packages:
                        expected_package_path = test_vendor_path / package.replace('/', os.sep)
                        if not expected_package_path.exists():
                            missing_packages.append(package)

            # Report validation results
            if validation_issues:
                print(f"    ❌ {len(validation_issues)} validation issues found:")
                for issue in validation_issues[:10]:  # Show first 10
                    print(f"        • {issue}")
                if len(validation_issues) > 10:
                    print(f"        ... and {len(validation_issues) - 10} more")

            if missing_packages:
                print(f"    ❌ {len(missing_packages)} expected packages missing from simulated vendor:")
                for pkg in missing_packages[:10]:  # Show first 10
                    print(f"        • {pkg}")
                if len(missing_packages) > 10:
                    print(f"        ... and {len(missing_packages) - 10} more")

                print("    ℹ️ Automatic override generation has been removed; please review the missing packages manually.")

            if not validation_issues and not missing_packages:
                print("    ✅ All expected packages can be created from cloned repositories")
                return True
            else:
                print(f"    ❌ Validation failed: {len(validation_issues)} issues, {len(missing_packages)} missing packages")
                return False

    def find_source_repository(self, module_path: str) -> Path:
        """Find the cloned repository that contains this module."""
        module_safe_name = self.safe_module_name(module_path)

        # Check for exact match first
        exact_path = Path(self.output_dir) / module_safe_name
        if exact_path.exists():
            return exact_path

        # Check for parent repository (e.g., example.org/foo/bar -> example_org_foo)
        path_parts = module_path.split('/')
        for i in range(len(path_parts) - 1, 0, -1):
            parent_path = '/'.join(path_parts[:i])
            parent_safe_name = self.safe_module_name(parent_path)
            parent_repo_path = Path(self.output_dir) / parent_safe_name
            if parent_repo_path.exists():
                return parent_repo_path

        return None

    def simulate_module_relocation(self, module_path: str, source_repo_path: Path, test_vendor_path: Path):
        """
        Simulate the module relocation process to test if it will work during build.
        This needs to recreate the same logic as our relocation.inc will use.
        """
        # Use the same submodule detection logic from repository analysis
        submodule_relationships = self.detect_submodule_relationships_for_validation(source_repo_path, module_path)

        if submodule_relationships:
            # This repository provides multiple modules - copy the full repo and create submodule links
            self.copy_full_repository_with_submodules(source_repo_path, test_vendor_path, submodule_relationships)
        else:
            # Single module - copy repository to module path
            target_path = test_vendor_path / module_path.replace('/', os.sep)
            self.copy_repository_contents(source_repo_path, target_path)

    def detect_submodule_relationships_for_validation(self, repo_path: Path, primary_module: str) -> dict:
        """
        Detect if this repository provides multiple modules (submodules).
        Returns mapping of module_path -> subpath within repository.
        Uses both override.conf and generic detection.
        """
        relationships = {}

        # First, check override.conf for explicit relationships
        if hasattr(self, 'submodule_overrides') and self.submodule_overrides:
            for override_module, (parent_module, subpath) in self.submodule_overrides.items():
                # If this repository is the parent for an override, include it
                if parent_module == primary_module:
                    relationships[override_module] = subpath
                    # Also include the parent module itself
                    relationships[primary_module] = ''

        # Check if this repository is supposed to provide other modules according to our analysis
        repo_provides = []
        for module_entry in self.oe_modules:
            if module_entry.get('fetch_success', True):
                # Check if this could be from the same repository
                if self.could_be_same_repository(primary_module, module_entry['path']):
                    repo_provides.append(module_entry['path'])

        if len(repo_provides) > 1:
            # Multiple modules from same repo - determine subpaths
            for module_path in repo_provides:
                if module_path not in relationships:  # Don't override explicit overrides
                    subpath = self.determine_subpath_in_repository(primary_module, module_path)
                    relationships[module_path] = subpath

        return relationships

    def could_be_same_repository(self, module1: str, module2: str) -> bool:
        """Check if two modules could come from the same repository."""
        # Simple heuristic: same domain and owner (first 3 parts for github.com/owner/repo)
        parts1 = module1.split('/')[:3]
        parts2 = module2.split('/')[:3]
        return parts1 == parts2

    def determine_subpath_in_repository(self, base_module: str, target_module: str) -> str:
        """Determine the subpath of target_module relative to base_module repository."""
        base_parts = base_module.split('/')
        target_parts = target_module.split('/')

        # Find common prefix
        common_length = 0
        for i in range(min(len(base_parts), len(target_parts))):
            if base_parts[i] == target_parts[i]:
                common_length = i + 1
            else:
                break

        # If target has more parts after common prefix, that's the subpath
        if len(target_parts) > common_length:
            return '/'.join(target_parts[common_length:])
        else:
            return ''

    def copy_full_repository_with_submodules(self, source_repo_path: Path, test_vendor_path: Path, relationships: dict):
        """Copy repository and create all expected submodule paths."""
        import shutil

        for module_path, subpath in relationships.items():
            target_path = test_vendor_path / module_path.replace('/', os.sep)

            if subpath:
                # Copy subpath from repository
                source_subpath = source_repo_path / subpath
                if source_subpath.exists():
                    self.copy_repository_contents(source_subpath, target_path)
            else:
                # Copy full repository
                self.copy_repository_contents(source_repo_path, target_path)

    def copy_repository_contents(self, source_path: Path, target_path: Path):
        """Copy repository contents to simulate relocation."""
        import shutil

        if not source_path.exists():
            return

        target_path.mkdir(parents=True, exist_ok=True)

        # Copy all contents recursively
        for item in source_path.iterdir():
            if item.name.startswith('.git'):
                continue  # Skip git metadata

            target_item = target_path / item.name
            try:
                if item.is_dir():
                    shutil.copytree(item, target_item, dirs_exist_ok=True)
                else:
                    shutil.copy2(item, target_item)
            except Exception:
                pass  # Skip files that can't be copied

    def get_repository_module_for_path(self, module_path: str) -> str:
        """Get the repository module that provides this module path."""
        for module_entry in self.oe_modules:
            if module_entry['path'] == module_path:
                return module_path
        return module_path

    def generate_fallback_src_uri(self, module_path: str, safe_name: str) -> Optional[str]:
        """Try to create a generic SRC_URI for modules missing from the primary fetch."""
        def strip_version_suffix(path: str) -> str:
            return re.sub(r'/v\d+$', '', path)

        # Attempt to derive a usable repository URL without per-module knowledge
        repo_url = self.derive_repo_url(module_path)
        if not repo_url:
            cleaned_path = strip_version_suffix(module_path)
            repo_url = f"https://{cleaned_path}"

        if not repo_url.startswith('http'):
            print(f"    ⚠️  Cannot derive a repository URL for {module_path} generically")
            return None

        # Resolve a commit to pin the source deterministically
        commit_hash = None
        for ref in ('HEAD', 'main', 'master'):
            try:
                result = subprocess.run(
                    ['git', 'ls-remote', repo_url, ref],
                    capture_output=True,
                    text=True,
                    timeout=30
                )
            except subprocess.TimeoutExpired:
                print(f"    ⚠️  Timeout determining commit for {repo_url} ({ref})")
                return None

            if result.returncode == 0 and result.stdout.strip():
                commit_hash = result.stdout.strip().split()[0]
                if ref != 'HEAD':
                    print(f"    📍 Found commit {commit_hash} for {repo_url} ({ref})")
                break

        if not commit_hash:
            print(f"    ⚠️  Could not determine a commit for {repo_url}; skipping fallback")
            return None

        src_uri = (
            f"git://{repo_url.replace('https://', '')};protocol=https;"
            f"nobranch=1;rev={commit_hash};shallow=1;"
            f"destsuffix=${{GO_SRCURI_DESTSUFFIX}}/modules/{safe_name}"
        )

        print(f"    🔄 Generated fallback SRC_URI for {module_path}: {repo_url}@{commit_hash} (shallow)")
        return src_uri


    def ensure_all_vendor_modules_included(self):
        """
        Ensure ALL modules from vendor analysis are included in oe_modules,
        and attempt to generate proper SRC_URI entries for missing vendor modules.
        This is critical for complete repository analysis and build success.
        """
        print("🔍 Ensuring all vendor modules are included for repository analysis...")

        # Get list of modules already in oe_modules
        existing_modules = {m['path'] for m in self.oe_modules}

        # Get all modules from vendor analysis (modules.txt)
        vendor_modules = set(self.vendor_packages.keys()) if self.vendor_packages else set()

        # Find missing modules
        missing_modules = vendor_modules - existing_modules

        if missing_modules:
            print(f"    📋 Found {len(missing_modules)} modules missing from oe_modules")
            print(f"    🔧 Processing missing vendor modules with proper SRC_URI generation...")

            success_count = 0
            for module_path in missing_modules:
                # Try to get version from vendor analysis (this should have been parsed)
                version = "unknown"
                if hasattr(self, 'vendor_module_info') and module_path in self.vendor_module_info:
                    version = self.vendor_module_info[module_path].get('version', 'unknown')

                print(f"      🔄 Processing missing vendor module: {module_path}@{version}")

                # Try to process this module properly with SRC_URI generation
                if self.process_module(module_path, version):
                    print(f"      ✅ Successfully processed {module_path}")
                    success_count += 1
                else:
                    print(f"      ⚠️  Failed to process {module_path}, adding with fallback SRC_URI...")

                    # Generate fallback SRC_URI for this module
                    safe_name = self.safe_module_name(module_path)
                    fallback_src_uri = self.generate_fallback_src_uri(module_path, safe_name)

                    if fallback_src_uri:
                        self.oe_src_uris.append(fallback_src_uri)
                        print(f"      📁 Generated fallback SRC_URI for {module_path}")

                    # Add module entry for repository analysis
                    missing_entry = {
                        'path': module_path,
                        'version': version,
                        'safe_name': safe_name,
                        'fetch_success': bool(fallback_src_uri),
                        'fallback_generated': True  # Mark as fallback-generated
                    }
                    self.oe_modules.append(missing_entry)

            print(f"    ✅ Processed {success_count}/{len(missing_modules)} missing vendor modules successfully")
            print(f"    ✅ Repository analysis now includes all {len(vendor_modules)} vendor modules")
        else:
            print(f"    ✅ All {len(vendor_modules)} vendor modules already included in oe_modules")


def detect_current_git_context() -> Optional[Dict[str, Optional[str]]]:
    """Return information about the current Git repository, if any."""
    try:
        inside = subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            capture_output=True,
            text=True,
            check=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None

    if inside.stdout.strip().lower() != "true":
        return None

    def _run_git_cmd(args: List[str]) -> Optional[str]:
        try:
            result = subprocess.run(args, capture_output=True, text=True, check=True)
            return result.stdout.strip() or None
        except subprocess.CalledProcessError:
            return None

    toplevel = _run_git_cmd(["git", "rev-parse", "--show-toplevel"])
    commit = _run_git_cmd(["git", "rev-parse", "HEAD"])
    branch = _run_git_cmd(["git", "rev-parse", "--abbrev-ref", "HEAD"])

    remote_url = _run_git_cmd(["git", "config", "--get", "remote.origin.url"])
    if not remote_url:
        remote_output = _run_git_cmd(["git", "remote", "-v"])
        if remote_output:
            seen = {}
            for line in remote_output.splitlines():
                parts = line.split()
                if len(parts) >= 2:
                    name, url = parts[0], parts[1]
                    if name not in seen:
                        seen[name] = url
            if "origin" in seen:
                remote_url = seen["origin"]
            elif seen:
                remote_url = next(iter(seen.values()))

    return {
        "toplevel": toplevel,
        "commit": commit,
        "branch": branch,
        "remote": remote_url,
    }


def prompt_yes_no(question: str, default: bool = True) -> bool:
    """Prompt the user with a yes/no question and return the answer."""
    if default:
        prompt = " [Y/n] "
    else:
        prompt = " [y/N] "

    while True:
        try:
            answer = input(question + prompt).strip().lower()
        except EOFError:
            return default

        if not answer:
            return default
        if answer in ("y", "yes"):
            return True
        if answer in ("n", "no"):
            return False
        print("Please respond with 'y' or 'n'.")


def main():
    print(f"Go Module Git Fetcher v{VERSION}")
    print("=" * 40)
    
    parser = argparse.ArgumentParser(
        description=f"Fetch Git repositories for Go modules and checkout exact revisions (v{VERSION})",
        epilog="""
Examples:
  # Use vendor-like filtering (RECOMMENDED for Yocto - ~120 deps instead of 350)
  %(prog)s --git-repo https://example.org/project.git --git-ref main --vendor-like --openembedded

  # Use hybrid approach for fast parallel downloads (NEW - 10x faster than gomodgit)
  %(prog)s --git-repo https://example.org/project.git --git-ref main --use-hybrid --recipedir /path/to/recipe

  # Use BitBake's gomodgit infrastructure (works but slow - 20+ minutes)
  %(prog)s --git-repo https://example.org/project.git --git-ref main --use-gomodgit --recipedir /path/to/recipe

  # Include all dependencies (comprehensive - may be 300+ modules)
  %(prog)s --git-repo https://example.org/project.git --git-ref main --include-indirect --vendor vendor
        """,
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    parser.add_argument(
        "go_mod_file",
        nargs='?',
        default="go.mod",
        help="Path to local go.mod file (default: go.mod)"
    )
    
    parser.add_argument("--git-repo", help="Git repository URL to fetch go.mod from")
    parser.add_argument("--git-ref", help="Git ref (tag, branch, or commit) to checkout")
    parser.add_argument("--go-mod-path", default="go.mod", help="Path to go.mod file within the Git repository")
    
    parser.add_argument("-o", "--output", default="modules", help="Output directory for cloned repositories")
    parser.add_argument("--vendor", help="Create vendor directory with source code")
    parser.add_argument("--openembedded", action="store_true", 
                       help="Generate OpenEmbedded files (modules.txt, src_uri.inc, relocation.inc)")
    parser.add_argument("--gomodcache", help="Directory to use for Go module cache (overrides GOMODCACHE)")
    parser.add_argument("--git-timeout", type=int, default=120,
                        help="Timeout in seconds for git clone/fetch commands (default: 120)")
    parser.add_argument("--git-retries", type=int, default=3,
                        help="Number of attempts for git clone/fetch commands (default: 3)")
    
    scope_group = parser.add_mutually_exclusive_group()
    scope_group.add_argument("--include-indirect", action="store_true", help="Include all transitive dependencies")
    scope_group.add_argument("--vendor-like", action="store_true", help="Use 'go mod vendor' filtering (RECOMMENDED)")

    parser.add_argument("--detect-missing-overrides", action="store_true",
                       help="Compare with 'go mod vendor' to detect missing overrides")
    parser.add_argument("--use-gomodgit", action="store_true",
                       help="Use BitBake's gomodgit:// infrastructure (EXPERIMENTAL)")
    parser.add_argument("--use-hybrid", action="store_true",
                       help="Use hybrid git:// + custom module cache approach for fast parallel downloads")
    parser.add_argument("--generate-gomodgit", action="store_true",
                       help="Generate go.sum.gomodgit reference checksums (optional; defaults to off)")
    parser.add_argument("--recipedir", help="Output directory for generated .inc files (default: current directory)")
    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose output")
    parser.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")

    args = parser.parse_args()

    # Offer to auto-populate Git arguments when running inside a repository
    if (not args.git_repo or not args.git_ref) and sys.stdin.isatty():
        context = detect_current_git_context()
        if context and context.get("commit"):
            repo_candidate = context.get("remote") or context.get("toplevel")
            ref_candidate = context.get("commit")
            missing_repo = not args.git_repo
            missing_ref = not args.git_ref

            if repo_candidate and (missing_repo or missing_ref):
                commit_short = ref_candidate[:12] if ref_candidate else None
                branch = context.get("branch") or "HEAD"
                print("💡 Detected local Git repository context:")
                if context.get("toplevel"):
                    print(f"   Path: {context['toplevel']}")
                if context.get("remote"):
                    print(f"   Remote: {context['remote']}")
                if commit_short:
                    branch_display = f" ({branch})" if branch and branch != "HEAD" else ""
                    print(f"   HEAD: {commit_short}{branch_display}")

                print("   Proposed values:")
                if missing_repo:
                    print(f"     --git-repo = {repo_candidate}")
                else:
                    print(f"     --git-repo = {args.git_repo} (existing)")
                if missing_ref:
                    print(f"     --git-ref  = {ref_candidate}")
                else:
                    print(f"     --git-ref  = {args.git_ref} (existing)")

                if prompt_yes_no("Use these Git settings?", default=True):
                    if missing_repo:
                        args.git_repo = repo_candidate
                    if missing_ref:
                        args.git_ref = ref_candidate
                else:
                    print("   ↩️  Keeping command-line values unchanged.")

    # Set default to vendor-like if nothing specified and generating OpenEmbedded files
    if not args.include_indirect and not args.vendor_like:
        if args.openembedded:
            print("💡 Using --vendor-like (recommended for Yocto builds)")
            args.vendor_like = True
        else:
            print("💡 Using direct dependencies only.")
    
    if args.vendor_like:
        print("✅ Using --vendor-like: This mimics 'go mod vendor' behavior")
        print("   This typically results in ~120 modules, similar to what Go builds actually need.")
        print()
    
    # Validate arguments
    if args.git_repo and not args.git_ref:
        parser.error("--git-ref is required when using --git-repo")
    elif args.git_ref and not args.git_repo:
        parser.error("--git-repo is required when using --git-ref")

    # Prepare Go environment (and create cache directory if requested)
    base_go_env = None
    if args.gomodcache:
        gomodcache_path = Path(args.gomodcache).expanduser().resolve()
        gomodcache_path.mkdir(parents=True, exist_ok=True)
        args.gomodcache = str(gomodcache_path)
        base_go_env = os.environ.copy()
        base_go_env['GOMODCACHE'] = args.gomodcache

    # Check tools
    try:
        result = subprocess.run(["go", "version"], check=True, capture_output=True, text=True, env=base_go_env)
        print(f"✅ Go toolchain: {result.stdout.strip()}")
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("❌ Error: 'go' command not found. Please install Go.")
        sys.exit(1)

    try:
        result = subprocess.run(["git", "--version"], check=True, capture_output=True, text=True)
        print(f"✅ Git: {result.stdout.strip()}")
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("❌ Error: 'git' command not found. Please install Git.")
        sys.exit(1)
    
    print()

    # Create fetcher and process modules
    try:
        fetcher = GoModuleFetcher(
            args.output,
            args.vendor,
            args.openembedded,
            args.include_indirect,
            args.vendor_like,
            args.gomodcache,
            generate_gomodgit=args.generate_gomodgit,
            git_timeout=args.git_timeout,
            git_retries=args.git_retries
        )
        fetcher.args = args  # Store args for later use

        # Handle gomodgit infrastructure bootstrap
        if args.use_gomodgit:
            print("🚀 Bootstrapping BitBake gomodgit:// infrastructure")

            if args.git_repo:
                # Fetch the main repository to get source directory
                source_dir = fetcher.fetch_main_repo(args.git_repo, args.git_ref)
                if not source_dir:
                    print("❌ Failed to fetch main repository")
                    sys.exit(1)
            else:
                # Use current directory if local go.mod file specified
                source_dir = Path(".").absolute()
                if not (source_dir / args.go_mod_file).exists():
                    print(f"❌ go.mod file not found: {args.go_mod_file}")
                    sys.exit(1)

            # Use the new gomodgit infrastructure
            output_dir = Path(args.recipedir) if args.recipedir else Path(".")
            fetcher.bootstrap_gomodgit_infrastructure(source_dir, output_dir=output_dir)
            success = True
        elif args.use_hybrid:
            print("🚀 Bootstrapping hybrid git:// + custom module cache infrastructure")

            if args.git_repo:
                # Fetch the main repository to get source directory
                source_dir = fetcher.fetch_main_repo(args.git_repo, args.git_ref)
                if not source_dir:
                    print("❌ Failed to fetch main repository")
                    sys.exit(1)
            else:
                # Use current directory if local go.mod file specified
                source_dir = Path(".").absolute()
                if not (source_dir / args.go_mod_file).exists():
                    print(f"❌ go.mod file not found: {args.go_mod_file}")
                    sys.exit(1)

            # Use the new hybrid infrastructure
            output_dir = Path(args.recipedir) if args.recipedir else Path(".")
            fetcher.bootstrap_hybrid_infrastructure(source_dir, output_dir=output_dir)
            success = True
        else:
            success = fetcher.fetch_all_modules(
                args.go_mod_path if args.git_repo else args.go_mod_file,
                include_indirect=args.include_indirect,
                git_repo=args.git_repo,
                git_ref=args.git_ref
            )
        
        fetcher.cleanup_temp_files()
        sys.exit(0 if success else 1)
        
    except KeyboardInterrupt:
        print("\nOperation cancelled by user")
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}")
        if args.verbose:
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
