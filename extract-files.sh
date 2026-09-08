#!/bin/bash
#
# Copyright (C) 2016 The CyanogenMod Project
# Copyright (C) 2017-2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#
# Proprietary blob extraction for the common OnePlus SM8475/SM8450 (taro)
# platform tree - and, when called through a device wrapper (udon / CPH2487),
# for that device tree as well.
#
# Usage (from anywhere inside a synced ROM source tree):
#
#   device/oneplus/sm8475-common/extract-files.sh <firmware-dump>
#
# <firmware-dump> is the rooted filesystem layout produced by
# tools/firmware_update/unpack_firmware.sh:
#
#   <dump>/system/... <dump>/system_ext/... <dump>/product/...
#   <dump>/vendor/... <dump>/odm/...
#
# The script is self-contained: it does NOT depend on the LineageOS
# extract_utils helper (the current crDroid 16 / LineageOS 23.2 sources do
# not ship vendor/lineage/build/tools/extract_utils.sh). For each tree it:
#
#   * copies every file listed in proprietary-files.txt (one path per line,
#     relative to the partition root; a trailing "|<sha1>" pins the expected
#     hash of the stock file) into vendor/oneplus/<tree>/proprietary/
#   * regenerates vendor/oneplus/<tree>/<name>-vendor.mk, the
#     CPH2487/sm8475 wrapper makefile and Android.bp
#
# The device wrappers export VENDOR / DEVICE / DEVICE_COMMON before exec'ing
# this script. When DEVICE is set and
# device/oneplus/$DEVICE/proprietary-files.txt exists, the device tree is
# processed in the same run.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VENDOR="${VENDOR:-oneplus}"
# The script lives in device/oneplus/<common-tree>; default to our own name.
DEVICE_COMMON="${DEVICE_COMMON:-$(basename "$SCRIPT_DIR")}"
DEVICE="${DEVICE:-}"

# ROM root = three levels up from device/oneplus/<tree>
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [ ! -d "$ROOT/device/oneplus" ]; then
    echo "error: $ROOT does not look like the top of a ROM source tree" >&2
    exit 1
fi
export ANDROID_ROOT="$ROOT"

