#!/bin/bash
# docker-storage-creator-blk.sh
# Docker container storage creator using virtio-blk for input (no initramfs rebuild needed)
# Version: 2.1.0-blk
#
# This version uses:
# - virtio-blk disk image for container INPUT (works with standard kernel)
# - base64 serial console for storage OUTPUT (proven approach)
# - Pre-built kernel + initramfs blobs (no rebuild per container)

set -e

VERSION="1.0.0"

# Configuration - will be set by argument parsing
INPUT_CONTAINER=""
OUTPUT_FILE=""
TARGET_ARCH=""
KERNEL_IMAGE=""
INITRAMFS_IMAGE=""
ROOTFS_DIR=""
CONTAINER_NAME=""
CONTAINER_TAG=""
WORK_DIR=""

# Global settings
VERBOSE=${VERBOSE:-true}
TIMEOUT=${TIMEOUT:-300}

# Blob locations (can be overridden)
BLOB_DIR="${CONTAINER_CROSS_TOOLS_DIR:-/usr/share/container-cross-tools}"

# Script directory for finding init script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    case "$level" in
        "INFO")
            echo -e "${GREEN}[$timestamp] [INFO] $message${NC}"
            ;;
        "WARN")
            echo -e "${YELLOW}[$timestamp] [WARN] $message${NC}" >&2
            ;;
        "ERROR")
            echo -e "${RED}[$timestamp] [ERROR] $message${NC}" >&2
            ;;
        "DEBUG")
            if [ "$VERBOSE" = "true" ]; then
                echo -e "${BLUE}[$timestamp] [DEBUG] $message${NC}"
            fi
            ;;
        "BLK")
            echo -e "${CYAN}[$timestamp] [BLK] $message${NC}"
            ;;
    esac
}

show_usage() {
    cat << EOF
docker-storage-creator-blk.sh v${VERSION}
Create Docker container storage using virtio-blk input (no initramfs rebuild)

USAGE:
    $0 [OPTIONS] <input-container> <output-file> <target-arch>

REQUIRED ARGUMENTS:
    input-container    Path to OCI container directory or Docker tar file
    output-file        Output tar file containing Docker storage
    target-arch        Target architecture (aarch64, x86_64)

OPTIONS:
    --kernel <path>      Path to kernel image (default: auto-detect from blob dir)
    --initramfs <path>   Path to initramfs (Phase 2: pre-built blob)
    --rootfs <path>      Path to rootfs (Phase 1: build initramfs dynamically)
    --blob-dir <path>    Directory containing pre-built blobs
    --name <name>        Container name (default: extracted from path)
    --tag <tag>          Container tag (default: latest)
    --work-dir <path>    Working directory for temporary files
    --timeout <seconds>  QEMU timeout (default: 300)
    --verbose            Enable verbose logging
    --help               Show this help message

MODES:
    Phase 1 (--rootfs):     Build initramfs dynamically, use virtio-blk for input
    Phase 2 (--initramfs):  Use pre-built initramfs blob, virtio-blk for input

I/O METHOD:
    Input:  virtio-blk disk image (container mounted from /dev/vda)
    Output: base64 over serial console (proven reliable)

EXAMPLES:
    # Using pre-built blobs (recommended):
    $0 container-oci/ output.tar aarch64

    # With explicit kernel/initramfs:
    $0 --kernel ./Image --initramfs ./initramfs.cpio.gz container-oci/ output.tar aarch64

    # Yocto integration:
    CONTAINER_CROSS_TOOLS_DIR=\${STAGING_DATADIR_NATIVE}/container-cross-tools \\
        $0 container-oci/ output.tar aarch64
EOF
}

# Parse command line arguments
POSITIONAL_ARGS=()
while [ $# -gt 0 ]; do
    case $1 in
        --kernel)
            KERNEL_IMAGE="$2"
            shift 2
            ;;
        --initramfs)
            INITRAMFS_IMAGE="$2"
            shift 2
            ;;
        --rootfs)
            ROOTFS_DIR="$2"
            shift 2
            ;;
        --blob-dir)
            BLOB_DIR="$2"
            shift 2
            ;;
        --name)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        --tag)
            CONTAINER_TAG="$2"
            shift 2
            ;;
        --work-dir)
            WORK_DIR="$2"
            shift 2
            ;;
        --arch)
            TARGET_ARCH="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        --*)
            log "ERROR" "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# Restore positional parameters
