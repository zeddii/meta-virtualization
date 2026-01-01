# Container Cross-Install System

Bundle pre-built OCI containers into your Yocto images at build time, enabling offline deployment without network access on first boot.

## Quick Start

### 1. Build the initramfs blobs (one-time per architecture)

```bash
# For ARM64 targets:
MACHINE=qemuarm64 bitbake vdkr-initramfs-create vpdmn-initramfs-create

# For x86_64 targets:
MACHINE=qemux86-64 bitbake vdkr-initramfs-create vpdmn-initramfs-create
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
2. During `do_rootfs`, the bbclass collects containers by runtime (Docker/Podman)
3. Containers are batch-imported into a QEMU VM running vrunner with Docker/Podman
4. A single vrunner session accumulates all containers for each runtime
5. The storage is extracted directly into the rootfs (Docker handles JSON merging internally)

## Architecture

The system uses vrunner.sh with batch-import mode for efficient container processing:

### Recipes

| Recipe | Purpose |
|--------|---------|
| `vdkr-initramfs-create` | Builds kernel + rootfs.img blobs for Docker |
| `vpdmn-initramfs-create` | Builds kernel + rootfs.img blobs for Podman |
| `vdkr-native` | Installs vrunner.sh and Docker blobs to native sysroot |
| `vpdmn-native` | Installs Podman blobs to native sysroot |

### Processing Flow

```
container-cross-install.bbclass
  - Collects containers by runtime
  - Calls vrunner --batch-import for Docker containers
  - Calls vrunner --batch-import for Podman containers
                    |
                    v
vrunner.sh --batch-import
  - Creates combined input disk with all OCI directories
  - Boots QEMU with rootfs.img containing Docker/Podman
  - Runs compound skopeo copy command to import all containers
  - Docker/Podman handles storage JSON internally
  - Exports storage tar via serial console
                    |
                    v
Direct tar extraction to rootfs
  - Docker: /var/lib/docker
  - Podman: /var/lib/containers/storage
```

### Initramfs Contents

The pre-built rootfs.img contains target-architecture binaries:

**Docker (vdkr):**
- docker, dockerd, containerd, containerd-shim-runc-v2
- skopeo, runc
- Core utilities: busybox, iproute2, util-linux

**Podman (vpdmn):**
- podman, skopeo, conmon
- crun, netavark, aardvark-dns
- Core utilities: busybox, iproute2, util-linux
- Libraries: libseccomp, libcap, yajl, ca-certificates

### QEMU Configuration

| Architecture | Machine | CPU | Kernel |
|--------------|---------|-----|--------|
| aarch64 | virt | cortex-a57 | Image |
| x86_64 | q35 | Skylake-Client | bzImage |

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

## Supported Configurations

| Target Architecture | MACHINE | Runtime |
|---------------------|---------|---------|
| ARM64 (aarch64) | qemuarm64 | docker, podman |
| x86_64 | qemux86-64 | docker, podman |

## Troubleshooting

### Build fails with "Blob directory not found"

The initramfs blobs haven't been built yet. Run:

```bash
MACHINE=qemuarm64 bitbake vdkr-initramfs-create vpdmn-initramfs-create
```

### Container not found

Ensure your container recipe:
1. Produces an OCI directory (not just a tar)
2. Is listed as a dependency of your image
3. The name in `BUNDLED_CONTAINERS` matches the directory name in `tmp/deploy/images/`

### "libsystemd.so.0 not found" or similar

The rootfs.img blobs are outdated or missing required libraries. Rebuild them:

```bash
MACHINE=qemuarm64 bitbake vdkr-initramfs-create -c cleansstate
MACHINE=qemuarm64 bitbake vdkr-initramfs-create
```

### "Container import failed"

This error from inside QEMU indicates the container couldn't be processed. Common causes:
1. Missing shared libraries in rootfs.img (rebuild the blobs)
2. Corrupt or empty container OCI directory
3. QEMU CPU incompatibility (the rootfs.img uses target binaries)

Check the build log for specific error messages from skopeo/podman.

## Example: Complete local.conf Setup

```bitbake
# Machine configuration
MACHINE = "qemuarm64"

# Enable multiconfig for blob building
BBMULTICONFIG = "vruntime-aarch64 vruntime-x86-64"

# Include Docker in the image
IMAGE_INSTALL:append = " docker"

# Or for Podman:
# IMAGE_INSTALL:append = " podman"

# Containers to bundle
BUNDLED_CONTAINERS = "my-app-latest-oci:docker"
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
