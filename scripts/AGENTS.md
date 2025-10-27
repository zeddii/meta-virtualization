# Go Module Fetcher for Yocto/BitBake – Agent Handoff

This document captures the state of the Go module fetcher rewrite as of 2025‑10‑22 and is intended for agents picking up the work.

## Mission & Objectives
- Deliver reproducible, fully offline Go builds inside BitBake.
- Source every module from auditable git repos while matching Go’s cache layout byte-for-byte.
- Integrate cleanly with existing Yocto tooling so recipes can mix `git://` and `gomod://` sources.

## Current Architecture Snapshot
- **Hybrid workflow (v3.0.0)** – `oe-go-mod-fetcher.py` still handles discovery → recipe generation → BitBake cache build. Discovery leans on `go mod download` when possible and falls back to `go.sum` for anything Go expects at build time.
- **Helper loop** – `scripts/fix-go-module.py` rebuilds individual modules inside `${WORKDIR}`, writes deterministic zip/mod/info files, and now also feeds the generator’s metadata cache with the commit/timestamp/subdir it just used.
- **Checksums** – `go-dirhash-native` remains the single source of `h1:` hashes; the BitBake task rewrites go.sum accordingly so git:// and gomod:// entries happily co-exist.
- **Archive fidelity** – Cache creation still stages repos in `${WORKDIR}`, strips vendored modules, normalises timestamps/perms, and synthesises `go.mod` for `+incompatible` releases.
- **Verification path** – The helper prints repo/commit + old/new hashes so we can see whether a module changed before re-running `bitbake -f -c compile k3s`.

### Key Files
- `meta-virtualization/scripts/oe-go-mod-fetcher.py` – generator CLI (current version header: 3.0.0).
- `meta-virtualization/recipes-containers/k3s/go-mod-cache.inc` – main BitBake task embedding the logic above.
- `meta-virtualization/recipes-containers/k3s/go-mod-git.inc` – git SRC_URI entries (regenerated alongside cache.inc).

## Recent Changes (since CLAUDE.md)
- Swapped the placeholder `.ziphash` implementation for native `dirhash` calls.
- Reworked cache builders to stage repos in temp dirs, strip vendor content, and preserve upstream `go.mod`.
- Ensured the BitBake task and generator share identical logic (no alias rewriting, same filters).
- Regenerated k3s includes so every module now requests canonical archives; kri-tools checksum mismatch is gone.
- Verified upstream proxy archive to confirm we now match Go’s view of cri-tools exactly.

## Completed TODO Items
- [x] Filter go.sum `/go.mod` entries out of both the generator and BitBake to eliminate the `go.mod.info` failure.
- [x] Add a persistent `git ls-remote` cache (`.oe-go-mod-fetcher.ls-remote-cache.json`) so repeat generations reuse commit lookups.
- [x] Preserve LICENSE detection hooks while staging exports under `${WORKDIR}` rather than `/tmp`.
- [x] Ensure dirhash-based checksum generation feeds both `.ziphash` files and go.sum regeneration.
- [x] Seed the generator with a reusable module metadata cache so legacy modules (e.g., `github.com/JeffAshton/win_pdh`) are emitted without manual overrides.
- [x] **Multiple versions (1:N)** – Generator now keeps all `(module, version)` pairs from go.sum using Sets (was never actually broken)
- [x] **gopkg.in mapping** – Added conventional mapping rules for gopkg.in vanity URLs in `resolve_module_metadata()`
- [x] **+incompatible handling** – Always synthesize go.mod for +incompatible versions regardless of repo contents
- [x] **Include /go.mod entries** – Modified `parse_go_sum()` to strip suffix and include indirect-only dependencies
- [x] **Short commit validation** – Multi-point validation to reject 12-char pseudo-version commits, cleaned 300 stale cache entries
- [x] **Version suffix stripping** – Strip `/vNN` from derived subdirs to fix apache/arrow and 26 other modules

## Current Status (as of 2025-10-26)

### What Works Now
- ✅ Hybrid discovery with `go mod download` + filesystem walk
- ✅ Git-based fetching with full 40-character SRCREVs (537 unique repos)
- ✅ gopkg.in vanity URL resolution with conventional mapping
- ✅ +incompatible versions with synthetic go.mod
- ✅ /go.mod-only entries (indirect dependencies) from go.sum
- ✅ Short commit hash rejection (755 indirect-only deps properly skipped)
- ✅ Version suffix stripping from subdirs (apache/arrow, kingpin/v2, etc.)
- ✅ Persistent caches for git ls-remote and module metadata
- ✅ Multiple versions of same module (Sets prevent collapse)

