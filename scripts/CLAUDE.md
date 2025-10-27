# Go Module Fetcher for Yocto/BitBake – Architecture & Implementation

This document describes the production hybrid architecture for building Go applications in Yocto/BitBake with complete offline builds from git sources.

## Mission & Objectives

Deliver reproducible, fully offline Go builds inside BitBake:
- Source every module from auditable git repos while matching Go's cache layout byte-for-byte
- Zero network access during `do_compile` - all downloads happen in `do_fetch`
- Integrate cleanly with existing Yocto tooling so recipes can mix `git://` and `gomod://` sources
- Maintain compatibility with oe-core's gomod.bbclass

## Constraints

### Yocto/BitBake Requirements
- **No network access in do_compile** - All downloads must happen in `do_fetch`
- **Deterministic builds** - Same inputs produce identical outputs
- **SRC_URI + checksums** - All sources declared upfront with verification
- **Standard task ordering** - `do_fetch` → `do_unpack` → `do_configure` → `do_compile`
- **Sandbox friendly** - All temporary work happens under `${WORKDIR}` (BitBake requirement)

### Go Module Cache Structure
Go expects modules in a specific format:
```
${S}/pkg/mod/
├── cache/
│   └── download/
│       └── {module_path}/
│           └── @v/
│               ├── {version}.info     # JSON: {"Version":"...", "Time":"..."}
│               ├── {version}.mod      # go.mod file
│               ├── {version}.zip      # Source archive
│               └── {version}.ziphash  # h1: checksum
└── {module_path}@{version}/          # Extracted source (from .zip)
```

## Current Architecture: Hybrid Go + Git (v3.0.0)

### Design Principle
**Use Go as the authoritative source for module paths and metadata, but build from git sources**

### Three-Phase Workflow

#### Phase 1: Discovery (Generation Time)
Use `go mod download` to discover module metadata, then parse filesystem to extract correct paths:

```python
def discover_modules(source_dir, gomodcache):
    """
    Let Go download modules to discover correct paths and metadata.
    This is ONLY for discovery - we build from git sources.
    """
    # Use persistent or temporary GOMODCACHE
    env = os.environ.copy()
    env['GOMODCACHE'] = gomodcache
    env['GOPROXY'] = 'https://proxy.golang.org'

    # Let Go download everything
    subprocess.run(['go', 'mod', 'download'], cwd=source_dir, env=env)

    # Walk filesystem to discover what Go created
    modules = []
    download_dir = f"{gomodcache}/cache/download"

    for dirpath, _, filenames in os.walk(download_dir):
        path_parts = Path(dirpath).relative_to(download_dir).parts

        if path_parts[-1] != '@v':
            continue

        # Module path is everything before @v
        module_path = '/'.join(path_parts[:-1])
        module_path = unescape_module_path(module_path)  # Unescape !-encoding

        # Process each .info file
        for filename in filenames:
            if not filename.endswith('.info'):
                continue

            version = filename[:-5]
            info = json.load(open(Path(dirpath) / filename))

            # Extract VCS information from Origin field
            origin = info.get('Origin', {})
            vcs_url = origin.get('URL')
            vcs_hash = origin.get('Hash')

            if not vcs_url or not vcs_hash:
                # Module lacks Origin - will handle via fallback
                continue

            modules.append({
                'module_path': module_path,  # CORRECT path from filesystem!
                'version': version,
                'vcs_url': vcs_url,
                'vcs_hash': vcs_hash,
                'timestamp': info.get('Time'),
                'subdir': origin.get('Subdir', ''),
            })

    return modules
```

**Key insight:** Filesystem walk eliminates path parsing bugs:
- Directory structure IS the module path (preserves `/v2`, `/v3`, etc.)
- No need to parse `go list` output or manipulate paths
- Handles all edge cases naturally

#### Phase 1b: Fallback for Missing Origin Metadata

Some modules don't have `Origin` metadata in `.info` files:
- gopkg.in modules (vanity URLs)
- Modules listed only in `go.sum` but not directly imported
- Replaced modules

Fallback resolver handles these cases:

```python
def resolve_module_metadata(module_path, version):
    """
    Derive git repository from module path for modules without Origin.
    """
    parts = module_path.split('/')

    # Handle gopkg.in special case
    if parts[0] == 'gopkg.in':
        # gopkg.in/pkg.v3 -> github.com/go-pkg/pkg
        # gopkg.in/user/pkg.v3 -> github.com/user/pkg
        if len(parts) == 2:
            pkg_name = parts[1].rsplit('.', 1)[0]  # Remove .vN
            vcs_url = f"https://github.com/go-{pkg_name}/{pkg_name}"
        elif len(parts) == 3:
            user = parts[1]
            pkg_name = parts[2].rsplit('.', 1)[0]
            vcs_url = f"https://github.com/{user}/{pkg_name}"
    else:
        # Standard path: github.com/user/repo
        base_repo = '/'.join(parts[:3])
        vcs_url = f"https://{base_repo}"
        subdir = '/'.join(parts[3:]) if len(parts) > 3 else ''

    # Resolve commit via git ls-remote
    tag = version.split('+')[0]
    commit = git_ls_remote(vcs_url, f"refs/tags/{tag}")

    return {
        'module_path': module_path,
        'version': version,
        'vcs_url': vcs_url,
        'vcs_hash': commit,
        'timestamp': derive_timestamp_from_version(version),
        'subdir': subdir,
    }
```

