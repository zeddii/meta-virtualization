#!/bin/sh
# vdkr-init.sh
# Init script for vdkr: execute arbitrary docker commands in QEMU
#
# This script runs on a real ext4 filesystem after switch_root from initramfs.
# The preinit script mounted /dev/vda (rootfs.img) and did switch_root to us.
#
# Drive layout (rootfs.img is always /dev/vda, mounted as /):
#   /dev/vda = rootfs.img (this script runs from here, mounted as /)
#   /dev/vdb = input disk (optional, OCI/tar/dir data)
#   /dev/vdc = state disk (optional, persistent Docker storage)
#
# Kernel parameters:
#   docker_cmd=<base64>    Base64-encoded docker command + args
#   docker_input=<type>    Input type: none, oci, tar, dir (default: none)
#   docker_output=<type>   Output type: text, tar, storage (default: text)
#   docker_state=<type>    State type: none, disk (default: none)
#
# Version: 2.0.0

echo "=== vdkr Init ==="
echo "Version: 2.1.0"

# Set up environment
export LD_LIBRARY_PATH="/lib:/lib64:/usr/lib:/usr/lib64"
export PATH="/bin:/sbin:/usr/bin:/usr/sbin"
export HOME="/root"
export USER="root"
export LOGNAME="root"

# Mount essential filesystems FIRST before anything else
# After switch_root, we need to remount these
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Remount root as read-write so we can create directories
# The rootfs.img comes in read-only from QEMU, remount rw
mount -o remount,rw /

# These can be tmpfs to save on rootfs writes
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /var/run 2>/dev/null || true
mount -t tmpfs tmpfs /var/tmp 2>/dev/null || true

# Mount cgroup filesystem (required for container runtimes)
mkdir -p /sys/fs/cgroup
mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || {
    mount -t tmpfs cgroup /sys/fs/cgroup 2>/dev/null || true
    for subsys in devices memory cpu,cpuacct blkio net_cls freezer pids; do
        subsys_dir=$(echo $subsys | cut -d, -f1)
        mkdir -p /sys/fs/cgroup/$subsys_dir
        mount -t cgroup -o $subsys cgroup /sys/fs/cgroup/$subsys_dir 2>/dev/null || true
    done
}

# Create required directories
# /var/run and /var/tmp are already tmpfs mounts
mkdir -p /run/containerd /run/lock
mkdir -p /var/lib/docker
mkdir -p /mnt/input

# Parse kernel command line
DOCKER_CMD_B64=""
DOCKER_INPUT="none"
DOCKER_OUTPUT="text"
DOCKER_STATE="none"

for param in $(cat /proc/cmdline); do
    case "$param" in
        docker_cmd=*)
            DOCKER_CMD_B64="${param#docker_cmd=}"
            ;;
        docker_input=*)
            DOCKER_INPUT="${param#docker_input=}"
            ;;
        docker_output=*)
            DOCKER_OUTPUT="${param#docker_output=}"
            ;;
        docker_state=*)
            DOCKER_STATE="${param#docker_state=}"
            ;;
    esac
done

# Decode the docker command
if [ -z "$DOCKER_CMD_B64" ]; then
    echo "===ERROR==="
    echo "No docker command provided (docker_cmd= missing)"
    sleep 2
    reboot -f
fi

DOCKER_CMD=$(echo "$DOCKER_CMD_B64" | base64 -d 2>/dev/null)
if [ -z "$DOCKER_CMD" ]; then
    echo "===ERROR==="
    echo "Failed to decode docker command"
    sleep 2
    reboot -f
fi

echo "Docker command: $DOCKER_CMD"
echo "Input type: $DOCKER_INPUT"
echo "Output type: $DOCKER_OUTPUT"
echo "State type: $DOCKER_STATE"

echo "Waiting for block devices..."
sleep 2

echo "Block devices:"
ls -la /dev/vd* 2>/dev/null || echo "No /dev/vd* devices"

# Determine which disk is input and which is state
# Drive layout (rootfs.img is always /dev/vda, mounted by preinit as /):
#   /dev/vda = rootfs.img (already mounted as /)
#   /dev/vdb = input (if present)
#   /dev/vdc = state (if both input and state present)
#   /dev/vdb = state (if only state, no input)
#
# The drives are added to QEMU in order: rootfs, input, state

INPUT_DISK=""
STATE_DISK=""

if [ "$DOCKER_INPUT" != "none" ] && [ "$DOCKER_STATE" = "disk" ]; then
    # Both present: rootfs=vda, input=vdb, state=vdc
    INPUT_DISK="/dev/vdb"
    STATE_DISK="/dev/vdc"
elif [ "$DOCKER_STATE" = "disk" ]; then
    # Only state: rootfs=vda, state=vdb
    STATE_DISK="/dev/vdb"
