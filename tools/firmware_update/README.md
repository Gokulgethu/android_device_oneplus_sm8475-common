# Update udon / CPH2487 blobs to a new official firmware

Use these scripts to regenerate the **vendor**, **device** and **common** trees
from a fresh OnePlus 11R firmware (e.g. **OxygenOS `CPH2487_16.0.5.1002(EX01)`**),
so custom ROMs build against the newest proprietary blobs with no stale-file errors.

> Full firmware packages are ~8–11 GB and `super.img` unpacks to ~12+ GB. **Run this
> on your Crave build VM / a Linux build host with ~40 GB free and root not required**
> (ext4 is read in userspace). It cannot run inside a small CI sandbox.

## 0. Get the firmware

Use the **full OTA** (contains `payload.bin`) — easiest, or the **QFIL/QPST** package
(contains `super.img`).

- OxygenOS full OTA / QFIL for `CPH2487` (India, EX01), version **16.0.5.1002**:
  - Oxygen Updater app (Settings → set device = OnePlus 11R, download the full OTA zip)
  - firmware mirrors: firmwaredrive / firmwarefile (search “CPH2487 EX01 16.0.5.1002 QFIL”)

Put the zip on the build host, e.g. `~/CPH2487_16.0.5.1002_EX01.zip`.

## 1. Install tools (once)

```bash
# payload OTA support
#   payload-dumper-go: https://github.com/ssut/payload-dumper-go/releases (single binary, put in PATH)
# QFIL / super.img support:
sudo apt-get install -y android-sdk-libsparse-utils   # simg2img
#   lpunpack: build from your ROM source:  m -j lpunpack   (out/.../bin/lpunpack)
# ext4 userspace reader (fallback): debugfs ships with e2fsprogs (usually present)
sudo apt-get install -y e2fsprogs p7zip-full
```

## 2. Unpack the firmware into a system dump

From **inside your synced ROM source tree** (`device/oneplus/...` present):

```bash
device/oneplus/udon/tools/firmware_update/unpack_firmware.sh \
    ~/CPH2487_16.0.5.1002_EX01.zip  /tmp/dump
```

This auto-detects `payload.bin` or `super.img`, unpacks system / system_ext / product /
vendor / odm / *_dlkm, and arranges them as a rooted dump under `/tmp/dump`.

## 3. Regenerate the proprietary trees

```bash
device/oneplus/udon/tools/firmware_update/update_blobs.sh /tmp/dump
```

This runs the standard LineageOS `extract-files.sh` (via
`vendor/lineage/build/tools/extract_utils.sh`) using `proprietary-files.txt`, rebuilds
`Android.bp` / `*.mk` / `BoardConfigVendor.mk` in
`vendor/oneplus/{udon,CPH2487,sm8475-common,sm8450-common}`, and refreshes the build
**fingerprint**, **description** and **security patch** in the product makefiles and
BoardConfigs.

## 4. Verify no blobs went missing

```bash
# Any blobs in proprietary-files.txt that are no longer in the dump are reported by
# extract-files. Audit them:
grep -rn "could not find\|file not found\|missing" /tmp/extract-*.log 2>/dev/null || true

# Ensure Dolby still resolves (hardware/dolby is a portable package, not firmware):
ls hardware/dolby >/dev/null && echo "Dolby package present"
```

## 5. Commit & push

```bash
for r in device/oneplus/udon device/oneplus/CPH2487 device/oneplus/sm8475-common device/oneplus/sm8450-common \
         vendor/oneplus/udon vendor/oneplus/CPH2487 vendor/oneplus/sm8475-common vendor/oneplus/sm8450-common; do
  [ -d "$r/.git" ] && { ( cd "$r" && git add -A && git commit -m "Update blobs to OxygenOS 16.0.5.1002 (EX01)" && git push ); }
done
```

Then:

```bash
repo sync -c -j$(nproc) --force-sync
source build/envsetup.sh && breakfast crdroid_udon && mka bacon
```

## Notes

- **Kernel**: the kernel is built from source (`kernel/oneplus/sm8475`, GKI 5.10/taro).
  A new firmware does **not** require a kernel change unless you want to bump the
  prebuilt `TARGET_PREBUILT_KERNEL`; leave the source kernel in place for custom ROMs.
- **Dolby Atmos** comes from the portable `hardware/dolby` repo (see `dolby.mk`); it is
  independent of the firmware extraction and continues to work after a blob bump.
- If `extract-files.sh` reports new/renamed blobs, update
  `device/oneplus/sm8475-common/proprietary-files.txt` accordingly (the script pins
  hashes; remove the trailing `|<sha1>` to let it re-pin automatically).
