#!/bin/bash
# vdkr-run.sh
# Core runner for vdkr: execute docker commands in QEMU-emulated environment
#
# Boot flow:
# 1. QEMU loads kernel + tiny initramfs (busybox + preinit)
# 2. preinit mounts rootfs.img (/dev/vda) and does switch_root
# 3. Real /init (vdkr-init.sh) runs on actual ext4 filesystem
# 4. Docker starts, executes command, outputs results
#
# This two-stage boot is required because Docker's runc needs pivot_root,
# which doesn't work from initramfs (rootfs isn't a mount point).
#
# Drive layout:
#   /dev/vda = rootfs.img (ro, ext4 with Docker tools)
#   /dev/vdb = input disk (optional, user data)
#   /dev/vdc = state disk (optional, persistent Docker storage)
#
# Version: 2.4.0

set -e

VERSION="2.4.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
TARGET_ARCH="${VDKR_ARCH:-aarch64}"
TIMEOUT="${VDKR_TIMEOUT:-300}"
VERBOSE="${VDKR_VERBOSE:-false}"

# Blob locations - relative to script for relocatable installation
# Note: recipe sed's this to $SCRIPT_DIR/vdkr-blobs for installed version
BLOB_DIR="${VDKR_BLOB_DIR:-$SCRIPT_DIR/blobs}"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

log() {
    local level="$1"
    local message="$2"
    case "$level" in
        "INFO")  [ "$VERBOSE" = "true" ] && echo -e "${GREEN}[vdkr]${NC} $message" >&2 || true ;;
        "WARN")  echo -e "${YELLOW}[vdkr]${NC} $message" >&2 ;;
        "ERROR") echo -e "${RED}[vdkr]${NC} $message" >&2 ;;
        "DEBUG") [ "$VERBOSE" = "true" ] && echo -e "${BLUE}[vdkr]${NC} $message" >&2 || true ;;
    esac
}

show_usage() {
    cat << 'EOF'
vdkr-run.sh - Execute docker commands in QEMU-emulated environment

USAGE:
    vdkr-run.sh [OPTIONS] -- <docker-command> [args...]

OPTIONS:
    --arch <arch>        Target architecture (aarch64, x86_64) [default: aarch64]
    --input <path>       Input file/directory for docker command (mounted as {INPUT})
    --input-type <type>  Input type: none, oci, tar, dir [default: auto-detect]
    --input-storage <tar> Restore Docker state from tar before running command
    --state-dir <path>   Use persistent directory for Docker storage between runs
    --output-type <type> Output type: text, tar, storage [default: text]
    --output <path>      Output file for tar/storage output types
    --blob-dir <path>    Directory containing kernel/initramfs blobs
    --timeout <secs>     QEMU timeout [default: 300]
    --keep-temp          Keep temporary files for debugging
    --verbose, -v        Enable verbose output
    --help, -h           Show this help

INPUT TYPES:
    none    No input data (docker commands that don't need files)
    oci     OCI container directory (has index.json, blobs/)
    tar     Tar archive (docker save output, etc.)
    dir     Generic directory

OUTPUT TYPES:
    text    Capture command stdout/stderr as text (default)
    tar     Expect command to create /tmp/output.tar, return as file
    storage Export entire /var/lib/docker as tar

PLACEHOLDERS:
    {INPUT}  Replaced with path to mounted input inside QEMU

EXAMPLES:
    # List images (no input needed)
    vdkr-run.sh -- docker images

    # Load an image from tar
    vdkr-run.sh --input myimage.tar -- docker load -i {INPUT}

    # Import an OCI container
    vdkr-run.sh --input ./container-oci/ --input-type oci \
        -- docker import {INPUT}/blobs/sha256/LARGEST myimage:latest

    # Save an image to tar (after loading)
    vdkr-run.sh --input myimage.tar --output-type tar \
        -- 'docker load -i {INPUT} && docker save -o /tmp/output.tar myimage:latest'

    # Get full docker storage after operations
    vdkr-run.sh --input myimage.tar --output-type storage --output storage.tar \
        -- docker load -i {INPUT}

EOF
}

# Parse arguments
INPUT_PATH=""
INPUT_TYPE="none"
INPUT_STORAGE=""
STATE_DIR=""
OUTPUT_TYPE="text"
OUTPUT_FILE=""
KEEP_TEMP="false"
DOCKER_CMD=""

while [ $# -gt 0 ]; do
    case $1 in
        --arch)
            TARGET_ARCH="$2"
            shift 2
            ;;
        --input)
            INPUT_PATH="$2"
            shift 2
            ;;
        --input-type)
            INPUT_TYPE="$2"
            shift 2
            ;;
        --input-storage)
            INPUT_STORAGE="$2"
            shift 2
            ;;
        --state-dir)
            STATE_DIR="$2"
            shift 2
            ;;
        --output-type)
            OUTPUT_TYPE="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --blob-dir)
            BLOB_DIR="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --keep-temp)
            KEEP_TEMP="true"
            shift
            ;;
        --verbose|-v)
            VERBOSE="true"
            shift
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        --)
            shift
            DOCKER_CMD="$*"
            break
            ;;
        *)
            # If we hit a non-option, assume rest is docker command
            DOCKER_CMD="$*"
            break
            ;;
    esac
