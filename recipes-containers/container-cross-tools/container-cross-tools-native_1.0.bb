# container-cross-tools-native_1.0.bb
# Cross-architecture container deployment tools
#
# These scripts enable deploying Docker and Podman containers from x86_64
# build hosts to ARM64/x86_64 targets using QEMU for container processing.
#
# The scripts work around Yocto's pseudo environment by running container
# tools inside QEMU where pseudo doesn't exist.

SUMMARY = "Cross-architecture container deployment tools"
DESCRIPTION = "Scripts for deploying containers from x86_64 build hosts \
               to ARM64/x86_64 targets using QEMU"
HOMEPAGE = "https://github.com/anthropics/meta-virtualization"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit native

# Scripts only - blobs come from container-cross-initramfs-native
SRC_URI = "\
    file://container-cross-deploy.sh \
    file://podman-storage-creator.sh \
    file://podman-storage-merger.sh \
    file://docker-storage-creator-blk.sh \
    file://standalone-container-storage-merger.sh \
    file://container-cross-init-docker-blk.sh \
"

# Depends on QEMU for running container tools
# coreutils-native provides 'timeout' command used by the scripts
DEPENDS = "qemu-system-native coreutils-native"

# Source directory where bitbake unpacks file:// URIs (UNPACKDIR = ${WORKDIR}/sources)
S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${bindir}

    # Main deployment interface
    install -m 0755 ${S}/container-cross-deploy.sh ${D}${bindir}/

    # Podman path scripts
    install -m 0755 ${S}/podman-storage-creator.sh ${D}${bindir}/
    install -m 0755 ${S}/podman-storage-merger.sh ${D}${bindir}/

    # Docker path scripts
    install -m 0755 ${S}/docker-storage-creator-blk.sh ${D}${bindir}/
    install -m 0755 ${S}/standalone-container-storage-merger.sh ${D}${bindir}/
    install -m 0755 ${S}/container-cross-init-docker-blk.sh ${D}${bindir}/

    # Create symlink for backward compatibility (flexible-container-merger.sh)
    ln -sf standalone-container-storage-merger.sh ${D}${bindir}/flexible-container-merger.sh
}

# Ensure scripts are available in native sysroot
SYSROOT_DIRS += "${bindir}"
