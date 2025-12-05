# Architecture & Workflow – Go Module Fetcher for Yocto/BitBake

This document explains the moving pieces that let us turn Go module metadata into reproducible, offline BitBake builds. It expands on the handoff notes in `AGENTS.md` by detailing each phase, the helper tooling, the BitBake tasks involved, and the operational constraints we must keep.

## Goals and Non‑Negotiable Requirements
- **Offline, reproducible builds** – After BitBake finishes `do_fetch`, every Go module must be satisfiable from the local workspace; no network is allowed during the cache replay or compile phases.
- **Canonical git provenance** – Every module revision is mapped to an auditable git repository and commit (`rev=`). We never trust proxy archives or hashes in `go.sum` without verifying the commit exists upstream.
- **Byte-for-byte module cache parity** – The reconstructed cache under `${WORKDIR}/module-cache` must match Go’s proxy layout so `go build` finds identical `zip`, `mod`, and `info` content and passes hash verification.
- **Deterministic regeneration** – Re-running the generator with the same inputs (source tree + cache) must produce identical `.inc` files. Any override or manual fix must be captured in the shared caches so future runs behave identically.
- **Human-operated network access** – CLI helpers can assume the human operator has unrestricted network access; the agent running inside Codex must only print full command lines.
- **No “ghost commit” explanations** – If BitBake sees an unreachable commit, the culprit is stale metadata or an incorrect override. Do not blame lingering git objects; clean data fixes the issue.

## High-level Data Flow
```
go.mod / go.sum ─┐
                 │   (Discovery + Validation)
go list -m all ──┤──► oe-go-mod-fetcher.py ─┐
go mod download ─┘                         │
                                             │ writes
Cached metadata (.cache/*.json) ═════════════╪══► go-mod-git.inc / go-mod-cache.inc
Fix helpers (gen-single-module.py,           │
 fix-go-module.py, check-srcrev.py) ═════════┘

BitBake do_fetch ─► vcs_cache/… bare repos ─► do_create_module_cache ─► module-cache/download/… ─► go build (offline)
```

## Tooling Components

- **`oe-go-mod-fetcher.py` (v3.0.0)**  
  Primary generator. Handles discovery, validation, recipe generation, cache ownership, and override management. Key options:
  - `--validate`: run discovery + commit verification without writing `.inc`.
  - `--cache-dir`: shared state (`.verify-cache.json`, `.module-cache.json`, repo overrides, ls-remote cache).
  - `--set-repo / --inject-commit`: pin module → repo mappings and seed verified commits.
  - `--skip-legacy-module-cache`: opt out of the cached metadata bootstrap when doing a clean refresh.

- **`gen-single-module.py`**  
  Targeted fixer. Automates the manual SRCREV repair loop:
  1. Clones or reuses a scratch repo, optionally showing recent commits (`--list-commits`).
  2. Suggests the module version/pseudo-version required by `go.sum`.
  3. Accepts a chosen commit SHA and rewrites `go-mod-git.inc`, `go-mod-cache.inc`, matching `SRCREV_*` (until we drop them), and refreshes the fetcher caches via `oe-go-mod-fetcher.py --set-repo … --inject-commit … --dry-run`.
  4. Leaves a preserved scratch directory when `--no-clean` is set so the operator can inspect history.

- **`fix-go-module.py`**  
  BitBake helper run inside `${WORKDIR}` to rebuild a single module. Produces deterministic `zip/mod/info`, feeds the module metadata cache with commit/timestamp/subdir details, and prints hash comparisons to confirm reproducibility.

- **`check-srcrev.py`**  
  Audits generated includes. Verifies each `rev=` exists on the advertised refs (after the branch substring fix), optionally fetching missing commits and updating the shared cache (`--fetch-missing`, `--force-remote`, `--verbose`).

- **`verify-commit-cache.py`**
  Replays `--validate` logs by executing the suggested "try:" fetch commands in bulk, updating `data/verify-cache.json` so follow-up runs can skip refetching.

- **`go-dirhash-native`**  
  Native helper available inside BitBake’s devshell; produces the canonical `h1:` hashes that feed both `go.sum` rewrites and the `.ziphash` entries.

- **Caches under `${CACHE_DIR}/data/` (typically `scripts/data/`)**
  See "JSON Cache Files" section below for detailed documentation.

- **`go-mod-vcs.bbclass`**
  Reusable BitBake class providing `do_create_module_cache` and `do_sync_go_files` tasks.
  Generated `.inc` files inherit this class rather than embedding task code.
  Declares `DEPENDS += "go-dirhash-native"` for checksum calculation.

## Workflow Phases

### Phase 0 – Inputs and Cache Bootstrap
1. Operator runs `oe-go-mod-fetcher.py` with consistent `--source-dir`, `--recipedir`, `--gomodcache`, `--cache-dir`.
2. Generator loads cached metadata (unless `--skip-legacy-module-cache` is given), repo overrides, and previously verified commits.
3. For each module in `go.mod`/`go.sum`, existing metadata seeds discovery; missing entries trigger new lookups.

### Phase 1 – Discovery & Validation
1. **Module enumeration**  
   - Run `go list -m all` to obtain the authoritative module graph.  
   - If needed, fall back to parsing `go.sum`, but the TODO backlog mandates aligning the final list with `go list` output and deduplicating per module path.
2. **Metadata hydration**  
   - Query cached data first.  
   - When timestamps or subdirs are missing, use `go list -m -json module@version` or `go mod download` to refresh `.info` and `.mod` files inside `--gomodcache`.
