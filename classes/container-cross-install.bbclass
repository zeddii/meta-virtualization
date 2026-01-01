# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
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
# Container format: <container-name>:<runtime>[:<autostart-policy>]
#   - container-name: Name of container in DEPLOY_DIR_IMAGE (OCI directory)
#   - runtime: docker or podman (default: docker if not specified)
#   - autostart-policy: Optional. If specified, creates systemd service to
#     start the container on boot. Valid values:
#       * autostart     - alias for unless-stopped (recommended)
#       * always        - always restart container
#       * unless-stopped - restart unless manually stopped
#       * on-failure    - restart only on non-zero exit code
#
# Autostart examples:
#   BUNDLED_CONTAINERS = "myapp-latest-oci:docker:autostart"
#   BUNDLED_CONTAINERS = "myapp-latest-oci:podman:always"
#
# Generated autostart files:
#   Docker: /etc/systemd/system/container-<name>.service (enabled)
#   Podman: /etc/containers/systemd/<name>.container (Quadlet format)
#
# The class uses pre-built initramfs blobs from container-cross-initramfs-native
# which contain both Docker and Podman tools. Runtime is selected via kernel
# cmdline parameter.
#
# ===========================================================================
# Integration with container-bundle.bbclass
# ===========================================================================
#
# This class also processes packages created by container-bundle.bbclass:
#   1. merge_installed_bundles() runs as ROOTFS_POSTPROCESS_COMMAND
#   2. Scans ${datadir}/container-bundles/{docker,podman}/*.tar
#   3. Merges storage tars into /var/lib/docker or /var/lib/containers
#   4. Reads *.meta files for autostart service generation
#
# The runtime is determined by the install directory (docker/ vs podman/),
# which is set by container-bundle.bbclass based on CONTAINER_BUNDLE_RUNTIME.
#
# See also: container-bundle.bbclass, CLAUDE.md

# Dependencies on native tools
# vdkr-native provides vrunner.sh and Docker blobs (rootfs.img with docker-moby)
# vpdmn-native provides Podman blobs (rootfs.img with podman)
DEPENDS += "qemuwrapper-cross qemu-system-native skopeo-native"
DEPENDS += "vdkr-native vpdmn-native"

# Determine multiconfig name for blob building based on target architecture
def get_vruntime_multiconfig(d):
    arch = d.getVar('TARGET_ARCH')
    if arch == 'aarch64':
        return 'vruntime-aarch64'
    elif arch in ['x86_64', 'i686', 'i586']:
        return 'vruntime-x86-64'
    else:
        return None

# Get the MACHINE name used in the multiconfig (for deploy path)
def get_vruntime_machine(d):
    arch = d.getVar('TARGET_ARCH')
    if arch == 'aarch64':
        return 'qemuarm64'
    elif arch in ['x86_64', 'i686', 'i586']:
        return 'qemux86-64'
    else:
        return None

VRUNTIME_MULTICONFIG = "${@get_vruntime_multiconfig(d)}"
VRUNTIME_MACHINE = "${@get_vruntime_machine(d)}"

# Use mcdepends to automatically build vdkr/vpdmn blobs via multiconfig
# This ensures blobs are built as part of the normal Yocto build flow
# Requires BBMULTICONFIG = "vruntime-aarch64 vruntime-x86-64" in local.conf
do_rootfs[mcdepends] = "mc::${VRUNTIME_MULTICONFIG}:vdkr-initramfs-create:do_deploy mc::${VRUNTIME_MULTICONFIG}:vpdmn-initramfs-create:do_deploy"

# Path to vrunner.sh from vdkr-native
VRUNNER_PATH = "${STAGING_BINDIR_NATIVE}/vrunner.sh"

# Blobs come from multiconfig's DEPLOY_DIR (built by mcdepends on vdkr-initramfs-create)
# Multiconfig uses separate TMPDIR, so deploy path is:
#   ${TOPDIR}/tmp-${VRUNTIME_MULTICONFIG}/deploy/images/${VRUNTIME_MACHINE}/
# Blobs are in runtime/arch subdirectories: ${BLOB_DIR}/${ARCH}/ (e.g., x86_64/, aarch64/)
VDKR_BLOB_DIR = "${TOPDIR}/tmp-${VRUNTIME_MULTICONFIG}/deploy/images/${VRUNTIME_MACHINE}/vdkr"
VPDMN_BLOB_DIR = "${TOPDIR}/tmp-${VRUNTIME_MULTICONFIG}/deploy/images/${VRUNTIME_MACHINE}/vpdmn"

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

