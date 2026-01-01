# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# container-cross-initramfs-build_1.0.bb
# ===========================================================================
# MAINTAINER-ONLY RECIPE - Builds unified QEMU initramfs for container cross-install
# ===========================================================================
#
# This recipe is used ONLY by the meta-virtualization layer MAINTAINER to
# rebuild the pre-built blobs that are checked into the layer. Normal users
# do NOT need to run this - they use the checked-in blobs automatically via
# container-cross-initramfs-native.
#
# The unified initramfs contains BOTH Docker and Podman tools, allowing
# runtime selection via kernel cmdline parameter: runtime=docker|podman
#
# ===========================================================================
# MAINTAINER WORKFLOW - Building and Checking In New Blobs
# ===========================================================================
#
# Step 1: Build for aarch64 (ARM64)
# ---------------------------------
#   cd /path/to/poky
#   source oe-init-build-env
#
#   # Ensure MACHINE is set (in local.conf or command line)
#   MACHINE=qemuarm64 bitbake container-cross-initramfs-build
#
# Step 2: Copy aarch64 blobs to layer
# -----------------------------------
#   cp tmp/deploy/images/qemuarm64/container-cross-initramfs/Image \
#      meta-virtualization/recipes-containers/container-cross-initramfs/files/aarch64/
#
#   cp tmp/deploy/images/qemuarm64/container-cross-initramfs/initramfs.cpio.gz \
#      meta-virtualization/recipes-containers/container-cross-initramfs/files/aarch64/
#
# Step 3: Build for x86_64
# ------------------------
#   MACHINE=qemux86-64 bitbake container-cross-initramfs-build
#
# Step 4: Copy x86_64 blobs to layer
# ----------------------------------
#   cp tmp/deploy/images/qemux86-64/container-cross-initramfs/bzImage \
#      meta-virtualization/recipes-containers/container-cross-initramfs/files/x86_64/
#
#   cp tmp/deploy/images/qemux86-64/container-cross-initramfs/initramfs.cpio.gz \
#      meta-virtualization/recipes-containers/container-cross-initramfs/files/x86_64/
#
# Step 5: Commit to layer
# -----------------------
#   cd meta-virtualization
#   git add recipes-containers/container-cross-initramfs/files/
#   git commit -m "container-cross-initramfs: update pre-built blobs"
#
# ===========================================================================
# WHAT'S IN THE INITRAMFS
# ===========================================================================
#
# Docker tools:
#   - docker, dockerd, containerd, containerd-shim-runc-v2
#   - docker-init, docker-proxy
#
# Podman tools:
#   - podman, skopeo, conmon
#
# OCI runtimes (shared):
#   - runc, crun
#
# Core:
#   - busybox (shell, coreutils)
#   - glibc, libseccomp, libcap, yajl
#   - systemd (libsystemd.so.0 required by dockerd)
#
# Configuration:
#   - Podman policy.json, storage.conf, containers.conf
#   - Basic passwd/group for user lookups
#
# ===========================================================================

SUMMARY = "Build unified QEMU initramfs for container cross-install"
DESCRIPTION = "Builds a minimal initramfs containing both Docker and Podman \
               tools for processing containers in QEMU. The resulting blobs \
               are intended to be checked into the layer for distribution."
HOMEPAGE = "https://github.com/anthropics/meta-virtualization"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Inherit deploy class for proper DEPLOYDIR handling
inherit deploy

# Only built on demand by maintainer - not part of world build
EXCLUDE_FROM_WORLD = "1"

# Disable sstate for this recipe - it's rarely run and sstate causes
# confusion when iterating on initramfs contents
SSTATE_SKIP_CREATION = "1"

# This is a target recipe (not native) because we need target binaries
# for the initramfs that will run under QEMU emulation

# Dependencies - we need the packages to be built so we can extract binaries
# Note: We use do_package_write_rpm to ensure binaries are fully built
DEPENDS = "virtual/kernel"

