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
# What it does (standard LineageOS extract_utils flow):
#   * extracts/lists proprietary blobs into vendor/oneplus/{udon,CPH2487,sm8475-common}
#   * regenerates Android.bp / *.mk / BoardConfigVendor.mk
#   * refreshes build fingerprint, security patch and device build props
#
set -euo pipefail

DUMP="${1:-}"; [ -z "$DUMP" ] && { echo "usage: update_blobs.sh <dump_dir>"; exit 1; }
[ -d "$DUMP" ] || { echo "dump dir not found: $DUMP (run unpack_firmware.sh first)"; exit 1; }

# Resolve ROM root: assume CWD is the top of the source tree.
ROOT="${ANDROID_BUILD_TOP:-$PWD}"
cd "$ROOT"

DEVICE_COMMON_DIR="device/oneplus/sm8475-common"
DEVICE_DIR="device/oneplus/udon"
[ -d "$DEVICE_COMMON_DIR" ] || die "device tree not found at $DEVICE_COMMON_DIR (run from ROM root)"

log(){ echo -e "\033[1;36m[*]\033[0m $*"; }
die(){ echo -e "\033[1;31m[x]\033[0m $*"; exit 1; }

export ANDROID_ROOT="$ROOT"

###############################################################################
# 1. Extract proprietary blobs (LineageOS extract_utils)
###############################################################################
log "Extracting blobs from dump: $DUMP"
chmod +x "$DEVICE_COMMON_DIR/extract-files.sh" "$DEVICE_DIR/extract-files.sh" 2>/dev/null || true

# extract-files.sh accepts the path to the system dump as its first argument.
# The common tree owns the blob list; the udon device tree delegates to it.
( cd "$DEVICE_COMMON_DIR" && ./extract-files.sh "$DUMP" ) || \
  die "extract-files.sh failed. Ensure vendor/lineage/build/tools/extract_utils.sh is present (repo sync)."

# Also run the per-device (CPH2487) extraction if that tree is present
if [ -d "device/oneplus/CPH2487" ] && [ -f device/oneplus/CPH2487/extract-files.sh ]; then
  ( cd device/oneplus/CPH2487 && ./extract-files.sh "$DUMP" ) || warn "CPH2487 extract skipped/failed"
fi

###############################################################################
# 2. Regenerate vendor makefiles
###############################################################################
log "Regenerating vendor Android.bp / *.mk"
for d in sm8475-common udon CPH2487; do
  if [ -f "vendor/oneplus/$d/setup-makefiles.sh" ]; then
    ( cd "vendor/oneplus/$d" && ./setup-makefiles.sh ) || warn "setup-makefiles for $d failed"
  fi
  if [ -f "device/oneplus/$d/setup-makefiles.sh" ]; then
    ( cd "device/oneplus/$d" && ./setup-makefiles.sh ) || true
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
  [ -n "$DESC" ] && sed -i "s|PRIVATE_BUILD_DESC=\\\"[^\"]*\\\"|PRIVATE_BUILD_DESC=\\\"$DESC\\\"|" "$mk"
  log "  updated $(basename "$mk")"
}
for d in "$DEVICE_DIR" device/oneplus/CPH2487 "$DEVICE_COMMON_DIR" device/oneplus/sm8450-common; do
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

  cd device/oneplus/udon           && git add -A && git commit -m "udon: update blobs to 16.0.5.1002"
  cd device/oneplus/sm8475-common && git add -A && git commit -m "sm8475-common: update blobs to 16.0.5.1002"
  cd vendor/oneplus/sm8475-common && git add -A && git commit -m "vendor: update proprietary blobs to 16.0.5.1002"
  # then push each, and re-sync + build:  breakfast crdroid_udon && mka bacon
TIP
