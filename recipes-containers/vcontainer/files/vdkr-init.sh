#!/bin/sh
# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
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
#   docker_network=1       Enable networking (configure eth0, DNS)
#
# Version: 2.2.0

# Set up environment
export LD_LIBRARY_PATH="/lib:/lib64:/usr/lib:/usr/lib64"
export PATH="/bin:/sbin:/usr/bin:/usr/sbin"
export HOME="/root"
export USER="root"
export LOGNAME="root"

# Mount essential filesystems if not already mounted (preinit moves them via mount --move)
mountpoint -q /dev  || mount -t devtmpfs devtmpfs /dev
mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys  || mount -t sysfs sysfs /sys

# Mount devpts for pseudo-terminals (needed for interactive mode with script command)
mkdir -p /dev/pts
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts

# Enable IP forwarding early (Docker checks this at startup and warns if disabled)
echo 1 > /proc/sys/net/ipv4/ip_forward

# Configure loopback interface (required for containerd CRI streaming server)
ip link set lo up
ip addr add 127.0.0.1/8 dev lo 2>/dev/null || true

# Check for interactive mode (suppresses boot messages)
# Must be after mounting /proc so we can read cmdline
QUIET_BOOT=0
for param in $(cat /proc/cmdline); do
    case "$param" in
        docker_interactive=1) QUIET_BOOT=1 ;;
    esac
done

# Logging function - suppresses output in interactive mode
log() {
    [ "$QUIET_BOOT" = "0" ] && echo "$@"
}

log "=== vdkr Init ==="
log "Version: 2.2.0"

# The rootfs.img is read-only at QEMU level (readonly=on), so we can't remount rw.
# Instead, we use tmpfs overlays for directories that need to be writable.

# These are tmpfs (rootfs is read-only)
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /mnt
mount -t tmpfs tmpfs /var/run 2>/dev/null || true
mount -t tmpfs tmpfs /var/tmp 2>/dev/null || true