log()  { echo -e "\033[1;36m[*]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

MISSING_TOTAL=0

###############################################################################
# Blob extraction
###############################################################################

# find_dump_file <rel>: echo the dump path if the file is present, else fail.
# Handles both flat and A/B-style nested "system/system" dumps.
find_dump_file() {
    local rel="$1" cand
    cand="$DUMP/$rel"
    [ -f "$cand" ] && { echo "$cand"; return 0; }
    case "$rel" in
        system/*)
            cand="$DUMP/system/system/${rel#system/}"
            [ -f "$cand" ] && { echo "$cand"; return 0; }
            ;;
    esac
    return 1
}

# extract_tree <dev> <proprietary-files.txt>
extract_tree() {
    local dev="$1" list="$2"
    local out="$ROOT/vendor/$VENDOR/$dev"
    local ok=0 missing=0
    local line file src dst want got

    [ -f "$list" ] || { warn "$dev: no proprietary-files.txt at $list - skipped"; return 0; }

    log "Extracting $dev blobs ($list) -> $out"
    mkdir -p "$out/proprietary"

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        file="${line%%|*}"
        # trim whitespace + surrounding quotes
        file="$(printf '%s' "$file" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')"
        case "$file" in ''|\#*) continue ;; esac
        # a ";OVERRIDES=..." suffix is a module-override directive, not part of
        # the path (kept in the list, not applied by this extractor)
        if [[ "$file" == *";OVERRIDES="* ]]; then
            warn "  $dev: OVERRIDES directive preserved in list but not applied by this extractor: ${file#*;}"
            file="${file%%;*}"
        fi

        if src="$(find_dump_file "$file")"; then
            dst="$out/proprietary/$file"
            mkdir -p "$(dirname "$dst")"
            cp -f "$src" "$dst"
            # verify a pinned hash when the list carries one; refresh the pin
            # automatically when the stock file changed
            if [[ "$line" == *"|"* ]]; then
                want="${line#*|}"
                got="$(sha1sum "$dst" | cut -d' ' -f1)"
                if [ "$want" != "$got" ]; then
                    warn "PIN CHANGED $dev: $file (list: $want, dump: $got) - updating list"
                    local tmp_list; tmp_list="$(mktemp)"
                    awk -v f="$file" -v h="$got" 'index($0, f "|") == 1 { print f "|" h; next } { print }' "$list" > "$tmp_list" && mv "$tmp_list" "$list"
                fi
            fi
            ok=$((ok+1))
        else
            warn "MISSING $dev: $file (not in dump)"
            missing=$((missing+1))
        fi
    done < "$list"

    log "  $dev: $ok extracted, $missing missing"
    MISSING_TOTAL=$((MISSING_TOTAL+missing))

    write_makefiles "$dev"
}

###############################################################################
# Makefile / Android.bp generation
###############################################################################

# copy_out_var <partition>: the TARGET_COPY_OUT variable for a partition prefix
copy_out_var() {
    case "$1" in
        vendor)      echo '$(TARGET_COPY_OUT_VENDOR)' ;;
        odm)         echo '$(TARGET_COPY_OUT_ODM)' ;;
        product)     echo '$(TARGET_COPY_OUT_PRODUCT)' ;;
        system_ext)  echo '$(TARGET_COPY_OUT_SYSTEM_EXT)' ;;
        system)      echo '$(TARGET_COPY_OUT_SYSTEM)' ;;
        vendor_dlkm) echo '$(TARGET_COPY_OUT_VENDOR_DLKM)' ;;
        *)           return 1 ;;
    esac
}

# specific_flag <partition>: Soong *_specific flag for a partition prefix
specific_flag() {
    case "$1" in
        vendor)     echo "soc_specific" ;;
        odm)        echo "device_specific" ;;
        product)    echo "product_specific" ;;
        system_ext) echo "system_ext_specific" ;;
        *)          return 1 ;;
    esac
}

# write_vendor_mk <dev>: regenerate the PRODUCT_COPY_FILES makefile.
# The build always includes the device list under the name udon-vendor.mk and
# the common list under the name sm8450-common-vendor.mk (legacy pair naming).
write_vendor_mk() {
    local dev="$1"
    local realname
    case "$dev" in
        udon|CPH2487) realname="udon" ;;
        *)            realname="sm8450-common" ;;
    esac
    local out="$ROOT/vendor/$VENDOR/$dev"
    local mk="$out/${realname}-vendor.mk"

    if [ ! -d "$out/proprietary" ]; then
        warn "$dev: $out/proprietary not found, run extract-files.sh first"
        return 0
    fi

    local entries=() f part var
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        f="${f#proprietary/}"
        part="${f%%/*}"
        var="$(copy_out_var "$part")" || { warn "  $dev: unknown partition '$part' in $f, skipped"; continue; }
        entries+=("vendor/$VENDOR/$dev/proprietary/$f:$var/${f#"$part"/}")
    done < <(cd "$out" && find proprietary -type f -print | LC_ALL=C sort)

    {
        echo "# Automatically generated file. DO NOT MODIFY"
        echo "#"
        echo "# This file is generated by device/oneplus/$dev/setup-makefiles.sh"
        echo ""
        echo "PRODUCT_SOONG_NAMESPACES += \\"
        echo "    vendor/$VENDOR/$dev"
        echo ""
        if [ ${#entries[@]} -gt 0 ]; then
            echo "PRODUCT_COPY_FILES += \\"
            local n=0 total=${#entries[@]} e
            for e in "${entries[@]}"; do
                n=$((n+1))
                if [ "$n" -lt "$total" ]; then
                    echo "    $e \\"
                else
                    echo "    $e"
                fi
            done
        fi
    } > "$mk"
    log "  wrote $mk (${#entries[@]} files)"
}

# write_wrapper_mk <dev>: regenerate the cross-tree wrapper makefile.
write_wrapper_mk() {
    local dev="$1"
    local out="$ROOT/vendor/$VENDOR/$dev"
    case "$dev" in
        udon|CPH2487)
            cat > "$out/CPH2487-vendor.mk" <<'EOF'
#
# Copyright (C) 2023-2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

$(call inherit-product-if-exists, vendor/oneplus/udon/udon-vendor.mk)
$(call inherit-product-if-exists, vendor/oneplus/CPH2487/udon-vendor.mk)
EOF
            ;;
        *)
            cat > "$out/sm8475-common-vendor.mk" <<'EOF'
#
# Copyright (C) 2023-2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

$(call inherit-product-if-exists, vendor/oneplus/sm8450-common/sm8450-common-vendor.mk)
$(call inherit-product-if-exists, vendor/oneplus/sm8475-common/sm8450-common-vendor.mk)
EOF
            ;;
    esac
}

# write_android_bp <dev>: reconcile Android.bp against proprietary/.
#
# Existing module blocks are kept verbatim while all of their sources still
# exist; blocks whose sources vanished are dropped. New vintf manifest xmls,
# apps and jars that have no module yet are appended in canonical form.
# New cc_prebuilt_library_shared modules are intentionally NOT created
# automatically (promoting a library to a module is a build-policy decision);
# new .so files are still installed via PRODUCT_COPY_FILES.
write_android_bp() {
    local dev="$1"
    local out="$ROOT/vendor/$VENDOR/$dev"
    local bp="$out/Android.bp"
    local prop="$out/proprietary"
    if [ ! -d "$prop" ]; then
        warn "$dev: $prop not found, skipping Android.bp"
        return 0
    fi

    local tmp; tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    # --- parse the existing file into blocks: "idx \t type \t name \t src;src;..." ---
    : > "$tmp/index"
    if [ -f "$bp" ]; then
        awk -v dir="$tmp" '
            function flush(    idx2, name, srcs, n, i, s) {
                if (type == "") return
                idx2 = ++idx
                name = ""; srcs = ""
                n = split(buf, L, "\n")
                for (i = 1; i <= n; i++) {
                    if (L[i] ~ /^[ \t]*name:/)  { s = L[i]; sub(/.*name:[ \t]*"/, "", s); sub(/".*/, "", s); name = s }
                    if (L[i] ~ /^[ \t]*src:/)   { s = L[i]; sub(/.*src:[ \t]*"/, "", s); sub(/".*/, "", s); srcs = srcs s ";" }
                    if (L[i] ~ /^[ \t]*apk:/)   { s = L[i]; sub(/.*apk:[ \t]*"/, "", s); sub(/".*/, "", s); srcs = srcs s ";" }
                    if (L[i] ~ /^[ \t]*srcs:/)  { while (match(L[i], /"[^"]*"/)) { s = substr(L[i], RSTART+1, RLENGTH-2); srcs = srcs s "; "; L[i] = substr(L[i], RSTART+RLENGTH) } }
                    if (L[i] ~ /^[ \t]*jars:/)  { while (match(L[i], /"[^"]*"/)) { s = substr(L[i], RSTART+1, RLENGTH-2); srcs = srcs s "; "; L[i] = substr(L[i], RSTART+RLENGTH) } }
                }
                sub(/; $/, "", srcs); sub(/^; /, "", srcs)
                printf "%d\t%s\t%s\t%s\n", idx2, type, name, srcs >> (dir "/index")
                printf "%s", buf > (dir sprintf("/blk_%03d", idx2))
                type = ""
            }
            !inblk && /^[a-z_]+ \{/ { type = $1; sub(/ \{$/, "", type); buf = $0 "\n"; inblk = 1; next }
            inblk { buf = buf $0 "\n"; if ($0 == "}") { inblk = 0; flush() } }
            END { flush() }
        ' "$bp"
    fi

    # all sources referenced by existing blocks (kept or dropped)
    declare -A existing_srcs=()
    local i type name srcs s p
    while IFS=$'\t' read -r i type name srcs; do
        [ -n "$srcs" ] || continue
        for p in ${srcs//;/ }; do
            existing_srcs["$p"]=1
        done
    done < "$tmp/index"

    # --- decide keep/drop for each existing block, in file order ---
    local kept_blocks="" f
    declare -A used_names=()
    while IFS=$'\t' read -r i type name srcs; do
        case "$type" in
            prebuilt_etc_xml|android_app_import|dex_import|cc_prebuilt_library_shared) ;;
            soong_namespace) continue ;;
            *) [ -n "$type" ] && warn "  $dev: unknown module type '$type' in Android.bp, dropped on regen" ; continue ;;
        esac
        local alive=1
        for p in ${srcs//;/ }; do
            [ -f "$out/$p" ] || { alive=0; break; }
        done
        if [ "$alive" -eq 1 ]; then
            kept_blocks+="$(cat "$tmp/$(printf 'blk_%03d' "$i")")"$'\n\n'
            if [ -n "$name" ]; then used_names["$name"]=1; fi
        else
            log "  $dev: dropping stale module '$name' ($type)"
        fi
    done < "$tmp/index"

    : > "$tmp/new"

    # --- canonical emitters for new modules ---
    emit_xml() { # <src>
        local s="$1" part flag nm
        part="${s#proprietary/}"; part="${part%%/*}"
        nm="${s##*/}"; nm="${nm%.xml}"
        if [ -n "${used_names[$nm]:-}" ]; then nm="${part}_${nm}"; warn "  $dev: vintf name clash, using $nm"; fi
        used_names["$nm"]=1
        flag="$(specific_flag "$part" || true)"
        {
            echo "prebuilt_etc_xml {"
            printf '\tname: "%s",\n' "$nm"
            printf '\towner: "oneplus",\n'
            printf '\tsrc: "%s",\n' "$s"
            printf '\tfilename_from_src: true,\n'
            printf '\tsub_dir: "vintf/manifest",\n'
            if [ -n "$flag" ]; then printf '\t%s: true,\n' "$flag"; fi
            echo "}"
        } >> "$tmp/new"
        echo >> "$tmp/new"
    }
    emit_app() { # <apk>
        local s="$1" part flag nm priv
        part="${s#proprietary/}"; part="${part%%/*}"
        nm="${s##*/}"; nm="${nm%.apk}"
        if [ -n "${used_names[$nm]:-}" ]; then nm="${part}_${nm}"; warn "  $dev: app name clash, using $nm"; fi
        used_names["$nm"]=1
        flag="$(specific_flag "$part" || true)"
        case "$s" in *priv-app/*) priv=1 ;; *) priv=0 ;; esac
        {
            echo "android_app_import {"
            printf '\tname: "%s",\n' "$nm"
            printf '\towner: "oneplus",\n'
            printf '\tapk: "%s",\n' "$s"
            printf '\tcertificate: "platform",\n'
            printf '\tdex_preopt: {\n'
            printf '\t\tenabled: false,\n'
            printf '\t},\n'
            if [ "$priv" -eq 1 ]; then printf '\tprivileged: true,\n'; fi
            if [ -n "$flag" ]; then printf '\t%s: true,\n' "$flag"; fi
            echo "}"
        } >> "$tmp/new"
        echo >> "$tmp/new"
    }
    emit_jar() { # <jar>
        local s="$1" part flag nm
        part="${s#proprietary/}"; part="${part%%/*}"
        nm="${s##*/}"; nm="${nm%.jar}"
        if [ -n "${used_names[$nm]:-}" ]; then nm="${part}_${nm}"; warn "  $dev: jar name clash, using $nm"; fi
        used_names["$nm"]=1
        flag="$(specific_flag "$part" || true)"
        {
            echo "dex_import {"
            printf '\tname: "%s",\n' "$nm"
            printf '\towner: "oneplus",\n'
            printf '\tjars: ["%s"],\n' "$s"
            if [ -n "$flag" ]; then printf '\t%s: true,\n' "$flag"; fi
            echo "}"
        } >> "$tmp/new"
        echo >> "$tmp/new"
    }

    # --- detect new modules present in proprietary/ but not in the file ---
    # (find runs inside $out, so $f already includes the "proprietary/" prefix)
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -z "${existing_srcs[$f]:-}" ]; then emit_xml "$f"; fi
    done < <(cd "$out" && find proprietary -type f -path "*/etc/vintf/manifest/*.xml" | LC_ALL=C sort)
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -z "${existing_srcs[$f]:-}" ]; then emit_app "$f"; fi
    done < <(cd "$out" && find proprietary -type f \( -path "*/app/*/*.apk" -o -path "*/priv-app/*/*.apk" \) | LC_ALL=C sort)
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -z "${existing_srcs[$f]:-}" ]; then emit_jar "$f"; fi
    done < <(cd "$out" && find proprietary -type f -path "*/framework/*.jar" | LC_ALL=C sort)

    # --- reassemble ---
    {
        echo "// Automatically generated file. DO NOT MODIFY"
        echo "//"
        echo "// This file is generated by device/oneplus/$dev/setup-makefiles.sh"
        echo ""
        echo "soong_namespace {"
        echo "}"
        echo ""
        if [ -n "$kept_blocks" ]; then
            printf '%s' "$kept_blocks"
        fi
        if [ -s "$tmp/new" ]; then
            cat "$tmp/new"
        fi
    } > "$bp"
    log "  wrote $bp"
}