done

if [ -z "$DOCKER_CMD" ]; then
    log "ERROR" "No docker command specified"
    echo ""
    show_usage
    exit 1
fi

# Auto-detect input type if input provided but type not specified
if [ -n "$INPUT_PATH" ] && [ "$INPUT_TYPE" = "none" ]; then
    if [ -d "$INPUT_PATH" ]; then
        if [ -f "$INPUT_PATH/index.json" ] || [ -f "$INPUT_PATH/oci-layout" ]; then
            INPUT_TYPE="oci"
        else
            INPUT_TYPE="dir"
        fi
    elif [ -f "$INPUT_PATH" ]; then
        INPUT_TYPE="tar"
    fi
    log "DEBUG" "Auto-detected input type: $INPUT_TYPE"
fi

# Validate output file for types that need it
if [ "$OUTPUT_TYPE" = "tar" ] || [ "$OUTPUT_TYPE" = "storage" ]; then
    if [ -z "$OUTPUT_FILE" ]; then
        OUTPUT_FILE="/tmp/vdkr-output-$$.tar"
        log "WARN" "No --output specified, using: $OUTPUT_FILE"
    fi
fi

log "INFO" "vdkr-run v$VERSION"
log "INFO" "Architecture: $TARGET_ARCH"
log "INFO" "Docker command: $DOCKER_CMD"
[ -n "$INPUT_PATH" ] && log "INFO" "Input: $INPUT_PATH ($INPUT_TYPE)"
[ -n "$INPUT_STORAGE" ] && log "INFO" "Input storage: $INPUT_STORAGE"
[ -n "$STATE_DIR" ] && log "INFO" "State directory: $STATE_DIR"
log "INFO" "Output type: $OUTPUT_TYPE"
[ -n "$OUTPUT_FILE" ] && log "INFO" "Output file: $OUTPUT_FILE"

# Find kernel, initramfs, and rootfs
case "$TARGET_ARCH" in
    aarch64)
        KERNEL_IMAGE="$BLOB_DIR/aarch64/Image"
        INITRAMFS="$BLOB_DIR/aarch64/initramfs.cpio.gz"
        ROOTFS_IMG="$BLOB_DIR/aarch64/rootfs.img"
        QEMU_CMD="qemu-system-aarch64"
        QEMU_MACHINE="-M virt -cpu cortex-a57"
        CONSOLE="ttyAMA0"
        ;;
    x86_64)
        KERNEL_IMAGE="$BLOB_DIR/x86_64/bzImage"
        INITRAMFS="$BLOB_DIR/x86_64/initramfs.cpio.gz"
        ROOTFS_IMG="$BLOB_DIR/x86_64/rootfs.img"
        QEMU_CMD="qemu-system-x86_64"
        # Use q35 + Skylake-Client to match oe-core qemux86-64 machine
        QEMU_MACHINE="-M q35 -cpu Skylake-Client"
        CONSOLE="ttyS0"
        ;;
    *)
        log "ERROR" "Unsupported architecture: $TARGET_ARCH"
        exit 1
        ;;
esac

# Check for kernel
if [ ! -f "$KERNEL_IMAGE" ]; then
    log "ERROR" "Kernel not found: $KERNEL_IMAGE"
    log "ERROR" "Set VDKR_BLOB_DIR or --blob-dir to location of vdkr blobs"
    log "ERROR" "Build with: MACHINE=qemuarm64 bitbake vdkr-initramfs-build"
    exit 1
fi

# Check for initramfs
if [ ! -f "$INITRAMFS" ]; then
    log "ERROR" "Initramfs not found: $INITRAMFS"
    log "ERROR" "Build with: MACHINE=qemuarm64 bitbake vdkr-initramfs-build"
    exit 1
fi

