#!/usr/bin/env bash
#
# update_blobs.sh — regenerate vendor + device proprietary blobs for udon/CPH2487
# from an official firmware dump produced by unpack_firmware.sh.
#
# Run this from the TOP of your ROM source tree (where device/ and vendor/ live),
# e.g. your Crave workspace /tmp/src/android.
#
#   tools/firmware_update/unpack_firmware.sh CPH2487_16.0.5.1002_EX01.zip /tmp/dump
#   tools/firmware_update/update_blobs.sh  /tmp/dump
#
# What it does:
#   * extracts proprietary blobs into vendor/oneplus/{sm8475-common,sm8450-common,udon,CPH2487}
#     (self-contained extract-files.sh - no vendor/lineage extract_utils needed)
#   * regenerates Android.bp / *.mk / wrapper makefiles
#   * refreshes build fingerprint, security patch and device build props
#
set -euo pipefail

log(){ echo -e "\033[1;36m[*]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $*"; }
die(){ echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

DUMP="${1:-}"; [ -z "$DUMP" ] && { echo "usage: update_blobs.sh <dump_dir>" >&2; exit 1; }
[ -d "$DUMP" ] || die "dump dir not found: $DUMP (run unpack_firmware.sh first)"

# Resolve ROM root: assume CWD is the top of the source tree.
ROOT="${ANDROID_BUILD_TOP:-$PWD}"
cd "$ROOT"

DEVICE_COMMON_DIR="device/oneplus/sm8475-common"
[ -d "$DEVICE_COMMON_DIR" ] || die "device tree not found at $DEVICE_COMMON_DIR (run from ROM root)"

export ANDROID_ROOT="$ROOT"

###############################################################################
# 1. Extract proprietary blobs
###############################################################################
log "Extracting blobs from dump: $DUMP"
for d in sm8475-common sm8450-common udon CPH2487; do
  [ -f "device/oneplus/$d/extract-files.sh" ] || { warn "no extract-files.sh in device/oneplus/$d - skipped"; continue; }
  chmod +x "device/oneplus/$d/extract-files.sh" 2>/dev/null || true
  # The common script is self-contained: the common trees extract their own
  # list; the udon/CPH2487 wrappers additionally extract the per-device list
  # (device wrappers export DEVICE + DEVICE_COMMON before exec'ing it).
  ( cd "device/oneplus/$d" && ./extract-files.sh "$DUMP" ) \
    || die "extract-files.sh failed for $d - fix the dump/proprietary-files.txt and re-run"
done

###############################################################################
# 2. Regenerate vendor makefiles (idempotent - already run by step 1, but
#    harmless to repeat and required if step 1 was run in the past)
###############################################################################
log "Regenerating vendor Android.bp / *.mk"
for d in udon CPH2487 sm8475-common sm8450-common; do
  if [ -f "device/oneplus/$d/setup-makefiles.sh" ]; then
    ( cd "device/oneplus/$d" && ./setup-makefiles.sh ) || warn "setup-makefiles for $d failed"
  fi
done

###############################################################################
# 3. Refresh fingerprint + security patch from the dump
###############################################################################
log "Reading build props from the dump ..."
FP="$(grep -m1 -h '^ro.build.fingerprint=' \
        "$DUMP"/system/system/build.prop \
        "$DUMP"/system/build.prop \
        "$DUMP"/vendor/build.prop 2>/dev/null | cut -d= -f2- || true)"
DESC="$(grep -m1 -h '^ro.build.description=' \
        "$DUMP"/system/system/build.prop "$DUMP"/system/build.prop 2>/dev/null | cut -d= -f2- || true)"
SPL="$(grep -m1 -h '^ro.vendor.build.security_patch=' "$DUMP"/vendor/build.prop 2>/dev/null | cut -d= -f2- || true)"
[ -z "$SPL" ] && SPL="$(grep -m1 -h '^ro.build.version.security_patch=' "$DUMP"/system/system/build.prop "$DUMP"/system/build.prop 2>/dev/null | cut -d= -f2- || true)"

echo "    fingerprint : ${FP:-<not found>}"
echo "    description : ${DESC:-<not found>}"
echo "    sec patch   : ${SPL:-<not found>}"

patch_product_mk(){
  local mk="$1"
  [ -f "$mk" ] || return 0
  [ -n "$FP" ]   && sed -i "s|^BUILD_FINGERPRINT := .*|BUILD_FINGERPRINT := $FP|" "$mk"
  [ -n "$DESC" ] && sed -i "s|PRIVATE_BUILD_DESC=\\\"[^\\\"]*\\\"|PRIVATE_BUILD_DESC=\\\"$DESC\\\"|" "$mk"
  log "  updated $(basename "$mk")"
}
for d in "device/oneplus/udon" "device/oneplus/CPH2487" "device/oneplus/sm8475-common" "device/oneplus/sm8450-common"; do
  [ -d "$d" ] || continue
  for f in lineage_udon.mk lineage_CPH2487.mk crdroid_udon.mk aosp_udon.mk evolution_udon.mk rising_udon.mk pixelos_udon.mk matrixx_udon.mk derp_udon.mk bliss_udon.mk; do
    patch_product_mk "$d/$f"
  done
  if [ -n "$SPL" ]; then
    for bc in "$d/BoardConfigCommon.mk" "$d/BoardConfig.mk"; do
      [ -f "$bc" ] || continue
      sed -i "s|^BOOT_SECURITY_PATCH := .*|BOOT_SECURITY_PATCH := $SPL|" "$bc"
      sed -i "s|^VENDOR_SECURITY_PATCH := .*|VENDOR_SECURITY_PATCH := $SPL|" "$bc"
      log "  security patch -> $SPL in $(basename $bc)"
    done
  fi
done

echo
log "Done. Review changes then commit device + vendor trees."
cat <<'TIP'

  for r in device/oneplus/udon device/oneplus/CPH2487 \
           device/oneplus/sm8475-common device/oneplus/sm8450-common \
           vendor/oneplus/udon vendor/oneplus/CPH2487 \
           vendor/oneplus/sm8475-common vendor/oneplus/sm8450-common; do
    [ -d "$r/.git" ] && ( cd "$r" && git add -A && git commit -m "Update blobs to OxygenOS 16.0.5.1002 (EX01)" )
  done
  # mirror the sm8450/sm8475 pairs if you keep them in sync, then push,
  # re-sync + build:  breakfast crdroid_udon && mka bacon
TIP
