# Container Cross-Install System

Bundle pre-built OCI containers into your Yocto images at build time, enabling offline deployment without network access on first boot.

## Quick Start

### 1. Build the initramfs blobs (one-time per architecture)

```bash
# For ARM64 targets:
MACHINE=qemuarm64 bitbake container-cross-initramfs-build

# For x86_64 targets:
MACHINE=qemux86-64 bitbake container-cross-initramfs-build
```

### 2. Configure your image

Add to `conf/local.conf`:

```bitbake
# Containers to bundle (format: container-name-oci:runtime)
# runtime is 'docker' or 'podman'
BUNDLED_CONTAINERS = "my-app-latest-oci:docker"

# For multiple containers:
BUNDLED_CONTAINERS = "my-app-latest-oci:docker my-service-latest-oci:podman"
```

Or add directly to your image recipe:

```bitbake
inherit container-cross-install

BUNDLED_CONTAINERS = "my-app-latest-oci:docker"
```

### 3. Build your image

```bash
bitbake my-image
```

### 4. Verify

```bash
runqemu qemuarm64 nographic slirp qemuparams="-m 2048" my-image ext4

# On target:
docker images    # for Docker containers
podman images    # for Podman containers
```

## How It Works

1. Your container recipes produce OCI images in `tmp/deploy/images/${MACHINE}/`
2. During `do_rootfs`, the bbclass processes each container in `BUNDLED_CONTAINERS`
3. A QEMU VM boots with a minimal initramfs containing Docker/Podman tools
4. The container is imported into the runtime's storage format
5. The storage is extracted and merged into your image's rootfs

## Architecture

The system consists of several components:

### Recipes

| Recipe | Purpose |
|--------|---------|
| `container-cross-initramfs-build` | Builds kernel + initramfs blobs for QEMU |
| `container-cross-initramfs-native` | Installs all available blobs into native sysroot |
| `container-cross-tools-native` | Provides processing scripts |

**Note:** The native recipe installs blobs for ALL available architectures (aarch64 and x86_64), not just the current target. This allows building images for different targets without rebuilding the native recipe.

### Processing Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ container-cross-install.bbclass                                 │
│   - Invokes container-cross-deploy.sh for each container        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ container-cross-deploy.sh                                       │
│   - Routes to podman-storage-creator.sh or docker-storage-*     │
│   - Then calls merger script to install storage                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ podman-storage-creator.sh (for Podman)                          │
│   1. Try Skopeo fast path (native skopeo)                       │
│   2. If fails, use QEMU + pre-built initramfs                   │
│      - Creates virtio-blk disk with container                   │
│      - Boots QEMU with initramfs                                │
│      - container-cross-init.sh runs inside QEMU                 │
│      - Storage extracted via base64 over serial console         │
└─────────────────────────────────────────────────────────────────┘
```

### Initramfs Contents

The pre-built initramfs contains target-architecture binaries:

- **Container tools**: podman, skopeo, conmon, docker, dockerd, containerd
- **OCI runtimes**: crun, runc
- **Core utilities**: busybox
- **Libraries**: glibc, libseccomp, libcap, yajl, libsystemd, gpgme, libassuan, libgpg-error

### QEMU Configuration

| Architecture | Machine | CPU | Kernel |
|--------------|---------|-----|--------|
| aarch64 | virt | cortex-a57 | Image |
| x86_64 | q35 | Skylake-Client | bzImage |

These match the oe-core QEMU machine definitions for `qemuarm64` and `qemux86-64`.

## Container Sources

Containers must be in OCI directory format in `${DEPLOY_DIR_IMAGE}`:

```
tmp/deploy/images/qemuarm64/
├── my-app-latest-oci/
│   ├── index.json
│   ├── oci-layout
│   └── blobs/
└── my-service-latest-oci/
    └── ...
```

These are typically produced by recipes using `skopeo copy` to export containers.

## Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `BUNDLED_CONTAINERS` | "" | Space-separated list of `container-oci:runtime` |
| `CONTAINER_CROSS_USE_DEPLOY` | "0" | Set to "1" to use blobs from DEPLOY_DIR instead of layer |

## Supported Configurations

| Target Architecture | MACHINE | Runtime |
|---------------------|---------|---------|
| ARM64 (aarch64) | qemuarm64 | docker, podman |
| x86_64 | qemux86-64 | docker, podman |

## Troubleshooting

### Build fails with "MISSING BLOB"

The initramfs blobs haven't been built yet. Run:

```bash
MACHINE=qemuarm64 bitbake container-cross-initramfs-build
```

### Container not found

Ensure your container recipe:
1. Produces an OCI directory (not just a tar)
2. Is listed as a dependency of your image
3. The name in `BUNDLED_CONTAINERS` matches the directory name in `tmp/deploy/images/`

### "libsystemd.so.0 not found" or "libgpgme.so.45 not found"

The initramfs blobs are outdated or missing required libraries. Rebuild them:

```bash
MACHINE=qemuarm64 bitbake container-cross-initramfs-build -c cleansstate
MACHINE=qemuarm64 bitbake container-cross-initramfs-build
```

### "Container import failed - no storage to export"

This error from inside QEMU indicates the container couldn't be processed. Common causes:
1. Missing shared libraries in initramfs (rebuild the blobs)
2. Corrupt or empty container OCI directory
3. QEMU CPU incompatibility (the initramfs uses target binaries)

Check the build log for specific error messages from skopeo/podman.

### x86_64 builds show empty `podman images`

Ensure you rebuilt the x86_64 initramfs blobs after any changes:

```bash
MACHINE=qemux86-64 bitbake container-cross-initramfs-build -c cleansstate
MACHINE=qemux86-64 bitbake container-cross-initramfs-build
bitbake container-cross-initramfs-native -c cleansstate
bitbake my-image -c cleansstate
bitbake my-image
```

The x86_64 blobs use `-M q35 -cpu Skylake-Client` to match the qemux86-64 machine configuration.

## Development Workflow

For iterating on the initramfs without copying blobs each time:

```bash
# Add to local.conf:
CONTAINER_CROSS_USE_DEPLOY = "1"

# Rebuild initramfs and test:
MACHINE=qemuarm64 bitbake container-cross-initramfs-build
bitbake my-image -C rootfs
```

A warning banner reminds you to remove the variable when done.

## Example: Complete local.conf Setup

```bitbake
# Machine configuration
MACHINE = "qemuarm64"

# Include Docker in the image
IMAGE_INSTALL:append = " docker"

# Or for Podman:
# IMAGE_INSTALL:append = " podman"

# Containers to bundle
BUNDLED_CONTAINERS = "my-app-latest-oci:docker"

# Optional: Use blobs from DEPLOY_DIR during development
# CONTAINER_CROSS_USE_DEPLOY = "1"
```

## Example: Image Recipe

```bitbake
# my-container-image.bb
SUMMARY = "Image with pre-bundled containers"

inherit core-image
inherit container-cross-install

IMAGE_INSTALL = "packagegroup-core-boot docker"

# Containers to bundle
BUNDLED_CONTAINERS = "my-app-latest-oci:docker"

# Ensure container is built before image
do_rootfs[depends] += "my-app-container:do_deploy"
```