set -- "${POSITIONAL_ARGS[@]}"

# Extract positional arguments
INPUT_CONTAINER="$1"
OUTPUT_FILE="$2"
# Only use positional TARGET_ARCH if --arch wasn't specified
[ -z "$TARGET_ARCH" ] && TARGET_ARCH="$3"

# Validate required arguments
if [ -z "$INPUT_CONTAINER" ] || [ -z "$OUTPUT_FILE" ] || [ -z "$TARGET_ARCH" ]; then
    log "ERROR" "Missing required arguments"
    echo ""
    show_usage
    exit 1
fi

# Resolve output file path
OUTPUT_FILE=$(realpath -m "$OUTPUT_FILE")

# Check for pre-built initramfs from environment (set by bbclass)
if [ -n "$PREBUILT_INITRAMFS_PATH" ] && [ -f "$PREBUILT_INITRAMFS_PATH" ]; then
    log "INFO" "Using pre-built initramfs from PREBUILT_INITRAMFS_PATH"
    INITRAMFS_IMAGE="$PREBUILT_INITRAMFS_PATH"
fi

# Determine mode: Phase 1 (dynamic initramfs) or Phase 2 (pre-built)
BUILD_INITRAMFS="false"
if [ -n "$INITRAMFS_IMAGE" ] && [ -f "$INITRAMFS_IMAGE" ]; then
    # Pre-built initramfs available - use it even if --rootfs was provided
    log "INFO" "Phase 2 mode: Using pre-built initramfs"
elif [ -n "$ROOTFS_DIR" ]; then
    BUILD_INITRAMFS="true"
    log "INFO" "Phase 1 mode: Building initramfs dynamically from rootfs"
else
    # Try to auto-detect from blob directory
    log "INFO" "Attempting to auto-detect blobs from $BLOB_DIR"
fi

# Auto-detect kernel from blob directory if not specified
if [ -z "$KERNEL_IMAGE" ]; then
    case "$TARGET_ARCH" in
        "aarch64")
            KERNEL_IMAGE="$BLOB_DIR/aarch64/Image"
            [ ! -f "$KERNEL_IMAGE" ] && KERNEL_IMAGE="$BLOB_DIR/aarch64/Image.gz"
            ;;
        "x86_64")
            KERNEL_IMAGE="$BLOB_DIR/x86_64/bzImage"
            ;;
    esac
fi

# Auto-detect initramfs only if not building dynamically
if [ "$BUILD_INITRAMFS" = "false" ] && [ -z "$INITRAMFS_IMAGE" ]; then
    INITRAMFS_IMAGE="$BLOB_DIR/$TARGET_ARCH/initramfs.cpio.gz"
fi

# Validate kernel exists
if [ ! -f "$KERNEL_IMAGE" ]; then
    log "ERROR" "Kernel image not found: $KERNEL_IMAGE"
    log "ERROR" "Specify --kernel or set CONTAINER_CROSS_TOOLS_DIR"
    exit 1
fi

# Validate based on mode
if [ "$BUILD_INITRAMFS" = "true" ]; then
    # Phase 1: need rootfs
    if [ ! -d "$ROOTFS_DIR" ]; then
        log "ERROR" "Rootfs directory not found: $ROOTFS_DIR"
        exit 1
    fi
else
    # Phase 2: need pre-built initramfs
    if [ ! -f "$INITRAMFS_IMAGE" ]; then
        log "ERROR" "Initramfs not found: $INITRAMFS_IMAGE"
        log "ERROR" "Specify --initramfs, --rootfs, or set CONTAINER_CROSS_TOOLS_DIR"
        exit 1
    fi
fi