**gopkg.in Discovery Limitation:**
gopkg.in modules lack `Origin` metadata because the Go proxy acts as a redirect service:
- Proxy knows `gopkg.in/inf.v0` → `github.com/go-inf/inf`
- But doesn't include this mapping in `.info` files
- Must use conventional mapping rules (well-established, stable)

#### Phase 2: Recipe Generation
Generate BitBake recipe with git:// SRC_URI entries:

```python
def generate_recipe(modules, output_dir):
    """
    Generate go-mod-git.inc with git:// fetches
    Generate go-mod-cache.inc with BitBake task
    """
    src_uri_entries = []
    modules_data = []

    for module in modules:
        # Calculate unique hash for this git repo
        vcs_key = f"git3:{module['vcs_url']}"
        vcs_sha = hashlib.sha256(vcs_key.encode()).hexdigest()

        # Add git:// SRC_URI entry
        src_uri_entries.append(
            f"git://{module['vcs_url'][8:]};protocol=https;nobranch=1;"
            f"rev={module['vcs_hash']};name=git_{vcs_sha[:12]};"
            f"destsuffix=vcs_cache/{vcs_sha}"
        )

        # Add to modules_data for do_create_module_cache
        modules_data.append({
            'module': module['module_path'],
            'version': module['version'],
            'vcs_hash': vcs_sha,
            'commit': module['vcs_hash'],
            'timestamp': module['timestamp'],
            'subdir': module.get('subdir', ''),
        })

    # Write go-mod-git.inc and go-mod-cache.inc
    write_recipe_files(output_dir, src_uri_entries, modules_data)
```

#### Phase 3: Cache Building (BitBake Task)
Build module cache from git sources during `do_create_module_cache`:

```python
python do_create_module_cache() {
    """
    Create Go module cache from downloaded git repositories.
    Runs during BitBake build after git repos are fetched.
    """
    for module in modules_data:
        vcs_path = f"{WORKDIR}/sources/vcs_cache/{module['vcs_hash']}"

        # Checkout exact commit
        subprocess.run(['git', 'checkout', '-q', module['commit']], cwd=vcs_path)

        # Create cache directory
        cache_dir = Path(S) / "pkg" / "mod" / "cache" / "download"
        module_cache = cache_dir / module['module'] / "@v"
        module_cache.mkdir(parents=True, exist_ok=True)

        # 1. Create .info file
        info_data = {"Version": module['version'], "Time": module['timestamp']}
        (module_cache / f"{version}.info").write_text(json.dumps(info_data))

        # 2. Create .mod file
        # Special handling for +incompatible versions
        if '+incompatible' in version:
            mod_content = f"module {module_path}\n".encode('utf-8')
        elif (vcs_path / subdir / "go.mod").exists():
            mod_content = (vcs_path / subdir / "go.mod").read_bytes()
        else:
            mod_content = f"module {module_path}\n".encode('utf-8')
        (module_cache / f"{version}.mod").write_bytes(mod_content)

        # 3. Create .zip file using git archive
        create_zip_from_git(vcs_path, module, module_cache)

        # 4. Create .ziphash using go-dirhash-native
        hash_value = subprocess.run(
            ['dirhash', zip_path], capture_output=True, text=True
        ).stdout.strip()
        (module_cache / f"{version}.ziphash").write_text(f"{hash_value}\n")

        # 5. Extract zip to pkg/mod for offline builds
        zipfile.ZipFile(zip_path).extractall(Path(S) / "pkg" / "mod")
}
```

### Key Implementation Details

#### Archive Fidelity
Cache creation stages repos in `${WORKDIR}`, strips vendored modules, normalizes timestamps/permissions:

```python
def create_zip_from_git(vcs_path, module, cache_dir):
    """Create deterministic zip matching Go's expectations"""
    # Use git archive for reproducibility
    subprocess.run(['git', 'archive', '--format=tar', commit], cwd=vcs_path)

    # Filter vendored packages (nested go.mod files)
    excluded_prefixes = find_nested_gomod_files(extract_root)

    # Create zip with normalized timestamps (1980-01-01) and permissions
    with zipfile.ZipFile(zip_path, 'w') as zf:
        for file in sorted(files):
            if is_vendored_package(file):
                continue
            add_zip_entry(zf, file, normalized_timestamp=(1980,1,1,0,0,0))
```

#### +incompatible Handling
Modules with `+incompatible` suffix ALWAYS get synthetic go.mod:

```python
if '+incompatible' in version:
    # Always synthesize, even if repo has go.mod
    # Repo's go.mod may declare wrong module path (e.g., /v4 instead of base)
    mod_content = f"module {module_path}\n".encode('utf-8')
```

**Why:** `+incompatible` indicates pre-modules era. Repository may have later added go.mod with different module path (e.g., `/v4`), but Go expects minimal synthetic go.mod matching the import path.

#### Checksum Generation
`go-dirhash-native` provides single source of truth for `h1:` hashes:

```python
# Calculate h1: hash using dirhash helper
hash_value = subprocess.run(['dirhash', zip_path],
                           capture_output=True, text=True).stdout.strip()

# Regenerate go.sum from created cache
def regenerate_go_sum():
    for zip_file in cache_dir.rglob("*.zip"):
        hash_value = calculate_zip_checksum(zip_file)
        module_path, version = extract_from_path(zip_file)
        new_entries[(module_path, version)] = hash_value

    # Merge with existing go.sum entries (for gomod:// modules)
    final_entries = existing_entries.copy()
    final_entries.update(new_entries)
    write_go_sum(final_entries)
```