elif [ "$DOCKER_INPUT" != "none" ]; then
    # Only input: rootfs=vda, input=vdb
    INPUT_DISK="/dev/vdb"
fi

# Handle Docker storage
# The rootfs is mounted read-only by preinit. We need writable storage for Docker.
# Options:
#   1. State disk provided: mount it as /var/lib/docker
#   2. No state disk: use tmpfs for Docker storage (ephemeral)

if [ -n "$STATE_DISK" ] && [ -b "$STATE_DISK" ]; then
    echo "Mounting state disk $STATE_DISK as /var/lib/docker..."
    if mount -t ext4 "$STATE_DISK" /var/lib/docker 2>&1; then
        echo "SUCCESS: Mounted $STATE_DISK as Docker storage"
        echo "Docker storage contents:"
        ls -la /var/lib/docker/ 2>/dev/null || echo "(empty)"
    else
        echo "WARNING: Failed to mount state disk, using tmpfs"
        DOCKER_STATE="none"
    fi
fi

# If no state disk, use tmpfs for Docker storage
if [ "$DOCKER_STATE" != "disk" ]; then
    echo "Using tmpfs for Docker storage (ephemeral)..."
    mount -t tmpfs -o size=1G tmpfs /var/lib/docker
fi

# Handle input data if present
if [ -n "$INPUT_DISK" ] && [ -b "$INPUT_DISK" ]; then
    echo "Mounting input from $INPUT_DISK..."
    if mount -t ext4 "$INPUT_DISK" /mnt/input 2>&1; then
        echo "SUCCESS: Mounted $INPUT_DISK"
        echo "Input contents:"
        ls -la /mnt/input/
    else
        echo "WARNING: Failed to mount $INPUT_DISK, continuing without input"
        DOCKER_INPUT="none"
    fi
elif [ "$DOCKER_INPUT" != "none" ]; then
    echo "WARNING: No input device found, continuing without input"
    DOCKER_INPUT="none"
fi

# Start containerd if available
CONTAINERD_READY=false
if [ -x "/usr/bin/containerd" ]; then
    echo "Starting containerd..."
    /usr/bin/containerd --log-level info &
    CONTAINERD_PID=$!
    sleep 5
    if kill -0 $CONTAINERD_PID 2>/dev/null; then
        echo "Containerd running (PID: $CONTAINERD_PID)"
        CONTAINERD_READY=true
    fi
fi

# Start Docker daemon
echo "Starting Docker daemon..."
DOCKER_OPTS="--data-root=/var/lib/docker"
DOCKER_OPTS="$DOCKER_OPTS --storage-driver=overlay2"
DOCKER_OPTS="$DOCKER_OPTS --iptables=false"
DOCKER_OPTS="$DOCKER_OPTS --userland-proxy=false"
DOCKER_OPTS="$DOCKER_OPTS --bridge=none"
DOCKER_OPTS="$DOCKER_OPTS --host=unix:///var/run/docker.sock"
DOCKER_OPTS="$DOCKER_OPTS --exec-opt native.cgroupdriver=cgroupfs"
DOCKER_OPTS="$DOCKER_OPTS --log-level=info"

if [ "$CONTAINERD_READY" = "true" ]; then
    DOCKER_OPTS="$DOCKER_OPTS --containerd=/run/containerd/containerd.sock"
fi

/usr/bin/dockerd $DOCKER_OPTS &
DOCKER_PID=$!
echo "Docker daemon started (PID: $DOCKER_PID)"

# Wait for Docker to be ready
echo "Waiting for Docker daemon..."
DOCKER_READY=false

# Give dockerd a few seconds to start before checking
sleep 5

for i in $(seq 1 60); do
    if ! kill -0 $DOCKER_PID 2>/dev/null; then
        echo "===ERROR==="
        echo "Docker daemon died after $i iterations"
        # Try to get any logs from dockerd
        echo "Checking for docker logs..."
        cat /var/log/docker.log 2>/dev/null || true
        dmesg | tail -20 2>/dev/null || true
        sleep 2
        reboot -f
    fi

    if /usr/bin/docker info >/dev/null 2>&1; then
        echo "Docker daemon is ready!"
        DOCKER_READY=true
        break
    fi

    echo "Waiting... ($i/60)"
    sleep 2
done

if [ "$DOCKER_READY" != "true" ]; then
    echo "===ERROR==="
    echo "Docker failed to start"
    sleep 2
    reboot -f
fi

# Prepare input if needed - set up INPUT_PATH variable for command substitution
INPUT_PATH=""
if [ "$DOCKER_INPUT" = "oci" ] && [ -d "/mnt/input" ]; then
    INPUT_PATH="/mnt/input"