# ============================================================================
# Merge container bundles installed via IMAGE_INSTALL
# This function processes packages created by container-bundle.bbclass
# ============================================================================
merge_installed_bundles() {
    BUNDLES_DIR="${IMAGE_ROOTFS}${datadir}/container-bundles"

    if [ ! -d "${BUNDLES_DIR}" ]; then
        bbnote "No container bundles found in ${BUNDLES_DIR}"
        return 0
    fi

    bbnote "Processing installed container bundles from ${BUNDLES_DIR}"

    # Extract Docker bundles
    # Storage tars from container-bundle.bbclass have docker/ at root
    # Direct extraction replaces complex merger scripts - Docker handled JSON internally
    if [ -d "${BUNDLES_DIR}/docker" ]; then
        for tar in ${BUNDLES_DIR}/docker/*.tar; do
            [ -f "$tar" ] || continue
            bbnote "Extracting Docker bundle: $(basename $tar)"
            mkdir -p "${IMAGE_ROOTFS}/var/lib/docker"
            # Extract directly - tar has docker/ prefix, extracts to /var/lib/docker
            tar -xf "$tar" -C "${IMAGE_ROOTFS}/var/lib" --no-same-owner
        done
    fi

    # Extract Podman bundles
    # Storage tars from container-bundle.bbclass have contents at root (vfs-images/, vfs-layers/, etc.)
    # The tar is created from inside /var/lib/containers/storage, so no storage/ prefix
    # Direct extraction replaces complex merger scripts - Podman handled JSON internally
    if [ -d "${BUNDLES_DIR}/podman" ]; then
        for tar in ${BUNDLES_DIR}/podman/*.tar; do
            [ -f "$tar" ] || continue
            bbnote "Extracting Podman bundle: $(basename $tar)"
            mkdir -p "${IMAGE_ROOTFS}/var/lib/containers/storage"
            # Extract directly into storage/ - tar has no prefix
            tar -xf "$tar" -C "${IMAGE_ROOTFS}/var/lib/containers/storage" --no-same-owner
        done
    fi

    # Process autostart metadata from bundle packages
    for meta in ${BUNDLES_DIR}/*.meta; do
        [ -f "$meta" ] || continue
        bbnote "Processing autostart metadata: $(basename $meta)"

        while IFS= read -r bundle || [ -n "$bundle" ]; do
            [ -z "$bundle" ] && continue

            # Parse: source:runtime[:autostart-policy]
            local source=$(echo "$bundle" | cut -d: -f1)
            local runtime_type=$(echo "$bundle" | cut -d: -f2)
            local autostart_policy=$(echo "$bundle" | cut -d: -f3)

            # Skip if no autostart requested
            [ -z "$autostart_policy" ] && continue

            # Normalize autostart policy
            local restart_policy
            case "$autostart_policy" in
                autostart|unless-stopped)
                    restart_policy="unless-stopped"
                    ;;
                always|on-failure|no)
                    restart_policy="$autostart_policy"
                    ;;
                *)
                    bbwarn "Unknown restart policy '$autostart_policy' for $source, using 'unless-stopped'"
                    restart_policy="unless-stopped"
                    ;;
            esac

            # Extract image name from source
            local image_name
            local image_tag="latest"
            if echo "$source" | grep -qE '[/.]'; then
                # Remote container URL
                image_name=$(echo "$source" | sed 's|.*/||' | sed 's/:.*$//')
                image_tag=$(echo "$source" | grep -oE ':[^:]+$' | sed 's/^://' || echo "latest")
            else
                # Local container name
                image_name="$source"
                image_tag="latest"
            fi

            local service_name="container-$(echo "$image_name" | sed 's/[^a-zA-Z0-9_-]/-/g' | tr '[:upper:]' '[:lower:]')"

            bbnote "Creating autostart service for $source ($runtime_type, restart=$restart_policy)"

            if [ "$runtime_type" = "docker" ]; then
                generate_docker_service_from_bundle "$service_name" "$image_name" "$image_tag" "$restart_policy"
            elif [ "$runtime_type" = "podman" ]; then
                generate_podman_service_from_bundle "$service_name" "$image_name" "$image_tag" "$restart_policy"
            fi
        done < "$meta"
    done

    # Clean up bundle files from final image (they're just intermediate artifacts)
    rm -rf "${BUNDLES_DIR}"
    bbnote "Cleaned up container bundle files"
}