# Check for rootfs image (ext4 with Docker tools)
if [ ! -f "$ROOTFS_IMG" ]; then
    log "ERROR" "Rootfs image not found: $ROOTFS_IMG"
    log "ERROR" "Build with: MACHINE=qemuarm64 bitbake vdkr-initramfs-create"
    exit 1
fi

# Find QEMU - check PATH and common locations
if ! command -v "$QEMU_CMD" >/dev/null 2>&1; then
    # Try common locations
    for path in \
        "${STAGING_BINDIR_NATIVE:-}" \
        "/usr/bin"; do
        if [ -n "$path" ] && [ -x "$path/$QEMU_CMD" ]; then
            QEMU_CMD="$path/$QEMU_CMD"
            break
        fi
    done
fi

if ! command -v "$QEMU_CMD" >/dev/null 2>&1 && [ ! -x "$QEMU_CMD" ]; then
    log "ERROR" "QEMU not found: $QEMU_CMD"
    exit 1
fi

log "DEBUG" "Using QEMU: $QEMU_CMD"

# Create temp directory
TEMP_DIR="${TMPDIR:-/tmp}/vdkr-$$"
mkdir -p "$TEMP_DIR"

cleanup() {
    if [ "$KEEP_TEMP" = "true" ]; then
        log "DEBUG" "Keeping temp directory: $TEMP_DIR"
    else
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

log "DEBUG" "Using initramfs: $INITRAMFS"

# Create input disk image if needed
DISK_OPTS=""
if [ -n "$INPUT_PATH" ] && [ "$INPUT_TYPE" != "none" ]; then
    log "INFO" "Creating input disk image..."
    INPUT_IMG="$TEMP_DIR/input.img"

    # Calculate size (use -L to dereference hardlinks in OCI containers)
    if [ -d "$INPUT_PATH" ]; then
        SIZE_KB=$(du -skL "$INPUT_PATH" | cut -f1)
    else
        SIZE_KB=$(($(stat -c%s "$INPUT_PATH") / 1024))
    fi
    SIZE_MB=$(( (SIZE_KB / 1024) + 20 ))
    [ $SIZE_MB -lt 20 ] && SIZE_MB=20

    log "DEBUG" "Input size: ${SIZE_KB}KB, Image size: ${SIZE_MB}MB"

    dd if=/dev/zero of="$INPUT_IMG" bs=1M count=$SIZE_MB 2>/dev/null

    if [ -d "$INPUT_PATH" ]; then
        mke2fs -t ext4 -d "$INPUT_PATH" "$INPUT_IMG" 2>/dev/null
    else
        # Single file - create temp dir with the file
        EXTRACT_DIR="$TEMP_DIR/input-extract"
        mkdir -p "$EXTRACT_DIR"
        cp "$INPUT_PATH" "$EXTRACT_DIR/"
        mke2fs -t ext4 -d "$EXTRACT_DIR" "$INPUT_IMG" 2>/dev/null
    fi

    DISK_OPTS="-drive file=$INPUT_IMG,if=virtio,format=raw"
    log "DEBUG" "Input disk: $(ls -lh "$INPUT_IMG" | awk '{print $5}')"
fi

# Create state disk for persistent Docker storage (--state-dir)
STATE_DISK_OPTS=""
if [ -n "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR"
    STATE_IMG="$STATE_DIR/docker-state.img"

    if [ ! -f "$STATE_IMG" ]; then
        log "INFO" "Creating new state disk at $STATE_IMG..."
        # Create 2GB state disk for Docker storage
        dd if=/dev/zero of="$STATE_IMG" bs=1M count=2048 2>/dev/null
        mke2fs -t ext4 "$STATE_IMG" 2>/dev/null
    else
        log "INFO" "Using existing state disk: $STATE_IMG"
    fi

    # Use cache=directsync to ensure writes are flushed to disk
    # Combined with graceful shutdown wait, this ensures data integrity
    STATE_DISK_OPTS="-drive file=$STATE_IMG,if=virtio,format=raw,cache=directsync"
    log "DEBUG" "State disk: $(ls -lh "$STATE_IMG" | awk '{print $5}')"
fi

# Create state disk from input-storage tar (--input-storage)
if [ -n "$INPUT_STORAGE" ] && [ -z "$STATE_DIR" ]; then
    if [ ! -f "$INPUT_STORAGE" ]; then
        log "ERROR" "Input storage file not found: $INPUT_STORAGE"
        exit 1
    fi

    log "INFO" "Creating state disk from $INPUT_STORAGE..."
    STATE_IMG="$TEMP_DIR/state.img"

    # Calculate size from tar + headroom
    TAR_SIZE_KB=$(($(stat -c%s "$INPUT_STORAGE") / 1024))
    STATE_SIZE_MB=$(( (TAR_SIZE_KB / 1024) * 2 + 500 ))  # 2x tar size + 500MB headroom
    [ $STATE_SIZE_MB -lt 500 ] && STATE_SIZE_MB=500

    log "DEBUG" "Tar size: ${TAR_SIZE_KB}KB, State disk: ${STATE_SIZE_MB}MB"

    dd if=/dev/zero of="$STATE_IMG" bs=1M count=$STATE_SIZE_MB 2>/dev/null
    mke2fs -t ext4 "$STATE_IMG" 2>/dev/null

    # Mount and extract tar
    MOUNT_DIR="$TEMP_DIR/state-mount"
    mkdir -p "$MOUNT_DIR"

    # Use fuse2fs if available, otherwise need root
    if command -v fuse2fs >/dev/null 2>&1; then
        fuse2fs "$STATE_IMG" "$MOUNT_DIR" -o rw
        tar -xf "$INPUT_STORAGE" -C "$MOUNT_DIR"
        fusermount -u "$MOUNT_DIR"
    else
        log "WARN" "fuse2fs not found, using debugfs to inject tar (slower)"
        # Extract tar to temp, then use mke2fs -d
        EXTRACT_DIR="$TEMP_DIR/state-extract"
        mkdir -p "$EXTRACT_DIR"
        tar -xf "$INPUT_STORAGE" -C "$EXTRACT_DIR"
        mke2fs -t ext4 -d "$EXTRACT_DIR" "$STATE_IMG" 2>/dev/null
    fi

    # Use cache=directsync to ensure writes are flushed to disk
    STATE_DISK_OPTS="-drive file=$STATE_IMG,if=virtio,format=raw,cache=directsync"
    log "DEBUG" "State disk: $(ls -lh "$STATE_IMG" | awk '{print $5}')"
fi

# Encode docker command as base64
DOCKER_CMD_B64=$(echo -n "$DOCKER_CMD" | base64 -w0)

# Build kernel command line
KERNEL_APPEND="console=$CONSOLE,115200 init=/init"
KERNEL_APPEND="$KERNEL_APPEND docker_cmd=$DOCKER_CMD_B64"
KERNEL_APPEND="$KERNEL_APPEND docker_input=$INPUT_TYPE"
KERNEL_APPEND="$KERNEL_APPEND docker_output=$OUTPUT_TYPE"

# Tell init script if we have a state disk
if [ -n "$STATE_DISK_OPTS" ]; then
    KERNEL_APPEND="$KERNEL_APPEND docker_state=disk"
fi

# Build QEMU command
# Drive ordering is important:
#   /dev/vda = rootfs.img (read-only, ext4 with Docker tools)
#   /dev/vdb = input disk (if any)
#   /dev/vdc = state disk (if any)
# The preinit script in initramfs mounts /dev/vda and does switch_root
QEMU_OPTS="$QEMU_MACHINE -nographic -smp 2 -m 2048"
QEMU_OPTS="$QEMU_OPTS -kernel $KERNEL_IMAGE"
QEMU_OPTS="$QEMU_OPTS -initrd $INITRAMFS"
QEMU_OPTS="$QEMU_OPTS -drive file=$ROOTFS_IMG,if=virtio,format=raw,readonly=on"
QEMU_OPTS="$QEMU_OPTS $DISK_OPTS"
QEMU_OPTS="$QEMU_OPTS $STATE_DISK_OPTS"

log "INFO" "Starting QEMU..."
log "DEBUG" "Command: $QEMU_CMD $QEMU_OPTS -append \"$KERNEL_APPEND\""

# Run QEMU and capture output
QEMU_OUTPUT="$TEMP_DIR/qemu_output.txt"
timeout $TIMEOUT $QEMU_CMD $QEMU_OPTS -append "$KERNEL_APPEND" > "$QEMU_OUTPUT" 2>&1 &
QEMU_PID=$!

# Monitor for completion
COMPLETE=false
for i in $(seq 1 $TIMEOUT); do
    if [ ! -d "/proc/$QEMU_PID" ]; then
        log "DEBUG" "QEMU ended after $i seconds"
        break
    fi

    # Check for completion markers based on output type
    case "$OUTPUT_TYPE" in
        text)
            if grep -q "===OUTPUT_END===" "$QEMU_OUTPUT" 2>/dev/null; then
                COMPLETE=true
                break
            fi
            ;;
        tar)
            if grep -q "===TAR_END===" "$QEMU_OUTPUT" 2>/dev/null; then
                COMPLETE=true
                break
            fi
            ;;
        storage)
            if grep -q "===STORAGE_END===" "$QEMU_OUTPUT" 2>/dev/null; then
                COMPLETE=true
                break
            fi
            ;;
    esac

    # Check for error
    if grep -q "===ERROR===" "$QEMU_OUTPUT" 2>/dev/null; then
        log "ERROR" "Error in QEMU:"
        grep -A10 "===ERROR===" "$QEMU_OUTPUT"
        break
    fi

    # Progress indicator
    if [ $((i % 30)) -eq 0 ]; then
        if grep -q "Docker daemon is ready" "$QEMU_OUTPUT" 2>/dev/null; then
            log "INFO" "Docker is running, executing command..."
        elif grep -q "Starting Docker" "$QEMU_OUTPUT" 2>/dev/null; then
            log "INFO" "Docker is starting..."
        fi
    fi

    sleep 1
