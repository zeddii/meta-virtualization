# vdkr-native_1.0.bb
# ===========================================================================
# Emulated Docker for cross-architecture container operations
# ===========================================================================
#
# vdkr provides a Docker-like CLI that executes arbitrary docker commands
# inside a QEMU-emulated environment with the target architecture's Docker
# daemon. Commands like "docker load", "docker export", "docker images" etc
# are passed through to Docker running inside QEMU and results streamed back.
#
# vdkr uses its own initramfs (built by vdkr-initramfs-create) which
# has vdkr-init.sh baked in. This is separate from container-cross-install.
#
# USAGE:
#   vdkr-aarch64 images
#   vdkr-aarch64 vimport ./container-oci/ myapp:latest
#   vdkr-x86_64 load -i myimage.tar
#
# Each architecture has its own executable with embedded blob paths.
# No default "vdkr" command exists to prevent architecture confusion.
#
# DEPENDENCIES:
#   - Kernel/initramfs blobs from vdkr-initramfs-create
#   - QEMU system emulator (qemu-system-native)
#
# ===========================================================================

SUMMARY = "Emulated Docker for cross-architecture container operations"
DESCRIPTION = "Provides vdkr CLI that executes docker commands inside \
               QEMU-emulated environment. Useful for building/manipulating \
               containers for target architectures on a different host."
HOMEPAGE = "https://github.com/anthropics/meta-virtualization"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit native

# Dependencies
DEPENDS = "qemu-system-native coreutils-native"

# vdkr-init.sh is now baked into the initramfs, not installed separately
SRC_URI = "\
    file://vdkr.sh \
    file://vdkr-run.sh \
"

# Pre-built blobs are optional - they're checked into the layer after being
# built by vdkr-initramfs-build. If not present, vdkr will still build
# but will require --blob-dir at runtime.
#
# To build blobs:
#   MACHINE=qemuarm64 bitbake vdkr-initramfs-build
#   MACHINE=qemux86-64 bitbake vdkr-initramfs-build
# Then copy from tmp/deploy/images/<machine>/vdkr-initramfs/ to files/blobs/<arch>/
#
# For development, set VDKR_USE_DEPLOY = "1" in local.conf to use blobs
# directly from DEPLOY_DIR instead of copying to layer.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Layer directory containing optional blobs
VDKR_LAYER_BLOBS = "${THISDIR}/files/blobs"

# Deploy directories (used when VDKR_USE_DEPLOY = "1")
VDKR_DEPLOY_AARCH64 = "${DEPLOY_DIR}/images/qemuarm64/vdkr-initramfs"
VDKR_DEPLOY_X86_64 = "${DEPLOY_DIR}/images/qemux86-64/vdkr-initramfs"

# Set to "1" in local.conf to prefer DEPLOY_DIR blobs over layer
VDKR_USE_DEPLOY ?= "0"

S = "${UNPACKDIR}"

