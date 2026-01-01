# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# vpdmn-initramfs-create_1.0.bb
# ===========================================================================
# MAINTAINER-ONLY RECIPE - Builds QEMU blobs for vpdmn
# ===========================================================================
#
# This recipe packages the boot blobs for vpdmn:
# - A tiny initramfs with just busybox for switch_root
# - The rootfs.img squashfs image with Podman (built via multiconfig)
# - The kernel
#
# The boot flow is:
#   QEMU boots kernel + tiny initramfs
#   -> preinit mounts rootfs.img from /dev/vda
#   -> switch_root into rootfs.img
#   -> vpdmn-init.sh runs with a real root filesystem
#   -> Podman executes container commands
#
# ===========================================================================
# MAINTAINER WORKFLOW
# ===========================================================================
#
# Step 1: Build for aarch64 (multiconfig dependency is automatic):
#   bitbake vpdmn-initramfs-create
#
# Step 2: Copy blobs to layer:
#   cp tmp/deploy/images/qemuarm64/vpdmn-initramfs/Image \
#      meta-virtualization/recipes-containers/vcontainer/files/blobs/vpdmn/aarch64/
#   cp tmp/deploy/images/qemuarm64/vpdmn-initramfs/initramfs.cpio.gz \
#      meta-virtualization/recipes-containers/vcontainer/files/blobs/vpdmn/aarch64/
#   cp tmp/deploy/images/qemuarm64/vpdmn-initramfs/rootfs.img \
#      meta-virtualization/recipes-containers/vcontainer/files/blobs/vpdmn/aarch64/
#
# Step 3: For x86_64:
#   MACHINE=qemux86-64 bitbake vpdmn-initramfs-create
#   # Then copy blobs similarly to files/blobs/vpdmn/x86_64/
#
# ===========================================================================

SUMMARY = "Build QEMU blobs for vpdmn"
DESCRIPTION = "Packages a tiny initramfs for switch_root and bundles the \
               rootfs.img with Podman from multiconfig build for vpdmn."
HOMEPAGE = "https://github.com/anthropics/meta-virtualization"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit deploy

# Only built on demand by maintainer
EXCLUDE_FROM_WORLD = "1"

# Need squashfs-tools-native for unsquashfs to extract files from rootfs.img
DEPENDS = "squashfs-tools-native"

# Always rebuild - no sstate caching for this recipe
# This ensures source file changes (like vpdmn-init.sh in the rootfs) are picked up
SSTATE_SKIP_CREATION = "1"
do_compile[nostamp] = "1"
do_deploy[nostamp] = "1"

# Only populate native sysroot, skip target sysroot to avoid libgcc conflicts
INHIBIT_DEFAULT_DEPS = "1"

# Dependencies:
# 1. The multiconfig rootfs image (vpdmn-rootfs-image from same vruntime-* multiconfig)
# 2. The kernel (from main build, not multiconfig)
#
# Use regular depends for rootfs-image since both recipes are in the same multiconfig
# Use mcdepends for kernel since it's from the main (default) config
do_compile[depends] = "vpdmn-rootfs-image:do_image_complete"
do_compile[mcdepends] = "mc:${VPDMN_MULTICONFIG}::virtual/kernel:do_deploy"

# Use the same preinit as vdkr - it's generic
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
        return 'vruntime-aarch64'
    elif arch in ['x86_64', 'i686', 'i586']:
        return 'vruntime-x86-64'
    return 'vruntime-aarch64'

def get_blob_arch(d):
    """Map TARGET_ARCH to vrunner blob architecture (aarch64 or x86_64)"""
    arch = d.getVar('TARGET_ARCH')
    if arch == 'aarch64':
        return 'aarch64'
    elif arch in ['x86_64', 'i686', 'i586']:
        return 'x86_64'
    return 'aarch64'

KERNEL_IMAGETYPE_INITRAMFS = "${@get_kernel_image_name(d)}"
VPDMN_MULTICONFIG = "${@get_multiconfig_name(d)}"
BLOB_ARCH = "${@get_blob_arch(d)}"

