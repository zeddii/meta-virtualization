# vdkr-initramfs-create_1.0.bb
# ===========================================================================
# MAINTAINER-ONLY RECIPE - Builds QEMU blobs for vdkr
# ===========================================================================
#
# This recipe packages the boot blobs for vdkr:
# - A tiny initramfs with just busybox for switch_root
# - The rootfs.img ext4 image (built via multiconfig)
# - The kernel
#
# The boot flow is:
#   QEMU boots kernel + tiny initramfs
#   -> preinit mounts rootfs.img from /dev/vda
#   -> switch_root into rootfs.img
#   -> vdkr-init.sh runs with a real root filesystem
#   -> Docker can use pivot_root properly
#
# ===========================================================================
# MAINTAINER WORKFLOW
# ===========================================================================
#
# Step 1: Build for aarch64 (multiconfig dependency is automatic):
#   bitbake vdkr-initramfs-create
#
# Step 2: Copy blobs to layer:
#   cp tmp/deploy/images/qemuarm64/vdkr-initramfs/Image \
#      meta-virtualization/recipes-containers/vdkr/files/blobs/aarch64/
#   cp tmp/deploy/images/qemuarm64/vdkr-initramfs/initramfs.cpio.gz \
#      meta-virtualization/recipes-containers/vdkr/files/blobs/aarch64/
#   cp tmp/deploy/images/qemuarm64/vdkr-initramfs/rootfs.img \
#      meta-virtualization/recipes-containers/vdkr/files/blobs/aarch64/
#
# Step 3: For x86_64:
#   MACHINE=qemux86-64 bitbake vdkr-initramfs-create
#   # Then copy blobs similarly to files/blobs/x86_64/
#
# ===========================================================================

SUMMARY = "Build QEMU blobs for vdkr"
DESCRIPTION = "Packages a tiny initramfs for switch_root and bundles the \
               rootfs.img from multiconfig build for vdkr."
HOMEPAGE = "https://github.com/anthropics/meta-virtualization"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit deploy

# Only built on demand by maintainer
EXCLUDE_FROM_WORLD = "1"

# Need e2fsprogs-native for debugfs to extract files from rootfs.img
DEPENDS = "e2fsprogs-native"

# Only populate native sysroot, skip target sysroot to avoid libgcc conflicts
INHIBIT_DEFAULT_DEPS = "1"

# Dependencies:
# 1. The multiconfig rootfs image (vdkr-rootfs-image from eruntime-* multiconfig)
# 2. The kernel (from main build, not multiconfig)
#
# Use mcdepends to automatically trigger multiconfig build
do_compile[mcdepends] = "mc::${VDKR_MULTICONFIG}:vdkr-rootfs-image:do_image_complete"
do_compile[depends] = "virtual/kernel:do_deploy"

SRC_URI = "file://vdkr-preinit.sh"

S = "${UNPACKDIR}"
B = "${WORKDIR}/build"

def get_kernel_image_name(d):
    arch = d.getVar('TARGET_ARCH')
    if arch == 'aarch64':
        return 'Image'
    elif arch in ['x86_64', 'i686', 'i586']:
        return 'bzImage'
    elif arch == 'arm':
        return 'zImage'
    return 'Image'

def get_multiconfig_name(d):
    arch = d.getVar('TARGET_ARCH')
    if arch == 'aarch64':
        return 'eruntime-aarch64'
    elif arch in ['x86_64', 'i686', 'i586']:
        return 'eruntime-x86-64'
    return 'eruntime-aarch64'

KERNEL_IMAGETYPE_INITRAMFS = "${@get_kernel_image_name(d)}"
VDKR_MULTICONFIG = "${@get_multiconfig_name(d)}"

# Path to the multiconfig build output
VDKR_MC_DEPLOY = "${TOPDIR}/tmp-${VDKR_MULTICONFIG}/deploy/images/${MACHINE}"

