#!/usr/bin/env bash
#
# unpack_firmware.sh — turn an official OnePlus 11R (CPH2487) firmware package
# into a rooted "system dump" tree ready for LineageOS extract-files.sh.
#
# Supports BOTH package formats:
#   1) Full OTA  (.zip containing payload.bin)          -> needs payload-dumper-go
#   2) QFIL/QPST (.zip containing raw .img / super.img)  -> needs lpunpack + ext4 reader
#
# Output layout (use this with extract-files.sh / update_blobs.sh):
#   <OUT>/system/system/...
#   <OUT>/system/system_ext/...
#   <OUT>/system/product/...
#   <OUT>/vendor/...
#   <OUT>/odm/...
#   <OUT>/system_dlkm ...  etc.
#
# Usage:
#   unpack_firmware.sh <firmware.zip|firmware_dir> <OUT_DIR>
#
# No root required (ext4 images are read in userspace).
#
set -euo pipefail

PKG="${1:-}"; OUT="${2:-$PWD/dump}"
[ -z "$PKG" ] && { echo "usage: unpack_firmware.sh <firmware.zip|dir> <OUT_DIR>"; exit 1; }

log(){ echo -e "\033[1;36m[*]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $*"; }
die(){ echo -e "\033[1;31m[x]\033[0m $*"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

need(){ command -v "$1" >/dev/null 2>&1 || { warn "missing tool: $1  (see tools/firmware_update/README.md)"; return 1; }; }

###############################################################################
# 1. Locate images inside the package
###############################################################################
SRC="$WORK/src"; mkdir -p "$SRC"
if [ -d "$PKG" ]; then
  log "Using extracted firmware directory: $PKG"
  cp -a "$PKG"/. "$SRC"/ 2>/dev/null || true
else
  log "Extracting firmware zip (this is large)..."
  command -v unzip >/dev/null || die "unzip not found"
  unzip -o -q "$PKG" -d "$SRC" || die "unzip failed"
fi

# Normalise: QFIL packs images under a sub-folder; find them.
find "$SRC" -type f -name '*.img' 2>/dev/null | sed 's|.*/||' | sort -u | while read -r i; do log "  found image: $i"; done

PAYLOAD="$(find "$SRC" -name payload.bin | head -1 || true)"
SUPERIMG="$(find "$SRC" -name 'super.img*' -o -name 'super_*.img' 2>/dev/null | head -1 || true)"

###############################################################################
# 2. Partition image -> extraction
###############################################################################
extract_ext4(){   # <image_file> <mount_label>
  local img="$1" label="$2" dest="$OUT/$label"
  [ -f "$img" ] || { warn "no image for $label"; return 0; }
  log "Extracting $label from $(basename "$img") ..."
  mkdir -p "$dest"
  if command -v debugfs >/dev/null 2>&1; then
    # fast, reliable e2fsprogs userspace read (no root)
    ( cd "$dest" && debugfs -R 'rdump / .' "$img" >/dev/null 2>&1 ) \
      || warn "debugfs read failed for $label"
  elif python3 -c 'import ext4' 2>/dev/null; then
    python3 "$(dirname "$0")/ext4_dump.py" "$img" "$dest" || warn "ext4_dump failed for $label"
  elif command -v 7z >/dev/null 2>&1; then
    7z x -y -o"$dest" "$img" >/dev/null || warn "7z read failed for $label"
  else
    die "No ext4 reader available. Install e2fsprogs (debugfs), or: pip install ext4, or install p7zip-full."
  fi
}

unpack_super(){    # <super.img>
  local super="$1" d="$WORK/lpunpacked"; mkdir -p "$d"
  # Convert sparse -> raw if needed
  if head -c4 "$super" | xxd -p 2>/dev/null | grep -qi '3aff26ed'; then
    log "super.img is sparse; converting to raw ..."
    if command -v simg2img >/dev/null 2>&1; then simg2img "$super" "$d/super.raw.img"; super="$d/super.raw.img"
    else die "super is sparse but simg2img missing (install android-sdk-libsparse-utils)."; fi
  fi
  if command -v lpunpack >/dev/null 2>&1; then
    lpunpack "$super" "$d" || die "lpunpack failed"
  elif [ -f "$(dirname "$0")/lpunpack.py" ]; then
    python3 "$(dirname "$0")/lpunpack.py" "$super" "$d" || die "lpunpack.py failed (pip install liblp? )"
  else
    die "Need lpunpack. On a ROM source tree: use system/extras/partition_tools/lpunpack (build with 'm lpunpack') or grab lpunpack.py."
  fi
  for p in system system_ext product vendor odm vendor_dlkm odm_dlkm system_dlkm; do
    img="$(find "$d" -name "${p}.img" | head -1 || true)"
    [ -n "$img" ] && extract_ext4 "$img" "$p"
  done
}

###############################################################################
# 3. Dispatch
###############################################################################
if [ -n "$PAYLOAD" ]; then
  log "Found payload.bin (full OTA)."
  if command -v payload-dumper-go >/dev/null 2>&1; then
    payload-dumper-go -p system,system_ext,product,vendor,odm,vendor_dlkm,odm_dlkm,system_dlkm -o "$WORK/payload" "$PAYLOAD"
    for p in system system_ext product vendor odm vendor_dlkm odm_dlkm system_dlkm; do
      img="$WORK/payload/$p.img"; [ -f "$img" ] && extract_ext4 "$img" "$p"
    done
  else
    die "payload.bin present but payload-dumper-go not installed.
       Install:  https://github.com/ssut/payload-dumper-go/releases  (single static binary)
       Or use the QFIL/QPST package (super.img) instead."
  fi
elif [ -n "$SUPERIMG" ]; then
  log "Found super image: $SUPERIMG"
  # QFIL may also ship vendor/odm as standalone images; handle super first.
  unpack_super "$SUPERIMG"
  # Pick up any standalone partition images present (vendor.img, odm.img, etc.)
  for p in system system_ext product vendor odm vendor_dlkm odm_dlkm system_dlkm; do
    [ -d "$OUT/$p" ] && continue
    img="$(find "$SRC" -maxdepth 3 -name "${p}.img" | head -1 || true)"
    [ -n "$img" ] && extract_ext4 "$img" "$p"
  done
else
  die "Could not find payload.bin or super.img in the package."
fi

###############################################################################
# 4. Arrange into the layout extract-files expects
###############################################################################
log "Arranging dump layout ..."
mkdir -p "$OUT/system"
# system image already mounts at / ; Lineage expects system/system, system/system_ext, system/product
[ -d "$OUT/system/system" ]  || { [ -d "$OUT/system_ext" ] && mv "$OUT/system_ext" "$OUT/system/system_ext" 2>/dev/null || true; }
[ -d "$OUT/system/system_ext" ] || true
[ -d "$OUT/system/product" ]  || { [ -d "$OUT/product" ]    && mv "$OUT/product"    "$OUT/system/product"    2>/dev/null || true; }
# if $OUT/system is the root itself (debugfs dumped /), put it under system/system
if [ -f "$OUT/system/build.prop" ] && [ ! -d "$OUT/system/system" ]; then
  mkdir -p "$WORK/sysroot" && mv "$OUT/system"/* "$WORK/sysroot"/ 2>/dev/null || true
  mkdir -p "$OUT/system/system" && mv "$WORK/sysroot"/* "$OUT/system/system"/ 2>/dev/null || true
fi

echo
log "DONE. System dump root: $OUT"
log "Next:  $(dirname "$0")/update_blobs.sh $OUT"