done

# Wait for QEMU to exit gracefully (poweroff from inside flushes disks properly)
# Only kill if it hangs after seeing completion marker
if [ "$COMPLETE" = "true" ] && [ -d "/proc/$QEMU_PID" ]; then
    log "DEBUG" "Waiting for QEMU to complete graceful shutdown..."
    # Give QEMU up to 30 seconds to poweroff after command completes
    for wait_i in $(seq 1 30); do
        if [ ! -d "/proc/$QEMU_PID" ]; then
            log "DEBUG" "QEMU shutdown complete"
            break
        fi
        sleep 1
    done
fi

# Force kill QEMU only if still running after grace period
if [ -d "/proc/$QEMU_PID" ]; then
    log "WARN" "QEMU still running, forcing termination..."
    kill $QEMU_PID 2>/dev/null || true
    wait $QEMU_PID 2>/dev/null || true
fi

# Extract results
if [ "$COMPLETE" = "true" ]; then
    # Get exit code
    EXIT_CODE=$(grep -oP '===EXIT_CODE=\K[0-9]+' "$QEMU_OUTPUT" | head -1)
    EXIT_CODE="${EXIT_CODE:-0}"

    case "$OUTPUT_TYPE" in
        text)
            log "INFO" "=== Command Output ==="
            sed -n '/===OUTPUT_START===/,/===OUTPUT_END===/p' "$QEMU_OUTPUT" | grep -v "==="
            log "INFO" "=== Exit Code: $EXIT_CODE ==="
            ;;

        tar)
            log "INFO" "Extracting tar output..."
            sed -n '/===TAR_START===/,/===TAR_END===/p' "$QEMU_OUTPUT" | \
                grep -v "===" | tr -d '\r' | base64 -d > "$OUTPUT_FILE" 2>/dev/null

            if tar -tf "$OUTPUT_FILE" >/dev/null 2>&1; then
                log "INFO" "SUCCESS: Output saved to $OUTPUT_FILE"
                log "INFO" "Size: $(ls -lh "$OUTPUT_FILE" | awk '{print $5}')"
            else
                log "ERROR" "Output file is not a valid tar"
                exit 1
            fi
            ;;

        storage)
            log "INFO" "Extracting storage..."
            sed -n '/===STORAGE_START===/,/===STORAGE_END===/p' "$QEMU_OUTPUT" | \
                grep -v "===" | tr -d '\r' | base64 -d > "$OUTPUT_FILE" 2>/dev/null

            if tar -tf "$OUTPUT_FILE" >/dev/null 2>&1; then
                log "INFO" "SUCCESS: Docker storage saved to $OUTPUT_FILE"
                log "INFO" "Size: $(ls -lh "$OUTPUT_FILE" | awk '{print $5}')"
                log "INFO" ""
                log "INFO" "To deploy: tar -xf $OUTPUT_FILE -C /var/lib/"
            else
                log "ERROR" "Storage file is not a valid tar"
                exit 1
            fi
            ;;
    esac

    exit "${EXIT_CODE:-0}"
else
    log "ERROR" "Command execution failed or timed out"
    log "ERROR" "QEMU output saved to: $QEMU_OUTPUT"

    if [ "$VERBOSE" = "true" ]; then
        log "DEBUG" "=== Last 50 lines of QEMU output ==="
        tail -50 "$QEMU_OUTPUT"
    fi

    exit 1
fi
