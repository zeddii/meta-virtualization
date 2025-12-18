# vdkr-rootfs-image.bb
# Minimal Docker-capable image for vdkr QEMU environment
#
# This image is built via multiconfig and used by vdkr-initramfs-create
# to provide a proper rootfs for running Docker in QEMU.
#
# Build with:
#   bitbake mc:vdkr-aarch64:vdkr-rootfs-image
#   bitbake mc:vdkr-x86-64:vdkr-rootfs-image

SUMMARY = "Minimal Docker rootfs for vdkr"
DESCRIPTION = "A minimal image containing Docker tools for use with vdkr. \
               This image runs inside QEMU to provide Docker command execution."

LICENSE = "MIT"

# Inherit from core-image-minimal for a minimal base
inherit core-image

# We need Docker and container tools
IMAGE_INSTALL = " \
    packagegroup-core-boot \
    docker-moby \
    containerd \
    runc \
    skopeo \
    busybox \
"

# No extra features needed
IMAGE_FEATURES = ""

# Keep the image small
IMAGE_ROOTFS_SIZE = "524288"
IMAGE_ROOTFS_EXTRA_SPACE = "0"

# We only need ext4
IMAGE_FSTYPES = "ext4"

# Install our init script
ROOTFS_POSTPROCESS_COMMAND += "install_vdkr_init;"

install_vdkr_init() {
    # Install vdkr-init.sh as /init
    install -m 0755 ${THISDIR}/files/vdkr-init.sh ${IMAGE_ROOTFS}/init

    # Create required directories
    install -d ${IMAGE_ROOTFS}/mnt/input
    install -d ${IMAGE_ROOTFS}/mnt/state
    install -d ${IMAGE_ROOTFS}/var/lib/docker
    install -d ${IMAGE_ROOTFS}/run/containerd

    # Create skopeo policy
    install -d ${IMAGE_ROOTFS}/etc/containers
    echo '{"default":[{"type":"insecureAcceptAnything"}]}' > ${IMAGE_ROOTFS}/etc/containers/policy.json
}