elif [ "$DOCKER_INPUT" = "tar" ] && [ -d "/mnt/input" ]; then
    # Find tar file in input
    INPUT_PATH=$(find /mnt/input -name "*.tar" -o -name "*.tar.gz" | head -n 1)
    [ -z "$INPUT_PATH" ] && INPUT_PATH="/mnt/input"
elif [ "$DOCKER_INPUT" = "dir" ]; then
    INPUT_PATH="/mnt/input"
fi

# Export for command substitution
export INPUT_PATH

# Substitute {INPUT} placeholder in command with actual path
DOCKER_CMD_FINAL=$(echo "$DOCKER_CMD" | sed "s|{INPUT}|$INPUT_PATH|g")

echo "=== Executing Docker Command ==="
echo "Command: $DOCKER_CMD_FINAL"
echo ""

# Execute the docker command and capture output
EXEC_OUTPUT="/tmp/docker_output.txt"
EXEC_EXIT_CODE=0

# Use eval to properly handle quoted arguments
eval "$DOCKER_CMD_FINAL" > "$EXEC_OUTPUT" 2>&1 || EXEC_EXIT_CODE=$?

echo "Exit code: $EXEC_EXIT_CODE"

# Output results based on output type
case "$DOCKER_OUTPUT" in
    text)
        # Simple text output
        echo "===OUTPUT_START==="
        cat "$EXEC_OUTPUT"
        echo "===OUTPUT_END==="
        echo "===EXIT_CODE=$EXEC_EXIT_CODE==="
        ;;

    tar)
        # Command should have produced a tar file at /tmp/output.tar
        if [ -f /tmp/output.tar ]; then
            echo "===TAR_START==="
            base64 /tmp/output.tar
            echo "===TAR_END==="
            echo "===EXIT_CODE=$EXEC_EXIT_CODE==="
        else
            echo "===ERROR==="
            echo "Expected /tmp/output.tar but file not found"
            echo "Command output:"
            cat "$EXEC_OUTPUT"
        fi
        ;;

    storage)
        # Export entire docker storage
        echo "Stopping Docker gracefully..."
        /usr/bin/docker system prune -f >/dev/null 2>&1 || true
        kill $DOCKER_PID 2>/dev/null || true
        [ -n "$CONTAINERD_PID" ] && kill $CONTAINERD_PID 2>/dev/null || true
        sleep 3

        echo "Packaging Docker storage..."
        cd /var/lib
        tar -cf /tmp/storage.tar docker/

        STORAGE_SIZE=$(stat -c%s /tmp/storage.tar 2>/dev/null || echo "0")
        echo "Storage size: $STORAGE_SIZE bytes"

        if [ "$STORAGE_SIZE" -gt 1000 ]; then
            echo "===STORAGE_START==="
            base64 /tmp/storage.tar
            echo "===STORAGE_END==="
            echo "===EXIT_CODE=$EXEC_EXIT_CODE==="
        else
            echo "===ERROR==="
            echo "Storage too small"
        fi
        ;;

    *)
        echo "===ERROR==="
        echo "Unknown output type: $DOCKER_OUTPUT"
        ;;
esac

# Graceful shutdown: stop Docker, unmount filesystems, sync
echo "=== Shutting down gracefully ==="

# Stop Docker daemon to flush all writes
if [ -n "$DOCKER_PID" ]; then
    echo "Stopping Docker daemon..."
    kill $DOCKER_PID 2>/dev/null || true
    # Wait for dockerd to exit
    for i in $(seq 1 10); do
        if ! kill -0 $DOCKER_PID 2>/dev/null; then
            echo "Docker daemon stopped"
            break
        fi
        sleep 1
    done
fi

# Stop containerd
if [ -n "$CONTAINERD_PID" ]; then
    echo "Stopping containerd..."
    kill $CONTAINERD_PID 2>/dev/null || true
    sleep 2
fi

# Sync all filesystems
sync

# Unmount state disk if mounted (ensures all data is flushed)
if mount | grep -q "/var/lib/docker"; then
    echo "Unmounting Docker state disk..."
    # Force sync to the block device before unmount
    sync
    umount /var/lib/docker || {
        echo "Warning: umount failed, trying lazy unmount"
        umount -l /var/lib/docker 2>/dev/null || true
    }
fi

# Unmount input if mounted
umount /mnt/input 2>/dev/null || true

# Final sync and flush all block devices
sync
# Flush all block device buffers
for dev in /dev/vd*; do
    [ -b "$dev" ] && blockdev --flushbufs "$dev" 2>/dev/null || true
done
sync
sleep 2

echo "=== vdkr Complete ==="
# Use poweroff instead of reboot to ensure clean shutdown
poweroff -f