#### Mixed Sources Support
Recipes can combine `git://` and `gomod://` entries:

```bitbake
inherit go-mod

SRC_URI = "\
    git://github.com/internal/lib;rev=${SRCREV};destsuffix=vcs_cache/... \
    gomod://github.com/public/lib;version=v1.2.3;sha256sum=... \
"

# do_create_module_cache handles git:// entries
# gomod.bbclass handles gomod:// entries
# Both write to ${S}/pkg/mod/cache/download/
# Go sees unified cache during do_compile
```

## Recent Fixes & Discoveries

### Critical: go.sum Regeneration Issue (Fixes #6, #7, #8 - 2025-10-26/27)
**The Problem:** Checksum mismatches during `do_compile` even though we were building correct module cache files from git. Go was rejecting our modules with "SECURITY ERROR" messages.

**Root Cause Analysis:**
Three separate but related bugs in the `regenerate_go_sum()` function:

1. **Fix #6 - Upstream go.sum Conflicts**: Git-fetched repositories contained their own go.sum files with proxy.golang.org checksums. Go read these during submodule builds and rejected our git-built archives.
   - Solution: `find ${WORKDIR}/sources/vcs_cache -name "go.sum" -delete || true` in do_compile

2. **Fix #7 - Wrong Dictionary Key Format**: `regenerate_go_sum()` stored .mod checksums with key `(module/go.mod", version)` instead of `(module", "version/go.mod")`, so `.update()` couldn't override old proxy checksums.
   - Solution: Changed line 818 to `new_entries[(module_path, f"{version}/go.mod")] = mod_checksum`

3. **Fix #8 - Literal vs Real Newline**: `calculate_mod_checksum()` used literal `\\n` string instead of real newline `\n`, calculating proxy-format checksums instead of git-format checksums.
   - Solution: Changed line 772 to `summary = f"{file_hash}  go.mod\n".encode('ascii')`

**Why All Three Were Needed:**
- Fix #6 alone: Removed conflicting upstream go.sum, but our regenerated go.sum still had wrong checksums
- Fix #7 alone: Correct key format, but WRONG checksum values (still proxy format)
- Fix #8 alone: Correct checksum values, but WRONG key format (wouldn't override)
- **Together**: Correct key format AND correct checksum values → successful override of proxy checksums with git-based ones

**Impact:** This was the final blocker for pure git-based builds. Without these fixes, `regenerate_go_sum()` was essentially non-functional - it appeared to run but didn't actually update any checksums.

**Lessons Learned:**
- The `\\n` bug was particularly insidious because it accidentally matched proxy.golang.org's checksum format
- Always verify the ACTUAL contents of regenerated files, not just that the code ran
- Dictionary key format matters - `.update()` silently fails to override if keys don't match exactly

---

### Fix #1: +incompatible Synthetic go.mod (2025-10-25)
**Problem:** `github.com/mistifyio/go-zfs@v2.1.2-..+incompatible` had real go.mod declaring `module github.com/mistifyio/go-zfs/v4`, causing checksum mismatch.

**Solution:** Always synthesize minimal go.mod for `+incompatible`, even if repo has go.mod file.

**Root cause:** Repository evolved from pre-modules (v2) to modules era (v4+), but `+incompatible` version references pre-modules commit that Go expects to have synthetic go.mod.

### Fix #2: gopkg.in Support (2025-10-25)
**Problem:** `gopkg.in/inf.v0@v0.9.1` couldn't be discovered - no `Origin` metadata in `.info` files.

**Solution:** Added conventional mapping rules in fallback resolver:
- `gopkg.in/pkg.vN` → `github.com/go-pkg/pkg`
- `gopkg.in/user/pkg.vN` → `github.com/user/pkg`

**Discovery limitation:** gopkg.in modules lack `Origin` in `.info` because:
- Go proxy acts as vanity URL redirect service
- Proxy knows the mapping but doesn't include in metadata
- Cannot be discovered via filesystem walk
- Must use well-established conventional mapping (stable, legacy system)

### Fix #3: /go.mod-only Entries (2025-10-26)
**Problem:** `github.com/google/go-cmp@v0.6.0` missing - go.sum had only `/go.mod` entry for this version.

**Solution:** Modified `parse_go_sum()` to strip `/go.mod` suffix and include base version:
```python
module_path, version, _ = parts
if version.endswith('/go.mod'):
    version = version[:-7]  # Strip suffix, include module
modules.add((module_path, version))
```

**Root cause:** Indirect dependencies sometimes only have go.mod checksums in go.sum (Go only needs module declarations, not source code). These were being filtered out.

### Fix #4: Short Commit Hash Validation (2025-10-26)
**Problem:** BitBake parse errors for modules with 12-character pseudo-version commits like `dmitri.shuralyov.com/app/changes@v0.0.0-20180602232624-0a106ad413e3`.

**Solution:** Multi-point validation to reject short hashes:
1. `resolve_module_metadata()` - Return None if `git ls-remote` can't expand short commit
2. `discover_modules()` - Skip modules with `len(vcs_hash) != 40`
3. `load_metadata_from_inc()` - Skip bootstrap entries with invalid commit lengths
4. Cleaned 300 cached entries with 12-character commits

**Root cause:**
- Pseudo-versions embed short (12-char) commit hashes
- `git ls-remote` can't resolve short hashes (needs tags/branches)
- BitBake requires full 40-character SRCREVs
- Metadata cache was poisoning itself by re-loading bad commits from old .inc files

