#!/bin/bash
#
# Copyright (C) 2016 The CyanogenMod Project
# Copyright (C) 2017-2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#
# Regenerate the vendor makefiles (Android.bp, <tree>-vendor.mk and the
# CPH2487/sm8475 wrapper makefile) from the already-extracted blobs in
# vendor/oneplus/<tree>/proprietary/ - no firmware dump required.
#
# Run from anywhere inside a synced ROM source tree:
#
#   device/oneplus/sm8475-common/setup-makefiles.sh
#
# The device wrappers (device/oneplus/{udon,CPH2487}/setup-makefiles.sh)
# export VENDOR / DEVICE / DEVICE_COMMON and exec this script; DEVICE
# additionally selects the per-device vendor tree to be regenerated.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VENDOR="${VENDOR:-oneplus}"
# The script lives in device/oneplus/<common-tree>; default to our own name.
DEVICE_COMMON="${DEVICE_COMMON:-$(basename "$SCRIPT_DIR")}"

# Reuse the implementation from extract-files.sh - its main() does not run
# when the file is sourced, so this only pulls in the helpers.
source "$SCRIPT_DIR/extract-files.sh"

setup_main
