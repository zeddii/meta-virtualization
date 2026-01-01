# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# container-bundle.bbclass
# ===========================================================================
# Container bundling class for creating installable container packages
# ===========================================================================
#
# This class creates packages that bundle pre-processed container images.
# When these packages are installed via IMAGE_INSTALL, the containers are
# automatically merged into the target image's container storage.
#
# Usage:
#   inherit container-bundle
#
#   CONTAINER_BUNDLES = "\
#       myapp \
#       mydb:autostart \
#       docker.io/library/redis:7 \
#   "
#
#   # REQUIRED for remote containers:
#   CONTAINER_DIGESTS[docker.io/library/redis:7] = "sha256:..."
#
# Variable format: source[:autostart-policy]
#   - source: Either a local recipe name or a remote registry URL
#     * Local: "myapp", "container-base" (simple names)
#     * Remote: "docker.io/library/alpine:3.19" (contains / or .)
#   - autostart-policy: Optional. autostart | always | unless-stopped | on-failure
#
# Runtime Selection (in order of precedence):
#   1. CONTAINER_BUNDLE_RUNTIME in recipe (explicit override)
#   2. CONTAINER_PROFILE distro/local.conf setting
#   3. Default: "docker"
#
# Remote containers:
#   - Must have pinned digest via CONTAINER_DIGESTS
#   - A licensing warning is emitted during fetch
#   - Fetched using skopeo-native in do_fetch phase
#
# Local containers:
#   - Built via dependency on do_image_complete
#   - Picked up from DEPLOY_DIR_IMAGE
#
# ===========================================================================
# Integration with container-cross-install.bbclass
# ===========================================================================
#
# This class creates packages that are processed by container-cross-install:
#   1. Installs storage tar to ${datadir}/container-bundles/${RUNTIME}/
#   2. Installs metadata to ${datadir}/container-bundles/${PN}.meta
#   3. container-cross-install.bbclass merges these during image creation
#
# The runtime directory (docker/ vs podman/) tells container-cross-install
# which merger script to use and where to install the storage.
#
# See also: container-cross-install.bbclass, CLAUDE.md

CONTAINER_BUNDLES ?= ""

# Default runtime based on CONTAINER_PROFILE
# Can be overridden in recipe with CONTAINER_BUNDLE_RUNTIME = "podman"
def get_bundle_runtime(d):
    """Determine container runtime from CONTAINER_PROFILE or default to docker"""
    profile = d.getVar('CONTAINER_PROFILE') or 'docker'
    if profile in ['podman']:
        return 'podman'
    # docker, containerd, k3s-*, default all use docker storage format
    return 'docker'

CONTAINER_BUNDLE_RUNTIME ?= "${@get_bundle_runtime(d)}"

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

VRUNTIME_MULTICONFIG = "${@get_vruntime_multiconfig(d)}"
VRUNTIME_MACHINE = "${@get_vruntime_machine(d)}"
BLOB_ARCH = "${@get_blob_arch(d)}"

# Path to vrunner.sh from vdkr-native
VRUNNER_PATH = "${STAGING_BINDIR_NATIVE}/vrunner.sh"

# Blobs come from multiconfig deploy directory
# These are built by vdkr-initramfs-create and vpdmn-initramfs-create
VDKR_BLOB_DIR = "${TOPDIR}/tmp-${VRUNTIME_MULTICONFIG}/deploy/images/${VRUNTIME_MACHINE}/vdkr"
VPDMN_BLOB_DIR = "${TOPDIR}/tmp-${VRUNTIME_MULTICONFIG}/deploy/images/${VRUNTIME_MACHINE}/vpdmn"

def is_remote_container(source):
    """Detect if source is a registry URL vs local recipe name.

    Remote indicators: contains '/' or '.' in the base name (before first :)
    Local: simple recipe name like "myapp" or "container-base"
    """
    base = source.split(':')[0] if ':' in source else source
    return '/' in base or '.' in base

