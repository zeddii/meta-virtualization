# container-cross-install.bbclass
# ===========================================================================
# Cross-architecture container deployment class
# ===========================================================================
#
# This class enables bundling containers into target images during build time.
# It uses QEMU with a pre-built initramfs to process containers built for
# different architectures (cross-compilation safe).
#
# Usage:
#   inherit container-cross-install
#   BUNDLED_CONTAINERS = "container-base-latest-oci:docker container-app-latest-oci:podman"
#
# Container format: <container-name>:<runtime>
#   - container-name: Name of container in DEPLOY_DIR_IMAGE (OCI directory)
#   - runtime: docker or podman (default: docker if not specified)
#
# The class uses pre-built initramfs blobs from container-cross-initramfs-native
# which contain both Docker and Podman tools. Runtime is selected via kernel
# cmdline parameter.

# Dependencies on native tools
DEPENDS += "qemuwrapper-cross qemu-system-native skopeo-native"
DEPENDS += "container-cross-tools-native container-cross-initramfs-native"

# Path to pre-built blobs in native sysroot
CONTAINER_CROSS_BLOB_DIR = "${STAGING_DATADIR_NATIVE}/container-cross-initramfs"

bundle_containers[network] = "1"
do_testsdkext[nostamp] = "1"

# Map TARGET_ARCH to QEMU architecture names
def get_qemu_arch(d):
    """Map Yocto TARGET_ARCH to QEMU architecture name"""
    arch = d.getVar('TARGET_ARCH')
    arch_map = {
        'aarch64': 'aarch64',
        'arm': 'arm',
        'x86_64': 'x86_64',
        'i686': 'i386',
        'i586': 'i386',
    }
    return arch_map.get(arch, arch)

QEMU_ARCH = "${@get_qemu_arch(d)}"

# Map TARGET_ARCH to kernel image name
def get_kernel_name(d):
    """Map Yocto TARGET_ARCH to kernel image filename"""
    arch = d.getVar('TARGET_ARCH')
    kernel_map = {
        'aarch64': 'Image',
        'arm': 'zImage',
        'x86_64': 'bzImage',
        'i686': 'bzImage',
        'i586': 'bzImage',
    }
    return kernel_map.get(arch, 'Image')

KERNEL_IMAGETYPE_QEMU = "${@get_kernel_name(d)}"

# Map TARGET_ARCH to blob directory name (aarch64, x86_64)
def get_blob_arch(d):
    """Map Yocto TARGET_ARCH to blob directory name"""
    arch = d.getVar('TARGET_ARCH')
    blob_map = {
        'aarch64': 'aarch64',
        'arm': 'aarch64',  # Use aarch64 blobs for 32-bit ARM too
        'x86_64': 'x86_64',
        'i686': 'x86_64',
        'i586': 'x86_64',
    }
    return blob_map.get(arch, 'aarch64')

BLOB_ARCH = "${@get_blob_arch(d)}"

bundle_containers() {
    set +e

    if [ -n "${BUNDLED_CONTAINERS}" ]; then
        bbnote "Processing bundled containers: ${BUNDLED_CONTAINERS}"
        bbnote "Target architecture: ${QEMU_ARCH}"

        # Locate pre-built blobs from container-cross-initramfs-native
        BLOB_DIR="${CONTAINER_CROSS_BLOB_DIR}/${BLOB_ARCH}"
        PREBUILT_KERNEL="${BLOB_DIR}/${KERNEL_IMAGETYPE_QEMU}"
        PREBUILT_INITRAMFS="${BLOB_DIR}/initramfs.cpio.gz"

        bbnote "Pre-built blob directory: ${BLOB_DIR}"
        bbnote "Pre-built kernel: ${PREBUILT_KERNEL}"
        bbnote "Pre-built initramfs: ${PREBUILT_INITRAMFS}"

        # Verify blobs exist
        if [ ! -f "${PREBUILT_KERNEL}" ]; then
            bbwarn "Pre-built kernel not found at ${PREBUILT_KERNEL}"
            bbwarn "Falling back to DEPLOY_DIR_IMAGE kernel"
            PREBUILT_KERNEL="${DEPLOY_DIR_IMAGE}/${KERNEL_IMAGETYPE_QEMU}"
        fi

        if [ ! -f "${PREBUILT_INITRAMFS}" ]; then
            bbwarn "Pre-built initramfs not found at ${PREBUILT_INITRAMFS}"
            bbwarn "Container bundling may use legacy mode (slower)"
            PREBUILT_INITRAMFS=""
        fi

        for bc in ${BUNDLED_CONTAINERS}; do

            container_name="$(echo $bc | cut -d: -f1)"
            runtime_type="$(echo $bc | cut -d: -f2)"

            echo "[INFO]: container: $container_name"
            echo "[INFO]: runtime: $runtime_type"

            # if the two names match, there wasn't a : and a specified
            # type. So let's default to docker rather than erroring
            if [ "$container_name" = "$runtime_type" ]; then
                runtime_type="docker"
            fi

            bbnote "*** processing ${DEPLOY_DIR_IMAGE}/$container_name"
            echo "${DEPLOY_DIR_IMAGE}/$container_name"

            if ! [ -e ${DEPLOY_DIR_IMAGE}/$container_name ]; then
                bbfatal "============================================================
MISSING CONTAINER: $container_name
============================================================
Container not found: ${DEPLOY_DIR_IMAGE}/$container_name

BUNDLED_CONTAINERS specifies '$container_name' but it doesn't exist.

To fix, build the container for this machine:
  MACHINE=${MACHINE} bitbake $(echo $container_name | sed 's/-latest-oci$//' | sed 's/-oci$//')

Or remove it from BUNDLED_CONTAINERS if not needed.
============================================================"
            fi

            echo "Processing container with cross-deploy tools..."

            # Container storage cache directory
            export DOCKER_STORAGE_CACHE_DIR="${WORKDIR}/container-cache"

            # Determine output directory based on runtime
            if [ "$runtime_type" = "docker" ]; then
                OUTPUT_DIR="${IMAGE_ROOTFS}/var/lib/docker"
            elif [ "$runtime_type" = "podman" ]; then
                OUTPUT_DIR="${IMAGE_ROOTFS}/var/lib/containers/storage"
            else
                bberror "Unknown runtime type: $runtime_type (expected: docker or podman)"
                continue
            fi

            # Build command - use virtio-blk mode with pre-built initramfs
            # Note: --initramfs triggers 9p mode which is blocked, so we pass
            # the initramfs via environment variable for the blk creator script
            export PREBUILT_INITRAMFS_PATH="${PREBUILT_INITRAMFS}"

            DEPLOY_CMD="container-cross-deploy.sh $runtime_type \
                ${DEPLOY_DIR_IMAGE}/$container_name \
                $OUTPUT_DIR \
                --kernel ${PREBUILT_KERNEL} \
                --rootfs ${IMAGE_ROOTFS} \
                --arch ${QEMU_ARCH} \
                --verbose \
                --use-blk \
                --work-dir ${WORKDIR}"

            echo "$DEPLOY_CMD"
            eval $DEPLOY_CMD

            echo "Container $container_name processing complete!"
        done

        echo "Done processing all bundled containers"
    fi
}

ROOTFS_POSTPROCESS_COMMAND += "bundle_containers;"
