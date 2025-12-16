# container-cross-initramfs-native_1.0.bb
# ===========================================================================
# Pre-built QEMU blobs for container cross-install
# ===========================================================================
#
# This recipe installs kernel and initramfs blobs used by container-cross-tools
# to process containers in QEMU. Blobs are architecture-specific and OPTIONAL
# in the layer - users can build them on demand.
#
# BLOB SOURCES (checked in priority order):
#
#   1. Layer files (if checked in by maintainer):
#      files/aarch64/Image, files/aarch64/initramfs.cpio.gz
#      files/x86_64/bzImage, files/x86_64/initramfs.cpio.gz
#
#   2. AUTOMATIC FALLBACK - User-built blobs in DEPLOY_DIR:
#      ${DEPLOY_DIR_IMAGE}/container-cross-initramfs/
#      (built by container-cross-initramfs-build recipe)
#
# Blobs are NOT in SRC_URI - they are checked at install time from either
# the layer files directory or DEPLOY_DIR. This allows the recipe to parse
# even when blobs haven't been built/checked-in yet.
#
# If blobs are missing, build them with:
#
#   MACHINE=qemuarm64 bitbake container-cross-initramfs-build
#   # or for x86_64:
#   MACHINE=qemux86-64 bitbake container-cross-initramfs-build
#
# The blobs from tmp/deploy/images/${MACHINE}/container-cross-initramfs/
# will be automatically used.
#
# ===========================================================================

SUMMARY = "Pre-built QEMU blobs for container cross-install"
DESCRIPTION = "Generic kernel and unified initramfs for ARM64/x86_64 \
               container processing in QEMU. These blobs enable cross-architecture \
               container deployment without requiring MACHINE-specific kernels."
HOMEPAGE = "https://github.com/anthropics/meta-virtualization"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit native

# Only the init script is in SRC_URI - blob files are OPTIONAL and checked
# directly from the layer files directory or DEPLOY_DIR in do_install.
# This allows the recipe to parse even when blobs haven't been built yet.
SRC_URI = "file://container-cross-init.sh"

# Source directory
S = "${UNPACKDIR}"

# Path to layer files directory (for optional blob lookup)
LAYER_FILES_DIR = "${FILE_DIRNAME}/files"

# Minimum size for a valid initramfs (placeholder files are < 1KB)
INITRAMFS_MIN_SIZE = "1000000"

# Set to "1" in local.conf to prefer DEPLOY_DIR blobs over layer files
# Useful for development/testing without copying blobs to layer
CONTAINER_CROSS_USE_DEPLOY ?= "0"