# Extract container name from path if not specified
if [ -z "$CONTAINER_NAME" ]; then
    DIR_NAME=$(basename "$INPUT_CONTAINER" | sed 's/-oci$//')

    if echo "$DIR_NAME" | grep -qE "^[^-]+-[^-]+-[^-]+$"; then
        # Format: prefix-middle-tag (e.g., container-base-latest)
        CONTAINER_NAME=$(echo "$DIR_NAME" | sed 's/-[^-]*$//')
        CONTAINER_TAG=$(echo "$DIR_NAME" | sed 's/.*-//')
    elif echo "$DIR_NAME" | grep -qE "^[^-]+-[^-]+$"; then
        # Format: name-tag
        CONTAINER_NAME=$(echo "$DIR_NAME" | cut -d- -f1)
        CONTAINER_TAG=$(echo "$DIR_NAME" | cut -d- -f2)
    else
        CONTAINER_NAME="$DIR_NAME"
        CONTAINER_TAG="${CONTAINER_TAG:-latest}"
    fi
fi
CONTAINER_TAG="${CONTAINER_TAG:-latest}"

log "INFO" "Docker Storage Creator v$VERSION (virtio-blk)"
log "INFO" "=============================================="
log "INFO" "Input: $INPUT_CONTAINER"
log "INFO" "Output: $OUTPUT_FILE"
log "INFO" "Architecture: $TARGET_ARCH"
log "INFO" "Container: $CONTAINER_NAME:$CONTAINER_TAG"
log "INFO" "Kernel: $KERNEL_IMAGE"
log "INFO" "Initramfs: $INITRAMFS_IMAGE"

# Create temporary directories
if [ -n "$WORK_DIR" ]; then
    mkdir -p "$WORK_DIR"
    TEMP_DIR="$WORK_DIR/.docker-blk-$$"
else
    TEMP_DIR="${TMPDIR:-/tmp}/.docker-blk-$$"
fi

mkdir -p "$TEMP_DIR"

log "BLK" "Created work directory: $TEMP_DIR"

