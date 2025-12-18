#!/bin/sh
# vdkr-preinit.sh
# Minimal init for initramfs - mounts rootfs and does switch_root
#
# This script runs from the initramfs and:
# 1. Mounts essential filesystems
# 2. Finds and mounts the rootfs.img (virtio-blk)
# 3. Executes switch_root to the real root filesystem
#
# The real init (/init or /sbin/init on rootfs) then runs vdkr-init.sh logic

echo "=== vdkr preinit ==="

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Wait for block devices to appear
echo "Waiting for block devices..."
sleep 2

# Show available block devices
echo "Block devices:"
ls -la /dev/vd* 2>/dev/null || echo "No virtio block devices found"

# The rootfs.img is always the first virtio-blk device (/dev/vda)
# Additional devices (input, state) come after
ROOTFS_DEV="/dev/vda"

if [ ! -b "$ROOTFS_DEV" ]; then
    echo "ERROR: Rootfs device $ROOTFS_DEV not found!"
    echo "Available devices:"
    ls -la /dev/
    sleep 10
    reboot -f
fi

# Create mount point and mount rootfs
mkdir -p /mnt/root
echo "Mounting rootfs from $ROOTFS_DEV..."

if ! mount -t ext4 -o ro "$ROOTFS_DEV" /mnt/root; then
    echo "ERROR: Failed to mount rootfs!"
    sleep 10
    reboot -f
fi

echo "Rootfs mounted successfully"
echo "Contents:"
ls -la /mnt/root/

# Verify init exists on rootfs
if [ ! -x /mnt/root/init ] && [ ! -x /mnt/root/sbin/init ]; then
    echo "ERROR: No init found on rootfs!"
    sleep 10
    reboot -f
fi

# Clean up before switch_root
umount /proc
umount /sys
# Note: don't unmount /dev - switch_root needs it

# Switch to real root
# switch_root will:
# 1. Mount the new root
# 2. chroot into it
# 3. Execute the new init
# 4. Delete everything in the old initramfs
echo "Switching to real root..."

if [ -x /mnt/root/init ]; then
    exec switch_root /mnt/root /init
elif [ -x /mnt/root/sbin/init ]; then
    exec switch_root /mnt/root /sbin/init
fi

# If we get here, switch_root failed
echo "ERROR: switch_root failed!"
sleep 10
reboot -f
