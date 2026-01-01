#!/bin/sh
# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# vpdmn-init.sh
# Init script for vpdmn: execute arbitrary podman commands in QEMU
#
# This script runs on a real ext4 filesystem after switch_root from initramfs.
# The preinit script mounted /dev/vda (rootfs.img) and did switch_root to us.
#
# Drive layout (rootfs.img is always /dev/vda, mounted as /):
#   /dev/vda = rootfs.img (this script runs from here, mounted as /)
#   /dev/vdb = input disk (optional, OCI/tar/dir data)
#   /dev/vdc = state disk (optional, persistent Podman storage)
#
# Kernel parameters:
#   podman_cmd=<base64>    Base64-encoded podman command + args
#   podman_input=<type>    Input type: none, oci, tar, dir (default: none)
#   podman_output=<type>   Output type: text, tar, storage (default: text)
#   podman_state=<type>    State type: none, disk (default: none)
#   podman_network=1       Enable networking (configure eth0, DNS)
#
# Version: 1.0.0
#
# Note: Podman is daemonless - no containerd/dockerd required!

# Set up environment
export LD_LIBRARY_PATH="/lib:/lib64:/usr/lib:/usr/lib64"
export PATH="/bin:/sbin:/usr/bin:/usr/sbin"
export HOME="/root"
export USER="root"
export LOGNAME="root"

# Podman needs XDG_RUNTIME_DIR
export XDG_RUNTIME_DIR="/run/user/0"

# Mount essential filesystems if not already mounted (preinit moves them via mount --move)
mountpoint -q /dev  || mount -t devtmpfs devtmpfs /dev
mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys  || mount -t sysfs sysfs /sys

# Mount devpts for pseudo-terminals (needed for interactive mode with script command)
mkdir -p /dev/pts
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts

# Enable IP forwarding (may be useful for containers)
echo 1 > /proc/sys/net/ipv4/ip_forward

# Check for interactive mode (suppresses boot messages)
# Must be after mounting /proc so we can read cmdline
QUIET_BOOT=0
for param in $(cat /proc/cmdline); do
    case "$param" in
        podman_interactive=1) QUIET_BOOT=1 ;;
    esac
done

# Logging function - suppresses output in interactive mode
log() {
    [ "$QUIET_BOOT" = "0" ] && echo "$@"
}

log "=== vpdmn Init ==="
log "Version: 1.0.0"

# The rootfs.img is read-only at QEMU level (readonly=on), so we can't remount rw.
# Instead, we use tmpfs overlays for directories that need to be writable.

# These are tmpfs (rootfs is read-only)
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /mnt

# Create and mount directories that podman needs writable
# Note: /var/tmp, /var/run, /var/log are symlinks to /var/volatile/* in Yocto
mkdir -p /dev/shm
mount -t tmpfs tmpfs /dev/shm

# Mount /var/volatile for Yocto's volatile symlinks (/var/tmp -> volatile/tmp, etc.)
mkdir -p /var/volatile
mount -t tmpfs tmpfs /var/volatile
mkdir -p /var/volatile/tmp /var/volatile/log /var/volatile/run /var/volatile/cache

# Also mount /var/cache directly (not a symlink)
mount -t tmpfs tmpfs /var/cache

# Create XDG_RUNTIME_DIR for podman
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

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
mkdir -p /run/lock
mkdir -p /mnt/input

# /var/lib/containers exists in rootfs.img (read-only), mount tmpfs over it
# This allows us to create subdirectories like /var/lib/containers/storage
# Note: The state disk mount (if present) will overmount /var/lib/containers/storage later
mount -t tmpfs tmpfs /var/lib/containers
mkdir -p /var/lib/containers/storage

# Parse kernel command line
PODMAN_CMD_B64=""
PODMAN_INPUT="none"
PODMAN_OUTPUT="text"
PODMAN_STATE="none"
PODMAN_NETWORK="0"
PODMAN_INTERACTIVE="0"
PODMAN_DAEMON="0"

for param in $(cat /proc/cmdline); do
    case "$param" in
        podman_cmd=*)
            PODMAN_CMD_B64="${param#podman_cmd=}"
            ;;
        podman_input=*)
            PODMAN_INPUT="${param#podman_input=}"
            ;;
        podman_output=*)
            PODMAN_OUTPUT="${param#podman_output=}"
            ;;
        podman_state=*)
            PODMAN_STATE="${param#podman_state=}"
            ;;
        podman_network=*)
            PODMAN_NETWORK="${param#podman_network=}"
            ;;
        podman_interactive=*)
            PODMAN_INTERACTIVE="${param#podman_interactive=}"
            ;;
        podman_daemon=*)
            PODMAN_DAEMON="${param#podman_daemon=}"
            ;;
    esac