# We extract binaries from the package image directories after do_install
# This ensures we get the actual target binaries, not just sysroot headers
do_compile[depends] = "busybox:do_install \
                       skopeo:do_install \
                       podman:do_install \
                       crun:do_install \
                       runc:do_install \
                       conmon:do_install \
                       docker-moby:do_install \
                       containerd:do_install \
                       glibc:do_install \
                       libseccomp:do_install \
                       libcap:do_install \
                       yajl:do_install \
                       systemd:do_install \
                       gpgme:do_install \
                       libassuan:do_install \
                       libgpg-error:do_install \
                       nftables:do_install \
                       libmnl:do_install \
                       libnftnl:do_install \
                       jansson:do_install \
                       virtual/kernel:do_deploy"

# Base workdir for target packages (under tmp/work/<tune>/)
PKGWORK_BASE = "${TMPDIR}/work/${TUNE_PKGARCH}-poky-linux"

# Include the unified init script
SRC_URI = "file://container-cross-init.sh"

S = "${UNPACKDIR}"
B = "${WORKDIR}/build"

# Map architecture to kernel image name
def get_kernel_image_name(d):
    arch = d.getVar('TARGET_ARCH')
    if arch == 'aarch64':
        return 'Image'
    elif arch in ['x86_64', 'i686', 'i586']:
        return 'bzImage'
    elif arch == 'arm':
        return 'zImage'
    return 'Image'

KERNEL_IMAGETYPE_INITRAMFS = "${@get_kernel_image_name(d)}"