# Cleanup trap - only cleanup if WORK_DIR was not specified
cleanup() {
    if [ -z "$WORK_DIR" ]; then
        log "DEBUG" "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    else
        log "DEBUG" "Preserving work directory for debugging: $TEMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

# Create disk image with container
log "BLK" "Creating virtio-blk disk image with container..."
CONTAINER_IMG="$TEMP_DIR/container-input.img"

# Calculate size needed (container size + 10MB padding)
if [ -d "$INPUT_CONTAINER" ]; then
    # Add trailing slash to follow symlinks properly with du
    SIZE_KB=$(du -sk "$INPUT_CONTAINER/" | cut -f1)
else
    SIZE_KB=$(stat -c%s "$INPUT_CONTAINER" 2>/dev/null || echo "10240")
    SIZE_KB=$((SIZE_KB / 1024))
fi
SIZE_MB=$(( (SIZE_KB / 1024) + 10 ))
[ $SIZE_MB -lt 10 ] && SIZE_MB=10

log "DEBUG" "Container size: ${SIZE_KB}KB, Image size: ${SIZE_MB}MB"

# Create ext4 image with contents
dd if=/dev/zero of="$CONTAINER_IMG" bs=1M count=$SIZE_MB 2>/dev/null

if [ -d "$INPUT_CONTAINER" ]; then
    # Directory - use mke2fs -d to populate
    # Use trailing slash to follow symlinks for mke2fs
    mke2fs -t ext4 -d "$INPUT_CONTAINER/" "$CONTAINER_IMG" 2>/dev/null
else
    # Tar file - extract to temp then populate
    EXTRACT_DIR="$TEMP_DIR/extract"
    mkdir -p "$EXTRACT_DIR"
    tar -xf "$INPUT_CONTAINER" -C "$EXTRACT_DIR/"
    mke2fs -t ext4 -d "$EXTRACT_DIR" "$CONTAINER_IMG" 2>/dev/null
fi

log "BLK" "Created disk image: $(ls -lh "$CONTAINER_IMG" | awk '{print $5}')"

# Phase 1: Build initramfs dynamically if --rootfs was provided
if [ "$BUILD_INITRAMFS" = "true" ]; then
    log "INFO" "Phase 1: Building initramfs dynamically from rootfs..."

    INITRAMFS_DIR="$TEMP_DIR/initramfs"
    mkdir -p "$INITRAMFS_DIR"/{bin,sbin,etc,proc,sys,dev,tmp,run,mnt/input,mnt/output}
    mkdir -p "$INITRAMFS_DIR"/{var/lib,var/run,var/tmp,usr/bin,usr/sbin,usr/lib,usr/lib64,lib,lib64}
    mkdir -p "$INITRAMFS_DIR"/root

    # Find and copy busybox
    BUSYBOX_PATH=""
    for dir in bin sbin usr/bin usr/sbin; do
        if [ -f "$ROOTFS_DIR/$dir/busybox" ]; then
            BUSYBOX_PATH="$ROOTFS_DIR/$dir/busybox"
            break
        fi
    done

    if [ -z "$BUSYBOX_PATH" ]; then
        log "ERROR" "busybox not found in rootfs"
        exit 1
    fi

    log "DEBUG" "Found busybox: $BUSYBOX_PATH"
    cp "$BUSYBOX_PATH" "$INITRAMFS_DIR/bin/busybox"
    chmod +x "$INITRAMFS_DIR/bin/busybox"

    # Create busybox symlinks
    cd "$INITRAMFS_DIR/bin"
    for cmd in sh mount umount mkdir cat echo sleep tar kill ps find head tail grep cut wc stat ln cp mv rm ls chmod chown test true false sort awk sed gzip gunzip sync dd printf tee base64 tr fold file reboot seq expr; do
        ln -sf busybox "$cmd" 2>/dev/null || true
    done
    cd - >/dev/null

    # Copy Docker binaries
    log "DEBUG" "Copying Docker binaries..."
    for binary in docker dockerd containerd containerd-shim containerd-shim-runc-v1 containerd-shim-runc-v2 runc docker-init docker-proxy; do
        for dir in bin sbin usr/bin usr/sbin; do
            if [ -f "$ROOTFS_DIR/$dir/$binary" ]; then
                cp "$ROOTFS_DIR/$dir/$binary" "$INITRAMFS_DIR/usr/bin/"
                log "DEBUG" "  Copied: $binary"
                break
            fi
        done
    done

    # Copy shared libraries - handle usrmerge
    log "DEBUG" "Copying shared libraries..."
    if [ -L "$ROOTFS_DIR/lib" ]; then
        # usrmerge layout
        for lib_dir in usr/lib usr/lib64; do
            if [ -d "$ROOTFS_DIR/$lib_dir" ]; then
                mkdir -p "$INITRAMFS_DIR/$lib_dir"
                find "$ROOTFS_DIR/$lib_dir" -maxdepth 1 -type f \( -name "*.so*" -o -name "ld-*" \) -exec cp {} "$INITRAMFS_DIR/$lib_dir/" \; 2>/dev/null || true
                find "$ROOTFS_DIR/$lib_dir" -maxdepth 1 -type l \( -name "*.so*" -o -name "ld-*" \) -exec cp -P {} "$INITRAMFS_DIR/$lib_dir/" \; 2>/dev/null || true
            fi
        done
        # Create usrmerge symlinks
        ln -sf usr/lib "$INITRAMFS_DIR/lib"
        [ -d "$INITRAMFS_DIR/usr/lib64" ] && ln -sf usr/lib64 "$INITRAMFS_DIR/lib64"
    else
        # Traditional layout
        for lib_dir in lib lib64 usr/lib usr/lib64; do
            if [ -d "$ROOTFS_DIR/$lib_dir" ]; then
                mkdir -p "$INITRAMFS_DIR/$lib_dir"
                find "$ROOTFS_DIR/$lib_dir" -maxdepth 1 -type f \( -name "*.so*" -o -name "ld-*" \) -exec cp {} "$INITRAMFS_DIR/$lib_dir/" \; 2>/dev/null || true
                find "$ROOTFS_DIR/$lib_dir" -maxdepth 1 -type l \( -name "*.so*" -o -name "ld-*" \) -exec cp -P {} "$INITRAMFS_DIR/$lib_dir/" \; 2>/dev/null || true
            fi
        done
    fi

    LIB_COUNT=$(find "$INITRAMFS_DIR" -name "*.so*" | wc -l)
    log "DEBUG" "Copied $LIB_COUNT library files"

    # Create basic /etc files
    cat > "$INITRAMFS_DIR/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF

    cat > "$INITRAMFS_DIR/etc/group" << 'EOF'
root:x:0:
nobody:x:65534:
EOF

    cat > "$INITRAMFS_DIR/etc/nsswitch.conf" << 'EOF'
passwd:     files
group:      files
shadow:     files
hosts:      files dns
EOF

    # Copy the init script
    INIT_SCRIPT="$SCRIPT_DIR/container-cross-init-docker-blk.sh"
    if [ -f "$INIT_SCRIPT" ]; then
        log "DEBUG" "Using init script: $INIT_SCRIPT"
        cp "$INIT_SCRIPT" "$INITRAMFS_DIR/init"
    else
        log "ERROR" "Init script not found: $INIT_SCRIPT"
        exit 1
    fi
    chmod +x "$INITRAMFS_DIR/init"

    # Create the initramfs cpio archive
    log "INFO" "Creating initramfs archive..."
    INITRAMFS_IMAGE="$TEMP_DIR/initramfs.cpio.gz"
    cd "$INITRAMFS_DIR"
    find . | cpio -o -H newc 2>/dev/null | gzip > "$INITRAMFS_IMAGE"
    cd - >/dev/null

    INITRAMFS_SIZE=$(stat -c%s "$INITRAMFS_IMAGE")
    log "INFO" "Initramfs created: $(($INITRAMFS_SIZE / 1024 / 1024))MB"
fi

# Find QEMU - check common locations
find_qemu() {
    local arch="$1"
    local qemu_name="qemu-system-$arch"

    # Check if already in PATH
    if command -v "$qemu_name" >/dev/null 2>&1; then
        echo "$qemu_name"
        return 0
    fi

    # Check Yocto native sysroot locations
    local search_paths=(
        "${STAGING_BINDIR_NATIVE:-}"
        "${OECORE_NATIVE_SYSROOT:-}/usr/bin"
    )

    for path in "${search_paths[@]}"; do
        if [ -n "$path" ] && [ -x "$path/$qemu_name" ]; then
            echo "$path/$qemu_name"
            return 0
        fi
    done

    return 1
}

# Select QEMU command and options based on architecture
case "$TARGET_ARCH" in
    "aarch64")
        QEMU_CMD=$(find_qemu "aarch64") || {
            log "ERROR" "qemu-system-aarch64 not found"
            log "ERROR" "Install qemu-user-static or run from Yocto environment"
            exit 1
        }
        QEMU_MACHINE="-M virt -cpu cortex-a57"
        CONSOLE="ttyAMA0"
        ;;
    "x86_64")
        QEMU_CMD=$(find_qemu "x86_64") || {
            log "ERROR" "qemu-system-x86_64 not found"
            log "ERROR" "Install qemu-user-static or run from Yocto environment"
            exit 1
        }
        # Use q35 + Skylake-Client to match oe-core qemux86-64 machine
        QEMU_MACHINE="-M q35 -cpu Skylake-Client"
        CONSOLE="ttyS0"
        ;;
    *)
        log "ERROR" "Unsupported architecture: $TARGET_ARCH"
        exit 1
        ;;