# Create a writable /etc using tmpfs overlay
# Copy existing /etc contents to tmpfs, then bind mount over /etc
mkdir -p /tmp/etc-overlay
cp -a /etc/* /tmp/etc-overlay/ 2>/dev/null || true
mount --bind /tmp/etc-overlay /etc

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
mkdir -p /var/lib/containerd
mkdir -p /mnt/input

# Parse kernel command line
DOCKER_CMD_B64=""
DOCKER_INPUT="none"
DOCKER_OUTPUT="text"
DOCKER_STATE="none"
DOCKER_NETWORK="0"
DOCKER_INTERACTIVE="0"
DOCKER_DAEMON="0"

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
        docker_network=*)
            DOCKER_NETWORK="${param#docker_network=}"
            ;;
        docker_interactive=*)
            DOCKER_INTERACTIVE="${param#docker_interactive=}"
            ;;
        docker_daemon=*)
            DOCKER_DAEMON="${param#docker_daemon=}"
            ;;
    esac
done

# Decode the docker command (not required for daemon mode)
DOCKER_CMD=""
if [ -n "$DOCKER_CMD_B64" ]; then
    DOCKER_CMD=$(echo "$DOCKER_CMD_B64" | base64 -d 2>/dev/null)
fi

# Require command for non-daemon mode
if [ -z "$DOCKER_CMD" ] && [ "$DOCKER_DAEMON" != "1" ]; then
    echo "===ERROR==="
    echo "No docker command provided (docker_cmd= missing)"
    sleep 2
    reboot -f
fi

log "Docker command: $DOCKER_CMD"
log "Input type: $DOCKER_INPUT"
log "Output type: $DOCKER_OUTPUT"
log "State type: $DOCKER_STATE"

log "Waiting for block devices..."
sleep 2

log "Block devices:"
[ "$QUIET_BOOT" = "0" ] && ls -la /dev/vd* 2>/dev/null || log "No /dev/vd* devices"

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
    log "Mounting state disk $STATE_DISK as /var/lib/docker..."
    if mount -t ext4 "$STATE_DISK" /var/lib/docker 2>&1; then
        log "SUCCESS: Mounted $STATE_DISK as Docker storage"
        log "Docker storage contents:"
        [ "$QUIET_BOOT" = "0" ] && ls -la /var/lib/docker/ 2>/dev/null || log "(empty)"
    else
        log "WARNING: Failed to mount state disk, using tmpfs"
        DOCKER_STATE="none"
    fi
fi

# If no state disk, use tmpfs for Docker storage
if [ "$DOCKER_STATE" != "disk" ]; then
    log "Using tmpfs for Docker storage (ephemeral)..."
    mount -t tmpfs -o size=1G tmpfs /var/lib/docker
fi

# Handle input data if present
if [ -n "$INPUT_DISK" ] && [ -b "$INPUT_DISK" ]; then
    log "Mounting input from $INPUT_DISK..."
    if mount -t ext4 "$INPUT_DISK" /mnt/input 2>&1; then
        log "SUCCESS: Mounted $INPUT_DISK"
        log "Input contents:"
        [ "$QUIET_BOOT" = "0" ] && ls -la /mnt/input/
    else
        log "WARNING: Failed to mount $INPUT_DISK, continuing without input"
        DOCKER_INPUT="none"
    fi
elif [ "$DOCKER_INPUT" != "none" ]; then
    log "WARNING: No input device found, continuing without input"
    DOCKER_INPUT="none"
fi

# Configure networking if enabled
if [ "$DOCKER_NETWORK" = "1" ]; then
    log "Configuring network..."

    # Find the network interface (usually eth0 or enp0s* with virtio)
    NET_IFACE=""
    for iface in eth0 enp0s2 enp0s3 ens3; do
        if [ -d "/sys/class/net/$iface" ]; then
            NET_IFACE="$iface"
            break
        fi
    done

    if [ -n "$NET_IFACE" ]; then
        log "Found network interface: $NET_IFACE"

        # Bring up the interface
        ip link set "$NET_IFACE" up

        # QEMU slirp provides:
        #   Guest IP: 10.0.2.15/24
        #   Gateway:  10.0.2.2
        #   DNS:      10.0.2.3
        ip addr add 10.0.2.15/24 dev "$NET_IFACE"
        ip route add default via 10.0.2.2

        # Configure DNS - use QEMU's built-in DNS forwarder plus public fallbacks
        mkdir -p /etc
        # Remove any existing symlink (systemd creates one pointing to non-existent file)
        rm -f /etc/resolv.conf
        cat > /etc/resolv.conf << 'DNSEOF'
nameserver 10.0.2.3
nameserver 8.8.8.8
nameserver 1.1.1.1
DNSEOF

        # Wait a moment for the network to settle
        sleep 1

        # Verify connectivity
        log "Testing network connectivity..."
        if ping -c 1 -W 3 10.0.2.2 >/dev/null 2>&1; then
            log "  Gateway (10.0.2.2): OK"
        else
            log "  Gateway (10.0.2.2): FAILED"
        fi

        # Test external connectivity (Google DNS)
        if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
            log "  External (8.8.8.8): OK"
        else
            log "  External (8.8.8.8): FAILED (may be filtered)"
        fi

        log "Network configured: $NET_IFACE (10.0.2.15)"
        [ "$QUIET_BOOT" = "0" ] && ip addr show "$NET_IFACE"
        [ "$QUIET_BOOT" = "0" ] && ip route
        [ "$QUIET_BOOT" = "0" ] && cat /etc/resolv.conf
    else
        log "WARNING: No network interface found"
        [ "$QUIET_BOOT" = "0" ] && ls /sys/class/net/
    fi
else
    log "Networking: disabled"
fi

# Start containerd if available
CONTAINERD_READY=false
if [ -x "/usr/bin/containerd" ]; then
    log "Starting containerd..."
    # Ensure containerd state directory exists and is writable
    mkdir -p /var/lib/containerd
    mkdir -p /run/containerd
    /usr/bin/containerd --log-level info --root /var/lib/containerd --state /run/containerd >/tmp/containerd.log 2>&1 &
    CONTAINERD_PID=$!
    # Wait for containerd socket to appear
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if [ -S /run/containerd/containerd.sock ]; then
            log "Containerd running (PID: $CONTAINERD_PID)"
            CONTAINERD_READY=true
            break
        fi
        sleep 1
    done
    if [ "$CONTAINERD_READY" != "true" ]; then
        log "WARNING: Containerd failed to start, check /tmp/containerd.log"
        [ -f /tmp/containerd.log ] && cat /tmp/containerd.log >&2
    fi
fi

# Start Docker daemon
log "Starting Docker daemon..."
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

/usr/bin/dockerd $DOCKER_OPTS >/dev/null 2>&1 &
DOCKER_PID=$!
log "Docker daemon started (PID: $DOCKER_PID)"

# Wait for Docker to be ready
log "Waiting for Docker daemon..."
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
        log "Docker daemon is ready!"
        DOCKER_READY=true
        break
    fi

    log "Waiting... ($i/60)"
    sleep 2
done

if [ "$DOCKER_READY" != "true" ]; then
    echo "===ERROR==="
    echo "Docker failed to start"
    sleep 2
    reboot -f
fi

# Daemon mode: enter command loop instead of single command execution
if [ "$DOCKER_DAEMON" = "1" ]; then
    log "=== Daemon Mode ==="

    # Find the virtio-serial port for command channel
    # virtserialport creates /dev/vportNp1 where N depends on controller order
    # Also check /dev/virtio-ports/vdkr (symlink created by udev if available)
    VDKR_PORT=""
    for port in /dev/vport0p1 /dev/vport1p1 /dev/vport2p1 /dev/virtio-ports/vdkr /dev/hvc1; do
        if [ -c "$port" ]; then
            VDKR_PORT="$port"
            log "Found virtio-serial port: $port"
            break
        fi
    done

    if [ -z "$VDKR_PORT" ]; then
        log "ERROR: Could not find virtio-serial port for daemon mode"
        # Fall back to using console
        log "Available devices:"
        ls -la /dev/hvc* /dev/vport* /dev/virtio-ports/ 2>/dev/null || true
        sleep 5
        reboot -f
    fi

    log "Using virtio-serial port: $VDKR_PORT"

    # Mount virtio-9p shared directory for file I/O between host and guest
    mkdir -p /mnt/share
    MOUNT_ERR=$(mount -t 9p -o trans=virtio,version=9p2000.L,cache=none vdkr_share /mnt/share 2>&1)
    if [ $? -eq 0 ]; then
        log "Mounted virtio-9p share at /mnt/share"
    else
        log "WARNING: Could not mount virtio-9p share: $MOUNT_ERR"
        log "Available filesystems:"
        cat /proc/filesystems 2>/dev/null | head -20
    fi

    # Open bidirectional FD to the virtio-serial port
    exec 3<>"$VDKR_PORT"

    log "Daemon ready, waiting for commands..."

    # Command loop - read commands from virtio-serial, execute, send response
    while true; do
        CMD_B64=""
        if read -r CMD_B64 <&3; then
            log "Received: '$CMD_B64'"
            # Handle special commands
            case "$CMD_B64" in
                "===PING===")
                    # Use cat to ensure unbuffered write to FD 3
                    echo "===PONG===" | cat >&3
                    continue
                    ;;
                "===SHUTDOWN===")
                    log "Received shutdown command"
                    echo "===SHUTTING_DOWN===" | cat >&3
                    break
                    ;;
            esac

            # Decode command
            CMD=$(echo "$CMD_B64" | base64 -d 2>/dev/null)
            if [ -z "$CMD" ]; then
                printf "===ERROR===\nFailed to decode command\n===END===\n" | cat >&3
                continue
            fi

            # Check for interactive command
            if echo "$CMD" | grep -q "^===INTERACTIVE==="; then
                CMD="${CMD#===INTERACTIVE===}"
                log "Interactive command: $CMD"

                # Signal ready
                printf "===INTERACTIVE_READY===\n" >&3

                # Set up terminal environment
                export TERM=linux

                # Run command with PTY using script command
                # This allocates a pseudo-terminal which docker -it requires
                # -q: quiet (suppress script's own messages)
                # -f: flush output after each write (critical for interactive I/O)
                # stdin/stdout/stderr connected to virtio-serial via FD 3
                script -qf -c "$CMD" /dev/null <&3 >&3 2>&1
                INTERACTIVE_EXIT=$?

                # Give output time to flush
                sleep 0.5

                # Send end marker on its own line
                printf "\n===INTERACTIVE_END=%d===\n" "$INTERACTIVE_EXIT" >&3

                log "Interactive command completed (exit: $INTERACTIVE_EXIT)"
                continue
            fi

            # Check if command needs input from shared directory
            NEEDS_INPUT=false
            if echo "$CMD" | grep -q "^===USE_INPUT==="; then
                NEEDS_INPUT=true
                CMD="${CMD#===USE_INPUT===}"
                log "Command needs input from shared directory"
            fi

            log "Executing: $CMD"

            # Verify shared directory has content if needed
            if [ "$NEEDS_INPUT" = "true" ]; then
                if ! mountpoint -q /mnt/share; then
                    printf "===ERROR===\nvirtio-9p share not mounted\n===END===\n" | cat >&3
                    continue
                fi
                if [ -z "$(ls -A /mnt/share 2>/dev/null)" ]; then
                    printf "===ERROR===\nShared directory is empty\n===END===\n" | cat >&3
                    continue
                fi
                log "Shared directory contents:"
                ls -la /mnt/share/ 2>/dev/null || true
            fi

            # Set up INPUT_PATH for command substitution (like regular mode uses {INPUT})
            # Use /mnt/share for virtio-9p shared directory
            INPUT_PATH="/mnt/share"

            # Replace {INPUT} placeholder in command
            CMD=$(echo "$CMD" | sed "s|{INPUT}|$INPUT_PATH|g")

            # Execute command and capture output
            EXEC_OUTPUT="/tmp/daemon_output.txt"
            EXEC_EXIT_CODE=0
            eval "$CMD" > "$EXEC_OUTPUT" 2>&1 || EXEC_EXIT_CODE=$?

            # Clean up shared directory after command (for next use)
            if [ "$NEEDS_INPUT" = "true" ]; then
                log "Cleaning shared directory..."
                rm -rf /mnt/share/* 2>/dev/null || true
            fi

            # Send response
            {
                echo "===OUTPUT_START==="
                cat "$EXEC_OUTPUT"
                echo "===OUTPUT_END==="
                echo "===EXIT_CODE=$EXEC_EXIT_CODE==="
                echo "===END==="
            } | cat >&3

            log "Command completed (exit code: $EXEC_EXIT_CODE)"
        else
            # Read failed - maybe port closed?
            sleep 1
        fi
    done

    # Close the FD when done
    exec 3>&-

    # Fall through to graceful shutdown
    log "Daemon shutting down..."
fi

# Skip command execution if we're in daemon mode (already handled)
if [ "$DOCKER_DAEMON" = "1" ]; then
    # Jump to graceful shutdown section
    :
else

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

log "=== Executing Docker Command ==="
log "Command: $DOCKER_CMD_FINAL"
log ""

# Handle interactive mode
if [ "$DOCKER_INTERACTIVE" = "1" ]; then
    # Set up terminal for interactive use
    export TERM=linux

    # Clear the "Starting container..." message from vrunner.sh
    # \r returns to start of line, \033[K clears to end of line
    printf '\r\033[K'

    # Execute the docker command with terminal attached
    # stdin/stdout/stderr go directly to the serial console
    eval "$DOCKER_CMD_FINAL"
    EXEC_EXIT_CODE=$?

    # Container exited - proceed directly to graceful shutdown
else
    # Non-interactive mode: capture output
    EXEC_OUTPUT="/tmp/docker_output.txt"
    EXEC_EXIT_CODE=0

    # Use eval to properly handle quoted arguments
    eval "$DOCKER_CMD_FINAL" > "$EXEC_OUTPUT" 2>&1 || EXEC_EXIT_CODE=$?

    log "Exit code: $EXEC_EXIT_CODE"

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
            # Suppress kernel messages during base64 output to avoid interleaving
            dmesg -n 1
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
            # Suppress kernel messages during base64 output to avoid interleaving
            dmesg -n 1
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
fi

fi  # End of non-daemon mode block

# Graceful shutdown: stop Docker, unmount filesystems, sync
log "=== Shutting down gracefully ==="

# Stop Docker daemon to flush all writes
if [ -n "$DOCKER_PID" ]; then
    log "Stopping Docker daemon..."
    kill $DOCKER_PID 2>/dev/null || true
    # Wait for dockerd to exit
    for i in $(seq 1 10); do
        if ! kill -0 $DOCKER_PID 2>/dev/null; then
            log "Docker daemon stopped"
            break
        fi
        sleep 1
    done
fi

# Stop containerd
if [ -n "$CONTAINERD_PID" ]; then
    log "Stopping containerd..."
    kill $CONTAINERD_PID 2>/dev/null || true
    sleep 2
fi

# Sync all filesystems
sync

# Unmount state disk if mounted (ensures all data is flushed)
if mount | grep -q "/var/lib/docker"; then
    log "Unmounting Docker state disk..."
    # Force sync to the block device before unmount
    sync
    umount /var/lib/docker || {
        log "Warning: umount failed, trying lazy unmount"
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

log "=== vdkr Complete ==="
# Use poweroff instead of reboot to ensure clean shutdown
poweroff -f