do_install() {
    install -d ${D}${datadir}/container-cross-initramfs/aarch64
    install -d ${D}${datadir}/container-cross-initramfs/x86_64

    # Print banner if using deploy override
    if [ "${CONTAINER_CROSS_USE_DEPLOY}" = "1" ]; then
        bbwarn "============================================================"
        bbwarn "CONTAINER_CROSS_USE_DEPLOY=1: Using DEPLOY_DIR blobs!"
        bbwarn "Blobs from tmp/deploy/ will be preferred over layer files."
        bbwarn "Remove from local.conf when done testing."
        bbwarn "============================================================"
    fi

    # Helper to check if deploy blob is newer than layer blob
    check_newer_deploy() {
        local arch="$1"
        local filename="$2"
        local layer_blob="${LAYER_FILES_DIR}/${arch}/${filename}"
        local deploy_blob=""

        case "$arch" in
            aarch64)
                deploy_blob="${DEPLOY_DIR}/images/qemuarm64/container-cross-initramfs/${filename}"
                ;;
            x86_64)
                deploy_blob="${DEPLOY_DIR}/images/qemux86-64/container-cross-initramfs/${filename}"
                ;;
        esac

        if [ -f "$layer_blob" ] && [ -f "$deploy_blob" ]; then
            local layer_size=$(stat -c%s "$layer_blob" 2>/dev/null || echo 0)
            local deploy_size=$(stat -c%s "$deploy_blob" 2>/dev/null || echo 0)
            # Only warn if both are valid blobs (not placeholders) and sizes differ
            if [ "$layer_size" -gt 1000000 ] && [ "$deploy_size" -gt 1000000 ]; then
                if [ "$deploy_blob" -nt "$layer_blob" ]; then
                    bbwarn "DEPLOY_DIR has newer $filename for $arch!"
                    bbwarn "  Layer: $(stat -c'%s bytes, %y' "$layer_blob")"
                    bbwarn "  Deploy: $(stat -c'%s bytes, %y' "$deploy_blob")"
                    bbwarn "To update layer, run:"
                    bbwarn "  cp $deploy_blob \\"
                    bbwarn "     ${@d.getVar('FILE_DIRNAME')}/files/${arch}/"
                fi
            fi
        fi
    }

    # Check for newer blobs in DEPLOY_DIR (only when not using deploy override)
    # Note: We check ALL architectures since this native recipe provides blobs
    # for any target architecture that might use container-cross-install
    if [ "${CONTAINER_CROSS_USE_DEPLOY}" != "1" ]; then
        check_newer_deploy "aarch64" "initramfs.cpio.gz"
        check_newer_deploy "aarch64" "Image"
        check_newer_deploy "x86_64" "initramfs.cpio.gz"
        check_newer_deploy "x86_64" "bzImage"
    fi

    # Helper function to install blob with automatic fallback to deploy directory
    # Priority order controlled by CONTAINER_CROSS_USE_DEPLOY variable
    install_blob() {
        local arch="$1"
        local filename="$2"
        local dest="${D}${datadir}/container-cross-initramfs/${arch}/${filename}"
        local layer_blob="${LAYER_FILES_DIR}/${arch}/${filename}"
        local min_size="${INITRAMFS_MIN_SIZE}"
        local use_deploy="${CONTAINER_CROSS_USE_DEPLOY}"

        # For kernel images, lower threshold
        case "$filename" in
            Image|bzImage|zImage) min_size="100000" ;;
        esac

        # Get DEPLOY_DIR blob path
        local deploy_blob=""
        case "$arch" in
            aarch64)
                deploy_blob="${DEPLOY_DIR}/images/qemuarm64/container-cross-initramfs/${filename}"
                ;;
            x86_64)
                deploy_blob="${DEPLOY_DIR}/images/qemux86-64/container-cross-initramfs/${filename}"
                ;;
        esac

        # If CONTAINER_CROSS_USE_DEPLOY=1, check deploy first
        if [ "$use_deploy" = "1" ]; then
            if [ -n "$deploy_blob" ] && [ -f "$deploy_blob" ]; then
                local size=$(stat -c%s "$deploy_blob" 2>/dev/null || echo 0)
                if [ "$size" -gt "$min_size" ]; then
                    bbnote "Installing $filename for $arch from DEPLOY_DIR (priority override)"
                    bbnote "Source: $deploy_blob (${size} bytes)"
                    install -m 0644 "$deploy_blob" "$dest"
                    return 0
                fi
            fi
            bbnote "DEPLOY_DIR blob not found or invalid, falling back to layer..."
        fi

        # Check layer blob (default priority 1, or fallback if USE_DEPLOY=1)
        if [ -f "$layer_blob" ]; then
            local size=$(stat -c%s "$layer_blob" 2>/dev/null || echo 0)
            if [ "$size" -gt "$min_size" ]; then
                bbnote "Installing $filename for $arch from layer (${size} bytes)"
                install -m 0644 "$layer_blob" "$dest"
                return 0
            else
                bbnote "Layer blob $filename for $arch is placeholder (${size} bytes), checking fallback..."
            fi
        fi

        # Check DEPLOY_DIR as fallback (if not already checked above)
        if [ "$use_deploy" != "1" ] && [ -n "$deploy_blob" ] && [ -f "$deploy_blob" ]; then
            local size=$(stat -c%s "$deploy_blob" 2>/dev/null || echo 0)
            if [ "$size" -gt "$min_size" ]; then
                bbnote "Installing $filename for $arch from DEPLOY_DIR (${size} bytes)"
                bbnote "Source: $deploy_blob"
                install -m 0644 "$deploy_blob" "$dest"
                return 0
            fi
        fi

        # No valid blob found - provide clear instructions and fail
        local machine_name=""
        case "$arch" in
            aarch64) machine_name="qemuarm64" ;;
            x86_64) machine_name="qemux86-64" ;;
            *) machine_name="qemu${arch}" ;;
        esac

        bbfatal "============================================================\n\
MISSING BLOB: $filename for $arch\n\
============================================================\n\
Container cross-install requires pre-built initramfs blobs.\n\
The layer does not include them (too large for git).\n\
\n\
To build the required blobs (one-time), run:\n\
  MACHINE=${machine_name} bitbake container-cross-initramfs-build\n\
\n\
Then rebuild your image.\n\
============================================================"
    }

    # Install blobs for ALL supported architectures
    # This native recipe provides blobs for any target that might use
    # container-cross-install. The bbclass selects the right architecture
    # at image build time based on the actual TARGET_ARCH.
    #
    # Note: install_blob will skip (not fail) if blobs aren't available
    # for an architecture. The actual target architecture check happens
    # in the container-cross-install.bbclass.

    # Try to install aarch64 blobs (skip if not available)
    if [ -f "${LAYER_FILES_DIR}/aarch64/Image" ] || \
       [ -f "${DEPLOY_DIR}/images/qemuarm64/container-cross-initramfs/Image" ]; then
        install_blob "aarch64" "Image"
        install_blob "aarch64" "initramfs.cpio.gz"
    else
        bbnote "aarch64 blobs not available - skipping (build with MACHINE=qemuarm64 if needed)"
    fi

    # Try to install x86_64 blobs (skip if not available)
    if [ -f "${LAYER_FILES_DIR}/x86_64/bzImage" ] || \
       [ -f "${DEPLOY_DIR}/images/qemux86-64/container-cross-initramfs/bzImage" ]; then
        install_blob "x86_64" "bzImage"
        install_blob "x86_64" "initramfs.cpio.gz"
    else
        bbnote "x86_64 blobs not available - skipping (build with MACHINE=qemux86-64 if needed)"
    fi

    # Install unified init script (always from layer)
    install -d ${D}${datadir}/container-cross-initramfs
    if [ -f ${S}/container-cross-init.sh ]; then
        install -m 0755 ${S}/container-cross-init.sh \
            ${D}${datadir}/container-cross-initramfs/
    fi
}

# Make blobs available in native sysroot
SYSROOT_DIRS += "${datadir}/container-cross-initramfs"