do_install() {
    # Install architecture-specific executables
    # No generic "vdkr" command - must use vdkr-aarch64 or vdkr-x86_64
    install -d ${D}${bindir}
    install -d ${D}${bindir}/vdkr-blobs/aarch64
    install -d ${D}${bindir}/vdkr-blobs/x86_64

    # Install runner script (shared by all arch wrappers)
    install -m 0755 ${S}/vdkr-run.sh ${D}${bindir}/

    # Update runner to find blobs in vdkr-blobs subdir
    sed -i 's|\$SCRIPT_DIR/blobs|\$SCRIPT_DIR/vdkr-blobs|' \
        ${D}${bindir}/vdkr-run.sh

    # Determine blob source directories based on VDKR_USE_DEPLOY
    if [ "${VDKR_USE_DEPLOY}" = "1" ]; then
        AARCH64_SRC="${VDKR_DEPLOY_AARCH64}"
        X86_64_SRC="${VDKR_DEPLOY_X86_64}"
        bbwarn "============================================================"
        bbwarn "VDKR_USE_DEPLOY=1: Using blobs from DEPLOY_DIR"
        bbwarn "This is for development only. For permanent use, copy blobs:"
        bbwarn ""
        bbwarn "  # For aarch64:"
        bbwarn "  cp ${VDKR_DEPLOY_AARCH64}/Image \\"
        bbwarn "     ${VDKR_LAYER_BLOBS}/aarch64/"
        bbwarn "  cp ${VDKR_DEPLOY_AARCH64}/initramfs.cpio.gz \\"
        bbwarn "     ${VDKR_LAYER_BLOBS}/aarch64/"
        bbwarn ""
        bbwarn "  # For x86_64:"
        bbwarn "  cp ${VDKR_DEPLOY_X86_64}/bzImage \\"
        bbwarn "     ${VDKR_LAYER_BLOBS}/x86_64/"
        bbwarn "  cp ${VDKR_DEPLOY_X86_64}/initramfs.cpio.gz \\"
        bbwarn "     ${VDKR_LAYER_BLOBS}/x86_64/"
        bbwarn ""
        bbwarn "Then remove VDKR_USE_DEPLOY from local.conf"
        bbwarn "============================================================"
    else
        AARCH64_SRC="${VDKR_LAYER_BLOBS}/aarch64"
        X86_64_SRC="${VDKR_LAYER_BLOBS}/x86_64"
    fi

    # Install aarch64 blobs and create arch-specific wrapper
    # Requires: Image, initramfs.cpio.gz, rootfs.img
    if [ -f "$AARCH64_SRC/Image" ] && [ -f "$AARCH64_SRC/rootfs.img" ]; then
        install -m 0644 "$AARCH64_SRC/Image" ${D}${bindir}/vdkr-blobs/aarch64/
        install -m 0644 "$AARCH64_SRC/initramfs.cpio.gz" ${D}${bindir}/vdkr-blobs/aarch64/
        install -m 0644 "$AARCH64_SRC/rootfs.img" ${D}${bindir}/vdkr-blobs/aarch64/
        bbnote "Installed aarch64 blobs from $AARCH64_SRC"
        # Create arch-specific wrapper
        install -m 0755 ${S}/vdkr.sh ${D}${bindir}/vdkr-aarch64
        sed -i 's/DEFAULT_ARCH=.*/DEFAULT_ARCH="aarch64"/' ${D}${bindir}/vdkr-aarch64
    else
        bbnote "No aarch64 blobs found at $AARCH64_SRC - vdkr-aarch64 not installed"
        bbnote "Required: Image, initramfs.cpio.gz, rootfs.img"
    fi

    # Install x86_64 blobs and create arch-specific wrapper
    # Requires: bzImage, initramfs.cpio.gz, rootfs.img
    if [ -f "$X86_64_SRC/bzImage" ] && [ -f "$X86_64_SRC/rootfs.img" ]; then
        install -m 0644 "$X86_64_SRC/bzImage" ${D}${bindir}/vdkr-blobs/x86_64/
        install -m 0644 "$X86_64_SRC/initramfs.cpio.gz" ${D}${bindir}/vdkr-blobs/x86_64/
        install -m 0644 "$X86_64_SRC/rootfs.img" ${D}${bindir}/vdkr-blobs/x86_64/
        bbnote "Installed x86_64 blobs from $X86_64_SRC"
        # Create arch-specific wrapper
        install -m 0755 ${S}/vdkr.sh ${D}${bindir}/vdkr-x86_64
        sed -i 's/DEFAULT_ARCH=.*/DEFAULT_ARCH="x86_64"/' ${D}${bindir}/vdkr-x86_64
    else
        bbnote "No x86_64 blobs found at $X86_64_SRC - vdkr-x86_64 not installed"
        bbnote "Required: bzImage, initramfs.cpio.gz, rootfs.img"
    fi
}

# Make available in native sysroot
SYSROOT_DIRS += "${bindir}"