# Generate Docker systemd service (for bundle packages)
generate_docker_service_from_bundle() {
    local service_name="$1"
    local image_name="$2"
    local image_tag="$3"
    local restart_policy="$4"

    local service_dir="${IMAGE_ROOTFS}/lib/systemd/system"
    local service_file="${service_dir}/${service_name}.service"

    mkdir -p "$service_dir"

    cat > "$service_file" << EOF
[Unit]
Description=Docker Container ${image_name}:${image_tag}
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=${restart_policy}
RestartSec=5s
TimeoutStartSec=0
ExecStartPre=-/usr/bin/docker rm -f ${image_name}
ExecStart=/usr/bin/docker run --rm --name ${image_name} ${image_name}:${image_tag}
ExecStop=/usr/bin/docker stop ${image_name}

[Install]
WantedBy=multi-user.target
EOF

    local wants_dir="${IMAGE_ROOTFS}/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$wants_dir"
    ln -sf "/lib/systemd/system/${service_name}.service" "${wants_dir}/${service_name}.service"

    bbnote "Created and enabled ${service_name}.service for Docker container ${image_name}:${image_tag}"
}

# Generate Podman Quadlet container file (for bundle packages)
generate_podman_service_from_bundle() {
    local service_name="$1"
    local image_name="$2"
    local image_tag="$3"
    local restart_policy="$4"

    local quadlet_dir="${IMAGE_ROOTFS}/etc/containers/systemd"
    local container_file="${quadlet_dir}/${service_name}.container"

    mkdir -p "$quadlet_dir"

    cat > "$container_file" << EOF
# Quadlet container file for ${image_name}:${image_tag}
# Generated by container-cross-install

[Unit]
Description=Podman Container ${image_name}:${image_tag}

[Container]
Image=${image_name}:${image_tag}
ContainerName=${image_name}

[Service]
Restart=${restart_policy}
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    bbnote "Created Quadlet file ${service_name}.container for Podman container ${image_name}:${image_tag}"
}