3. **Repository resolution**  
   - Apply repo overrides before trusting proxy URLs (critical for vanity domains like `gvisor.dev` or `gopkg.in`).  
   - Vanity resolution lives in `resolve_module_metadata()` with explicit mapping rules.
4. **Commit verification**  
   - Generator uses `_verify_commit_accessible()` to ensure each SHA exists on the remote by running `git ls-remote` and fetching when necessary.  
   - Results are persisted in `.verify-cache.json` so subsequent runs can short-circuit.  
   - If a commit cannot be resolved, the run must fail (fail-fast requirement) and output the module list for manual intervention.
5. **Optional `--validate`**  
   - Stops after verification, prints a summary of missing metadata, and logs ready-to-run commands for `gen-single-module.py` or `oe-go-mod-fetcher.py --inject-commit/--set-repo`.  
   - Use this to vet the entire module graph without touching `.inc` files.

### Phase 2 – Recipe Generation
1. Reuses cached validation data; TODO item “Reuse validation cache” aims to avoid revalidating unchanged modules during this phase.
2. Writes `go-mod-git.inc` with `SRC_URI` entries mapping each module to its canonical git repo and commit (plus `nobranch=1` when appropriate).  
   - Upcoming work: deduplicate entries so each module appears once (matching `go list -m all`).
3. Writes `go-mod-cache.inc`, embedding the metadata used by BitBake’s `do_create_module_cache` task (module path, version, commit, timestamp, subdir, expected hash).
4. Updates shared caches to reflect any new metadata so later runs remain deterministic.
5. Emits a summary listing skipped modules (missing repo metadata) and the log path for auditing.

### BitBake Discovery Workflow (Recommended)

The `go-mod-discovery.bbclass` provides modular tasks for discovery, extraction, and generation. Tasks can be run individually or chained together.

**Available Tasks:**

| Task | Purpose | Network? |
|------|---------|----------|
| `discover_modules` | Build project, download modules to cache | Yes |
| `extract_modules` | Extract metadata from cache to `modules.json` | No |
| `generate_modules` | Generate `.inc` files from `modules.json` | No |
| `discover_and_generate` | Run all three in sequence | Yes |
| `show_upgrade_commands` | Print copy-pasteable command lines | No |
| `clean_discovery` | Remove persistent discovery cache | No |

**Quick Start - All-in-One:**
```bash
# Configure recipe with GO_MOD_DISCOVERY_GIT_REPO, then:
bitbake k3s -c discover_and_generate
# Done! Recipe .inc files are automatically regenerated.
```

**Step-by-Step Workflow:**
```bash
# Step 1: Download modules (slow, requires network)
bitbake k3s -c discover_modules

# Step 2: Extract metadata to JSON (fast, no network)
bitbake k3s -c extract_modules

# Step 3: Generate .inc files (fast, no network)
bitbake k3s -c generate_modules
```

This modular approach is useful when:
- Debugging discovery issues (run steps individually)
- Reusing an existing cache (skip step 1, run steps 2-3)
- Testing different generation options (rerun step 3 only)

**Show Commands Without Running:**
```bash
bitbake k3s -c show_upgrade_commands
```

This prints all available options with recipe-specific values filled in:
- Option 1: Direct script invocation (no BitBake)
- Option 2: Step-by-step BitBake tasks
- Option 3: All-in-one BitBake task
- Option 4: Use existing discovery cache

**Recipe Configuration (k3s example):**
```bitbake
TAGS = "static_build netcgo osusergo providerless"
GO_MOD_DISCOVERY_BUILD_TARGET = "./cmd/server/main.go"
GO_MOD_DISCOVERY_GIT_REPO = "https://github.com/rancher/k3s.git"
GO_MOD_DISCOVERY_GIT_REF = "${SRCREV_k3s}"
inherit go-mod-discovery
```

**Manual Script Invocation (Alternative to BitBake):**
```bash
# Option 1: Generate directly from git repo (recommended for new recipes)
python3 ./meta-virtualization/scripts/oe-go-mod-fetcher.py \
    --git-repo https://github.com/rancher/k3s.git \
    --git-ref ${SRCREV} \
    --recipedir ./meta-virtualization/recipes-containers/k3s

# Option 2: Use existing discovery cache
python3 ./meta-virtualization/scripts/extract-discovered-modules.py \
    --gomodcache ${TOPDIR}/go-mod-discovery/k3s/${PV}/cache \
    --output ${TOPDIR}/go-mod-discovery/k3s/${PV}/modules.json

python3 ./meta-virtualization/scripts/oe-go-mod-fetcher.py \
    --discovered-modules ${TOPDIR}/go-mod-discovery/k3s/${PV}/modules.json \
    --git-repo https://github.com/rancher/k3s.git \
    --git-ref ${SRCREV} \
    --recipedir ./meta-virtualization/recipes-containers/k3s
```

**Key Variables:**
| Variable | Default | Description |
|----------|---------|-------------|
| `GO_MOD_DISCOVERY_BUILD_TARGET` | (required) | Go build target (e.g., `./cmd/server`) |
| `GO_MOD_DISCOVERY_GIT_REPO` | `""` | Git repo URL (required for `generate_modules`) |
| `GO_MOD_DISCOVERY_GIT_REF` | `${SRCREV}` | Git commit/tag |
| `GO_MOD_DISCOVERY_RECIPEDIR` | `${FILE_DIRNAME}` | Output directory for .inc files |
| `GO_MOD_DISCOVERY_DIR` | `${TOPDIR}/go-mod-discovery/${PN}/${PV}` | Persistent cache location |
| `GO_MOD_DISCOVERY_MODULES_JSON` | `${GO_MOD_DISCOVERY_DIR}/modules.json` | Extracted metadata file |