esac

log "DEBUG" "Using QEMU: $QEMU_CMD"

# Build QEMU command with virtio-blk input
QEMU_OPTS="$QEMU_MACHINE -nographic -smp 2 -m 2048"
QEMU_OPTS="$QEMU_OPTS -kernel $KERNEL_IMAGE"
QEMU_OPTS="$QEMU_OPTS -initrd $INITRAMFS_IMAGE"

# Add virtio-blk device for container input
QEMU_OPTS="$QEMU_OPTS -drive file=$CONTAINER_IMG,if=virtio,format=raw"

# Kernel command line with parameters for init script
KERNEL_APPEND="console=$CONSOLE,115200 init=/init"
KERNEL_APPEND="$KERNEL_APPEND container_name=$CONTAINER_NAME container_tag=$CONTAINER_TAG"
KERNEL_APPEND="$KERNEL_APPEND runtime=docker"

log "BLK" "Starting QEMU with virtio-blk container input..."
log "DEBUG" "Command: $QEMU_CMD $QEMU_OPTS -append \"$KERNEL_APPEND\""

# Run QEMU and capture output
QEMU_OUTPUT="$TEMP_DIR/qemu_output.txt"
timeout $TIMEOUT $QEMU_CMD $QEMU_OPTS -append "$KERNEL_APPEND" > "$QEMU_OUTPUT" 2>&1 &
QEMU_PID=$!

