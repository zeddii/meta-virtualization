# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# Add 9P filesystem support for vdkr/vpdmn virtio-9p file sharing

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://9p.cfg"
