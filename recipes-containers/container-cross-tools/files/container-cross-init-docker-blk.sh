#!/bin/sh
# container-cross-init-docker-blk.sh
# Init script for Docker container processing via virtio-blk input
# This script runs inside QEMU and processes containers using:
# - virtio-blk for container INPUT (mounted from /dev/vda)
# - base64 serial console for storage OUTPUT (proven reliable)
#
# Kernel parameters:
#   container_name=<name>  Container name for tagging
#   container_tag=<tag>    Container tag (default: latest)
#   runtime=docker         Runtime type (docker or podman)

echo "=== Container Cross-Install Init (Docker/virtio-blk) ==="
echo "Version: 2.1.0-blk"

# Set up environment
export LD_LIBRARY_PATH="/lib:/lib64:/usr/lib:/usr/lib64"
export PATH="/bin:/sbin:/usr/bin:/usr/sbin"
export HOME="/root"

# Mount essential filesystems
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true

# Mount cgroup filesystem (required for Docker)
mkdir -p /sys/fs/cgroup
mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || {
    # Fallback to cgroup v1 if v2 fails
    mount -t tmpfs cgroup /sys/fs/cgroup 2>/dev/null || true
    for subsys in devices memory cpu,cpuacct blkio net_cls freezer pids; do
        subsys_dir=$(echo $subsys | cut -d, -f1)
        mkdir -p /sys/fs/cgroup/$subsys_dir
        mount -t cgroup -o $subsys cgroup /sys/fs/cgroup/$subsys_dir 2>/dev/null || true
    done
}

# Create required directories
mkdir -p /var/lib/docker /var/run /run/containerd
mkdir -p /mnt/input

# Parse kernel command line
CONTAINER_NAME="imported"
CONTAINER_TAG="latest"
RUNTIME="docker"

for param in $(cat /proc/cmdline); do
    case "$param" in
        container_name=*)
            CONTAINER_NAME="${param#container_name=}"
            ;;
        container_tag=*)
            CONTAINER_TAG="${param#container_tag=}"
            ;;
        runtime=*)
            RUNTIME="${param#runtime=}"
            ;;
    esac
done

echo "Container: $CONTAINER_NAME:$CONTAINER_TAG"
echo "Runtime: $RUNTIME"

# Wait for block devices
echo "Waiting for block devices..."
sleep 2

# List available block devices
echo "Block devices:"
ls -la /dev/vd* 2>/dev/null || echo "No /dev/vd* devices"

# Mount container from virtio-blk device
echo "Mounting container from /dev/vda..."
if mount -t ext4 /dev/vda /mnt/input 2>&1; then
    echo "SUCCESS: Mounted /dev/vda"
else
    echo "===ERROR==="
    echo "Failed to mount /dev/vda"
    sleep 5
    reboot -f
fi

# Verify input has content
if [ ! "$(ls -A /mnt/input 2>/dev/null)" ]; then
    echo "===ERROR==="
    echo "Input container is empty"
    sleep 2
    reboot -f
fi

echo "Input contents:"
ls -la /mnt/input/

# Detect container format
CONTAINER_FORMAT="UNKNOWN"
if [ -f "/mnt/input/index.json" ] || [ -f "/mnt/input/oci-layout" ]; then
    CONTAINER_FORMAT="OCI"
    echo "Detected OCI format"
elif [ -f "/mnt/input/manifest.json" ]; then
    CONTAINER_FORMAT="DOCKER"
    echo "Detected Docker format"
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
for i in $(seq 1 60); do
    if ! kill -0 $DOCKER_PID 2>/dev/null; then
        echo "===ERROR==="
        echo "Docker daemon died"
        break
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

# Load/import container
echo "=== Loading container ($CONTAINER_FORMAT) ==="
LOAD_SUCCESS=false

if [ "$CONTAINER_FORMAT" = "OCI" ]; then
    # For OCI format, we need to import layers
    echo "Processing OCI format..."

    # Try to find and import the filesystem layer
    if [ -d "/mnt/input/blobs/sha256" ]; then
        cd /mnt/input/blobs/sha256

        # Find largest blob (filesystem layer)
        LARGEST_BLOB=""
        LARGEST_SIZE=0
        for blob in *; do
            if [ -f "$blob" ]; then
                BLOB_SIZE=$(stat -c%s "$blob" 2>/dev/null || echo "0")
                if [ "$BLOB_SIZE" -gt "$LARGEST_SIZE" ]; then
                    LARGEST_SIZE="$BLOB_SIZE"
                    LARGEST_BLOB="$blob"
                fi
            fi
        done

        if [ -n "$LARGEST_BLOB" ]; then
            echo "Importing blob: $LARGEST_BLOB ($LARGEST_SIZE bytes)"

            # Decompress if needed and import
            if file "$LARGEST_BLOB" 2>/dev/null | grep -q gzip; then
                gunzip -c "$LARGEST_BLOB" > /tmp/layer.tar
                /usr/bin/docker import /tmp/layer.tar "$CONTAINER_NAME:$CONTAINER_TAG" && LOAD_SUCCESS=true
            else
                /usr/bin/docker import "$LARGEST_BLOB" "$CONTAINER_NAME:$CONTAINER_TAG" && LOAD_SUCCESS=true
            fi
        fi
        cd /
    fi

elif [ "$CONTAINER_FORMAT" = "DOCKER" ]; then
    # For Docker format, use docker load
    echo "Loading Docker format..."

    # Create tar from input directory
    tar -cf /tmp/container.tar -C /mnt/input .

    if /usr/bin/docker load -i /tmp/container.tar; then
        echo "Docker load succeeded"
        LOAD_SUCCESS=true

        # Tag with our desired name if needed
        LOADED_ID=$(/usr/bin/docker images -q | head -1)
        if [ -n "$LOADED_ID" ]; then
            /usr/bin/docker tag "$LOADED_ID" "$CONTAINER_NAME:$CONTAINER_TAG" 2>/dev/null || true
        fi
    fi
fi

if [ "$LOAD_SUCCESS" = "true" ]; then
    echo "Container loaded successfully!"
    /usr/bin/docker images
else
    echo "WARNING: Container load may have failed"
    echo "Docker images:"
    /usr/bin/docker images
fi

# Unmount container input
umount /mnt/input 2>/dev/null || true

# Stop Docker gracefully
echo "Stopping Docker..."
/usr/bin/docker system prune -f >/dev/null 2>&1 || true
kill $DOCKER_PID 2>/dev/null || true
[ -n "$CONTAINERD_PID" ] && kill $CONTAINERD_PID 2>/dev/null || true
sleep 3

# Package Docker storage and output via base64 on serial console
echo "=== Packaging Docker storage ==="
cd /var/lib
tar -cf /tmp/docker-storage.tar docker/

STORAGE_SIZE=$(stat -c%s /tmp/docker-storage.tar 2>/dev/null || echo "0")
echo "Docker storage size: $STORAGE_SIZE bytes"

if [ "$STORAGE_SIZE" -gt 1000 ]; then
    echo "Streaming Docker storage via base64..."
    echo "===DOCKER_STORAGE_START==="
    base64 /tmp/docker-storage.tar
    echo "===DOCKER_STORAGE_END==="
    echo "Storage transfer complete"
else
    echo "===ERROR==="
    echo "Storage too small - processing may have failed"
fi

# Shutdown
echo "=== Complete ==="
sync
sleep 2
reboot -f
