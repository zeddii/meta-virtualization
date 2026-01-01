# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# Kernel config fragments for vdkr/vpdmn:
# - 9P filesystem for virtio-9p file sharing (volume mounts)
# - Squashfs and overlayfs for rootfs images

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://9p.cfg file://squashfs.cfg"