done

# Decode the podman command (not required for daemon mode)
PODMAN_CMD=""
if [ -n "$PODMAN_CMD_B64" ]; then
    PODMAN_CMD=$(echo "$PODMAN_CMD_B64" | base64 -d 2>/dev/null)
fi

# Require command for non-daemon mode
if [ -z "$PODMAN_CMD" ] && [ "$PODMAN_DAEMON" != "1" ]; then
    echo "===ERROR==="
    echo "No podman command provided (podman_cmd= missing)"
    sleep 2
    reboot -f
fi

log "Podman command: $PODMAN_CMD"
log "Input type: $PODMAN_INPUT"
log "Output type: $PODMAN_OUTPUT"
log "State type: $PODMAN_STATE"

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

if [ "$PODMAN_INPUT" != "none" ] && [ "$PODMAN_STATE" = "disk" ]; then
    # Both present: rootfs=vda, input=vdb, state=vdc
    INPUT_DISK="/dev/vdb"
    STATE_DISK="/dev/vdc"
elif [ "$PODMAN_STATE" = "disk" ]; then
    # Only state: rootfs=vda, state=vdb
    STATE_DISK="/dev/vdb"
elif [ "$PODMAN_INPUT" != "none" ]; then
    # Only input: rootfs=vda, input=vdb
    INPUT_DISK="/dev/vdb"
fi

# Handle Podman storage
# Note: We already mounted tmpfs over /var/lib/containers and created /var/lib/containers/storage
# early in the init (for read-only rootfs compatibility). Here we just handle the state disk case.
#
# If state disk provided, mount it at /var/lib/containers/storage (overmounting the tmpfs).
# The state disk contains storage contents directly (vfs-images/, vfs-layers/, etc.).

if [ -n "$STATE_DISK" ] && [ -b "$STATE_DISK" ]; then
    log "Mounting state disk $STATE_DISK as /var/lib/containers/storage..."
    if mount -t ext4 "$STATE_DISK" /var/lib/containers/storage 2>&1; then
        log "SUCCESS: Mounted $STATE_DISK as Podman storage"
        log "Podman storage contents:"
        [ "$QUIET_BOOT" = "0" ] && ls -la /var/lib/containers/storage/ 2>/dev/null || log "(empty)"
    else
        log "WARNING: Failed to mount state disk, using tmpfs fallback"
        PODMAN_STATE="none"
    fi
else
    log "Using tmpfs for Podman storage (ephemeral)..."
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
        PODMAN_INPUT="none"
    fi
elif [ "$PODMAN_INPUT" != "none" ]; then
    log "WARNING: No input device found, continuing without input"
    PODMAN_INPUT="none"
fi

# Configure networking if enabled
if [ "$PODMAN_NETWORK" = "1" ]; then
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

# Podman is daemonless - no need to start any daemons!
# Just verify podman is available
if [ -x "/usr/bin/podman" ]; then
    log "Podman available: $(podman --version 2>/dev/null || echo 'version unknown')"
else
    echo "===ERROR==="
    echo "Podman not found at /usr/bin/podman"
    sleep 2
    reboot -f
fi

# Daemon mode: enter command loop instead of single command execution
if [ "$PODMAN_DAEMON" = "1" ]; then
    log "=== Daemon Mode ==="

    # Find the virtio-serial port for command channel
    # virtserialport creates /dev/vportNp1 where N depends on controller order
    # Also check /dev/virtio-ports/vpdmn (symlink created by udev if available)
    VPDMN_PORT=""
    for port in /dev/vport0p1 /dev/vport1p1 /dev/vport2p1 /dev/virtio-ports/vpdmn /dev/hvc1; do
        if [ -c "$port" ]; then
            VPDMN_PORT="$port"
            log "Found virtio-serial port: $port"
            break
        fi
    done

    if [ -z "$VPDMN_PORT" ]; then
        log "ERROR: Could not find virtio-serial port for daemon mode"
        # Fall back to using console
        log "Available devices:"
        ls -la /dev/hvc* /dev/vport* /dev/virtio-ports/ 2>/dev/null || true
        sleep 5
        reboot -f
    fi

    log "Using virtio-serial port: $VPDMN_PORT"

    # Mount virtio-9p shared directory for file I/O between host and guest
    mkdir -p /mnt/share
    MOUNT_ERR=$(mount -t 9p -o trans=virtio,version=9p2000.L,cache=none vpdmn_share /mnt/share 2>&1)
    if [ $? -eq 0 ]; then
        log "Mounted virtio-9p share at /mnt/share"
    else
        log "WARNING: Could not mount virtio-9p share: $MOUNT_ERR"
        log "Available filesystems:"
        cat /proc/filesystems 2>/dev/null | head -20
    fi

    # Open bidirectional FD to the virtio-serial port
    exec 3<>"$VPDMN_PORT"

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
                # This allocates a pseudo-terminal which podman -it requires
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
if [ "$PODMAN_DAEMON" = "1" ]; then
    # Jump to graceful shutdown section
    :