log "INFO" "QEMU started (PID: $QEMU_PID), monitoring..."

# Monitor for completion - look for base64 data in output
PROCESSING_COMPLETE=false
for i in $(seq 1 $TIMEOUT); do
    if [ ! -d "/proc/$QEMU_PID" ]; then
        log "DEBUG" "QEMU process ended after $i seconds"
        break
    fi

    # Check for success marker in output
    if grep -q "===DOCKER_STORAGE_START===" "$QEMU_OUTPUT" 2>/dev/null; then
        if grep -q "===DOCKER_STORAGE_END===" "$QEMU_OUTPUT" 2>/dev/null; then
            PROCESSING_COMPLETE=true
            log "INFO" "Docker storage data received!"
            break
        fi
    fi

    # Check for error marker
    if grep -q "===ERROR===" "$QEMU_OUTPUT" 2>/dev/null; then
        log "ERROR" "Processing failed inside QEMU"
        grep -A5 "===ERROR===" "$QEMU_OUTPUT"
        break
    fi

    # Show progress periodically
    if [ $((i % 30)) -eq 0 ]; then
        if grep -q "Docker daemon is ready" "$QEMU_OUTPUT" 2>/dev/null; then
            log "INFO" "Docker is running, processing container..."
        elif grep -q "Starting Docker" "$QEMU_OUTPUT" 2>/dev/null; then
            log "INFO" "Docker is starting..."
        elif grep -q "Mounted /dev/vda" "$QEMU_OUTPUT" 2>/dev/null; then
            log "INFO" "Container mounted from virtio-blk..."
        fi
    fi

    sleep 1
done

# Stop QEMU if still running
if [ -d "/proc/$QEMU_PID" ]; then
    kill $QEMU_PID 2>/dev/null || true
    wait $QEMU_PID 2>/dev/null || true
fi

# Extract base64 data from output
if [ "$PROCESSING_COMPLETE" = "true" ]; then
    log "INFO" "Extracting Docker storage from output..."

    # Extract base64 data between markers
    # Strip carriage returns (CRLF from serial console) before base64 decode
    sed -n '/===DOCKER_STORAGE_START===/,/===DOCKER_STORAGE_END===/p' "$QEMU_OUTPUT" | \
        grep -v "===" | \
        tr -d '\r' | \
        base64 -d > "$OUTPUT_FILE" 2>/dev/null

    OUTPUT_SIZE=$(stat -c%s "$OUTPUT_FILE" 2>/dev/null || echo "0")

    # Verify it's a valid tar
    if [ "$OUTPUT_SIZE" -gt 1000 ] && tar -tf "$OUTPUT_FILE" >/dev/null 2>&1; then
        log "INFO" "=============================================="
        log "INFO" "SUCCESS! Docker storage created via virtio-blk"
        log "BLK" "Method: virtio-blk input + base64 output"
        log "INFO" "Output: $OUTPUT_FILE"
        log "INFO" "Size: $(($OUTPUT_SIZE / 1024))KB"
        log "INFO" ""
        log "INFO" "Deployment:"
        log "INFO" "  tar -xf $OUTPUT_FILE -C /var/lib/"
        log "INFO" "  systemctl restart docker"
        log "INFO" "  docker images"

        exit 0
    else
        log "ERROR" "Output file is not a valid tar archive"
    fi
else
    log "ERROR" "Docker storage creation failed"
    log "ERROR" "Check QEMU output: $QEMU_OUTPUT"

    # Show last 50 lines of QEMU output for debugging
    if [ -f "$QEMU_OUTPUT" ]; then
        log "DEBUG" "=== Last 50 lines of QEMU output ==="
        tail -50 "$QEMU_OUTPUT"
    fi
fi

exit 1