**Results:** 537 git repos with valid 40-char hashes, 755 indirect-only dependencies skipped

### Fix #5: Version Suffix Stripping from Subdirs (2025-10-26)
**Problem:** `github.com/apache/arrow/go/v11@v11.0.0` failing with `fatal: pathspec 'go/v11' did not match any files`. Hash showed `h1:47DEQp...` (empty string).

**Solution:** Strip version suffixes when deriving subdirs in `resolve_module_metadata()`:
```python
# Calculate subdir from module path, but strip version suffixes
if len(parts) > 3:
    subdir_parts = parts[3:]
    # Remove trailing version suffix (e.g., v2, v3, v11)
    if subdir_parts and subdir_parts[-1].startswith('v') and subdir_parts[-1][1:].isdigit():
        subdir_parts = subdir_parts[:-1]
    subdir = '/'.join(subdir_parts) if subdir_parts else ''
```

**Root cause:**
- Module path `github.com/apache/arrow/go/v11` has `/v11` as version suffix, not directory
- Actual repository structure: `go/` directory contains code with `module github.com/apache/arrow/go/v11` in go.mod
- Generator was deriving `subdir='go/v11'` from module path, but should be `subdir='go'`
- `git archive` created empty archives when given non-existent subdirs

**Cache invalidation required:** Cleaned 27 modules from metadata cache with bad version-suffixed subdirs (apache/arrow, kingpin/v2, cespare/xxhash/v2, etc.)

### Fix #6: Delete Upstream go.sum Files (2025-10-26)
**Problem:** Build failing with checksum mismatch for `github.com/envoyproxy/go-control-plane/envoy@v1.32.3`. Go was reading go.sum files from git-fetched repositories (e.g., `vcs_cache/.../envoy/go.sum`) and trying to validate against proxy.golang.org checksums, which don't match our git-built archives.

**Solution:** Delete all go.sum files from `${WORKDIR}/sources/vcs_cache` at the start of do_compile:
```bash
find ${WORKDIR}/sources/vcs_cache -name "go.sum" -delete || true
```

**Root cause:**
- Git repositories often contain their own go.sum files with proxy checksums
- When Go builds submodules (like `envoy/`), it validates against those go.sum files
- Our git-built modules produce different (but valid) checksums than proxy tarballs
- We can't regenerate every upstream repository's go.sum
- Solution: Remove them entirely - we already have the trusted source code from git

**Why this is safe:**
- We've already validated git commits via SRCREVs in BitBake
- Source code is from audited git repositories (more secure than proxy)
- Our module cache has correct checksums in k3s's regenerated go.sum
- Removing upstream go.sum files only prevents validation conflicts, doesn't bypass security

## Current Status (v3.0.0)

### What Works
- ✅ Hybrid discovery: `go mod download` + filesystem walk
- ✅ Git-based fetching with SRC_URI entries
- ✅ Module cache creation from git sources
- ✅ Correct handling of `/v2`, `/v3` module paths
- ✅ `+incompatible` version support with synthetic go.mod
- ✅ gopkg.in vanity URL resolution
- ✅ Multiple versions of same module (1:N)
- ✅ Persistent caches (git ls-remote, module metadata)
- ✅ `go-dirhash-native` for checksum verification
- ✅ go.sum regeneration with hash validation
- ✅ Mixing git:// and gomod:// in same recipe

### Known Limitations
- Metadata cache requires manual updates via fix-go-module.py helper
- gopkg.in mapping uses conventional rules (not discovered)
- Some edge cases may require manual metadata cache entries

### Testing Status
- ✅ k3s recipe (626 modules, 58 with multiple versions)
- ✅ +incompatible modules (19 modules)
- ✅ gopkg.in modules (inf.v0, yaml.v3, etc.)
- ⏳ Full end-to-end k3s build validation in progress

## Helper Tools

### fix-go-module.py
Rebuilds individual modules and updates metadata cache:

```bash
# Rebuild specific module with correct commit/timestamp
fix-go-module.py gopkg.in/inf.v0 v0.9.1

# Updates .oe-go-mod-fetcher.module-cache.json with VCS info
# Allows regeneration to pick up correct metadata
```

### Persistent Caches
The generator maintains two JSON cache files in the scripts directory to optimize regeneration:

**`.oe-go-mod-fetcher.ls-remote-cache.json`**
- Caches `git ls-remote` results (URL + ref → commit hash)
- Avoids redundant network calls for tag/commit lookups
- Keyed by `{url}|||{ref}`

**`.oe-go-mod-fetcher.module-cache.json`**
- Caches full module metadata: `vcs_url`, `commit`, `timestamp`, `subdir`
- Keyed by `{module_path}|||{version}`
- Populated from:
  1. Previous cache file (persistent across runs)
  2. Existing go-mod-git.inc + go-mod-cache.inc files (bootstrap)
  3. New discoveries via `resolve_module_metadata()`

**Cache invalidation:**
When fixes change how metadata is derived (like subdir calculation), bad cached data can persist. Current workarounds:
- Manual cache cleaning (e.g., `del data[key]` for affected modules)
- Delete entire cache file and regenerate