### Manual Fix Loop (Single Module Repair)
1. Run `gen-single-module.py MODULE REPO --list-commits N` to inspect history. If BitBake failed against a GitHub mirror, retry with the canonical upstream (e.g., `https://gvisor.googlesource.com/gvisor`).
2. Inspect the preserved scratch repo, pick a valid commit, then rerun the helper with the SHA (and optional `--no-clean` to keep the workspace).
   - Helper rewrites the include files, updates `SRCREV_*` (until they are removed), and seeds the generator caches via `oe-go-mod-fetcher.py --set-repo … --inject-commit … --dry-run`.
3. Optionally run `check-srcrev.py --match MODULE …` to confirm the fix before rebuilding.
4. Regenerate includes if multiple modules were touched, or run BitBake directly for a targeted fetch.

### Validation Utilities
- **`check-srcrev.py`** catches stale or malformed branch parameters (`;branch=` vs `nobranch=1`) and ensures the includes advertise only reachable commits.
- **`verify-commit-cache.py`** consumes validation logs to automatically populate the verified commit cache without manual command replay.
- **`fix-go-module.py`** can recreate problematic modules inside BitBake's `WORKDIR`, ensuring deterministic archives and feeding metadata back to the generator.

## Permanent Fix Workflow & Caching System

### Overview: Temporary vs Permanent Fixes

The fast-fix tools (`fast-fix-module.py`, `investigate-missing-module.py`) provide **temporary** fixes by directly modifying build directory files. These modifications are lost when:
- Running `bitbake -c cleanall`
- Recipe file changes trigger task hash changes (re-fetch/unpack)
- Deleting the build directory

To make fixes **permanent**, you must ensure the generator discovers and includes the missing modules in future regenerations.

### The Multi-Tier Caching System

oe-go-mod-fetcher.py maintains several persistent caches stored in `scripts/data/`:

#### 1. Module Metadata Cache (`data/module-cache.json`)

**Purpose:** Cache VCS resolution results to speed up future regenerations.

**Format:**
```json
{
  "github.com/opencontainers/runtime-spec|||v1.0.2": {
    "vcs_url": "https://github.com/opencontainers/runtime-spec",
    "commit": "a59a1fd4aff7706679d37bf0d281842c2694a1af",
    "timestamp": "1970-01-01T00:00:00Z",
    "subdir": ""
  }
}
```

