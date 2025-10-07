# oe-go-mod-fetcher Quick Start

This guide highlights the most common workflows for `oe-go-mod-fetcher.py`, with a focus on the hybrid (git://) flow that mirrors the BitBake include we ship for NerdCTL and similar recipes.

## Prerequisites
- Go toolchain available on `PATH` (the script runs `go version` to verify).
- Git CLI available.
- Optional but recommended: a writable Go module cache directory that you can reuse across runs (pass via `--gomodcache`).

## Automatic Git Detection
When you run the script from inside a Git working tree and omit `--git-repo`/`--git-ref`, the tool will:
1. Detect the current checkout (remote URL, commit, branch).
2. Offer to use those values for `--git-repo` and `--git-ref`.
3. Respect your answer; choose **Y** to accept or **N** to keep manually supplied values.

This removes the need to copy the repository URL and commit hash into every command while iterating on a recipe.

## Common Workflows

### 1. Generate Hybrid Module Cache Artifacts (in-repo)
```
./oe-go-mod-fetcher.py --use-hybrid \
    --recipedir /path/to/meta-layer/recipes-containers/example \
    --gomodcache /local/cache/go-mod-cache
```

- Uses the current Git checkout for `--git-repo/--git-ref` (prompted automatically).
- Writes `src_uri.inc`, `module_cache_task.inc`, and optional helpers under `--recipedir`.
- Mirrors the BitBake-side `do_create_module_cache`/`do_generate_go_sum` logic so recipe includes stay in sync.

### 2. Regenerate Artifacts for a Remote Repository
```
./oe-go-mod-fetcher.py --use-hybrid \
    --git-repo https://github.com/containerd/nerdctl.git \
    --git-ref 832c4556e0b82789f687b70d1e394b892e035722 \
    --recipedir /path/to/meta-layer/recipes-containers/nerdctl \
    --gomodcache /local/cache/go-mod-cache
```

- Explicitly pins repository and revision when you are not working from an in-tree checkout.
- Reuses the same Go module cache so repeat runs are much faster.

### 3. Generate Reference go.sum.gomodgit (Optional)
```
./oe-go-mod-fetcher.py --use-hybrid --generate-gomodgit \
    --recipedir /path/to/meta-layer/recipes-containers/example
```

- Produces a `go.sum.gomodgit` snapshot alongside the hybrid artifacts.
- Only needed when you want to keep the historical checksum reference; the BitBake flow now calculates Hash1 locally.

## Tips
- Pair hybrid outputs with the staged `go-dirhash-native` recipe so BitBake can compute Hash1 checksums offline.
- Clear `${S}/pkg/mod/cache/download` in the build tree when switching branches or after script upgrades so new zip-filtering rules take effect.
- Keep `module_cache_task.inc` and the script in sync; rerun the fetcher whenever you adjust the include manually.
- Pre-populate the Git cache by cloning modules to `${GOMODCACHE}/repos/<safe-name>` (e.g. `github.com/example/module` → `github.com_example_module`), keeping a normal `.git/` worktree with an `origin` remote so the script can refresh tags and check out commits.
- The generator now caches finished module archives under `${GOMODCACHE}/cache/download` (or `~/.cache/oe-go-mod-fetcher/downloads` when no gomodcache is provided); reruns will reuse the stored `.zip/.mod` pair as long as the commit hash is unchanged.

## Integrating with a Recipe
1. Drop the generated files (`src_uri.inc`, `module_cache_task.inc`, optional `go.sum.gomodgit`) into the recipe directory.
2. In your recipe:
   ```
   inherit go goarch

   SRC_URI = "git://example.org/project.git;branch=main;destsuffix=${GO_SRCURI_DESTSUFFIX}"
   include src_uri.inc
   include module_cache_task.inc
   ```
   - `src_uri.inc` appends all module fetch entries (gomodgit or hybrid git://).
   - `module_cache_task.inc` brings in the custom cache builder, Hash1 go.sum generator, and the `GOMODCACHE`/`GOBUILDFLAGS` exports.
3. Ensure the recipe’s `do_compile` uses `${GOFLAGS}`; the include sets `-mod=mod -modcacherw` and disables the network so builds stay offline.
4. When updating either include, rerun the script so the checked-in file and generator remain aligned.