**Known issue:** Metadata cache can "poison" itself by bootstrapping from old .inc files. If generated .inc files contain bad data, it gets reloaded into the cache on next run (see Fix #4).

## Architectural Guardrails

### Design Constraints
- **Offline guarantee** - GOPROXY=off during builds, all modules from git
- **Sandbox friendly** - All work under `${WORKDIR}`, no global `/tmp` writes
- **Checksum parity** - dirhash is single source of truth, go.sum matches created artifacts
- **BitBake Python** - No `typing` imports in .inc files (parser limitation)
- **Major-version handling** - `/vN` paths, nested subdirs, +incompatible all supported

### Anti-Patterns Eliminated
- ❌ `go list -m -json` path parsing (normalizes paths incorrectly)
- ❌ Manual go.sum parsing and augmentation
- ❌ Module path manipulation (stripping /v3, etc.)
- ❌ Complex parent module detection heuristics

### Why This Works
1. **Filesystem as truth** - Directory structure IS the module path
2. **Go's own discovery** - Let Go figure out correct paths/versions
3. **Git for sources** - Auditable, patchable, offline-resilient
4. **Standard BitBake** - No special task ordering or tooling required

## Comparison to Alternatives

### vs. oe-core gomod.bbclass
- **Same:** Module cache format, can mix with gomod:// fetches
- **Different:** Uses git sources instead of proxy.golang.org tarballs
- **Advantage:** Full source control, can patch dependencies, offline resilience

### vs. Old Implementation (v2.4.5)
- **Old:** `go list` → manual parsing → complex workarounds
- **New:** `go mod download` → filesystem walk → simple and reliable
- **Result:** Eliminated 4000+ lines of fragile parsing code

## References

### Yocto/OE-Core
- `/opt/bruce/poky/meta/classes-recipe/go-mod-update-modules.bbclass` - Filesystem walk inspiration
- `/opt/bruce/poky/bitbake/lib/bb/fetch2/gomod.py` - gomod:// fetcher for comparison

### Current Implementation
- `meta-virtualization/scripts/oe-go-mod-fetcher.py` (v3.0.0) - Hybrid architecture
- `meta-virtualization/scripts/oe-go-mod-fetcher-mark1.py` - Old v2.4.5 (backup reference)
- `meta-virtualization/scripts/fix-go-module.py` - Helper for manual module rebuilds

### Documentation
- `AGENTS.md` - Agent handoff document with current status and TODO items
- `CLAUDE.md.backup-20251021-012908` - Old architecture design (pre-v3.0.0)

---

## TODO: Improvements & Workflow Enhancements

### Cache Management Improvements
- [x] **Add `--clean-cache` flag** to oe-go-mod-fetcher.py (2025-10-26)
  - `--clean-cache` clears `.oe-go-mod-fetcher.module-cache.json` before regeneration
  - `--clean-ls-remote-cache` clears both caches (implies --clean-cache)
  - Documented in --help with examples
  - Useful when metadata derivation logic changes (subdir calculation, etc.)

- [ ] **Add `--cache-dir` option** to specify cache location
  - Allow storing cache files alongside GOMODCACHE instead of scripts directory
  - Useful for CI/containerized builds where scripts/ may be read-only
  - Default to scripts directory for backward compatibility

- [ ] **Prevent bootstrap cache poisoning**
  - Add validation when loading from .inc files (commit length, subdir sanity checks)
  - Option to disable bootstrap entirely (`--no-bootstrap`)
  - Consider versioning cache format to detect stale entries

### Subdir Detection Improvements
- [ ] **Smarter subdir detection for version-suffixed modules**
  - Current fix strips all trailing `/vNN` patterns
  - May need refinement for edge cases (e.g., actual `/v2` subdirectories)
  - Consider checking actual repository structure via git ls-tree

- [ ] **Validate subdirs during discovery**
  - When Origin.Subdir is present, verify it exists in repository
  - Warn if derived subdir doesn't match repository structure

### Module Metadata Validation
- [ ] **Add checksum validation for cached metadata**
  - Detect when cached commit doesn't match expected pseudo-version
  - Auto-invalidate stale cache entries

- [ ] **Better handling of missing Origin metadata**
  - Expand gopkg.in mapping to other vanity URL services
  - Consider using `go mod download -json` for richer metadata

---

**Last Updated:** 2025-10-27
**Status:** Production (v3.0.0), critical fixes applied
**Current Focus:** Testing complete go.sum regeneration fix (Fixes #6-#8)

**Recent Work (2025-10-26/27):**
- **CRITICAL**: Fixed go.sum regeneration (Fixes #6, #7, #8)
  - Deleted upstream go.sum files before compile
  - Fixed dictionary key format in regenerate_go_sum()
  - Fixed checksum calculation (literal vs real newline)
  - Result: regenerate_go_sum() now properly overrides proxy checksums with git-based ones
- Fixed version suffix stripping in subdir derivation (apache/arrow/go/v11)
- Added `--clean-cache` and `--clean-ls-remote-cache` flags
- Documented cache poisoning issue and workarounds

**Next Steps:**
1. Regenerate k3s recipe to pick up Fixes #7 and #8
2. Rebuild k3s with corrected go-mod-cache.inc
3. Verify no checksum mismatches during do_compile
4. If successful, mark v3.0.0 as production-ready for git-based builds

### Fix #7: go.sum Regeneration Key Format (2025-10-26)
**Problem:** After implementing Fix #6 (deleting upstream go.sum files), build still failed with the same envoy checksum mismatch. Investigation revealed that `regenerate_go_sum()` was using the wrong key format for .mod checksums, so it was preserving old proxy.golang.org checksums instead of recalculating from our git-built .mod files.

**Root Cause:** The go.sum file uses two different key formats for the same module:
- `.zip` checksum: `(module_path, version)` → `github.com/foo/bar v1.2.3 h1:...`
- `.mod` checksum: `(module_path, "version/go.mod")` → `github.com/foo/bar v1.2.3/go.mod h1:...`

But `regenerate_go_sum()` was using the wrong format:
```python
new_entries[(f"{module_path}/go.mod", version)] = mod_checksum  # WRONG
```

This created entries like `github.com/foo/bar/go.mod v1.2.3 h1:...` which didn't match the existing entries, so `.update()` didn't override them.

**Solution:** Fix the key format in `regenerate_go_sum()` (oe-go-mod-fetcher.py line 818):
```python
new_entries[(module_path, f"{version}/go.mod")] = mod_checksum  # CORRECT
```

Now the keys match and `.update()` correctly overrides old proxy checksums with newly calculated git-based checksums.

**Why this is critical:** Without this fix, our git-based architecture produces different .mod files than proxy.golang.org (like envoy v1.32.3 with `replace v0.13.4` vs proxy's `v0.13.3`), but regenerate_go_sum() was preserving the old proxy checksums, causing checksum mismatches during compile.

**Files changed:**
- `/opt/bruce/poky-go-mod-update/meta-virtualization/scripts/oe-go-mod-fetcher.py` (line 818)
- This fix will propagate to go-mod-cache.inc on next regeneration

### Fix #8: Checksum Calculation - Literal vs Real Newline (2025-10-27)
**Problem:** After Fix #7 (correct key format), build STILL failed with checksum mismatch on `dario.cat/mergo@v1.0.1`. Investigation revealed that `calculate_mod_checksum()` was using a LITERAL backslash-n string (`\\n`) instead of a real newline character (`\n`), causing it to calculate the WRONG checksum that matched the old proxy checksum instead of our git-built .mod file.

**Root Cause:** In the `calculate_mod_checksum()` function (line 772 of oe-go-mod-fetcher.py), the code was:
```python
summary = f"{file_hash}  go.mod\\n".encode('ascii')  # WRONG - literal backslash-n
```

This calculates the checksum as if the summary string contained the literal characters `\` and `n`, not a newline. This happened to match proxy.golang.org's checksum format (which also uses `\\n`), but doesn't match what Go actually expects (a real newline).

**Evidence:**
```python
# Our .mod file content
mod_bytes = b'module dario.cat/mergo\n\ngo 1.13\n\nrequire gopkg.in/yaml.v3 v3.0.1\n'

# Method 1 (wrong - what we had):
summary = f"{sha256(mod_bytes).hexdigest()}  go.mod\\n".encode('ascii')
# Produces: h1:1CNOUvBgs3/qU1J/0R4kkdFfNfmgicULfBadLXhEFmw= (OLD proxy checksum)

# Method 2 (correct - what we need):
summary = f"{sha256(mod_bytes).hexdigest()}  go.mod\n".encode('ascii')
# Produces: h1:uNxQE+84aUszobStD9th8a29P2fMDhsBdgRYvZOxGmk= (CORRECT checksum)
```

**Solution:** Change line 772 to use a real newline:
```python
summary = f"{file_hash}  go.mod\n".encode('ascii')  # CORRECT - real newline
```

**Why this is the REAL fix:**
- Fix #7 corrected the dictionary key format so `.update()` could override old entries
- But Fix #7 alone wasn't enough because `calculate_mod_checksum()` was still calculating the WRONG checksum
- Even with the correct key format, we were just replacing old proxy checksums with... the same proxy checksums!
- Fix #8 ensures we calculate the CORRECT checksum that matches our git-built .mod files

**Combined effect of Fix #7 + Fix #8:**
1. Fix #7: New checksums are stored with correct key format → `.update()` works
2. Fix #8: New checksums are CORRECT values → go.sum gets updated with right checksums
3. Result: `regenerate_go_sum()` now properly overrides proxy checksums with git-based ones

**Files changed:**
- `/opt/bruce/poky-go-mod-update/meta-virtualization/scripts/oe-go-mod-fetcher.py` (line 772)
- Must regenerate to propagate to go-mod-cache.inc

### Fix #9: Sibling Version Fallback for Missing VCS Info (2025-10-27)
**Problem:** After Fixes #6-#8 resolved checksum mismatches, build failed with a NEW error: `cel.dev/expr@v0.24.0 requires google.golang.org/protobuf@v1.34.2: module lookup disabled by GOPROXY=off`. Investigation showed 755 modules being skipped as "indirect-only dependencies" because they lacked `.info` files with VCS metadata.

**Root Cause:** During `go mod download`, Go only creates complete `.info` files (with `Origin.URL` and `Origin.Hash`) for modules it actually downloads and uses. For indirect dependencies at specific versions that aren't selected by MVS (Minimal Version Selection), Go may only download the `.mod` file without VCS metadata. Our script correctly identified these as having no VCS info, but incorrectly assumed they were ALL "indirect-only" (only need go.mod, not source).

**Evidence:**
```bash
# protobuf v1.34.2 exists in go.sum (required by cel.dev/expr@v0.24.0)
$ grep "google.golang.org/protobuf v1.34.2" /home/bruce/git/k3s/go.sum
google.golang.org/protobuf v1.34.2/go.mod h1:qYOHts0dSfpeUzUFpOMr/WGzszTmLH+DiWniOlNbLDw=

# But only .mod file in GOMODCACHE (no .info, .zip, .ziphash)
$ ls /opt/bruce/cache/go-mod-cache/cache/download/google.golang.org/protobuf/@v/v1.34*
v1.34.2.mod

# While v1.36.6 has complete files (was discovered)
$ ls /opt/bruce/cache/go-mod-cache/cache/download/google.golang.org/protobuf/@v/v1.36.6.*
v1.36.6.info  v1.36.6.mod  v1.36.6.zip  v1.36.6.ziphash
```

**Key Insight:** When `resolve_module_metadata()` fails because there's no `.info` file, we can use the VCS URL from ANY other version of the same module to resolve the missing version. All versions of a module come from the same git repository, so if we have `v1.36.6`'s VCS URL, we can use it to look up `v1.34.2`'s commit.

**Solution:** Implement sibling version fallback in main loop (oe-go-mod-fetcher.py lines 1332-1389):
```python
# Build index of discovered modules by module_path
modules_by_path = {}
for m in modules:
    modules_by_path.setdefault(m['module_path'], []).append(m)

for module_path, version in sorted(go_sum_modules):
    # Try normal resolution first
    fallback = resolve_module_metadata(module_path, version)
    if fallback:
        modules.append(fallback)
        modules_by_path.setdefault(module_path, []).append(fallback)
    else:
        # If resolution failed, try using VCS URL from sibling version
        if module_path in modules_by_path:
            reference_module = modules_by_path[module_path][0]
            vcs_url = reference_module['vcs_url']

            # Try to resolve using known VCS URL
            tag = version.split('+')[0]
            commit = git_ls_remote(vcs_url, f"refs/tags/{tag}") or git_ls_remote(vcs_url, tag)

            if commit:
                # Successfully resolved using fallback VCS URL
                timestamp = derive_timestamp_from_version(version)
                subdir = reference_module.get('subdir', '')

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
                modules_by_path[module_path].append(fallback)
                print(f"  ✓ {module_path}@{version} (resolved using VCS URL from sibling version)")
                continue

        # Still couldn't resolve - truly indirect-only
        print(f"  ⚠️  Skipping {module_path}@{version} (indirect-only dependency)")
```

**Results:**
- **115 additional modules** resolved using sibling version fallback
- Total modules increased from **866 to 981**
- Skipped modules decreased from **755 to 640**
- Successfully resolved: `google.golang.org/protobuf@v1.34.2`, `cel.dev/expr@v0.15.0-v0.20.0`, `go.opencensus.io@v0.18.0-v0.23.0`, and many others

**Example output:**
```
⚠️  Unable to derive repository for google.golang.org/protobuf@v1.34.2
✓ google.golang.org/protobuf@v1.34.2 (resolved using VCS URL from sibling version)
```

**Why this works:**
- All versions of a Go module share the same git repository
- If `module@v1.0.0` has VCS URL `https://github.com/foo/bar`, then `module@v2.0.0` uses the same URL
- We can use `git ls-remote` to look up any tag in that repository
- Subdir is inherited from discovered sibling (usually correct for same module path)

**Limitations:**
- If NO version of a module was discovered (none have .info files), fallback won't work
- These modules are truly indirect-only and will remain skipped (640 modules)
- Subdir inheritance may be incorrect if different versions use different subdirs (rare)

**Impact:** This fix resolves compilation errors for dependencies that require specific versions not directly imported by the main project. Without it, builds would fail even though we have the repository URL available from other versions of the same module.

**Files changed:**
- `/opt/bruce/poky-go-mod-update/meta-virtualization/scripts/oe-go-mod-fetcher.py` (lines 1332-1389)

### Fix #10: Pseudo-Version Resolution via Repository Cloning (2025-10-27)
**Problem:** After Fix #9, build progressed further but failed with a NEW missing module: `google.golang.org/genproto/googleapis/rpc@v0.0.0-20240826202546-f6391c0de4c7`. This is a pseudo-version with a SHORT commit hash (12 characters) that cannot be resolved via `git ls-remote`.

**Root Cause:** Pseudo-versions embed short commit hashes in their version strings (e.g., `v0.0.0-20240826202546-f6391c0de4c7` contains short hash `f6391c0de4c7`). When these modules aren't discovered during `go mod download` (no .info file), we cannot resolve them because:

1. **`git ls-remote` only works with refs** (tags, branches), NOT commit hashes
2. **Short commits cannot be expanded** without having the repository cloned locally
3. **Fix #9's sibling fallback** uses `git ls-remote` for tags, so it fails for pseudo-versions too

**Evidence:**
```bash
# cel.dev/expr@v0.24.0's go.mod requires this specific pseudo-version
$ cat /opt/bruce/cache/go-mod-cache/cache/download/cel.dev/expr/@v/v0.24.0.mod
require (
    google.golang.org/genproto/googleapis/rpc v0.0.0-20240826202546-f6391c0de4c7
    google.golang.org/protobuf v1.34.2
)

# This version only has .mod file (no .info with VCS metadata)
$ ls /opt/bruce/cache/go-mod-cache/cache/download/google.golang.org/genproto/googleapis/rpc/@v/v0.0.0-20240826202546-f6391c0de4c7.*
v0.0.0-20240826202546-f6391c0de4c7.mod  # Only .mod, no .info!

# But we have other versions with full VCS info
$ ls /opt/bruce/cache/go-mod-cache/cache/download/google.golang.org/genproto/googleapis/rpc/@v/v0.0.0-20250826171959-ef028d996bc1.*
v0.0.0-20250826171959-ef028d996bc1.info
v0.0.0-20250826171959-ef028d996bc1.mod
v0.0.0-20250826171959-ef028d996bc1.zip
v0.0.0-20250826171959-ef028d996bc1.ziphash
```

**Why this is different from Fix #9:**
- Fix #9 works for **tagged versions** (e.g., `v1.34.2`) by using `git ls-remote` with tag names
- Pseudo-versions have **embedded short commit hashes** that `git ls-remote` cannot resolve
- Need to clone the repository and search git log for commits matching timestamp + short hash

**Solution:** Implement pseudo-version resolution by cloning repositories and searching commit history:

```python
def resolve_pseudo_version_commit(vcs_url: str, timestamp_str: str, short_commit: str,
                                   clone_cache_dir: Optional[Path] = None) -> Optional[str]:
    """
    Resolve a pseudo-version's short commit hash to a full 40-character hash.

    Args:
        vcs_url: Git repository URL
        timestamp_str: Timestamp from pseudo-version (format: YYYYMMDDHHmmss)
        short_commit: Short commit hash (12 characters) from pseudo-version
        clone_cache_dir: Directory to cache cloned repositories

    Returns:
        Full 40-character commit hash, or None if not found
    """
    # Parse timestamp
    try:
        dt = datetime.strptime(timestamp_str, "%Y%m%d%H%M%S")
        # Search window: ±1 day around timestamp
        since = (dt - timedelta(days=1)).isoformat()
        until = (dt + timedelta(days=1)).isoformat()
    except ValueError:
        return None

    # Determine clone directory
    if clone_cache_dir:
        repo_hash = hashlib.sha256(vcs_url.encode()).hexdigest()[:16]
        clone_dir = clone_cache_dir / f"repo_{repo_hash}"
    else:
        clone_dir = Path(tempfile.mkdtemp(prefix="pseudo-resolve-"))

    try:
        # Clone or update repository
        if clone_dir.exists():
            # Repository already cloned, fetch latest
            subprocess.run(
                ['git', 'fetch', '--all'],
                cwd=clone_dir,
                capture_output=True,
                check=True
            )
        else:
            # Clone repository (bare clone for efficiency)
            clone_dir.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                ['git', 'clone', '--bare', vcs_url, str(clone_dir)],
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
            check=True
        )

        # Find commit with matching short hash prefix
        for line in result.stdout.strip().splitlines():
            if not line:
                continue
            full_hash, commit_time = line.split()
            if full_hash.startswith(short_commit):
                return full_hash

        return None

    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        return None
    finally:
        # Clean up if we created a temp directory
        if not clone_cache_dir and clone_dir.exists():
            shutil.rmtree(clone_dir)
```

**Integration with sibling version fallback (Fix #9 enhancement):**

```python
# In main loop, after Fix #9's sibling fallback fails for pseudo-versions
if module_path in modules_by_path:
    reference_module = modules_by_path[module_path][0]
    vcs_url = reference_module['vcs_url']

    # Try to resolve using known VCS URL
    tag = version.split('+')[0]

    # Check if this is a pseudo-version
    pseudo_match = re.match(r'v\d+\.\d+\.\d+-(\d{14})-([0-9a-fA-F]+)', tag)

    if pseudo_match:
        # Pseudo-version with short commit - need to clone and search
        timestamp_str = pseudo_match.group(1)
        short_commit = pseudo_match.group(2)

        commit = resolve_pseudo_version_commit(
            vcs_url,
            timestamp_str,
            short_commit,
            clone_cache_dir=Path.home() / '.cache' / 'oe-go-mod-fetcher' / 'repos'
        )
    else:
        # Regular tagged version - use git ls-remote
        commit = git_ls_remote(vcs_url, f"refs/tags/{tag}") or git_ls_remote(vcs_url, tag)

    if commit:
        # Successfully resolved!
        timestamp = derive_timestamp_from_version(version)
        subdir = reference_module.get('subdir', '')

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
        print(f"  ✓ {module_path}@{version} (resolved pseudo-version via clone)")
        continue
```

**Performance considerations:**
- **Clone cache**: Repositories are cloned to `~/.cache/oe-go-mod-fetcher/repos/` and reused across runs
- **Bare clones**: Use `--bare` for minimal disk usage (no working tree)
- **Incremental fetch**: Existing clones are updated with `git fetch` instead of re-cloning
- **Timeout**: 5-minute timeout per clone operation to prevent hangs
- **Search window**: Only search ±1 day around timestamp for efficiency

**Benefits:**
- Resolves pseudo-versions that `git ls-remote` cannot handle
- Reuses clone cache across regenerations (fast subsequent runs)
- Works for any pseudo-version, not just specific services
- No API keys or rate limits (unlike GitHub API approach)

**Limitations:**
- First-time clones add time to generation (one-time cost per repository)
- Requires sufficient disk space for clone cache
- May fail for very large repositories (mitigated by bare clones)
- Assumes timestamp in pseudo-version accurately reflects commit time (±1 day window)

**Files changed:**
- `/opt/bruce/poky-go-mod-update/meta-virtualization/scripts/oe-go-mod-fetcher.py` - Add `resolve_pseudo_version_commit()` function
- `/opt/bruce/poky-go-mod-update/meta-virtualization/scripts/oe-go-mod-fetcher.py` (lines 1332-1389) - Enhance sibling fallback to handle pseudo-versions