# Path to the multiconfig build output
VPDMN_MC_DEPLOY = "${TOPDIR}/tmp-${VPDMN_MULTICONFIG}/deploy/images/${MACHINE}"

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

    # Extract busybox from the multiconfig rootfs image (squashfs)
    MC_TMPDIR="${TOPDIR}/tmp-${VPDMN_MULTICONFIG}"
    ROOTFS_SRC="${MC_TMPDIR}/deploy/images/${MACHINE}/vpdmn-rootfs-image-${MACHINE}.rootfs.squashfs"

    if [ ! -f "${ROOTFS_SRC}" ]; then
        bbfatal "Rootfs image not found at ${ROOTFS_SRC}. Build it first with: bitbake mc:${VPDMN_MULTICONFIG}:vpdmn-rootfs-image"
    fi

    # Extract busybox from rootfs using unsquashfs
    # In usrmerge layouts, busybox is at usr/bin/busybox
    BUSYBOX_PATH="usr/bin/busybox"
    EXTRACT_DIR="${B}/squashfs-extract"

    bbnote "Extracting busybox from $BUSYBOX_PATH"
    # Try native sysroot first, fall back to system unsquashfs
    UNSQUASHFS="${WORKDIR}/recipe-sysroot-native/usr/bin/unsquashfs"
    if [ ! -x "$UNSQUASHFS" ]; then
        UNSQUASHFS="/usr/bin/unsquashfs"
    fi
    if [ ! -x "$UNSQUASHFS" ]; then
        bbfatal "unsquashfs not found in native sysroot or at /usr/bin/unsquashfs"
    fi
    bbnote "Using unsquashfs: $UNSQUASHFS"

    rm -rf "${EXTRACT_DIR}"
    $UNSQUASHFS -d "${EXTRACT_DIR}" "${ROOTFS_SRC}" "$BUSYBOX_PATH"

    if [ ! -f "${EXTRACT_DIR}/${BUSYBOX_PATH}" ]; then
        bbfatal "Failed to extract busybox from rootfs image"
    fi
    cp "${EXTRACT_DIR}/${BUSYBOX_PATH}" "${INITRAMFS_DIR}/bin/busybox"
    chmod +x ${INITRAMFS_DIR}/bin/busybox

    # Create minimal symlinks
    cd ${INITRAMFS_DIR}/bin
    for cmd in sh mount umount mkdir ls cat echo sleep switch_root reboot; do
        ln -sf busybox $cmd 2>/dev/null || true
    done
    cd -

    # Install preinit script as /init (same as vdkr - it's generic)
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
    # Deploy to vpdmn/<arch> subdirectory so vrunner can find blobs at $BLOB_DIR/$ARCH/
    install -d ${DEPLOYDIR}/vpdmn/${BLOB_ARCH}

    if [ -f ${B}/initramfs.cpio.gz ]; then
        install -m 0644 ${B}/initramfs.cpio.gz ${DEPLOYDIR}/vpdmn/${BLOB_ARCH}/
        bbnote "Deployed initramfs.cpio.gz to vpdmn/${BLOB_ARCH}/"
    fi

    if [ -f ${B}/rootfs.img ]; then
        install -m 0644 ${B}/rootfs.img ${DEPLOYDIR}/vpdmn/${BLOB_ARCH}/
        bbnote "Deployed rootfs.img to vpdmn/${BLOB_ARCH}/"
    fi

    if [ -f ${B}/kernel ]; then
        install -m 0644 ${B}/kernel ${DEPLOYDIR}/vpdmn/${BLOB_ARCH}/${KERNEL_IMAGETYPE_INITRAMFS}
        bbnote "Deployed kernel as vpdmn/${BLOB_ARCH}/${KERNEL_IMAGETYPE_INITRAMFS}"
    fi

    cat > ${DEPLOYDIR}/vpdmn/${BLOB_ARCH}/README << EOF
vpdmn Boot Blobs
==================

Built for: ${TARGET_ARCH}
Machine: ${MACHINE}
Multiconfig: ${VPDMN_MULTICONFIG}
Date: $(date)

Files:
  ${KERNEL_IMAGETYPE_INITRAMFS}  - Kernel image for QEMU
  initramfs.cpio.gz              - Tiny initramfs (switch_root only)
  rootfs.img                     - Root filesystem with Podman tools

Boot flow:
  QEMU boots kernel + initramfs
  -> preinit mounts rootfs.img from /dev/vda
  -> switch_root into rootfs.img
  -> vpdmn-init.sh runs Podman commands

To install into layer:

  # For aarch64:
  mkdir -p meta-virtualization/recipes-containers/vcontainer/files/blobs/vpdmn/aarch64
  cp ${KERNEL_IMAGETYPE_INITRAMFS} initramfs.cpio.gz rootfs.img \\
     meta-virtualization/recipes-containers/vcontainer/files/blobs/vpdmn/aarch64/

  # For x86_64:
  mkdir -p meta-virtualization/recipes-containers/vcontainer/files/blobs/vpdmn/x86_64
  cp ${KERNEL_IMAGETYPE_INITRAMFS} initramfs.cpio.gz rootfs.img \\
     meta-virtualization/recipes-containers/vcontainer/files/blobs/vpdmn/x86_64/
EOF
}

addtask deploy after do_compile before do_build