**Populated from:**
- `.info` files discovered during `go mod download` (primary source)
- Fallback resolution via `resolve_module_metadata()` (vanity URLs, gopkg.in, etc.)
- Previous `.inc` files during bootstrap (can cause cache poisoning - see Fix #4)
- Fast-fix tools when run with `--discover` mode

**Key insight:** Having metadata in this cache does NOT guarantee the module will be generated! The cache is only consulted AFTER the module is discovered from `go.sum`.

#### 2. Repository Override Cache (`data/repo-overrides.json`)

**Purpose:** Pin specific modules to use specific repositories (override vanity URLs, use forks/mirrors).

**Format:**
```json
{
  "github.com/example/module": "https://github.com/myfork/module",
  "github.com/example/other|||v1.2.3": "https://my-mirror.com/other"
}
```

**Populated from:**
- Manual injection via `--set-repo MODULE REPO` flag
- Used to override discovery for modules that ARE in go.sum

**Key use cases:**
- Redirect vanity URLs to specific repositories
- Use a fork or mirror instead of the canonical repository
- Override discovery for problematic modules

#### 3. Verification Cache (`data/verify-cache.json`)

**Purpose:** Cache results of commit verification (`git ls-remote`) to skip expensive network operations.

**Format:**
```json
{
  "https://github.com/example/repo|||abc123def456...": true
}
```

**Populated from:**
- Automatic during `verify_commit_reachable()` calls
- Manual injection via `--inject-commit REPO COMMIT` flag
- `verify-commit-cache.py` bulk verification tool

### The Discovery Pipeline: Why go.sum is the Source of Truth

The generator follows this strict workflow:

```python
# Step 1: Discover modules from go.sum (REQUIRED)
go_sum_modules = parse_go_sum(source_dir / "go.sum")
modules = []

# Step 2: For each module in go.sum, resolve VCS info
for module_path, version in go_sum_modules:
    # Check metadata cache FIRST (fast path)
    cached = get_from_metadata_cache(module_path, version)
    if cached:
        modules.append(cached)
        continue

    # Check repository overrides
    repo_override = get_repo_override(module_path, version)
    if repo_override:
        # Use overridden repository for VCS resolution
        vcs_url = repo_override

    # Not in cache - discover via filesystem walk or fallback
    discovered = discover_from_gomodcache(module_path, version)
    if not discovered:
        discovered = resolve_module_metadata(module_path, version)

    if discovered:
        modules.append(discovered)
        update_metadata_cache(module_path, version, discovered)
```

**Critical point:** If a module is NOT in `go.sum`, Step 1 never adds it to `go_sum_modules`, so Step 2 never attempts to resolve it - **even if the metadata cache already has VCS info for it!**

This design ensures:
- go.sum is the authoritative declaration of required modules
- The cache is purely an optimization (speeds up VCS resolution)
- Manual cache injection cannot bypass go.sum requirements

### Three Paths to Permanent Fixes

#### Path A: Module Not in go.sum (Most Common)

**Symptom:** Build fails with "module lookup disabled by GOPROXY=off" for a module that's not in the source repository's go.sum.

**Root Cause:** k3s's go.mod is incomplete - missing an indirect dependency that Go tries to resolve at compile time.

**Permanent Fix:**
```bash
cd /home/bruce/git/k3s  # or your source repository

# Add the missing module
go get github.com/opencontainers/runtime-spec@v1.0.2

# Clean up (removes unused dependencies, updates go.sum)
go mod tidy

# Verify it's now in go.sum (TWO entries per module)
grep "github.com/opencontainers/runtime-spec v1.0.2" go.sum
# Should show:
# github.com/opencontainers/runtime-spec v1.0.2 h1:... (zip checksum from proxy)
# github.com/opencontainers/runtime-spec v1.0.2/go.mod h1:... (mod checksum from proxy)
```

**What happens next (automatic):**
1. Source repository now has module in `go.sum` ✓
2. Regenerate recipe: `oe-go-mod-fetcher.py` discovers it from `go.sum` ✓
3. Generator checks metadata cache - finds VCS info (fast!) ✓
4. Generates `.inc` entries for the module ✓
5. During BitBake build: `do_create_module_cache` creates cache from git ✓
6. After cache creation: `regenerate_go_sum()` recalculates checksums from git-built artifacts ✓
7. Build uses regenerated go.sum with **git-based checksums** (not proxy) ✓

**Key insight about go.sum checksums:** The checksums added by `go get` (from proxy.golang.org) are TEMPORARY placeholders. The `regenerate_go_sum()` function (Fixes #6-#8 in CLAUDE.md) **replaces** them with checksums calculated from our git-built artifacts during `do_create_module_cache`. This is why:
- You don't need to worry about proxy vs git checksum differences
- The permanent workflow is simply: add to go.sum, regenerate recipe
- All checksum conversion happens automatically during the build

#### Path B: Module in go.sum but Generator Skipped It

**Symptom:** Module appears in go.sum but wasn't included in generated `.inc` files.

**Root Cause:** Generator couldn't resolve VCS info (no Origin metadata, resolution failed, etc.).

**Permanent Fix:**
```bash
cd /opt/bruce/poky-go-mod-update/meta-virtualization/scripts

# Manually add to .inc files
python3 gen-single-module.py github.com/example/module \
    v1.2.3 \
    https://github.com/example/module \
    abc123def456...  # full 40-character commit hash
```

**What this does:**
- Directly updates `go-mod-git.inc` with `SRC_URI` git fetch entry
- Directly updates `go-mod-cache.inc` with module metadata
- Updates metadata cache for future regenerations
- Bypasses go.sum requirement (direct .inc injection)

**Note:** This still uses `regenerate_go_sum()` to ensure git-based checksums!

#### Path C: Generator Needs Fixing (Discovery Bug)

**Symptom:** Generator has a bug that prevents discovering certain modules (like the vanity URL problem solved by Fix #15).

**Immediate Workaround:** Use Path B (`gen-single-module.py`) to manually add the module.

**Long-term Fix:** Fix the generator code and document in `AGENTS.md`. Examples:
- Fix #15: Added dynamic vanity URL resolution with `?go-get=1` queries
- Fix #12: Added golang.org/x special handling
- Fix #14: Added go.uber.org vanity URL mapping

### Cache Injection Flags: When and Why to Use Them

#### `--set-repo MODULE REPO`

**Use case:** Override repository URL for a module that IS in go.sum.

```bash
# Pin module to use a fork instead of canonical repository
./oe-go-mod-fetcher.py \
    --set-repo github.com/example/module https://github.com/myfork/module \
    --git-repo https://github.com/k3s-io/k3s.git \
    --git-ref $COMMIT \
    --recipedir ../recipes-containers/k3s/
```

**When to use:**
- Testing a fork or patch of a dependency
- Using a mirror for reliability
- Overriding vanity URL resolution (though Fix #15 handles most cases automatically)

**Important:** This does NOT add the module to go.sum! The module must already be discovered from go.sum for the override to take effect.

#### `--inject-commit REPO COMMIT`

**Use case:** Mark a repository+commit pair as already verified (skip network check).

```bash
# Speed up regeneration by pre-seeding verified commits
./oe-go-mod-fetcher.py \
    --inject-commit https://github.com/example/repo abc123def456... \
    --git-repo https://github.com/k3s-io/k3s.git \
    --git-ref $COMMIT \
    --recipedir ../recipes-containers/k3s/
```

**When to use:**
- Speeding up regeneration (avoids `git ls-remote` network calls)
- Working offline with previously verified commits
- Bulk verification with `verify-commit-cache.py`

**Workflow:** Run `verify-commit-cache.py` on validation logs to bulk-inject verified commits.

### Common Misconceptions

**Misconception 1:** "Adding metadata to the cache will make the generator include the module."

**Reality:** The metadata cache is only consulted AFTER a module is discovered from go.sum. Adding metadata doesn't trigger discovery.

**Misconception 2:** "I need to use `--inject-commit` to add missing modules."

**Reality:** `--inject-commit` is for optimization (skip verification), not for adding modules. Use `go get` (Path A) or `gen-single-module.py` (Path B) to add modules.

**Misconception 3:** "The checksums in go.sum need to match our git-built artifacts."

**Reality:** The checksums added by `go get` are from proxy.golang.org and WON'T match. That's expected! The `regenerate_go_sum()` function automatically replaces them with git-based checksums during `do_create_module_cache`.

### Fast-Fix Workflow Integration

The fast-fix tools (`fast-fix-module.py`, `investigate-missing-module.py`) are designed for **rapid iteration during debugging**:

1. **Temporary fix:** `fast-fix-module.py` creates module cache artifacts in the build directory
2. **Test:** `bitbake -c compile k3s` verifies the fix works
3. **Permanent fix:** Once working, apply Path A (`go get`) or Path B (`gen-single-module.py`)
4. **Regenerate:** Run `oe-go-mod-fetcher.py` to update `.inc` files
5. **Verify:** `bitbake -c cleanall k3s && bitbake k3s` confirms permanent fix works

**Key benefit:** Fast-fix testing takes 5-10 seconds vs 30+ minutes for full BitBake cycles, enabling rapid iteration.

### Summary: The Complete Permanent Fix Flow

```
Missing Module Detected (build failure)
    ↓
Fast-fix for rapid testing (5-10 sec)
    ↓
Test passes - determine root cause:
    ↓
    ├─ NOT in go.sum? → Path A: go get + go mod tidy
    ├─ IN go.sum but not generated? → Path B: gen-single-module.py
    └─ Generator bug? → Path C: Fix generator + Path B workaround
    ↓
Regenerate recipe (oe-go-mod-fetcher.py)
    ↓
BitBake discovers module from go.sum
    ↓
Generator finds VCS info (from metadata cache - fast!)
    ↓
Generates .inc entries
    ↓
BitBake build: do_create_module_cache builds from git
    ↓
regenerate_go_sum() replaces proxy checksums with git checksums
    ↓
✅ Permanent fix complete - works on clean builds
```

## BitBake Task Lifecycle

1. **`do_fetch` (k3s recipe + includes)**  
   - Uses `go-mod-git.inc` to clone each module’s repo into `${WORKDIR}/vcs_cache/<hash>`.  
   - `nobranch=1` tells the fetcher to allow detached commits; `rev=` selects the exact SHA.  
   - Mirroring logic (BitBake `MIRRORS`) runs if the primary host is unreachable.
   - Any missing commit surfaces here; the fix loop ensures regenerated includes avoid this state.

2. **`do_unpack` / `do_patch`**  
   - Standard Yocto tasks; Go module handling happens later. Nothing special for the fetcher, but note that all module sources already exist under `vcs_cache`.

3. **`do_create_module_cache` (from `go-mod-cache.inc`)**
   - Iterates `GO_MODULE_CACHE_DATA`. For each entry:
     1. Checks out the cached repo at the specified commit (and subdir if present).
     2. Removes vendor directories and normalizes timestamps/permissions.
     3. Synthesizes `go.mod` for `+incompatible` modules when upstream lacks one.
     4. For modules with path mismatches (e.g., k3s-io/kubernetes staging packages), synthesizes corrected `go.mod` while **preserving the `go X.XX` version directive** (Fix #31).
     5. Generates deterministic `zip`, `mod`, and `info` files under `${WORKDIR}/module-cache/download/<module>/@v/`.
     6. Runs `dirhash` to compute the canonical `h1:` hash and rewrites `go.sum` accordingly.
   - **Critical**: The `assemble_zip()` function must create zip files **inside** the `TemporaryDirectory` context manager to avoid empty archives (Fix #30).
   - Result: `${WORKDIR}/module-cache` mirrors the Go proxy layout and becomes the offline `GOMODCACHE`.

4. **`do_validate_modules` (PROPOSED - not yet implemented)**
   - **TODO:** Add validation task between `do_create_module_cache` and `do_compile`
   - Runs `go list -deps ./...` to validate ALL dependencies (including transitive)
   - Fails fast with clear error messages listing ALL missing modules at once
   - Much faster than waiting for compile failures (5-10 seconds vs 5-10 minutes)
   - See: `check-missing-modules.sh` for standalone implementation
   - **CRITICAL**: Do NOT use `-e` flag or template format (`-f`) - these truncate error messages
   - Implementation:
     ```python
     do_validate_modules() {
         cd ${S}/src/import
         export GOMODCACHE="${S}/pkg/mod"
         export GOPROXY=off
         export GO111MODULE=on
         export GOTOOLCHAIN=local  # Don't try to download newer Go versions

         # Check all dependencies (direct + transitive)
         # Redirect stdout to /dev/null, capture full errors in stderr
         if ! go list -deps ./... >/dev/null 2>${WORKDIR}/missing-modules.log; then
             bbfatal "Missing Go modules detected:\n$(cat ${WORKDIR}/missing-modules.log)"
         fi
     }
     addtask validate_modules after do_create_module_cache before do_compile
     ```

5. **`do_compile`**
   - Invokes the Go toolchain with `GOMODCACHE=${WORKDIR}/module-cache`.
   - Because `go.sum` now references hashes generated by `dirhash`, Go's module verifier is satisfied without network access.

6. **Optional QA / test tasks**
   - Developers often run `dirhash` inside `bitbake k3s -c devshell` to spot-check tricky modules (e.g., ones with `/v2` subdirectories or `+incompatible` semantics).

## Missing Module Detection & Rapid Fix Helpers

When `do_compile` fails with "module lookup disabled by GOPROXY=off" errors, the following helper scripts provide fast iteration without BitBake cycles:

### 1. `check-missing-modules.sh` - Pre-Compilation Validator
Validates the module cache BEFORE compilation to find ALL missing modules at once:

```bash
./check-missing-modules.sh [k3s-workdir]
```

**How it works:**
- Uses `go list -deps ./...` (NO `-e` flag, NO template format) to validate all dependencies
- Captures full stderr with complete error messages including `module@version`
- Extracts unique missing modules with regex pattern
- Outputs to `missing-modules-list.txt` for batch processing
- Much faster than compile-fail iteration (5-10 seconds vs 5-10 minutes)

**Key implementation insight:** The template format `-f '{{.Error}}'` only captures truncated error strings ending in "requires". Using raw stderr gives full error messages like:
```
pkg/agent/run.go:15:2: github.com/raulk/go-watchdog@v1.3.0 requires
	github.com/elastic/gosigar@v0.12.0: module lookup disabled by GOPROXY=off
```

### 2. `batch-fix-missing-modules.sh` - Automated Fix Loop
Automatically discovers and fixes all missing modules in an iterative loop:

```bash
./batch-fix-missing-modules.sh [k3s-workdir]
```

**How it works:**
1. Runs `check-missing-modules.sh` to find missing modules
2. For each `module@version`, runs `fast-fix-module.py --discover`
3. Parses multi-line discover output to extract suggested fix command
4. Executes fix command to synthesize module cache entry
5. Re-checks and repeats until no missing modules (max 50 iterations)
6. Tracks progress with success/failure counts per iteration

**Key implementation insight:** The awk parser handles multi-line commands with backslash continuation by:
- Finding the "✅ Use this commit:" marker
- Collecting the `python3 fast-fix-module.py` command
- Reading continuation lines that start with `--` flags
- Stripping ALL whitespace and backslashes before joining
- Producing a clean single-line command without literal `\` characters

### 3. `fast-fix-module.py` - Rapid Module Synthesizer
Synthesizes individual module cache entries directly in the BitBake workdir without regeneration:

```bash
# New MODULE@VERSION format (2025-10-29)
python3 fast-fix-module.py 'github.com/elastic/gosigar@v0.12.0' --discover

# Apply with discovered repo/commit
python3 fast-fix-module.py github.com/elastic/gosigar v0.12.0 \
    --repo https://github.com/elastic/gosigar \
    --commit 226a3899de055358d2b823c9861975d230225201
```

**Enhancements (2025-10-29):**
- Accepts `MODULE@VERSION` format for easier copy/paste from error messages
- Parses `@` separator to extract module and version automatically
- Validates that version is present (either as separate arg or in MODULE@VERSION)
- `--discover` mode clones repo and runs `git show-ref --tags` to find commits
- Prints suggested fix command for easy execution

**Why this workflow is necessary:**
- BitBake cycles are slow (fetch + unpack + configure + compile = 10-30 minutes)
- Missing modules are often transitive dependencies not visible until late in build
- Rapid synthesis allows fixing 10+ modules in the time it takes for one BitBake cycle
- All fixes are temporary (workdir only) until permanent go.sum updates are applied

## JSON Cache Files

The fetcher maintains four JSON cache files in the `scripts/data/` directory. These are **runtime caches** used by `oe-go-mod-fetcher.py` - they are NOT inherited by recipes but are shared across all recipe generations.

### Cache File Summary

| File | Size (typical) | Purpose | Git Track? |
|------|----------------|---------|------------|
| `data/module-cache.json` | ~500 KB | Main module metadata - VCS info for each module@version | ❌ No |
| `data/vanity-url-cache.json` | ~17 KB | Vanity import path resolution (custom domains → git URLs) | ❌ No |
| `data/ls-remote-cache.json` | ~200 KB | Git ref resolution (caches `git ls-remote` results) | ❌ No |
| `data/verify-cache.json` | ~500 KB | Commit verification status (which commits are fetchable) | ❌ No |
| `data/repo-overrides.json` | ~1 KB | Dynamic overrides from `--set-repo` (temporary/testing) | ❌ No |
| `data/manual-overrides.json` | ~1 KB | Permanent overrides for broken module discovery | ✅ **Yes** |

**Git tracking recommendation:**
```gitignore
scripts/data/*.json
!scripts/data/manual-overrides.json
```

The distinction is **generated vs curated**: all caches except `manual-overrides.json` are machine-generated and can be rebuilt. `manual-overrides.json` contains human knowledge about modules where automatic discovery fails and should be shared across developers/CI.

### 1. Module Metadata Cache (`data/module-cache.json`)

**Purpose:** Primary cache of resolved VCS information for each module@version.

**Key format:** `"module_path|||version"` → metadata object

**Example:**
```json
{
  "github.com/spf13/cobra|||v1.8.1": {
    "commit": "e94f6d0dd9a5e5738dca6bce03c4b1207ffbc0ec",
    "ref": "refs/tags/v1.8.1",
    "subdir": "",
    "timestamp": "2024-06-01T10:31:11Z",
    "vcs_url": "https://github.com/spf13/cobra"
  }
}
```

**Populated by:** Discovery phase walking `GOMODCACHE/.info` files, vanity URL resolution, manual injection.

### 2. Vanity Import Cache (`data/vanity-url-cache.json`)

**Purpose:** Maps Go vanity import paths to actual git repository URLs.

**Key format:** `"import_path"` → git URL or `null` (if not a vanity path)

**Example:**
```json
{
  "cloud.google.com/go": "https://github.com/googleapis/google-cloud-go",
  "golang.org/x/crypto": "https://go.googlesource.com/crypto",
  "k8s.io/api": "https://github.com/kubernetes/api",
  "bitbucket.org/bertimus9/systemstat": null
}
```

**Populated by:** HTTP `?go-get=1` queries to vanity domains, hardcoded mappings for known domains.

### 3. Git Ref Cache (`data/ls-remote-cache.json`)

**Purpose:** Caches `git ls-remote` results to avoid repeated network calls.

**Key format:** `"repo_url|||ref"` → commit hash or `null` (if ref not found)

**Example:**
```json
{
  "https://github.com/spf13/cobra|||refs/tags/v1.8.1": "e94f6d0dd9a5e5738dca6bce03c4b1207ffbc0ec",
  "https://github.com/some/repo|||refs/tags/v0.0.1": null
}
```

**Populated by:** Automatic during ref resolution, especially for pseudo-versions.

### 4. Verification Cache (`data/verify-cache.json`)

**Purpose:** Tracks which repo+commit pairs have been verified as fetchable.

**Key format:** `"repo_url|||commit_hash"` → verification metadata

**Example:**
```json
{
  "https://github.com/spf13/cobra|||e94f6d0dd9a5e5738dca6bce03c4b1207ffbc0ec": {
    "verified": true,
    "fetch_method": "fetch",
    "first_verified": "2025-11-28T21:48:51.687336+00:00",
    "last_checked": "2025-11-28T21:48:51.687336+00:00"
  }
}
```

**Populated by:** Automatic during commit verification, `verify-commit-cache.py` bulk tool, `--inject-commit` flag.

### 5. Repository Overrides (`data/repo-overrides.json`)

**Purpose:** Dynamic overrides created via `--set-repo` for temporary/testing purposes.

**Key format:** `"module_path"` or `"module_path|||version"` → git URL

**Example:**
```json
{
  "example.com/broken-module": "https://github.com/org/actual-repo",
  "example.com/specific|||v1.2.3": "https://github.com/org/version-specific-repo"
}
```

**Populated by:** `--set-repo module_path repo_url` command-line option.

**Note:** These are local/temporary overrides. For permanent fixes, use `manual-overrides.json`.

### 6. Manual Overrides (`data/manual-overrides.json`) ✅ Git-tracked

**Purpose:** Permanent, human-curated overrides for modules where automatic discovery fails.

**Key format:** `"module_path"` or `"module_path@version"` → git URL

**Example:**
```json
{
  "example.com/broken-vanity": "https://github.com/org/actual-repo",
  "example.com/versioned@v1.2.3": "https://github.com/org/specific-version-repo"
}
```

**Populated by:** Manual editing when discovery fails for a module.

**Priority order:** Dynamic (`--set-repo`) > Manual (git-tracked) > Legacy hardcoded

**Workflow for adding permanent overrides:**
1. When discovery fails, identify the correct repository URL
2. Add entry to `scripts/data/manual-overrides.json`
3. Commit to git so fix is shared with other developers/CI

### Cache Architecture Insight

These caches form a resolution pipeline:
1. **Vanity cache** → Resolves `cloud.google.com/go` to `github.com/googleapis/google-cloud-go`
2. **ls-remote cache** → Resolves `refs/tags/v1.8.1` to commit `e94f6d0...`
3. **Module cache** → Stores complete metadata for recipe generation
4. **Verify cache** → Confirms commits are actually fetchable (detects force-pushed tags)

With warm caches, a full k3s regeneration runs in seconds instead of 30+ minutes.

## Directory Structure

The scripts directory has the following cache and data structure:

```
scripts/
├── .cache/
│   └── repos/              # Git repository clone cache (runtime, gitignored)
│                           # Used for commit verification and fallback resolution
│                           # ~11GB when populated, safe to delete (regenerates on demand)
│
├── data/
│   ├── .verify/            # Verification working directory (runtime, gitignored)
│   │                       # Temporary clones for commit verification
│   │                       # ~17GB when populated, safe to delete
│   │
│   ├── module-cache.json       # Module metadata cache (gitignored)
│   ├── vanity-url-cache.json   # Vanity URL resolution cache (gitignored)
│   ├── ls-remote-cache.json    # Git ls-remote cache (gitignored)
│   ├── verify-cache.json       # Commit verification cache (gitignored)
│   └── manual-overrides.json   # Manual repo overrides (TRACKED in git)
│
├── .gitignore              # Ignores all runtime caches
├── oe-go-mod-fetcher.py    # Main generator script
├── extract-discovered-modules.py  # Module extraction helper
└── *.md                    # Documentation
```

**Space requirements:**
- Minimal (no caches): ~2 MB
- With JSON caches only: ~3 MB
- With clone cache (`.cache/repos/`): ~11 GB
- With verify cache (`data/.verify/`): ~17 GB
- Full caches: ~28 GB

All large directories are gitignored and can be safely deleted to reclaim space.
They will regenerate on demand when verification features are used.

## Generated Recipe Files

The generator produces two `.inc` files per recipe:

### `go-mod-git.inc` - Git Fetch Entries

Contains `SRC_URI` entries for each unique repo+commit combination:

```
SRC_URI += "git://github.com/spf13/cobra;protocol=https;nobranch=1;shallow=1;rev=e94f6d0dd9a5e5738dca6bce03c4b1207ffbc0ec;name=git_41456771_1;destsuffix=vcs_cache/2d91d6bc5de..."
SRCREV_git_41456771_1 = "e94f6d0dd9a5e5738dca6bce03c4b1207ffbc0ec"
```

**Key components:**
- `rev=<commit>` - The git commit to fetch (embedded in URL)
- `name=git_XXXX_N` - Unique name for this fetch (repo hash + index)
- `destsuffix=vcs_cache/<hash>` - Where to place the checkout (content-addressed by vcs_hash)
- `SRCREV_<name>` - BitBake variable (currently redundant with embedded rev=)

### `go-mod-cache.inc` - Module Metadata

Contains the bbclass inheritance and module data:

```
inherit go-mod-vcs

GO_MODULE_CACHE_DATA = '[\
{"module":"github.com/spf13/cobra","version":"v1.8.1","vcs_hash":"2d91d6bc...","timestamp":"2024-06-01T10:31:11Z","subdir":"","vcs_ref":"refs/tags/v1.8.1"},\
...]'
```

**Key fields in GO_MODULE_CACHE_DATA:**
- `module` - Go module path (e.g., `github.com/spf13/cobra`)
- `version` - Go module version (e.g., `v1.8.1`)
- `vcs_hash` - Content-addressable hash linking to the git checkout in `vcs_cache/`
- `timestamp` - Commit timestamp (for pseudo-version validation)
- `subdir` - Subdirectory within repo (for monorepos)
- `vcs_ref` - Git ref hint (e.g., `refs/tags/v1.8.1`)

**Note:** The `commit` hash is NOT stored in GO_MODULE_CACHE_DATA. BitBake's fetcher uses `rev=<commit>` embedded in the SRC_URI to check out the correct commit, and the `go-mod-vcs.bbclass` uses `HEAD` to reference it (since HEAD always points to the fetched commit).

## Manual Commit Update Workflow

If you need to manually update a single module's commit (e.g., a security patch or upstream force-push):

### Files to Modify

**Only `go-mod-git.inc`** - Update the `rev=<commit>` in the `SRC_URI` line.

The `go-mod-cache.inc` does NOT contain commit hashes - it uses `vcs_hash` to reference the git checkout location, and the `go-mod-vcs.bbclass` uses `HEAD` to access the fetched commit.

### Example: Updating `github.com/spf13/cobra` from `e94f6d0...` to `abc1234...`

**Step 1:** Find the module in `go-mod-git.inc`:
```bash
grep "spf13/cobra" recipes-containers/k3s/go-mod-git.inc
```

**Step 2:** Update the SRC_URI rev= parameter:
```
# Before:
SRC_URI += "git://github.com/spf13/cobra;...;rev=e94f6d0dd9a5e5738dca6bce03c4b1207ffbc0ec;name=git_41456771_1;..."

# After:
SRC_URI += "git://github.com/spf13/cobra;...;rev=abc1234567890abcdef1234567890abcdef12345;name=git_41456771_1;..."
```

That's it! No other files need to be modified for a commit-only update.

### Important Notes

- The `vcs_hash` in `destsuffix` and `go-mod-cache.inc` should NOT be changed - it links to the checkout location
- If updating to a different version (not just commit), regenerate using `oe-go-mod-fetcher.py`
- Consider updating the fetcher caches (`data/*.json`) if you want the change to persist across regenerations

### Simplified Architecture (2024-12 cleanup)

The architecture has been simplified to eliminate redundancy:
- **Removed:** `SRCREV_<name>` variables (~1565 lines per recipe - unused since `rev=` is embedded in SRC_URI)
- **Removed:** `"commit"` field from `GO_MODULE_CACHE_DATA` JSON (redundant - BitBake's `rev=` already checks out the correct commit, and bbclass uses `HEAD`)

Commits are now stored in exactly one place: the `rev=<commit>` parameter in `SRC_URI`.

## Operational Constraints & Conventions
- Always pass identical `--cache-dir` to every helper (`oe-go-mod-fetcher.py`, `gen-single-module.py`, `verify-commit-cache.py`). Shared state is what keeps discovery, validation, and manual fixes consistent.
- Never assume a commit is reachable just because `git fetch <sha>` once succeeded; re-verify via `check-srcrev.py` or the generator before regenerating includes.
- Document every manual fix by letting `gen-single-module.py` drive the process; avoid hand-editing `.inc` files without updating the caches.
- When a canonical host differs from the GitHub mirror exposed in `go.sum`, prefer the canonical host for overrides (e.g., `gvisor.dev/gvisor` → `https://gvisor.googlesource.com/gvisor`). BitBake trusts `git ls-remote`, and mirrors may hide historical commits.
- Keep the TODO backlog in `AGENTS.md` aligned with architecture changes.

## Summary
1. **Discovery/Validation** with `oe-go-mod-fetcher.py` ensures every module maps to a canonical repo + commit and that each SHA is reachable.  
2. **Recipe Generation** writes `.inc` files and persists metadata so BitBake can replay the module cache deterministically.  
3. **Manual Fix Helpers** provide a quick repair path when upstream repos drop commits or when overrides change.  
4. **BitBake Tasks** (`do_fetch`, `do_create_module_cache`, `do_compile`) consume the includes to build an offline `GOMODCACHE` and produce reproducible Go binaries.  

By following this flow—and enforcing the constraints above—we guarantee that a validated generator run produces `go-mod-*.inc` files that BitBake can build from scratch without ever talking to the internet.
