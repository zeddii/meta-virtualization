# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# vcontainer-native_1.0.bb
# ===========================================================================
# Standalone bundle of vdkr (Docker) and vpdmn (Podman) tools
# ===========================================================================
#
# This recipe creates a redistributable standalone tarball containing:
#   - vdkr: Emulated Docker CLI for cross-architecture containers
#   - vpdmn: Emulated Podman CLI for cross-architecture containers
#   - QEMU binaries and dependencies
#   - All required blobs (kernel, initramfs, rootfs)
#
# USAGE:
#   # Build the standalone tarball:
#   MACHINE=qemux86-64 bitbake vcontainer-native -c create_tarball
#
#   # Or for ARM64:
#   MACHINE=qemuarm64 bitbake vcontainer-native -c create_tarball
#
# OUTPUT:
#   tmp/deploy/vdkr/vcontainer-standalone-<arch>.tar.gz
#
# ===========================================================================

SUMMARY = "Standalone bundle of vdkr and vpdmn container tools"
DESCRIPTION = "Creates a redistributable tarball containing vdkr (Docker) \
               and vpdmn (Podman) CLI tools with all dependencies for \
               cross-architecture container operations."
HOMEPAGE = "https://github.com/anthropics/meta-virtualization"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit native

# Depend on both container tools
DEPENDS = "vdkr-native vpdmn-native qemu-system-native socat-native"

# No source - this recipe just bundles other recipes
SRC_URI = ""
S = "${WORKDIR}/sources"
do_unpack[noexec] = "1"
do_patch[noexec] = "1"

do_compile[noexec] = "1"
do_install[noexec] = "1"

