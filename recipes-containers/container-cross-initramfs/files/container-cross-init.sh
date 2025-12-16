#!/bin/sh
# container-cross-init.sh
# Unified init script for container cross-install via QEMU
# Supports both Docker and Podman runtimes via kernel cmdline parameter
#
# This script runs inside QEMU and processes containers using:
# - virtio-blk for container INPUT (mounted from /dev/vda)
# - base64 serial console for storage OUTPUT
#
# Kernel parameters:
#   container_name=<name>  Container name for tagging
#   container_tag=<tag>    Container tag (default: latest)
#   runtime=docker|podman  Runtime type (default: docker)
#
# Version: 3.0.0-unified

echo "=== Container Cross-Install Init (Unified) ==="
echo "Version: 3.0.0-unified"

# Set up environment
export LD_LIBRARY_PATH="/lib:/lib64:/usr/lib:/usr/lib64"
export PATH="/bin:/sbin:/usr/bin:/usr/sbin"
export HOME="/root"
export USER="root"
export LOGNAME="root"

# Mount essential filesystems
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true

# Mount cgroup filesystem (required for container runtimes)
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
mkdir -p /var/run /run/containerd /run/lock /var/tmp
mkdir -p /mnt/input
chmod 1777 /var/tmp

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

# ============================================================================
# DOCKER RUNTIME
# ============================================================================
process_docker() {
    echo "=== Processing with Docker runtime ==="

    # Create Docker directories
    mkdir -p /var/lib/docker

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
        return 1
    fi

    # Load/import container
    echo "=== Loading container ($CONTAINER_FORMAT) ==="
    LOAD_SUCCESS=false

    if [ "$CONTAINER_FORMAT" = "OCI" ]; then
        echo "Processing OCI format..."

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
        echo "Loading Docker format..."
        tar -cf /tmp/container.tar -C /mnt/input .

        if /usr/bin/docker load -i /tmp/container.tar; then
            echo "Docker load succeeded"
            LOAD_SUCCESS=true

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

    # Package Docker storage
    echo "=== Packaging Docker storage ==="
    cd /var/lib
    tar -cf /tmp/storage.tar docker/

    STORAGE_SIZE=$(stat -c%s /tmp/storage.tar 2>/dev/null || echo "0")
    echo "Docker storage size: $STORAGE_SIZE bytes"

    if [ "$STORAGE_SIZE" -gt 1000 ]; then
        echo "Streaming Docker storage via base64..."
        echo "===DOCKER_STORAGE_START==="
        base64 /tmp/storage.tar
        echo "===DOCKER_STORAGE_END==="
        echo "Storage transfer complete"
        return 0
    else
        echo "===ERROR==="
        echo "Storage too small - processing may have failed"
        return 1
    fi
}