else

# Prepare input if needed - set up INPUT_PATH variable for command substitution
INPUT_PATH=""
if [ "$PODMAN_INPUT" = "oci" ] && [ -d "/mnt/input" ]; then
    INPUT_PATH="/mnt/input"
elif [ "$PODMAN_INPUT" = "tar" ] && [ -d "/mnt/input" ]; then
    # Find tar file in input
    INPUT_PATH=$(find /mnt/input -name "*.tar" -o -name "*.tar.gz" | head -n 1)
    [ -z "$INPUT_PATH" ] && INPUT_PATH="/mnt/input"
elif [ "$PODMAN_INPUT" = "dir" ]; then
    INPUT_PATH="/mnt/input"
fi

# Export for command substitution
export INPUT_PATH

# Substitute {INPUT} placeholder in command with actual path
PODMAN_CMD_FINAL=$(echo "$PODMAN_CMD" | sed "s|{INPUT}|$INPUT_PATH|g")

log "=== Executing Podman Command ==="
log "Command: $PODMAN_CMD_FINAL"
log ""

# Handle interactive mode
if [ "$PODMAN_INTERACTIVE" = "1" ]; then
    # Set up terminal for interactive use
    export TERM=linux

    # Clear the "Starting container..." message from vrunner.sh
    # \r returns to start of line, \033[K clears to end of line
    printf '\r\033[K'

    # Execute the podman command with terminal attached
    # stdin/stdout/stderr go directly to the serial console
    eval "$PODMAN_CMD_FINAL"
    EXEC_EXIT_CODE=$?

    # Container exited - proceed directly to graceful shutdown
else
    # Non-interactive mode: capture output
    EXEC_OUTPUT="/tmp/podman_output.txt"
    EXEC_EXIT_CODE=0

    # Use eval to properly handle quoted arguments
    eval "$PODMAN_CMD_FINAL" > "$EXEC_OUTPUT" 2>&1 || EXEC_EXIT_CODE=$?

    log "Exit code: $EXEC_EXIT_CODE"

    # Output results based on output type
    case "$PODMAN_OUTPUT" in
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
        # Export entire podman storage
        # Tar from inside /var/lib/containers/storage so paths are vfs-images/... directly
        # This works with the merger which extracts to OUTPUT_DIR=/var/lib/containers/storage
        echo "Packaging Podman storage..."
        if ! cd /var/lib/containers/storage; then
            echo "===ERROR==="
            echo "Failed to cd to /var/lib/containers/storage"
            echo "Contents of /var/lib/containers:"
            ls -la /var/lib/containers/ 2>&1 || echo "(not found)"
            poweroff -f
            exit 1
        fi
        tar -cf /tmp/storage.tar .

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
        echo "Unknown output type: $PODMAN_OUTPUT"
        ;;
    esac
fi

fi  # End of non-daemon mode block

# Graceful shutdown: unmount filesystems, sync
log "=== Shutting down gracefully ==="

# Podman is daemonless - nothing to stop!

# Sync all filesystems
sync

# Unmount state disk if mounted (ensures all data is flushed)
if mount | grep -q "/var/lib/containers"; then
    log "Unmounting Podman state disk..."
    # Force sync to the block device before unmount
    sync
    umount /var/lib/containers || {
        log "Warning: umount failed, trying lazy unmount"
        umount -l /var/lib/containers 2>/dev/null || true
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

log "=== vpdmn Complete ==="
# Use poweroff instead of reboot to ensure clean shutdown
poweroff -f