# write_makefiles <dev>: vendor mk + wrapper + Android.bp for one vendor tree
write_makefiles() {
    local dev="$1"
    local out="$ROOT/vendor/$VENDOR/$dev"
    mkdir -p "$out"
    write_vendor_mk "$dev"
    write_wrapper_mk "$dev"
    write_android_bp "$dev"
}

###############################################################################
# Entry points
###############################################################################

# main: full extraction (needs a firmware dump as $1)
main() {
    DUMP="${1:-}"
    if [ -z "$DUMP" ]; then
        echo "usage: $(basename "${BASH_SOURCE[0]}") <path-to-firmware-dump>" >&2
        exit 1
    fi
    [ -d "$DUMP" ] || die "firmware dump not found: $DUMP"

    log "Firmware dump : $DUMP"
    log "ROM root      : $ROOT"

    local trees=("$DEVICE_COMMON")
    if [ -n "$DEVICE" ] && [ "$DEVICE" != "$DEVICE_COMMON" ] && [ -f "$ROOT/device/oneplus/$DEVICE/proprietary-files.txt" ]; then
        trees+=("$DEVICE")
    fi
    local t
    for t in "${trees[@]}"; do
        extract_tree "$t" "$ROOT/device/oneplus/$t/proprietary-files.txt"
    done

    echo
    if [ "$MISSING_TOTAL" -ne 0 ]; then
        warn "$MISSING_TOTAL file(s) listed in proprietary-files.txt were not found in the dump."
        warn "Audit the list above: fix the dump, or update proprietary-files.txt, then re-run."
        exit 1
    fi
    log "Done. Review the vendor trees, then commit device + vendor repos."
}

# setup_main: makefile regeneration only (no dump needed) - used by
# setup-makefiles.sh, which sources this file.
setup_main() {
    local trees=("$DEVICE_COMMON")
    if [ -n "$DEVICE" ] && [ "$DEVICE" != "$DEVICE_COMMON" ] && [ -f "$ROOT/device/oneplus/$DEVICE/proprietary-files.txt" ]; then
        trees+=("$DEVICE")
    fi
    local t
    for t in "${trees[@]}"; do
        write_makefiles "$t"
    done
    log "Makefiles regenerated."
}

# Only run main when executed directly (sourcing for setup-makefiles.sh must
# not trigger extraction).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