# Task to create a standalone redistributable tarball
# Run with: MACHINE=qemux86-64 bitbake vcontainer-native -c create_tarball
# Output: tmp/deploy/vdkr/vcontainer-standalone-<arch>.tar.gz
python do_create_tarball() {
    import os
    import shutil
    import tarfile
    import subprocess
    import re

    # Blob search order (per tool):
    # 1. If VDKR_USE_DEPLOY=1 / VPDMN_USE_DEPLOY=1, check DEPLOY_DIR first
    # 2. Check multiconfig deploy directory (tmp-vruntime-*/deploy/...)
    # 3. Check layer files (files/blobs/vdkr/<arch>/, files/blobs/vpdmn/<arch>/)
    # 4. Fall back to main DEPLOY_DIR paths

    deploy_base = d.getVar('DEPLOY_DIR_IMAGE')
    topdir = d.getVar('TOPDIR')
    thisdir = d.getVar('THISDIR')
    machine = d.getVar('MACHINE')
    vdkr_use_deploy = d.getVar('VDKR_USE_DEPLOY') == '1'
    vpdmn_use_deploy = d.getVar('VPDMN_USE_DEPLOY') == '1'

    arch_map = {
        'qemuarm64': 'aarch64',
        'qemux86-64': 'x86_64',
    }
    mc_map = {
        'qemuarm64': 'vruntime-aarch64',
        'qemux86-64': 'vruntime-x86-64',
    }
    blob_arch = arch_map.get(machine, 'x86_64')
    multiconfig = mc_map.get(machine)

    # Multiconfig deploy directory
    if multiconfig:
        mc_deploy_base = os.path.join(topdir, 'tmp-%s' % multiconfig, 'deploy', 'images', machine)
    else:
        mc_deploy_base = None

    def find_blob_dir(tool_name, use_deploy_first):
        """Find blob directory for vdkr or vpdmn, respecting USE_DEPLOY preference"""
        # Possible locations in priority order
        deploy_new = os.path.join(deploy_base, tool_name, blob_arch)
        deploy_legacy = os.path.join(deploy_base, '%s-initramfs' % tool_name)
        layer_dir = os.path.join(thisdir, 'files', 'blobs', tool_name, blob_arch)

        # Multiconfig deploy paths
        mc_deploy = os.path.join(mc_deploy_base, tool_name, blob_arch) if mc_deploy_base else None

        if use_deploy_first:
            # DEPLOY first, then layer
            candidates = [deploy_new, mc_deploy, deploy_legacy, layer_dir]
        else:
            # Layer first, then DEPLOY (multiconfig takes priority over main deploy)
            candidates = [layer_dir, mc_deploy, deploy_new, deploy_legacy]

        for path in candidates:
            if path and os.path.isdir(path):
                return path
        return None

    vdkr_deploy = find_blob_dir('vdkr', vdkr_use_deploy)
    vpdmn_deploy = find_blob_dir('vpdmn', vpdmn_use_deploy)

    bb.plain("VDKR_USE_DEPLOY=%s, VPDMN_USE_DEPLOY=%s" % ('1' if vdkr_use_deploy else '0', '1' if vpdmn_use_deploy else '0'))
    bb.plain("Looking for vdkr blobs in: %s" % (vdkr_deploy or "(not found)"))
    bb.plain("Looking for vpdmn blobs in: %s" % (vpdmn_deploy or "(not found)"))

    # Get staging directories
    staging_native = d.getVar('RECIPE_SYSROOT_NATIVE')
    bindir = os.path.join(staging_native, 'usr', 'bin')

    deploy_dir = d.getVar('DEPLOY_DIR') + '/vdkr'
    workdir = d.getVar('WORKDIR')

    # Clean and create directories
    os.makedirs(deploy_dir, exist_ok=True)
    staging_base = os.path.join(workdir, 'tarball-staging')
    if os.path.exists(staging_base):
        shutil.rmtree(staging_base)

    staging_dir = os.path.join(staging_base, 'vcontainer-standalone')
    os.makedirs(staging_dir)

    # Track which architectures and tools are included
    arch_list = []
    vdkr_included = False
    vpdmn_included = False

    # Map MACHINE to architecture and kernel name
    arch_map = {
        'qemuarm64': ('aarch64', 'Image'),
        'qemux86-64': ('x86_64', 'bzImage'),
    }

    machine = d.getVar('MACHINE')
    if machine not in arch_map:
        bb.fatal("Unsupported MACHINE: %s. Use qemuarm64 or qemux86-64" % machine)

    arch, kernel_name = arch_map[machine]
    blob_files = [(kernel_name, kernel_name), ('initramfs.cpio.gz', 'initramfs.cpio.gz'), ('rootfs.img', 'rootfs.img')]

    # =========================================================================
    # VDKR (Docker)
    # =========================================================================
    vdkr_blobs_dest = os.path.join(staging_dir, 'vdkr-blobs')
    os.makedirs(vdkr_blobs_dest)

    if vdkr_deploy and os.path.isdir(vdkr_deploy):
        all_exist = all(os.path.exists(os.path.join(vdkr_deploy, f[0])) for f in blob_files)
        if all_exist:
            arch_dest = os.path.join(vdkr_blobs_dest, arch)
            os.makedirs(arch_dest, exist_ok=True)
            for src_name, dst_name in blob_files:
                src_path = os.path.join(vdkr_deploy, src_name)
                shutil.copy2(src_path, os.path.join(arch_dest, dst_name))
                bb.plain("Copied vdkr blob: %s -> %s/%s" % (src_name, arch, dst_name))
            vdkr_included = True
            if arch not in arch_list:
                arch_list.append(arch)

    if vdkr_included:
        # Copy vdkr.sh
        vdkr_src = os.path.join(thisdir, 'files', 'vdkr.sh')
        if os.path.exists(vdkr_src):
            shutil.copy2(vdkr_src, os.path.join(staging_dir, 'vdkr'))
            os.chmod(os.path.join(staging_dir, 'vdkr'), 0o755)
            os.symlink('vdkr', os.path.join(staging_dir, 'vdkr-%s' % arch))
            bb.plain("Installed vdkr script")
    else:
        bb.warn("vdkr blobs not found - vdkr will not be included")
        bb.warn("Build with: bitbake vdkr-initramfs-create")

    # =========================================================================
    # VPDMN (Podman)
    # =========================================================================
    vpdmn_blobs_dest = os.path.join(staging_dir, 'vpdmn-blobs')
    os.makedirs(vpdmn_blobs_dest)

    if vpdmn_deploy and os.path.isdir(vpdmn_deploy):
        all_exist = all(os.path.exists(os.path.join(vpdmn_deploy, f[0])) for f in blob_files)
        if all_exist:
            arch_dest = os.path.join(vpdmn_blobs_dest, arch)
            os.makedirs(arch_dest, exist_ok=True)
            for src_name, dst_name in blob_files:
                src_path = os.path.join(vpdmn_deploy, src_name)
                shutil.copy2(src_path, os.path.join(arch_dest, dst_name))
                bb.plain("Copied vpdmn blob: %s -> %s/%s" % (src_name, arch, dst_name))
            vpdmn_included = True
            if arch not in arch_list:
                arch_list.append(arch)

    if vpdmn_included:
        # Copy vpdmn.sh
        vpdmn_src = os.path.join(thisdir, 'files', 'vpdmn.sh')
        if os.path.exists(vpdmn_src):
            shutil.copy2(vpdmn_src, os.path.join(staging_dir, 'vpdmn'))
            os.chmod(os.path.join(staging_dir, 'vpdmn'), 0o755)
            os.symlink('vpdmn', os.path.join(staging_dir, 'vpdmn-%s' % arch))
            bb.plain("Installed vpdmn script")
    else:
        bb.plain("vpdmn blobs not found - vpdmn will not be included")
        bb.plain("Build with: bitbake vpdmn-initramfs-create")

    # Check that at least one tool is included
    if not vdkr_included and not vpdmn_included:
        bb.fatal("No container tools found! Build blobs first:\n"
                 "  bitbake vdkr-initramfs-create\n"
                 "  bitbake vpdmn-initramfs-create")

    # =========================================================================
    # SHARED SCRIPTS
    # =========================================================================
    # Copy vrunner.sh (shared QEMU runner)
    run_script = os.path.join(bindir, 'vrunner.sh')
    if os.path.exists(run_script):
        shutil.copy2(run_script, staging_dir)
        bb.plain("Copied vrunner.sh (shared runner)")
    else:
        # Try from files directory
        run_script = os.path.join(thisdir, 'files', 'vrunner.sh')
        if os.path.exists(run_script):
            shutil.copy2(run_script, staging_dir)
            bb.plain("Copied vrunner.sh from files/")
        else:
            bb.fatal("vrunner.sh not found!")

    # Copy vcontainer-common.sh (shared CLI code for vdkr/vpdmn)
    common_script = os.path.join(thisdir, 'files', 'vcontainer-common.sh')
    if os.path.exists(common_script):
        shutil.copy2(common_script, staging_dir)
        bb.plain("Copied vcontainer-common.sh (shared CLI code)")
    else:
        bb.fatal("vcontainer-common.sh not found!")

    # =========================================================================
    # QEMU AND LIBRARIES
    # =========================================================================
    qemu_dir = os.path.join(staging_dir, 'qemu')
    lib_dir = os.path.join(staging_dir, 'lib')
    os.makedirs(qemu_dir)
    os.makedirs(lib_dir)

    # Collect all libraries needed by QEMU binaries
    sysroot_lib_dirs = [
        os.path.join(staging_native, 'usr', 'lib'),
        os.path.join(staging_native, 'lib'),
        os.path.join(staging_native, 'usr', 'lib64'),
        os.path.join(staging_native, 'lib64'),
    ]

    copied_libs = set()

    # System libraries that should NOT be bundled
    SKIP_LIBS = {
        'libc.so', 'libm.so', 'libpthread.so', 'libdl.so', 'librt.so',
        'libresolv.so', 'libnss_', 'libcrypt.so', 'libutil.so',
        'ld-linux', 'linux-vdso', 'libgcc_s.so', 'libstdc++.so',
    }

    def should_skip_lib(libname):
        for skip in SKIP_LIBS:
            if libname.startswith(skip) or skip in libname:
                return True
        return False

    def find_lib_in_sysroot(libname):
        for lib_path in sysroot_lib_dirs:
            if not os.path.isdir(lib_path):
                continue
            full_path = os.path.join(lib_path, libname)
            if os.path.exists(full_path):
                return full_path
            for f in os.listdir(lib_path):
                if f.startswith(libname.split('.so')[0]) and '.so' in f:
                    return os.path.join(lib_path, f)
        return None

    def copy_lib_and_deps(binary_path, depth=0):
        if depth > 10:
            return
        try:
            result = subprocess.run(['ldd', binary_path],
                                    capture_output=True, text=True,
                                    env={'LD_LIBRARY_PATH': ':'.join(sysroot_lib_dirs)})
            output = result.stdout + result.stderr
        except Exception as e:
            bb.warn("ldd failed for %s: %s" % (binary_path, str(e)))
            return

        for line in output.split('\n'):
            match = re.match(r'\s*(\S+\.so\S*)\s+=>\s+(\S+)\s+\(', line)
            if match:
                libname = match.group(1)
                libpath = match.group(2)

                if libname in copied_libs:
                    continue
                if should_skip_lib(libname):
                    continue

                sysroot_path = find_lib_in_sysroot(libname)
                if sysroot_path:
                    libpath = sysroot_path
                elif libpath.startswith('/lib') or libpath.startswith('/usr/lib'):
                    continue

                if libpath and os.path.exists(libpath) and libpath != 'not':
                    dest = os.path.join(lib_dir, libname)
                    if not os.path.exists(dest):
                        try:
                            real_path = os.path.realpath(libpath)
                            if os.path.isfile(real_path):
                                shutil.copy2(real_path, dest)
                                copied_libs.add(libname)
                                copy_lib_and_deps(dest, depth + 1)
                        except Exception as e:
                            bb.warn("Failed to copy %s: %s" % (libpath, str(e)))

    # Copy QEMU binaries
    for qemu in ['qemu-system-aarch64', 'qemu-system-x86_64']:
        src = os.path.join(staging_native, 'usr', 'bin', qemu)
        if os.path.exists(src):
            shutil.copy2(src, qemu_dir)
            copy_lib_and_deps(src)

    # Copy socat
    socat_src = os.path.join(staging_native, 'usr', 'bin', 'socat')
    if os.path.exists(socat_src):
        shutil.copy2(socat_src, staging_dir)
        copy_lib_and_deps(socat_src)
        bb.plain("Bundled socat")

    bb.plain("Bundled %d libraries" % len(copied_libs))

    # Copy QEMU datafiles
    qemu_datadir_src = os.path.join(staging_native, 'usr', 'share', 'qemu')
    qemu_datadir_dst = os.path.join(staging_dir, 'share', 'qemu')
    if os.path.isdir(qemu_datadir_src):
        shutil.copytree(qemu_datadir_src, qemu_datadir_dst)
        bb.plain("Bundled QEMU datafiles")

    # Create QEMU wrapper scripts
    for qemu in ['qemu-system-aarch64', 'qemu-system-x86_64']:
        qemu_path = os.path.join(qemu_dir, qemu)
        if os.path.exists(qemu_path):
            os.rename(qemu_path, qemu_path + '.bin')
            with open(qemu_path, 'w') as f:
                f.write('''#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="${SCRIPT_DIR}/../lib:${LD_LIBRARY_PATH}"
exec "${SCRIPT_DIR}/%s.bin" -L "${SCRIPT_DIR}/../share/qemu" "$@"
''' % qemu)
            os.chmod(qemu_path, 0o755)

    # =========================================================================
    # SETUP SCRIPTS
    # =========================================================================

    # Create init-env.sh
    vdkr_usage = ""
    if vdkr_included:
        vdkr_usage = '''
echo "vdkr (Docker) commands:"
echo "  vdkr images              # List docker images"
echo "  vdkr -a %s images        # Explicit architecture"
echo "  vdkr vimport ./oci/ app  # Import OCI directory"
''' % arch

    vpdmn_usage = ""
    if vpdmn_included:
        vpdmn_usage = '''
echo "vpdmn (Podman) commands:"
echo "  vpdmn images             # List podman images"
echo "  vpdmn -a %s images       # Explicit architecture"
''' % arch

    setup_script = os.path.join(staging_dir, 'init-env.sh')
    with open(setup_script, 'w') as f:
        f.write('''#!/bin/bash
# Source this file to set up vdkr/vpdmn environment
# Usage: source init-env.sh

VCONTAINER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="${VCONTAINER_DIR}:${VCONTAINER_DIR}/qemu:/usr/bin:/bin:${PATH}"

echo "vcontainer environment configured."
echo ""
%s%s
echo "Set default architecture:"
echo "  mkdir -p ~/.config/vdkr && echo '%s' > ~/.config/vdkr/arch"
''' % (vdkr_usage, vpdmn_usage, arch))
    os.chmod(setup_script, 0o755)

    # Create README
    tools_list = []
    if vdkr_included:
        tools_list.append("vdkr (Docker)")
    if vpdmn_included:
        tools_list.append("vpdmn (Podman)")

    readme = os.path.join(staging_dir, 'README.txt')
    with open(readme, 'w') as f:
        f.write('''vcontainer Standalone Package
================================

This is a self-contained distribution of: %s

Architecture: %s

Quick Start:
  source init-env.sh
%s%s
Contents:
  vrunner.sh       - QEMU runner (shared by vdkr and vpdmn)
  qemu/             - QEMU system emulators
  lib/              - Shared libraries
  share/qemu/       - QEMU firmware and datafiles
  socat             - Socket communication tool
  init-env.sh       - Environment setup script
%s%s
Requirements:
  - Linux x86_64 host
  - bash

For more information, see:
  https://github.com/anthropics/meta-virtualization
''' % (
    ', '.join(tools_list),
    arch,
    '  vdkr images      # Docker\n' if vdkr_included else '',
    '  vpdmn images     # Podman\n' if vpdmn_included else '',
    '  vdkr, vdkr-blobs/  - Docker CLI and blobs\n' if vdkr_included else '',
    '  vpdmn, vpdmn-blobs/  - Podman CLI and blobs\n' if vpdmn_included else '',
))

    # =========================================================================
    # CREATE TARBALL
    # =========================================================================
    tarball_name = 'vcontainer-standalone-%s' % arch
    tarball_path = os.path.join(deploy_dir, tarball_name + '.tar.gz')

    with tarfile.open(tarball_path, 'w:gz') as tar:
        tar.add(staging_dir, arcname='vcontainer-standalone')

    tarball_size = os.path.getsize(tarball_path)
    tarball_size_mb = tarball_size // (1024 * 1024)

    bb.plain("")
    bb.plain("=" * 70)
    bb.plain("vcontainer standalone tarball created:")
    bb.plain("  %s" % tarball_path)
    bb.plain("  Size: %d MB" % tarball_size_mb)
    bb.plain("  Architecture: %s" % arch)
    bb.plain("  vdkr (Docker): %s" % ("included" if vdkr_included else "NOT included"))
    bb.plain("  vpdmn (Podman): %s" % ("included" if vpdmn_included else "NOT included"))
    bb.plain("")
    bb.plain("To use:")
    bb.plain("  tar -xzf %s.tar.gz" % tarball_name)
    bb.plain("  cd vcontainer-standalone")
    bb.plain("  source init-env.sh")
    if vdkr_included:
        bb.plain("  vdkr images      # Docker")
    if vpdmn_included:
        bb.plain("  vpdmn images     # Podman")
    bb.plain("=" * 70)
}
addtask create_tarball
do_create_tarball[nostamp] = "1"
do_create_tarball[depends] = "qemu-system-native:do_populate_sysroot socat-native:do_populate_sysroot"

# Trigger multiconfig blob builds based on MACHINE
# This ensures blobs are built before create_tarball runs
def get_blob_mcdepends(d):
    machine = d.getVar('MACHINE')
    mc_map = {
        'qemuarm64': 'vruntime-aarch64',
        'qemux86-64': 'vruntime-x86-64',
    }
    mc = mc_map.get(machine)
    if mc:
        return "mc::%s:vdkr-initramfs-create:do_deploy mc::%s:vpdmn-initramfs-create:do_deploy" % (mc, mc)
    return ""

do_create_tarball[mcdepends] = "${@get_blob_mcdepends(d)}"