python __anonymous() {
    bundles = (d.getVar('CONTAINER_BUNDLES') or "").split()
    if not bundles:
        return

    # Get runtime from CONTAINER_BUNDLE_RUNTIME (set based on CONTAINER_PROFILE)
    runtime = d.getVar('CONTAINER_BUNDLE_RUNTIME') or 'docker'
    if runtime not in ['docker', 'podman']:
        bb.fatal(f"Invalid CONTAINER_BUNDLE_RUNTIME '{runtime}': must be 'docker' or 'podman'")

    local_recipes = []
    remote_urls = []
    processed_bundles = []

    for bundle in bundles:
        # New format: source[:autostart-policy]
        # For remote URLs like docker.io/library/redis:7, we need to handle
        # the tag colon differently from the autostart colon
        if is_remote_container(bundle):
            # Remote: could be "docker.io/library/redis:7" or "docker.io/library/redis:7:autostart"
            # Find the last colon that's an autostart policy
            if bundle.endswith(':autostart') or bundle.endswith(':always') or \
               bundle.endswith(':unless-stopped') or bundle.endswith(':on-failure') or \
               bundle.endswith(':no'):
                last_colon = bundle.rfind(':')
                source = bundle[:last_colon]
                autostart = bundle[last_colon+1:]
            else:
                source = bundle
                autostart = ""
            remote_urls.append(source)
        else:
            # Local: "myapp" or "myapp:autostart"
            parts = bundle.split(':')
            source = parts[0]
            autostart = parts[1] if len(parts) > 1 else ""
            local_recipes.append(source)

        # Store normalized format: source:runtime:autostart (for metadata file)
        processed_bundles.append(f"{source}:{runtime}:{autostart}" if autostart else f"{source}:{runtime}")

    # Add dependencies for local container recipes
    # Local containers are built in the MAIN context (not multiconfig)
    # and their OCI images are in main DEPLOY_DIR_IMAGE
    if local_recipes:
        deps = ""
        for recipe in local_recipes:
            # Container recipes produce OCI images via do_image_complete
            deps += f" {recipe}:do_image_complete"
        if deps:
            d.appendVarFlag('do_compile', 'depends', deps)

    # Store parsed lists for tasks
    d.setVar('_LOCAL_CONTAINERS', ' '.join(local_recipes))
    d.setVar('_REMOTE_CONTAINERS', ' '.join(remote_urls))
    d.setVar('_PROCESSED_BUNDLES', ' '.join(processed_bundles))
    d.setVar('_BUNDLE_RUNTIME', runtime)
}

# S must be a real directory
S = "${WORKDIR}/sources"
B = "${WORKDIR}/build"

do_unpack[noexec] = "1"
do_patch[noexec] = "1"
do_configure[noexec] = "1"

python do_fetch() {
    import subprocess
    import os

    remote_containers = (d.getVar('_REMOTE_CONTAINERS') or "").split()
    if not remote_containers:
        return

    workdir = d.getVar('WORKDIR')
    fetched_dir = os.path.join(workdir, 'fetched')
    os.makedirs(fetched_dir, exist_ok=True)

    # Find skopeo in native sysroot
    staging_bindir = d.getVar('STAGING_BINDIR_NATIVE')
    skopeo = os.path.join(staging_bindir, 'skopeo') if staging_bindir else 'skopeo'

    for url in remote_containers:
        if not url:
            continue

        # Digest is REQUIRED for remote containers
        digest = d.getVarFlag('CONTAINER_DIGESTS', url)
        if not digest:
            bb.fatal(f"Remote container '{url}' requires a pinned digest.\n"
                     f"Add: CONTAINER_DIGESTS[{url}] = \"sha256:...\"\n"
                     f"Get digest with: skopeo inspect docker://{url} | jq -r '.Digest'")

        # Emit licensing warning
        bb.warn(f"Fetching third-party container: {url}\n"
                f"Ensure you have rights to redistribute this container in your image.\n"
                f"Check the container's license terms before distribution.")

        src = f"{url}@{digest}"
        name = url.replace('/', '_').replace(':', '_')
        dest_dir = os.path.join(fetched_dir, name)
        dest = f"oci:{dest_dir}:latest"

        bb.note(f"Fetching {src} -> {dest}")

        try:
            subprocess.check_call([skopeo, 'copy', f'docker://{src}', dest])
        except subprocess.CalledProcessError as e:
            bb.fatal(f"Failed to fetch container '{url}': {e}")
}

do_fetch[network] = "1"
do_fetch[depends] += "skopeo-native:do_populate_sysroot"

do_compile() {
    set -e

    mkdir -p "${S}"
    mkdir -p "${B}"

    RUNTIME="${_BUNDLE_RUNTIME}"
    bbnote "Processing containers with runtime: ${RUNTIME}"

    # Single storage tar for all containers (same runtime)
    STORAGE_TAR="${B}/${RUNTIME}-storage.tar"
    rm -f "${STORAGE_TAR}"

    # Process each container
    for bundle in ${_PROCESSED_BUNDLES}; do
        # bundle format: source:runtime[:autostart]
        source=$(echo "$bundle" | cut -d: -f1)
        process_bundle "$source" "${RUNTIME}" "${STORAGE_TAR}"
    done

    # Store metadata for autostart processing (one bundle per line)
    # Uses _PROCESSED_BUNDLES which has normalized format with runtime
    printf '%s\n' ${_PROCESSED_BUNDLES} > "${B}/bundle-metadata.txt"
}