do_compile() {
    # Create initramfs directory structure
    INITRAMFS_DIR="${B}/initramfs"
    rm -rf ${INITRAMFS_DIR}
    mkdir -p ${INITRAMFS_DIR}/bin
    mkdir -p ${INITRAMFS_DIR}/sbin
    mkdir -p ${INITRAMFS_DIR}/lib
    mkdir -p ${INITRAMFS_DIR}/lib64
    mkdir -p ${INITRAMFS_DIR}/usr/bin
    mkdir -p ${INITRAMFS_DIR}/usr/sbin
    mkdir -p ${INITRAMFS_DIR}/usr/lib
    mkdir -p ${INITRAMFS_DIR}/usr/lib64
    mkdir -p ${INITRAMFS_DIR}/proc
    mkdir -p ${INITRAMFS_DIR}/sys
    mkdir -p ${INITRAMFS_DIR}/dev
    mkdir -p ${INITRAMFS_DIR}/tmp
    mkdir -p ${INITRAMFS_DIR}/run
    mkdir -p ${INITRAMFS_DIR}/mnt/input
    mkdir -p ${INITRAMFS_DIR}/var/lib/docker
    mkdir -p ${INITRAMFS_DIR}/var/lib/containers/storage
    mkdir -p ${INITRAMFS_DIR}/var/run
    mkdir -p ${INITRAMFS_DIR}/var/tmp
    mkdir -p ${INITRAMFS_DIR}/run/containerd
    mkdir -p ${INITRAMFS_DIR}/run/containers/storage
    mkdir -p ${INITRAMFS_DIR}/run/lock
    mkdir -p ${INITRAMFS_DIR}/etc/containers
    mkdir -p ${INITRAMFS_DIR}/root/.local/share/containers
    mkdir -p ${INITRAMFS_DIR}/root/.config/containers
    mkdir -p ${INITRAMFS_DIR}/usr/libexec/podman
    chmod 1777 ${INITRAMFS_DIR}/var/tmp

    bbnote "Building unified initramfs for ${TARGET_ARCH}"

    # Helper function to find a binary from a package's image directory
    # Usage: find_and_copy_binary <package-name> <binary-name> <dest-path>
    find_and_copy_binary() {
        local pkg_pattern="$1"
        local binary_name="$2"
        local dest_path="$3"

        # Search in the package's image directory
        # Path format: PKGWORK_BASE/<package>/<version>/image/
        local found_binary=""
        for pkg_dir in ${PKGWORK_BASE}/${pkg_pattern}/*/image; do
            if [ -d "$pkg_dir" ]; then
                for search_path in usr/bin usr/sbin bin sbin usr/libexec/podman; do
                    if [ -f "$pkg_dir/$search_path/$binary_name" ]; then
                        found_binary="$pkg_dir/$search_path/$binary_name"
                        break 2
                    fi
                done
            fi
        done

        if [ -n "$found_binary" ]; then
            cp "$found_binary" "$dest_path"
            chmod +x "$dest_path"
            bbnote "Copied $binary_name from $found_binary"
            return 0
        else
            bbnote "Binary $binary_name not found for package pattern $pkg_pattern"
            return 1
        fi
    }

    # =========================================================================
    # BUSYBOX - Core utilities
    # =========================================================================
    bbnote "Adding busybox..."
    if ! find_and_copy_binary "busybox" "busybox" "${INITRAMFS_DIR}/bin/busybox"; then
        bbfatal "busybox not found"
    fi

    # Create busybox symlinks for required commands
    cd ${INITRAMFS_DIR}/bin
    for cmd in sh ash mount umount mkdir cat echo sleep tar kill ps find \
               head tail grep cut wc stat ln cp mv rm ls chmod chown test \
               true false sort awk sed gzip gunzip sync dd printf tee base64 \
               tr fold id whoami file seq mknod; do
        ln -sf busybox $cmd 2>/dev/null || true
    done
    cd -

    # =========================================================================
    # PODMAN TOOLS
    # =========================================================================
    bbnote "Adding Podman tools..."
    find_and_copy_binary "skopeo" "skopeo" "${INITRAMFS_DIR}/usr/bin/skopeo" || true
    find_and_copy_binary "podman" "podman" "${INITRAMFS_DIR}/usr/bin/podman" || true
    if find_and_copy_binary "conmon" "conmon" "${INITRAMFS_DIR}/usr/bin/conmon"; then
        cp "${INITRAMFS_DIR}/usr/bin/conmon" "${INITRAMFS_DIR}/usr/libexec/podman/conmon"
    fi

    # =========================================================================
    # DOCKER TOOLS
    # =========================================================================
    bbnote "Adding Docker tools..."
    find_and_copy_binary "docker-moby" "docker" "${INITRAMFS_DIR}/usr/bin/docker" || true
    find_and_copy_binary "docker-moby" "dockerd" "${INITRAMFS_DIR}/usr/bin/dockerd" || true
    find_and_copy_binary "containerd" "containerd" "${INITRAMFS_DIR}/usr/bin/containerd" || true
    find_and_copy_binary "containerd" "containerd-shim-runc-v2" "${INITRAMFS_DIR}/usr/bin/containerd-shim-runc-v2" || true
    find_and_copy_binary "docker-moby" "docker-init" "${INITRAMFS_DIR}/usr/bin/docker-init" || true
    find_and_copy_binary "docker-moby" "docker-proxy" "${INITRAMFS_DIR}/usr/bin/docker-proxy" || true

    # =========================================================================
    # OCI RUNTIMES (shared by both Docker and Podman)
    # =========================================================================
    bbnote "Adding OCI runtimes..."

    # Try runc first
    RUNC_COPIED=false
    if find_and_copy_binary "runc" "runc" "${INITRAMFS_DIR}/usr/bin/runc"; then
        RUNC_COPIED=true
    fi

    # Try crun
    if find_and_copy_binary "crun" "crun" "${INITRAMFS_DIR}/usr/bin/crun"; then
        # If runc wasn't found, create symlink
        if [ "$RUNC_COPIED" = "false" ]; then
            ln -sf crun ${INITRAMFS_DIR}/usr/bin/runc
            bbnote "Created runc -> crun symlink"
        fi
    fi

    # =========================================================================
    # SHARED LIBRARIES
    # =========================================================================
    bbnote "Copying shared libraries from glibc..."

    # Copy libraries from glibc's image directory
    # Path format: PKGWORK_BASE/<package>/<version>/image/
    GLIBC_IMAGE=""
    for glibc_dir in ${PKGWORK_BASE}/glibc/*/image; do
        if [ -d "$glibc_dir" ]; then
            GLIBC_IMAGE="$glibc_dir"
            break
        fi
    done

    if [ -n "$GLIBC_IMAGE" ] && [ -d "$GLIBC_IMAGE" ]; then
        # Check for usrmerge (lib -> usr/lib symlink)
        if [ -L "${GLIBC_IMAGE}/lib" ]; then
            bbnote "Detected usrmerge layout"
            # Copy from usr/lib and usr/lib64 only
            for lib_dir in usr/lib usr/lib64; do
                if [ -d "${GLIBC_IMAGE}/${lib_dir}" ]; then
                    mkdir -p ${INITRAMFS_DIR}/${lib_dir}
                    find "${GLIBC_IMAGE}/${lib_dir}" -maxdepth 1 \
                        \( -name "*.so*" -o -name "ld-*" \) -type f \
                        -exec cp {} ${INITRAMFS_DIR}/${lib_dir}/ \; 2>/dev/null || true
                    find "${GLIBC_IMAGE}/${lib_dir}" -maxdepth 1 \
                        \( -name "*.so*" -o -name "ld-*" \) -type l \
                        -exec cp -P {} ${INITRAMFS_DIR}/${lib_dir}/ \; 2>/dev/null || true
                fi
            done
            # Create usrmerge symlinks
            rm -rf ${INITRAMFS_DIR}/lib 2>/dev/null || true
            ln -sf usr/lib ${INITRAMFS_DIR}/lib
            if [ -d "${INITRAMFS_DIR}/usr/lib64" ]; then
                rm -rf ${INITRAMFS_DIR}/lib64 2>/dev/null || true
                ln -sf usr/lib64 ${INITRAMFS_DIR}/lib64
            fi
        else
            bbnote "Traditional (non-usrmerge) layout"
            for lib_dir in lib lib64 usr/lib usr/lib64; do
                if [ -d "${GLIBC_IMAGE}/${lib_dir}" ]; then
                    mkdir -p ${INITRAMFS_DIR}/${lib_dir}
                    find "${GLIBC_IMAGE}/${lib_dir}" -maxdepth 1 \
                        \( -name "*.so*" -o -name "ld-*" \) -type f \
                        -exec cp {} ${INITRAMFS_DIR}/${lib_dir}/ \; 2>/dev/null || true
                    find "${GLIBC_IMAGE}/${lib_dir}" -maxdepth 1 \
                        \( -name "*.so*" -o -name "ld-*" \) -type l \
                        -exec cp -P {} ${INITRAMFS_DIR}/${lib_dir}/ \; 2>/dev/null || true
                fi
            done
        fi
    else
        bbwarn "glibc image directory not found"
    fi

    # Also copy libraries from other packages that may have additional deps
    # systemd provides libsystemd.so.0 required by dockerd
    # gpgme/libassuan/libgpg-error are required by skopeo
    # nftables provides libnftables.so.1 required by dockerd
    # libmnl, libnftnl, jansson are nftables dependencies
    for pkg_pattern in libseccomp libcap yajl systemd gpgme libassuan libgpg-error nftables libmnl libnftnl jansson; do
        for pkg_dir in ${PKGWORK_BASE}/${pkg_pattern}/*/image; do
            if [ -d "$pkg_dir" ]; then
                for lib_dir in lib lib64 usr/lib usr/lib64; do
                    if [ -d "${pkg_dir}/${lib_dir}" ]; then
                        mkdir -p ${INITRAMFS_DIR}/${lib_dir} 2>/dev/null || true
                        find "${pkg_dir}/${lib_dir}" -maxdepth 1 \
                            \( -name "*.so*" \) -type f \
                            -exec cp {} ${INITRAMFS_DIR}/${lib_dir}/ \; 2>/dev/null || true
                        find "${pkg_dir}/${lib_dir}" -maxdepth 1 \
                            \( -name "*.so*" \) -type l \
                            -exec cp -P {} ${INITRAMFS_DIR}/${lib_dir}/ \; 2>/dev/null || true
                    fi
                done
                break
            fi
        done
    done

    # Count libraries
    LIB_COUNT=$(find ${INITRAMFS_DIR} -name "*.so*" 2>/dev/null | wc -l)
    bbnote "Copied ${LIB_COUNT} shared library files"

    # =========================================================================
    # CONFIGURATION FILES
    # =========================================================================
    bbnote "Creating configuration files..."

    # Podman containers policy (allow all)
    cat > ${INITRAMFS_DIR}/etc/containers/policy.json << 'EOF'
{"default":[{"type":"insecureAcceptAnything"}]}
EOF

    # Podman storage.conf (VFS driver for cross-compilation compatibility)
    cat > ${INITRAMFS_DIR}/etc/containers/storage.conf << 'EOF'
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF

    # Podman containers.conf (disable networking)
    cat > ${INITRAMFS_DIR}/etc/containers/containers.conf << 'EOF'
[network]
network_backend = "none"

[engine]
cgroup_manager = "cgroupfs"
events_logger = "none"
EOF

    # Basic passwd and group files (required for user lookups)
    cat > ${INITRAMFS_DIR}/etc/passwd << 'EOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF

    cat > ${INITRAMFS_DIR}/etc/group << 'EOF'
root:x:0:
nobody:x:65534:
EOF

    # subuid/subgid for rootless podman
    cat > ${INITRAMFS_DIR}/etc/subuid << 'EOF'
root:100000:65536
EOF

    cat > ${INITRAMFS_DIR}/etc/subgid << 'EOF'
root:100000:65536
EOF

    # nsswitch.conf for user/group lookup
    cat > ${INITRAMFS_DIR}/etc/nsswitch.conf << 'EOF'
passwd:     files
group:      files
shadow:     files
hosts:      files dns
networks:   files
protocols:  files
services:   files
ethers:     files
rpc:        files
EOF

    # =========================================================================
    # INIT SCRIPT
    # =========================================================================
    bbnote "Installing unified init script..."
    cp ${S}/container-cross-init.sh ${INITRAMFS_DIR}/init
    chmod +x ${INITRAMFS_DIR}/init

    # =========================================================================
    # CREATE CPIO ARCHIVE
    # =========================================================================
    bbnote "Creating initramfs cpio archive..."
    cd ${INITRAMFS_DIR}
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > ${B}/initramfs.cpio.gz
    cd -

    INITRAMFS_SIZE=$(stat -c%s ${B}/initramfs.cpio.gz)
    bbnote "Initramfs created: ${INITRAMFS_SIZE} bytes ($(expr ${INITRAMFS_SIZE} / 1024 / 1024)MB)"

    # =========================================================================
    # COPY KERNEL
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

# This recipe only produces deploy artifacts - skip normal install/package tasks
do_install[noexec] = "1"
do_package[noexec] = "1"
do_packagedata[noexec] = "1"
do_package_write_rpm[noexec] = "1"
do_package_write_ipk[noexec] = "1"
do_package_write_deb[noexec] = "1"
do_populate_sysroot[noexec] = "1"

do_deploy() {
    install -d ${DEPLOYDIR}/container-cross-initramfs

    # Install initramfs
    if [ -f ${B}/initramfs.cpio.gz ]; then
        install -m 0644 ${B}/initramfs.cpio.gz \
            ${DEPLOYDIR}/container-cross-initramfs/
        bbnote "Deployed initramfs.cpio.gz"
    fi

    # Install kernel with architecture-appropriate name
    if [ -f ${B}/kernel ]; then
        install -m 0644 ${B}/kernel \
            ${DEPLOYDIR}/container-cross-initramfs/${KERNEL_IMAGETYPE_INITRAMFS}
        bbnote "Deployed kernel as ${KERNEL_IMAGETYPE_INITRAMFS}"
    fi

    # Create a README with instructions
    cat > ${DEPLOYDIR}/container-cross-initramfs/README << EOF
Container Cross-Install Initramfs Blobs
=======================================

Built for: ${TARGET_ARCH}
Machine: ${MACHINE}
Date: $(date)

Files:
  ${KERNEL_IMAGETYPE_INITRAMFS}  - Kernel image for QEMU
  initramfs.cpio.gz              - Unified initramfs (Docker + Podman)

To install these blobs into the layer:

  # For aarch64:
  cp ${KERNEL_IMAGETYPE_INITRAMFS} \\
     meta-virtualization/recipes-containers/container-cross-initramfs/files/aarch64/Image
  cp initramfs.cpio.gz \\
     meta-virtualization/recipes-containers/container-cross-initramfs/files/aarch64/

  # For x86_64:
  cp ${KERNEL_IMAGETYPE_INITRAMFS} \\
     meta-virtualization/recipes-containers/container-cross-initramfs/files/x86_64/bzImage
  cp initramfs.cpio.gz \\
     meta-virtualization/recipes-containers/container-cross-initramfs/files/x86_64/

Then commit the blobs to the layer.
EOF

    # Visible reminder to copy blobs
    bbwarn "============================================================"
    bbwarn "Initramfs blobs built for ${TARGET_ARCH} (${MACHINE})"
    bbwarn ""
    bbwarn "To use these blobs, either:"
    bbwarn "  1. Add to local.conf: CONTAINER_CROSS_USE_DEPLOY = \"1\""
    bbwarn "  2. Or copy to layer:"
    bbwarn "     cp ${DEPLOYDIR}/container-cross-initramfs/* \\"
    bbwarn "        meta-virtualization/recipes-containers/container-cross-initramfs/files/${BLOB_ARCH}/"
    bbwarn "============================================================"
}

addtask deploy after do_compile before do_build

# Ensure kernel is deployed before we try to copy it
do_compile[depends] += "virtual/kernel:do_deploy"

# Optional task to copy blobs directly to layer
# Run manually: bitbake container-cross-initramfs-build -c copy_to_layer
do_copy_to_layer() {
    LAYER_DIR="${@os.path.dirname(d.getVar('FILE'))}/files/${BLOB_ARCH}"

    if [ ! -d "${LAYER_DIR}" ]; then
        bbfatal "Layer directory not found: ${LAYER_DIR}"
    fi

    if [ ! -f "${DEPLOYDIR}/container-cross-initramfs/initramfs.cpio.gz" ]; then
        bbfatal "Blobs not found in DEPLOY_DIR - run do_deploy first"
    fi

    install -m 0644 "${DEPLOYDIR}/container-cross-initramfs/initramfs.cpio.gz" "${LAYER_DIR}/"
    install -m 0644 "${DEPLOYDIR}/container-cross-initramfs/${KERNEL_IMAGETYPE_INITRAMFS}" "${LAYER_DIR}/"

    bbwarn "============================================================"
    bbwarn "Copied blobs to: ${LAYER_DIR}/"
    bbwarn "Files:"
    ls -la "${LAYER_DIR}/" | while read line; do bbwarn "  $line"; done
    bbwarn ""
    bbwarn "Remember to:"
    bbwarn "  1. git add ${LAYER_DIR}/"
    bbwarn "  2. git commit -m 'container-cross-initramfs: update ${BLOB_ARCH} blobs'"
    bbwarn "  3. bitbake container-cross-initramfs-native -c cleanall"
    bbwarn "============================================================"
}
addtask copy_to_layer after do_deploy
do_copy_to_layer[nostamp] = "1"