do_compile() {
    mkdir -p ${B}

    # =========================================================================
    # PART 1: BUILD TINY INITRAMFS (just for switch_root)
    # =========================================================================
    INITRAMFS_DIR="${B}/initramfs"
    rm -rf ${INITRAMFS_DIR}
    mkdir -p ${INITRAMFS_DIR}/bin
    mkdir -p ${INITRAMFS_DIR}/proc
    mkdir -p ${INITRAMFS_DIR}/sys
    mkdir -p ${INITRAMFS_DIR}/dev
    mkdir -p ${INITRAMFS_DIR}/mnt/root

    bbnote "Building tiny initramfs for switch_root..."

    # Extract busybox from the multiconfig rootfs image
    MC_TMPDIR="${TOPDIR}/tmp-${VDKR_MULTICONFIG}"
    ROOTFS_SRC="${MC_TMPDIR}/deploy/images/${MACHINE}/vdkr-rootfs-image-${MACHINE}.rootfs.ext4"

    if [ ! -f "${ROOTFS_SRC}" ]; then
        bbfatal "Rootfs image not found at ${ROOTFS_SRC}. Build it first with: bitbake mc:${VDKR_MULTICONFIG}:vdkr-rootfs-image"
    fi

    # Mount the rootfs and extract busybox
    MOUNT_DIR="${B}/rootfs-mount"
    mkdir -p ${MOUNT_DIR}

    # Extract busybox from rootfs using debugfs
    # In usrmerge layouts, busybox is at usr/bin/busybox
    BUSYBOX_PATH="usr/bin/busybox"

    bbnote "Extracting busybox from $BUSYBOX_PATH"
    # Try native sysroot first, fall back to system debugfs
    DEBUGFS="${WORKDIR}/recipe-sysroot-native/usr/sbin/debugfs"
    if [ ! -x "$DEBUGFS" ]; then
        DEBUGFS="/usr/sbin/debugfs"
    fi
    if [ ! -x "$DEBUGFS" ]; then
        bbfatal "debugfs not found in native sysroot or at /usr/sbin/debugfs. Install e2fsprogs on the host."
    fi
    bbnote "Using debugfs: $DEBUGFS"
    $DEBUGFS -R "dump $BUSYBOX_PATH ${INITRAMFS_DIR}/bin/busybox" "${ROOTFS_SRC}" 2>&1

    if [ ! -f "${INITRAMFS_DIR}/bin/busybox" ]; then
        bbfatal "Failed to extract busybox from rootfs image"
    fi
    chmod +x ${INITRAMFS_DIR}/bin/busybox

    # Create minimal symlinks
    cd ${INITRAMFS_DIR}/bin
    for cmd in sh mount umount mkdir ls cat echo sleep switch_root reboot; do
        ln -sf busybox $cmd 2>/dev/null || true
    done
    cd -

    # Install preinit script as /init
    cp ${S}/vdkr-preinit.sh ${INITRAMFS_DIR}/init
    chmod +x ${INITRAMFS_DIR}/init

    # Create tiny initramfs cpio
    bbnote "Creating tiny initramfs cpio archive..."
    cd ${INITRAMFS_DIR}
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > ${B}/initramfs.cpio.gz
    cd -

    INITRAMFS_SIZE=$(stat -c%s ${B}/initramfs.cpio.gz)
    bbnote "Tiny initramfs created: ${INITRAMFS_SIZE} bytes ($(expr ${INITRAMFS_SIZE} / 1024)KB)"

    # =========================================================================
    # PART 2: COPY ROOTFS FROM MULTICONFIG BUILD
    # =========================================================================
    bbnote "Looking for multiconfig rootfs at: ${MC_TMPDIR}/deploy/images/${MACHINE}"

    # ROOTFS_SRC already set above when extracting busybox
    cp "${ROOTFS_SRC}" ${B}/rootfs.img
    ROOTFS_SIZE=$(stat -c%s ${B}/rootfs.img)
    bbnote "Rootfs image copied: ${ROOTFS_SIZE} bytes ($(expr ${ROOTFS_SIZE} / 1024 / 1024)MB)"

    # =========================================================================
    # PART 3: COPY KERNEL
    # =========================================================================
    bbnote "Copying kernel image..."
    KERNEL_FILE="${DEPLOY_DIR_IMAGE}/${KERNEL_IMAGETYPE_INITRAMFS}"
    if [ -f "${KERNEL_FILE}" ]; then
        cp "${KERNEL_FILE}" ${B}/kernel
        KERNEL_SIZE=$(stat -c%s ${B}/kernel)
        bbnote "Kernel copied: ${KERNEL_SIZE} bytes ($(expr ${KERNEL_SIZE} / 1024 / 1024)MB)"
    else
        bbwarn "Kernel not found at ${KERNEL_FILE}"
    fi
}

do_install[noexec] = "1"
do_package[noexec] = "1"
do_packagedata[noexec] = "1"
do_package_write_rpm[noexec] = "1"
do_package_write_ipk[noexec] = "1"
do_package_write_deb[noexec] = "1"
do_populate_sysroot[noexec] = "1"

do_deploy() {
    install -d ${DEPLOYDIR}/vdkr-initramfs

    if [ -f ${B}/initramfs.cpio.gz ]; then
        install -m 0644 ${B}/initramfs.cpio.gz ${DEPLOYDIR}/vdkr-initramfs/
        bbnote "Deployed initramfs.cpio.gz"
    fi

    if [ -f ${B}/rootfs.img ]; then
        install -m 0644 ${B}/rootfs.img ${DEPLOYDIR}/vdkr-initramfs/
        bbnote "Deployed rootfs.img"
    fi

    if [ -f ${B}/kernel ]; then
        install -m 0644 ${B}/kernel ${DEPLOYDIR}/vdkr-initramfs/${KERNEL_IMAGETYPE_INITRAMFS}
        bbnote "Deployed kernel as ${KERNEL_IMAGETYPE_INITRAMFS}"
    fi

    cat > ${DEPLOYDIR}/vdkr-initramfs/README << EOF
vdkr Boot Blobs
==================

Built for: ${TARGET_ARCH}
Machine: ${MACHINE}
Multiconfig: ${VDKR_MULTICONFIG}
Date: $(date)

Files:
  ${KERNEL_IMAGETYPE_INITRAMFS}  - Kernel image for QEMU
  initramfs.cpio.gz              - Tiny initramfs (switch_root only)
  rootfs.img                     - Root filesystem with Docker tools

Boot flow:
  QEMU boots kernel + initramfs
  -> preinit mounts rootfs.img from /dev/vda
  -> switch_root into rootfs.img
  -> vdkr-init.sh runs Docker commands

To install into layer:

  # For aarch64:
  mkdir -p meta-virtualization/recipes-containers/vdkr/files/blobs/aarch64
  cp ${KERNEL_IMAGETYPE_INITRAMFS} initramfs.cpio.gz rootfs.img \\
     meta-virtualization/recipes-containers/vdkr/files/blobs/aarch64/

  # For x86_64:
  mkdir -p meta-virtualization/recipes-containers/vdkr/files/blobs/x86_64
  cp ${KERNEL_IMAGETYPE_INITRAMFS} initramfs.cpio.gz rootfs.img \\
     meta-virtualization/recipes-containers/vdkr/files/blobs/x86_64/
EOF
}

addtask deploy after do_compile before do_build

do_compile[depends] += "virtual/kernel:do_deploy"
