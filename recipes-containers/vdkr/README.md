# vdkr - Emulated Docker for Cross-Architecture

Execute Docker commands inside a QEMU-emulated target environment.

## Quick Start

```bash
# Build vdkr
bitbake vdkr-native

# Import an OCI container for x86_64
vdkr-x86_64 vimport ./my-container-oci/ myapp:latest

# List images (state persists between runs)
vdkr-x86_64 images

# Export storage for deployment
vdkr-x86_64 --storage /tmp/docker-storage.tar vimport ./container-oci/ myapp:latest

# Clean persistent state
vdkr-x86_64 clean
```

## Architecture-Specific Executables

| Command | Target Architecture |
|---------|---------------------|
| `vdkr-aarch64` | ARM64 |
| `vdkr-x86_64` | x86-64 |

There is no generic `vdkr` command - use the architecture-specific variant.

## Commands

### Docker-Compatible (same syntax as Docker)

| Command | Description |
|---------|-------------|
| `images` | List images |
| `import <tarball> [name:tag]` | Import rootfs tarball |
| `load -i <file>` | Load Docker image archive |
| `save -o <file> <image>` | Save image to archive |
| `tag <source> <target>` | Tag an image |
| `rmi <image>` | Remove an image |

### Extended Commands (vdkr-specific)

| Command | Description |
|---------|-------------|
| `vimport <path> [name:tag]` | Import OCI directory, tarball, or directory (auto-detect) |
| `clean` | Remove persistent state |

## Options

| Option | Description |
|--------|-------------|
| `--stateless` | Don't use persistent state |
| `--storage <file>` | Export Docker storage to tar after command |
| `--state-dir <path>` | Override state directory |
| `-v, --verbose` | Enable verbose output |

## Exporting Images

Two ways to export, for different purposes:

```bash
# Export a single image as Docker archive (portable, can be `docker load`ed)
vdkr-x86_64 save -o /tmp/myapp.tar myapp:latest

# Export entire Docker storage for deployment to target rootfs
vdkr-x86_64 --storage /tmp/docker-storage.tar images
```

| Method | Output | Use case |
|--------|--------|----------|
| `save -o file image:tag` | Docker archive | Share image, load on another Docker |
| `--storage file` | `/var/lib/docker` tar | Deploy to target rootfs |

The `--storage` output extracts to a rootfs like:
```bash
tar -xf docker-storage.tar -C /path/to/rootfs/var/lib/
```

## Persistent State

By default, Docker state persists in `~/.vdkr/<arch>/`. Images imported in one session are available in the next.

```bash
vdkr-x86_64 vimport ./container-oci/ myapp:latest
vdkr-x86_64 images   # Shows myapp:latest

# Later...
vdkr-x86_64 images   # Still shows myapp:latest

# Start fresh
vdkr-x86_64 --stateless images   # Empty

# Clear state
vdkr-x86_64 clean
```

## Standalone Distribution

Create a self-contained redistributable tarball that works without Yocto:

```bash
# Build the standalone tarball
bitbake vdkr-native -c create_tarball

# Output varies by which architecture blobs are available:
#   tmp/deploy/vdkr/vdkr-standalone-x86_64.tar.gz        (~150MB, x86_64 only)
#   tmp/deploy/vdkr/vdkr-standalone-aarch64.tar.gz       (~150MB, aarch64 only)
#   tmp/deploy/vdkr/vdkr-standalone-aarch64-x86_64.tar.gz (~200MB, both)
```

The tarball includes:
- `vdkr-x86_64`, `vdkr-aarch64` - Architecture-specific CLI wrappers (whichever blobs are available)
- `vdkr-run.sh` - QEMU runner
- `vdkr-blobs/` - Kernel and initramfs per architecture
- `qemu/` - QEMU system emulators with wrapper scripts
- `lib/` - Shared libraries for QEMU
- `share/qemu/` - QEMU firmware files (BIOS, etc.)
- `setup-env.sh` - Environment setup script