# Task to print usage instructions for using vdkr from current location
# Run with: bitbake vdkr-native -c print_usage
python do_print_usage() {
    import os
    bindir = d.getVar('D') + d.getVar('bindir')

    # Find the actual install location
    image_dir = d.getVar('D')
    native_sysroot = d.getVar('STAGING_DIR_NATIVE')

    bb.plain("")
    bb.plain("=" * 70)
    bb.plain("vdkr Usage Instructions")
    bb.plain("=" * 70)
    bb.plain("")
    bb.plain("Option 1: Add to PATH (recommended)")
    bb.plain("-" * 40)
    bb.plain("export PATH=\"%s:$PATH\"" % (native_sysroot + d.getVar('bindir')))
    bb.plain("")
    bb.plain("Then use:")
    bb.plain("  vdkr-x86_64 images")
    bb.plain("  vdkr-aarch64 vimport ./container-oci/ app:latest")
    bb.plain("")
    bb.plain("Option 2: Direct invocation")
    bb.plain("-" * 40)
    bb.plain("%s/vdkr-x86_64 images" % (native_sysroot + d.getVar('bindir')))
    bb.plain("%s/vdkr-aarch64 images" % (native_sysroot + d.getVar('bindir')))
    bb.plain("")
    bb.plain("Option 3: Copy to standalone location")
    bb.plain("-" * 40)
    bb.plain("cp -a %s/vdkr-* %s/vdkr-run.sh %s/vdkr-blobs /path/to/dest/" %
             (native_sysroot + d.getVar('bindir'),
              native_sysroot + d.getVar('bindir'),
              native_sysroot + d.getVar('bindir')))
    bb.plain("")
    bb.plain("Note: QEMU must be in PATH. If not found, also add:")
    bb.plain("export PATH=\"%s:$PATH\"" % (d.getVar('STAGING_BINDIR_NATIVE')))
    bb.plain("")
    bb.plain("=" * 70)
}
addtask print_usage
do_print_usage[nostamp] = "1"