### Known Issues & Limitations
- **Cache poisoning** – Metadata cache can reload bad data from old .inc files during bootstrap
  - Workaround: Manual cache cleaning when derivation logic changes
  - TODO: Add `--clean-cache` flag and validation during bootstrap

- **Cache location** – Cache files stored in scripts/ directory (may be read-only in CI)
  - TODO: Add `--cache-dir` option to store alongside GOMODCACHE

- **Subdir detection** – Current fix strips all trailing `/vNN`, may need refinement for actual `/v2` subdirectories
  - TODO: Validate subdirs exist in repository using git ls-tree

- **Permissions** – fix-go-module.py helper requires `chmod -R u+w ${S}/pkg/mod/cache` in sandboxed environments

## Immediate Next Steps
1. **Persist helper results** – Modify `fix-go-module.py` to update `.oe-go-mod-fetcher.module-cache.json` every time it rebuilds a module (commit, timestamp, subdir, remote URL). Re-run the helper for the modules we already fixed so the cache captures them.
2. **Regenerate + rebuild** – After the metadata cache learns those entries, rerun `oe-go-mod-fetcher.py` and `bitbake -f -c compile k3s` until no GOPROXY lookups remain.
3. **Multiple versions** – Teach the generator to keep every `(module, version)` pair from `go.sum` instead of collapsing to a single entry per module.
4. **gopkg.in mapping** – Add generic mapping for gopkg.in paths (e.g., read the repo’s origin URL or derive it from helper metadata) so discovery does not depend on manual overrides.
5. **Permissions** – Document the requirement to `chmod -R u+w ${S}/pkg/mod/cache` before running the helper in sandboxed environments.
6. **Docs cleanup** – Capture the helper workflow (commands, expected hash output, metadata update) so future agents repeat the discovery loop without guesswork.

## Suggested Work Rhythm
- Use `oe-go-mod-fetcher.py --recipedir … --source-dir …` to regenerate includes whenever module metadata changes.
- After regeneration, spot-check tricky modules (v2/v3 suffixes, `+incompatible`, repos with vendor bundles) by running the staged `dirhash` helper:
  ```
  bitbake k3s -c devshell
  dirhash ${S}/pkg/mod/cache/download/<module>/@v/<version>.zip
  ```
- Keep exports of upstream proxy archives when diagnosing mismatches—they are the source of truth for `go.sum`.
- Clear or edit `.oe-go-mod-fetcher.ls-remote-cache.json` if upstream refs change; the generator now reuses it between runs.

## Contact Points
- Lock files during BitBake: `/opt/bruce/poky-go-mod-update/build/bitbake.lock`
- Staged helper: `${STAGING_BINDIR_NATIVE}/dirhash`
- Temporary module cache during discovery: `/tmp/go-discover-*` (auto-cleaned by generator)
- Persistent ls-remote cache: `meta-virtualization/scripts/.oe-go-mod-fetcher.ls-remote-cache.json`

## Architectural & Design Guardrails
- **Sandbox friendly** – All temporary work happens under `${WORKDIR}` (BitBake requirement). No writes to global `/tmp`.
- **Offline guarantee** – GOPROXY remains disabled. Every module must be retrieved from a git repository under BitBake’s control; regressions show up as `module lookup disabled by GOPROXY=off`.
- **Checksum parity** – `dirhash` is the single source of truth for zip hashes; go.sum entries must match the artifacts we create.
- **Mixed sources** – Recipes may combine `git://` and `gomod://` entries; regenerated go.sum therefore merges new git-based hashes with existing gomod entries instead of replacing the whole file.
- **Major-version handling** – Module paths with `/vN`, nested subdirectories (e.g., `client/v3`), and incompatible versions must all locate the real go.mod before falling back to a synthetic one.
- **BitBake Python** – BitBake’s parser can’t handle `typing` imports or annotations; all Python embedded in `.inc` files must remain plain, untyped syntax.

This summary should equip the next agent to continue the modernization without re-discovering earlier pitfalls.