Usage:
```bash
tar -xzf vdkr-standalone-aarch64-x86_64.tar.gz
cd vdkr-standalone-aarch64-x86_64
source setup-env.sh
vdkr-aarch64 images   # ARM64 containers on x86_64 host
vdkr-x86_64 images    # x86_64 containers
```

The standalone bundle is fully relocatable - works from any directory.

## Development Workflow

For rapid iteration, set `VDKR_USE_DEPLOY = "1"` in local.conf to use blobs directly from DEPLOY_DIR:

```bash
# In local.conf:
VDKR_USE_DEPLOY = "1"

# Build blobs
bitbake vdkr-initramfs-create

# Rebuild vdkr-native
bitbake vdkr-native -c cleansstate && bitbake vdkr-native
```

## Recipes

| Recipe | Purpose |
|--------|---------|
| `vdkr-native_1.0.bb` | Main vdkr CLI and blobs |
| `vdkr-initramfs-create_1.0.bb` | Build initramfs blobs (maintainer use) |

## Files

| File | Purpose |
|------|---------|
| `vdkr.sh` | Main CLI wrapper (becomes vdkr-{arch}) |
| `vdkr-run.sh` | QEMU runner script |
| `vdkr-init.sh` | Init script baked into initramfs |

## Architecture

```
vdkr-x86_64 vimport ./oci myapp:latest
    │
    ▼
vdkr.sh (arch=x86_64 baked in)
    │  - Parse command
    │  - Build runner args
    ▼
vdkr-run.sh
    │  - Create virtio-blk for input data
    │  - Create/reuse state disk (~/.vdkr/x86_64/)
    │  - Boot QEMU with kernel + initramfs
    │  - Encode command in kernel cmdline
    ▼
QEMU VM (x86_64)
    │  - vdkr-init.sh (baked into initramfs)
    │  - Mount state disk as /var/lib/docker
    │  - Start Docker daemon
    │  - Execute command
    │  - Graceful shutdown (sync, unmount)
    ▼
Output / persisted state
```

## Comparison with container-cross-install

| Aspect | container-cross-install | vdkr |
|--------|------------------------|---------|
| Purpose | Bundle containers into Yocto images | Interactive Docker CLI |
| When | Build-time (do_rootfs) | Any time |
| Persistence | None (each build is fresh) | State persists in ~/.vdkr/ |
| Initramfs | container-cross-initramfs | vdkr-initramfs |
| Init script | container-cross-init.sh | vdkr-init.sh |

## Troubleshooting

### "Kernel not found" error

Build the initramfs blobs for your architecture:
```bash
MACHINE=qemux86-64 bitbake vdkr-initramfs-create
# or
MACHINE=qemuarm64 bitbake vdkr-initramfs-create
```

### Docker daemon dies

Check QEMU output with verbose mode:
```bash
vdkr-x86_64 -v images
```

The output is saved to `/tmp/vdkr-*/qemu_output.txt`.

## Future Enhancements (TODO)

The following features could be added to vdkr:

### Interactive Mode
- Use QEMU's `-serial mon:stdio` with proper terminal setup
- Or virtio-console for better terminal emulation
- Detect if stdin is a TTY and enable interactive mode automatically

### Stdin Support
- Pass input via virtio-blk device (like container data)
- Or use virtio-vsock for bidirectional communication
- Or pipe through serial with proper escaping

### Networking
- Enable QEMU user-mode networking (`-netdev user`) for outbound access
- Would unlock `docker pull` from registries
- Port forwarding for exposed container ports

### Performance
- KVM acceleration when host/target architectures match
- Multi-threaded TCG (`-accel tcg,thread=multi`) for cross-arch
- Larger memory allocation for better caching

## See Also

- `CLAUDE.md` in the layer root for detailed architecture documentation
- `container-cross-install` for bundling containers into Yocto images at build time