# Task to create a standalone redistributable tarball
# Run with: bitbake vdkr-native -c create_tarball
# Output: tmp/deploy/vdkr/vdkr-standalone.tar.gz
python do_create_tarball() {
    import os
    import shutil
    import tarfile

    # For native recipes, bindir is an absolute path like:
    #   /path/to/build/tmp/work/x86_64-linux/vdkr-native/1.0/recipe-sysroot-native/usr/bin
    # D is the install directory, and files end up at ${D}${bindir} which is a deeply nested path
    # We need to find where the files actually are
    d_dir = d.getVar('D')
    bindir_var = d.getVar('bindir')

    # Try multiple possible locations
    possible_bindirs = [
        # Direct path (if bindir is relative like /usr/bin)
        os.path.join(d_dir, 'usr', 'bin'),
        # Full nested path (native recipes)
        d_dir + bindir_var,
        # Recipe sysroot (after populate_sysroot)
        d.getVar('RECIPE_SYSROOT_NATIVE') + '/usr/bin',
        # Staging native (shared sysroot)
        d.getVar('STAGING_DIR_NATIVE') + '/usr/bin',
    ]

    bindir = None
    for path in possible_bindirs:
        if os.path.exists(os.path.join(path, 'vdkr-run.sh')):
            bindir = path
            break

    if not bindir:
        bb.plain("Searched locations:")
        for path in possible_bindirs:
            bb.plain("  %s: %s" % (path, "EXISTS" if os.path.isdir(path) else "NOT FOUND"))
        bb.fatal("vdkr files not found in any known location")

    # For QEMU (different recipe), use the recipe sysroot
    staging_native = d.getVar('RECIPE_SYSROOT_NATIVE')

    deploy_dir = d.getVar('DEPLOY_DIR') + '/vdkr'
    workdir = d.getVar('WORKDIR')

    # Clean and create directories
    os.makedirs(deploy_dir, exist_ok=True)
    staging_base = os.path.join(workdir, 'tarball-staging')
    if os.path.exists(staging_base):
        shutil.rmtree(staging_base)

    # Use temp name for staging, will rename based on architectures found
    staging_dir = os.path.join(staging_base, 'vdkr-standalone')
    os.makedirs(staging_dir)

    # Copy vdkr executables and track which architectures are included
    arch_list = []
    arch_short = []  # For tarball naming: aarch64, x86_64
    for exe in ['vdkr-aarch64', 'vdkr-x86_64', 'vdkr-run.sh']:
        src = os.path.join(bindir, exe)
        if os.path.exists(src):
            shutil.copy2(src, staging_dir)
            if exe.startswith('vdkr-') and exe != 'vdkr-run.sh':
                arch_list.append(exe)
                # Extract arch from executable name (vdkr-aarch64 -> aarch64)
                arch_short.append(exe.replace('vdkr-', ''))

    # Copy blobs
    blobs_src = os.path.join(bindir, 'vdkr-blobs')
    if os.path.isdir(blobs_src):
        shutil.copytree(blobs_src, os.path.join(staging_dir, 'vdkr-blobs'))

    # Copy QEMU binaries and their library dependencies
    qemu_dir = os.path.join(staging_dir, 'qemu')
    lib_dir = os.path.join(staging_dir, 'lib')
    os.makedirs(qemu_dir)
    os.makedirs(lib_dir)

    import subprocess
    import re

    # Collect all libraries needed by QEMU binaries
    sysroot_lib_dirs = [
        os.path.join(staging_native, 'usr', 'lib'),
        os.path.join(staging_native, 'lib'),
        os.path.join(staging_native, 'usr', 'lib64'),
        os.path.join(staging_native, 'lib64'),
    ]

    copied_libs = set()

    # System libraries that should NOT be bundled - they must come from the host
    # These are fundamental glibc/system libs that would break the shell if overridden
    SKIP_LIBS = {
        'libc.so', 'libm.so', 'libpthread.so', 'libdl.so', 'librt.so',
        'libresolv.so', 'libnss_', 'libcrypt.so', 'libutil.so',
        'ld-linux', 'linux-vdso', 'libgcc_s.so', 'libstdc++.so',
    }

    def should_skip_lib(libname):
        """Check if this is a system library we shouldn't bundle"""
        for skip in SKIP_LIBS:
            if libname.startswith(skip) or skip in libname:
                return True
        return False

    def find_lib_in_sysroot(libname):
        """Find a library in the sysroot directories"""
        for lib_path in sysroot_lib_dirs:
            if not os.path.isdir(lib_path):
                continue
            # Try exact match first
            full_path = os.path.join(lib_path, libname)
            if os.path.exists(full_path):
                return full_path
            # Try with .so suffix variations
            for f in os.listdir(lib_path):
                if f.startswith(libname.split('.so')[0]) and '.so' in f:
                    return os.path.join(lib_path, f)
        return None

    def copy_lib_and_deps(binary_path, depth=0):
        """Recursively copy a binary and its library dependencies"""
        if depth > 10:  # Prevent infinite recursion
            return

        try:
            # Use ldd to find dependencies
            result = subprocess.run(['ldd', binary_path],
                                    capture_output=True, text=True,
                                    env={'LD_LIBRARY_PATH': ':'.join(sysroot_lib_dirs)})
            output = result.stdout + result.stderr
        except Exception as e:
            bb.warn("ldd failed for %s: %s" % (binary_path, str(e)))
            return

        # Parse ldd output: libname.so.X => /path/to/lib (addr)
        for line in output.split('\n'):
            # Match lines like: libfoo.so.1 => /path/to/libfoo.so.1 (0x...)
            match = re.match(r'\s*(\S+\.so\S*)\s+=>\s+(\S+)\s+\(', line)
            if match:
                libname = match.group(1)
                libpath = match.group(2)

                if libname in copied_libs:
                    continue

                # Skip fundamental system libraries
                if should_skip_lib(libname):
                    continue

                # Check if it's in our sysroot
                sysroot_path = find_lib_in_sysroot(libname)
                if sysroot_path:
                    libpath = sysroot_path
                elif libpath.startswith('/lib') or libpath.startswith('/usr/lib'):
                    # System lib not in sysroot - skip it
                    continue

                if libpath and os.path.exists(libpath) and libpath != 'not':
                    dest = os.path.join(lib_dir, libname)
                    if not os.path.exists(dest):
                        try:
                            # Follow symlinks to get the real file
                            real_path = os.path.realpath(libpath)
                            if os.path.isfile(real_path):
                                shutil.copy2(real_path, dest)
                                copied_libs.add(libname)
                                # Recursively get this library's dependencies
                                copy_lib_and_deps(dest, depth + 1)
                        except Exception as e:
                            bb.warn("Failed to copy %s: %s" % (libpath, str(e)))

    # Copy QEMU binaries and their dependencies
    for qemu in ['qemu-system-aarch64', 'qemu-system-x86_64']:
        src = os.path.join(staging_native, 'usr', 'bin', qemu)
        if os.path.exists(src):
            shutil.copy2(src, qemu_dir)
            copy_lib_and_deps(src)

    bb.plain("Bundled %d libraries for QEMU" % len(copied_libs))

    # Copy QEMU datafiles (BIOS, firmware, etc.)
    qemu_datadir_src = os.path.join(staging_native, 'usr', 'share', 'qemu')
    qemu_datadir_dst = os.path.join(staging_dir, 'share', 'qemu')
    if os.path.isdir(qemu_datadir_src):
        shutil.copytree(qemu_datadir_src, qemu_datadir_dst)
        bb.plain("Bundled QEMU datafiles from %s" % qemu_datadir_src)

    # Create wrapper scripts for QEMU that set LD_LIBRARY_PATH and QEMU datadir
    for qemu in ['qemu-system-aarch64', 'qemu-system-x86_64']:
        qemu_path = os.path.join(qemu_dir, qemu)
        if os.path.exists(qemu_path):
            # Rename original binary
            os.rename(qemu_path, qemu_path + '.bin')
            # Create wrapper
            with open(qemu_path, 'w') as f:
                f.write('''#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="${SCRIPT_DIR}/../lib:${LD_LIBRARY_PATH}"
exec "${SCRIPT_DIR}/%s.bin" -L "${SCRIPT_DIR}/../share/qemu" "$@"
''' % qemu)
            os.chmod(qemu_path, 0o755)

    # Create setup-env.sh
    # Note: We don't set LD_LIBRARY_PATH globally as that would break system tools
    # The QEMU wrapper scripts handle LD_LIBRARY_PATH for QEMU only
    setup_script = os.path.join(staging_dir, 'setup-env.sh')
    with open(setup_script, 'w') as f:
        f.write('''#!/bin/bash
# Source this file to set up vdkr environment
# Usage: source setup-env.sh

VDKR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure system utilities are available (needed by vdkr scripts)
# Prepend vdkr dirs, but keep /usr/bin:/bin for basic utilities
export PATH="${VDKR_DIR}:${VDKR_DIR}/qemu:/usr/bin:/bin:${PATH}"

echo "vdkr environment configured."
echo "Available commands:"
[ -f "${VDKR_DIR}/vdkr-aarch64" ] && echo "  vdkr-aarch64"
[ -f "${VDKR_DIR}/vdkr-x86_64" ] && echo "  vdkr-x86_64"
echo ""
echo "Example: vdkr-x86_64 images"
''')
    os.chmod(setup_script, 0o755)

    # Create README
    readme = os.path.join(staging_dir, 'README.txt')
    with open(readme, 'w') as f:
        f.write('''vdkr Standalone Package
==========================

This is a self-contained vdkr distribution.

Quick Start:
  source setup-env.sh
  vdkr-x86_64 images

Or run directly:
  ./vdkr-x86_64 images

Requirements:
  - Linux x86_64 host
  - bash

Contents:
  vdkr-aarch64    - vdkr for ARM64 targets
  vdkr-x86_64     - vdkr for x86_64 targets
  vdkr-run.sh     - QEMU runner (used internally)
  vdkr-blobs/     - Kernel and initramfs for each arch
  qemu/              - QEMU system emulators
  lib/               - Shared libraries for QEMU
  share/qemu/        - QEMU firmware and datafiles
  setup-env.sh       - Environment setup script

For more information, see:
  https://github.com/anthropics/meta-virtualization
''')

    # Create tarball with architecture(s) in the name
    # e.g., vdkr-standalone-x86_64.tar.gz or vdkr-standalone-aarch64-x86_64.tar.gz
    if arch_short:
        arch_suffix = '-'.join(sorted(arch_short))
        tarball_name = 'vdkr-standalone-%s' % arch_suffix
    else:
        tarball_name = 'vdkr-standalone'

    # Rename staging dir to match tarball name
    final_staging_dir = os.path.join(staging_base, tarball_name)
    os.rename(staging_dir, final_staging_dir)

    tarball_path = os.path.join(deploy_dir, tarball_name + '.tar.gz')
    with tarfile.open(tarball_path, 'w:gz') as tar:
        tar.add(final_staging_dir, arcname=tarball_name)

    # Report
    tarball_size = os.path.getsize(tarball_path)
    tarball_size_mb = tarball_size // (1024 * 1024)

    bb.plain("")
    bb.plain("=" * 70)
    bb.plain("vdkr standalone tarball created:")
    bb.plain("  %s" % tarball_path)
    bb.plain("  Size: %d MB" % tarball_size_mb)
    bb.plain("  Architectures: %s" % ', '.join(arch_short) if arch_short else "(none)")
    bb.plain("")
    bb.plain("To use:")
    bb.plain("  tar -xzf %s.tar.gz" % tarball_name)
    bb.plain("  cd %s" % tarball_name)
    bb.plain("  source setup-env.sh")
    if arch_list:
        bb.plain("  %s images" % arch_list[0])
    bb.plain("=" * 70)
}
addtask create_tarball after do_populate_sysroot
do_create_tarball[nostamp] = "1"
do_create_tarball[depends] = "qemu-system-native:do_populate_sysroot"