# ============================================================================
# PODMAN RUNTIME
# ============================================================================
process_podman() {
    echo "=== Processing with Podman runtime ==="

    # Additional Podman environment
    export XDG_RUNTIME_DIR="/run"
    export XDG_DATA_HOME="/root/.local/share"
    export XDG_CONFIG_HOME="/root/.config"

    # Create Podman directories
    mkdir -p /var/lib/containers/storage
    mkdir -p /run/containers/storage
    mkdir -p /root/.local/share/containers
    mkdir -p /root/.config/containers
    mkdir -p /run/user/0

    # Unmount container input (copy first for Podman)
    echo "Copying container to temp location..."
    mkdir -p /tmp/container-check
    cp -a /mnt/input/* /tmp/container-check/ 2>/dev/null || tar -xf /mnt/input -C /tmp/container-check 2>/dev/null || true
    umount /mnt/input 2>/dev/null || true

    echo "=== IMPORTING CONTAINER WITH PODMAN ==="
    LOAD_SUCCESS=false

    # Try skopeo first (simpler and more reliable)
    if command -v skopeo >/dev/null 2>&1; then
        echo "Trying skopeo..."
        if [ "$CONTAINER_FORMAT" = "OCI" ]; then
            if skopeo copy --dest-compress=false \
                "oci:/tmp/container-check" \
                "containers-storage:$CONTAINER_NAME:$CONTAINER_TAG" 2>&1; then
                echo "Skopeo copy succeeded!"
                LOAD_SUCCESS=true
            fi
        fi
    fi

    # Fallback to podman if skopeo didn't work
    if [ "$LOAD_SUCCESS" != "true" ]; then
        echo "Trying podman..."

        if [ "$CONTAINER_FORMAT" = "OCI" ]; then
            if podman pull "oci:/tmp/container-check" 2>&1; then
                echo "Podman pull succeeded"
                LOAD_SUCCESS=true
                LOADED_ID=$(podman images -q | head -1)
                if [ -n "$LOADED_ID" ]; then
                    podman tag "$LOADED_ID" "$CONTAINER_NAME:$CONTAINER_TAG" 2>&1 || true
                fi
            fi
        elif [ "$CONTAINER_FORMAT" = "DOCKER" ]; then
            if podman load -i /tmp/container-check/container.tar 2>&1; then
                echo "Podman load succeeded"
                LOAD_SUCCESS=true
                LOADED_ID=$(podman images -q | head -1)
                if [ -n "$LOADED_ID" ]; then
                    podman tag "$LOADED_ID" "$CONTAINER_NAME:$CONTAINER_TAG" 2>&1 || true
                fi
            fi
        fi
    fi

    # Final fallback: import largest blob
    if [ "$LOAD_SUCCESS" != "true" ] && [ -d "/tmp/container-check/blobs/sha256" ]; then
        echo "Trying fallback - import largest blob..."
        cd /tmp/container-check/blobs/sha256

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
            gunzip -c "$LARGEST_BLOB" > /tmp/layer.tar 2>&1 || cp "$LARGEST_BLOB" /tmp/layer.tar
            if podman import /tmp/layer.tar "$CONTAINER_NAME:$CONTAINER_TAG" 2>&1; then
                echo "Podman import succeeded"
                LOAD_SUCCESS=true
            fi
        fi
        cd /
    fi

    if [ "$LOAD_SUCCESS" = "true" ]; then
        echo "Container loaded successfully!"
        podman images
    else
        echo "===ERROR==="
        echo "Container import failed - no storage to export"
        podman images 2>&1 || true
        echo "Debugging info:"
        echo "  /mnt/input contents:"
        ls -la /mnt/input/ 2>&1 || echo "    (could not list)"
        echo "  skopeo version:"
        skopeo --version 2>&1 || echo "    (skopeo not working)"
        echo "  podman version:"
        podman --version 2>&1 || echo "    (podman not working)"
        return 1
    fi

    # Package containers storage
    # Exclude db.sql and libpod/ - these are session-specific
    echo "=== PACKAGING CONTAINERS STORAGE ==="
    cd /var/lib/containers
    tar -cf /tmp/storage.tar --exclude='storage/db.sql' --exclude='storage/libpod/*' storage/ 2>/dev/null || true

    STORAGE_SIZE=$(stat -c%s /tmp/storage.tar 2>/dev/null || echo "0")
    echo "Podman storage size: $STORAGE_SIZE bytes"

    if [ "$STORAGE_SIZE" -gt 1000 ]; then
        echo "Streaming Podman storage via base64..."
        echo "===STORAGE_START==="
        base64 /tmp/storage.tar
        echo "===STORAGE_END==="
        echo "Storage transfer complete"
        return 0
    else
        echo "===ERROR==="
        echo "Storage too small - processing may have failed"
        return 1
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

case "$RUNTIME" in
    docker)
        process_docker
        ;;
    podman)
        process_podman
        ;;
    *)
        echo "===ERROR==="
        echo "Unknown runtime: $RUNTIME"
        echo "Supported: docker, podman"
        sleep 2
        reboot -f
        ;;
esac

# Shutdown
echo "=== Complete ==="
sync
sleep 2
reboot -f