process_bundle() {
    local bundle="$1"
    local runtime="$2"
    local storage_tar="$3"

    local source=$(echo "$bundle" | cut -d: -f1)

    # Determine OCI directory and image reference
    if echo "$source" | grep -qE '[/.]'; then
        # Remote container - already fetched
        local name=$(echo "$source" | sed 's|[/:]|_|g')
        local oci_dir="${WORKDIR}/fetched/${name}"
        # Use the tag from the source URL or default to latest
        local tag=$(echo "$source" | grep -oE ':[^:]+$' | sed 's/^://' || echo "latest")
        local base_name=$(echo "$source" | sed 's|.*/||' | sed 's/:.*$//')
        local image_ref="${base_name}:${tag}"
    else
        # Local container - from DEPLOY_DIR
        local oci_dir="${DEPLOY_DIR_IMAGE}/${source}-latest-oci"
        # If not found, try without -latest suffix
        if [ ! -d "${oci_dir}" ]; then
            oci_dir="${DEPLOY_DIR_IMAGE}/${source}-oci"
        fi
        if [ ! -d "${oci_dir}" ]; then
            oci_dir="${DEPLOY_DIR_IMAGE}/${source}"
        fi
        local image_ref="${source}:latest"
    fi

    if [ ! -d "${oci_dir}" ]; then
        bbfatal "Container OCI directory not found: ${oci_dir}"
    fi

    bbnote "Importing ${oci_dir} as ${image_ref} (${runtime})"

    # Select blob directory and skopeo destination based on runtime
    if [ "$runtime" = "docker" ]; then
        RUNTIME_BLOB_DIR="${VDKR_BLOB_DIR}"
        SKOPEO_DEST="docker-daemon:${image_ref}"
    else
        RUNTIME_BLOB_DIR="${VPDMN_BLOB_DIR}"
        SKOPEO_DEST="containers-storage:${image_ref}"
    fi

    # Verify blob directory exists
    if [ ! -d "${RUNTIME_BLOB_DIR}" ]; then
        bbfatal "Blob directory not found: ${RUNTIME_BLOB_DIR}"
    fi

    # Build vrunner command
    VRUNNER_CMD="${VRUNNER_PATH} \
        --runtime ${runtime} \
        --arch ${BLOB_ARCH} \
        --blob-dir ${RUNTIME_BLOB_DIR} \
        --input ${oci_dir} \
        --input-type oci \
        --output-type storage \
        --output ${storage_tar} \
        --verbose"

    # If we have previous storage, load it first
    if [ -f "${storage_tar}" ]; then
        VRUNNER_CMD="${VRUNNER_CMD} --input-storage ${storage_tar}"
    fi

    VRUNNER_CMD="${VRUNNER_CMD} -- skopeo copy oci:{INPUT} ${SKOPEO_DEST}"

    bbnote "Running: ${VRUNNER_CMD}"
    TMPDIR="${WORKDIR}" eval ${VRUNNER_CMD}

    if [ $? -ne 0 ]; then
        bbfatal "Container import failed for ${source}"
    fi

    bbnote "Successfully imported ${image_ref}"
}

do_compile[depends] += "vdkr-native:do_populate_sysroot vpdmn-native:do_populate_sysroot"

do_install() {
    # Install storage tar for later merging by container-cross-install
    # Runtime is determined by CONTAINER_BUNDLE_RUNTIME (from CONTAINER_PROFILE)

    RUNTIME="${_BUNDLE_RUNTIME}"

    if [ -f "${B}/${RUNTIME}-storage.tar" ]; then
        install -d ${D}${datadir}/container-bundles/${RUNTIME}
        install -m 0644 ${B}/${RUNTIME}-storage.tar \
            ${D}${datadir}/container-bundles/${RUNTIME}/${PN}.tar
    fi

    # Install metadata for autostart service generation
    if [ -f "${B}/bundle-metadata.txt" ]; then
        install -d ${D}${datadir}/container-bundles
        install -m 0644 ${B}/bundle-metadata.txt \
            ${D}${datadir}/container-bundles/${PN}.meta
    fi
}

FILES:${PN} = "${datadir}/container-bundles"

# Automatically trigger multiconfig blob builds
# Note: This does NOT create circular dependencies because the blob build chain
# (vdkr/vpdmn-initramfs-create -> vdkr/vpdmn-rootfs-image) is completely separate
# from container image recipes. Circular deps only occur if bundle packages are
# globally added to all images (including container images themselves).
do_compile[mcdepends] = "mc::${VRUNTIME_MULTICONFIG}:vdkr-initramfs-create:do_deploy mc::${VRUNTIME_MULTICONFIG}:vpdmn-initramfs-create:do_deploy"