bundle_containers() {
    set +e

    # ========================================================================
    # Helper functions for autostart support
    # These must be defined INSIDE bundle_containers() to be available in
    # bitbake's ROOTFS_POSTPROCESS_COMMAND execution context
    # ========================================================================

    # Extract container image name and tag from OCI directory name
    # Sets: CONTAINER_IMAGE_NAME, CONTAINER_IMAGE_TAG
    # Input: /path/to/container-base-latest-oci
    # Note: Use _cci_ prefix to avoid conflicts with bitbake's environment variables
    extract_container_info() {
        _cci_oci_path="$1"
        _cci_dir_name=$(basename "$_cci_oci_path" | sed 's/-oci$//')

        CONTAINER_IMAGE_NAME=""
        CONTAINER_IMAGE_TAG="latest"

        # Three-part pattern: part1-part2-part3 (e.g., container-base-latest)
        if echo "$_cci_dir_name" | grep -qE '^[^-]+-[^-]+-[^-]+$'; then
            _cci_part1=$(echo "$_cci_dir_name" | cut -d- -f1)
            _cci_part2=$(echo "$_cci_dir_name" | cut -d- -f2)
            _cci_part3=$(echo "$_cci_dir_name" | cut -d- -f3)
            CONTAINER_IMAGE_NAME="${_cci_part1}-${_cci_part2}"
            CONTAINER_IMAGE_TAG="$_cci_part3"
        # Two-part pattern: name-tag (e.g., myapp-1.0)
        elif echo "$_cci_dir_name" | grep -qE '^[^-]+-[^-]+$'; then
            CONTAINER_IMAGE_NAME=$(echo "$_cci_dir_name" | cut -d- -f1)
            CONTAINER_IMAGE_TAG=$(echo "$_cci_dir_name" | cut -d- -f2)
        # Single name (e.g., myapp)
        else
            CONTAINER_IMAGE_NAME="$_cci_dir_name"
            CONTAINER_IMAGE_TAG="latest"
        fi
    }

    # Convert container name to valid systemd service name
    # Input: my-app/special:latest
    # Output: my-app-special-latest
    sanitize_service_name() {
        local name="$1"
        echo "$name" | sed 's/[^a-zA-Z0-9_-]/-/g' | tr '[:upper:]' '[:lower:]'
    }

    # Generate Docker systemd service file
    # Args: service_name image_name image_tag restart_policy
    generate_docker_service() {
        local service_name="$1"
        local image_name="$2"
        local image_tag="$3"
        local restart_policy="$4"

        # Use standard paths - systemd_system_unitdir is /lib/systemd/system
        local service_dir="${IMAGE_ROOTFS}/lib/systemd/system"
        local service_file="${service_dir}/${service_name}.service"

        mkdir -p "$service_dir"

        cat > "$service_file" << EOF
[Unit]
Description=Docker Container ${image_name}:${image_tag}
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=${restart_policy}
RestartSec=5s
TimeoutStartSec=0
ExecStartPre=-/usr/bin/docker rm -f ${image_name}
ExecStart=/usr/bin/docker run --rm --name ${image_name} ${image_name}:${image_tag}
ExecStop=/usr/bin/docker stop ${image_name}

[Install]
WantedBy=multi-user.target
EOF

        # Enable the service via symlink
        local wants_dir="${IMAGE_ROOTFS}/etc/systemd/system/multi-user.target.wants"
        mkdir -p "$wants_dir"
        ln -sf "/lib/systemd/system/${service_name}.service" "${wants_dir}/${service_name}.service"

        bbnote "Created and enabled ${service_name}.service for Docker container ${image_name}:${image_tag}"
    }

    # Generate Podman Quadlet container file
    # Args: service_name image_name image_tag restart_policy
    generate_podman_service() {
        local service_name="$1"
        local image_name="$2"
        local image_tag="$3"
        local restart_policy="$4"

        # Use Quadlet format for modern Podman
        local quadlet_dir="${IMAGE_ROOTFS}/etc/containers/systemd"
        local container_file="${quadlet_dir}/${service_name}.container"

        mkdir -p "$quadlet_dir"

        cat > "$container_file" << EOF
# Quadlet container file for ${image_name}:${image_tag}
# Generated by container-cross-install

[Unit]
Description=Podman Container ${image_name}:${image_tag}

[Container]
Image=${image_name}:${image_tag}
ContainerName=${image_name}

[Service]
Restart=${restart_policy}
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

        bbnote "Created Quadlet file ${service_name}.container for Podman container ${image_name}:${image_tag}"
    }

    # Install autostart services for containers with autostart policy
    install_autostart_services() {
        bbnote "Processing container autostart services..."

        if [ -z "${BUNDLED_CONTAINERS}" ]; then
            return 0
        fi

        for bc in ${BUNDLED_CONTAINERS}; do
            # Parse extended format: container:runtime[:autostart-policy]
            local container_name="$(echo $bc | cut -d: -f1)"
            local runtime_type="$(echo $bc | cut -d: -f2)"
            local autostart_policy="$(echo $bc | cut -d: -f3)"

            # Default runtime to docker if not specified
            if [ "$container_name" = "$runtime_type" ]; then
                runtime_type="docker"
                autostart_policy=""
            fi

            # Skip if no autostart requested
            if [ -z "$autostart_policy" ]; then
                bbnote "Container $container_name: no autostart configured"
                continue
            fi

            # Normalize autostart policy
            local restart_policy
            case "$autostart_policy" in
                autostart|unless-stopped)
                    restart_policy="unless-stopped"
                    ;;
                always|on-failure|no)
                    restart_policy="$autostart_policy"
                    ;;
                *)
                    bbwarn "Unknown restart policy '$autostart_policy' for $container_name, using 'unless-stopped'"
                    restart_policy="unless-stopped"
                    ;;
            esac

            # Extract image name and tag from OCI directory
            extract_container_info "${DEPLOY_DIR_IMAGE}/$container_name"

            # Generate service name
            local service_name="container-$(sanitize_service_name "${CONTAINER_IMAGE_NAME}")"

            bbnote "Creating autostart service for $container_name ($runtime_type, restart=$restart_policy)"

            if [ "$runtime_type" = "docker" ]; then
                generate_docker_service "$service_name" "${CONTAINER_IMAGE_NAME}" "${CONTAINER_IMAGE_TAG}" "$restart_policy"
            elif [ "$runtime_type" = "podman" ]; then
                generate_podman_service "$service_name" "${CONTAINER_IMAGE_NAME}" "${CONTAINER_IMAGE_TAG}" "$restart_policy"
            else
                bbwarn "Unknown runtime '$runtime_type' for autostart, skipping service generation"
            fi
        done
    }

    # ========================================================================
    # End helper functions
    # ========================================================================

    if [ -z "${BUNDLED_CONTAINERS}" ]; then
        bbnote "No bundled containers specified"
        return 0
    fi

    bbnote "Processing bundled containers: ${BUNDLED_CONTAINERS}"
    bbnote "Target architecture: ${QEMU_ARCH} (blob arch: ${BLOB_ARCH})"

    # Locate vrunner from vdkr-native
    VRUNNER="${VRUNNER_PATH}"
    bbnote "vrunner: ${VRUNNER}"

    # Verify vrunner exists
    if [ ! -f "${VRUNNER}" ]; then
        bbfatal "vrunner not found at ${VRUNNER}. Ensure vdkr-native is built."
    fi

    # ========================================================================
    # Collect containers by runtime for batch processing
    # Format: path:image:tag (as expected by vrunner --batch-import)
    # ========================================================================
    DOCKER_CONTAINERS=""
    PODMAN_CONTAINERS=""

    for bc in ${BUNDLED_CONTAINERS}; do
        container_name="$(echo $bc | cut -d: -f1)"
        runtime_type="$(echo $bc | cut -d: -f2)"

        # Default runtime to docker if not specified
        if [ "$container_name" = "$runtime_type" ]; then
            runtime_type="docker"
        fi

        bbnote "Collecting container: $container_name (runtime: $runtime_type)"

        # Verify container exists
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

        # Extract image name and tag from OCI directory name
        extract_container_info "${DEPLOY_DIR_IMAGE}/$container_name"
        BATCH_ENTRY="${DEPLOY_DIR_IMAGE}/${container_name}:${CONTAINER_IMAGE_NAME}:${CONTAINER_IMAGE_TAG}"

        if [ "$runtime_type" = "docker" ]; then
            DOCKER_CONTAINERS="${DOCKER_CONTAINERS} ${BATCH_ENTRY}"
        elif [ "$runtime_type" = "podman" ]; then
            PODMAN_CONTAINERS="${PODMAN_CONTAINERS} ${BATCH_ENTRY}"
        else
            bbwarn "Unknown runtime type: $runtime_type for $container_name, skipping"
        fi
    done

    # ========================================================================
    # Process Docker containers (batch import)
    # ========================================================================
    if [ -n "${DOCKER_CONTAINERS}" ]; then
        bbnote "Processing Docker containers: ${DOCKER_CONTAINERS}"

        DOCKER_STORAGE_TAR="${WORKDIR}/docker-storage-$$.tar"
        DOCKER_OUTPUT_DIR="${IMAGE_ROOTFS}/var/lib/docker"

        # Verify Docker blobs exist
        if [ ! -d "${VDKR_BLOB_DIR}" ]; then
            bbfatal "Docker blob directory not found at ${VDKR_BLOB_DIR}. Build with: bitbake vdkr-initramfs-create"
        fi

        # Check for existing Docker storage in rootfs (additive support)
        EXISTING_DOCKER_STORAGE=""
        if [ -d "${DOCKER_OUTPUT_DIR}" ] && [ -n "$(ls -A ${DOCKER_OUTPUT_DIR} 2>/dev/null)" ]; then
            bbnote "Found existing Docker storage, will merge additively"
            EXISTING_DOCKER_STORAGE="${WORKDIR}/existing-docker-$$.tar"
            tar -cf "${EXISTING_DOCKER_STORAGE}" -C "${IMAGE_ROOTFS}/var/lib" docker
        fi

        # Build vrunner batch-import command
        VRUNNER_CMD="${VRUNNER} \
            --runtime docker \
            --arch ${BLOB_ARCH} \
            --blob-dir ${VDKR_BLOB_DIR} \
            --batch-import \
            --output ${DOCKER_STORAGE_TAR} \
            --verbose"

        if [ -n "${EXISTING_DOCKER_STORAGE}" ]; then
            VRUNNER_CMD="${VRUNNER_CMD} --input-storage ${EXISTING_DOCKER_STORAGE}"
        fi

        VRUNNER_CMD="${VRUNNER_CMD} -- ${DOCKER_CONTAINERS}"

        bbnote "Running batch import for Docker containers..."
        TMPDIR="${WORKDIR}" eval ${VRUNNER_CMD}

        if [ $? -ne 0 ]; then
            bbfatal "Docker batch import failed"
        fi

        # Simple tar extraction - no merger needed!
        # The storage tar has correct structure with docker/ at root
        if [ -f "${DOCKER_STORAGE_TAR}" ]; then
            bbnote "Extracting Docker storage to rootfs..."
            mkdir -p "${DOCKER_OUTPUT_DIR}"
            # Extract with --strip-components=1 to remove the 'docker' prefix
            # since we're extracting directly into /var/lib/docker
            tar -xf "${DOCKER_STORAGE_TAR}" -C "${IMAGE_ROOTFS}/var/lib" --no-same-owner
            bbnote "Docker storage extracted successfully"
        fi

        rm -f "${EXISTING_DOCKER_STORAGE}"
    fi

    # ========================================================================
    # Process Podman containers (batch import)
    # ========================================================================
    if [ -n "${PODMAN_CONTAINERS}" ]; then
        bbnote "Processing Podman containers: ${PODMAN_CONTAINERS}"

        PODMAN_STORAGE_TAR="${WORKDIR}/podman-storage-$$.tar"
        PODMAN_OUTPUT_DIR="${IMAGE_ROOTFS}/var/lib/containers/storage"

        # Verify Podman blobs exist
        if [ ! -d "${VPDMN_BLOB_DIR}" ]; then
            bbfatal "Podman blob directory not found at ${VPDMN_BLOB_DIR}. Build with: bitbake vpdmn-initramfs-create"
        fi

        # Check for existing Podman storage in rootfs (additive support)
        EXISTING_PODMAN_STORAGE=""
        if [ -d "${PODMAN_OUTPUT_DIR}" ] && [ -n "$(ls -A ${PODMAN_OUTPUT_DIR} 2>/dev/null)" ]; then
            bbnote "Found existing Podman storage, will merge additively"
            EXISTING_PODMAN_STORAGE="${WORKDIR}/existing-podman-$$.tar"
            tar -cf "${EXISTING_PODMAN_STORAGE}" -C "${IMAGE_ROOTFS}/var/lib/containers" storage
        fi

        # Build vrunner batch-import command
        VRUNNER_CMD="${VRUNNER} \
            --runtime podman \
            --arch ${BLOB_ARCH} \
            --blob-dir ${VPDMN_BLOB_DIR} \
            --batch-import \
            --output ${PODMAN_STORAGE_TAR} \
            --verbose"

        if [ -n "${EXISTING_PODMAN_STORAGE}" ]; then
            VRUNNER_CMD="${VRUNNER_CMD} --input-storage ${EXISTING_PODMAN_STORAGE}"
        fi

        VRUNNER_CMD="${VRUNNER_CMD} -- ${PODMAN_CONTAINERS}"

        bbnote "Running batch import for Podman containers..."
        TMPDIR="${WORKDIR}" eval ${VRUNNER_CMD}

        if [ $? -ne 0 ]; then
            bbfatal "Podman batch import failed"
        fi

        # Simple tar extraction - no merger needed!
        if [ -f "${PODMAN_STORAGE_TAR}" ]; then
            bbnote "Extracting Podman storage to rootfs..."
            mkdir -p "${PODMAN_OUTPUT_DIR}"
            tar -xf "${PODMAN_STORAGE_TAR}" -C "${IMAGE_ROOTFS}/var/lib/containers" --no-same-owner
            bbnote "Podman storage extracted successfully"
        fi

        rm -f "${EXISTING_PODMAN_STORAGE}"
    fi

    # ========================================================================
    # Install autostart services
    # ========================================================================
    install_autostart_services

    bbnote "Done processing all bundled containers"
}

# First merge any bundles installed via IMAGE_INSTALL, then process BUNDLED_CONTAINERS
ROOTFS_POSTPROCESS_COMMAND += "merge_installed_bundles; bundle_containers;"
