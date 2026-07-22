#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <aosp-fvp-product-out> [mini|full]" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_OUT="$(cd "$1" && pwd)"
VARIANT="${2:-mini}"
[[ "$VARIANT" == "mini" || "$VARIANT" == "full" ]]

WORK="$ROOT/.build/livecontainer-arm64-fvp-se"
OUT="$ROOT/build/livecontainer-arm64-fvp-se"
UTM_TAG="${UTM_TAG:-v5.0.3}"
UTM_IPA_URL="https://github.com/utmapp/UTM/releases/download/${UTM_TAG}/UTM-SE.ipa"
OUTPUT_IPA="Android-iOSEmulator-AOSP-FVP-ARM64-SE-NoJIT-${VARIANT}-unsigned.ipa"
BUNDLE_ID="com.nightvibes33.androidiosemulator.arm64.se"
GITHUB_RELEASE_LIMIT=2147483648

for command in curl unzip zip zipinfo qemu-img otool xcrun plutil python3 shasum; do
  command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 1; }
done

for required in kernel combined-ramdisk.img system-qemu.img userdata.img; do
  [[ -f "$PRODUCT_OUT/$required" ]] || { echo "missing AOSP FVP image: $required" >&2; exit 1; }
done

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/utm" "$WORK/package/Payload" "$OUT"

printf '[1/8] Downloading official no-JIT UTM SE %s\n' "$UTM_TAG"
curl --fail --location --retry 4 --retry-delay 2 "$UTM_IPA_URL" -o "$WORK/UTM-SE.ipa"
unzip -q "$WORK/UTM-SE.ipa" -d "$WORK/utm"
UTM_APP="$(find "$WORK/utm/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$UTM_APP" ]]

printf '[2/8] Staging direct-boot raw ARM64 images\n'
STAGED_PRODUCT="$WORK/product-out"
mkdir -p "$STAGED_PRODUCT"
cp "$PRODUCT_OUT/kernel" "$STAGED_PRODUCT/kernel"
cp "$PRODUCT_OUT/combined-ramdisk.img" "$STAGED_PRODUCT/combined-ramdisk.img"
# Raw images avoid QCOW2 decompression and metadata writes during the interpreter path.
qemu-img convert -p -f raw -O raw -S 4k \
  "$PRODUCT_OUT/system-qemu.img" "$STAGED_PRODUCT/system-qemu.raw.img"
qemu-img convert -p -f raw -O raw -S 4k \
  "$PRODUCT_OUT/userdata.img" "$STAGED_PRODUCT/userdata.raw.img"
qemu-img info "$STAGED_PRODUCT/system-qemu.raw.img" | grep -q 'file format: raw'
qemu-img info "$STAGED_PRODUCT/userdata.raw.img" | grep -q 'file format: raw'
python3 "$ROOT/scripts/make_aosp_fvp_arm64_utm.py" \
  --product-out "$STAGED_PRODUCT" \
  --output "$WORK/Android-ARM64-SE.utm" \
  --variant "$VARIANT" \
  --execution-mode interpreter \
  --system-image-name system-qemu.raw.img \
  --userdata-image-name userdata.raw.img

printf '[3/8] Creating ARM64 no-JIT LiveContainer guest application\n'
GUEST_APP="$WORK/package/Payload/Android iOSEmulator ARM64 SE.app"
cp -R "$UTM_APP" "$GUEST_APP"
find "$GUEST_APP" -name _CodeSignature -type d -prune -exec rm -rf {} + || true
find "$GUEST_APP" -name embedded.mobileprovision -type f -delete || true
INFO_PLIST="$GUEST_APP/Info.plist"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
[[ -n "$EXECUTABLE" && -f "$GUEST_APP/$EXECUTABLE" ]]
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Android ARM64 SE' "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Android ARM64 SE' "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Android ARM64 SE' "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Add :CFBundleName string Android ARM64 SE' "$INFO_PLIST"
plutil -lint "$INFO_PLIST"

printf '[4/8] Retaining only dyld-required and ARM64 QEMU frameworks\n'
REQUIRED_FRAMEWORKS=(qemu-m68k-softmmu.framework qemu-aarch64-softmmu.framework)
for framework in "${REQUIRED_FRAMEWORKS[@]}"; do
  [[ -d "$GUEST_APP/Frameworks/$framework" ]] || { echo "UTM SE missing $framework" >&2; exit 1; }
done
for framework_path in "$GUEST_APP"/Frameworks/qemu-*-softmmu.framework; do
  framework="$(basename "$framework_path")"
  case "$framework" in
    qemu-m68k-softmmu.framework|qemu-aarch64-softmmu.framework) ;;
    *) rm -rf "$framework_path" ;;
  esac
done
MISSING_LINKED_FRAMEWORK=0
while IFS= read -r dependency; do
  case "$dependency" in
    @rpath/*.framework/*)
      relative_path="${dependency#@rpath/}"
      if [[ ! -f "$GUEST_APP/Frameworks/$relative_path" ]]; then
        echo "Missing strong-linked framework binary: $dependency" >&2
        MISSING_LINKED_FRAMEWORK=1
      fi
      ;;
  esac
done < <(otool -L "$GUEST_APP/$EXECUTABLE" | tail -n +2 | awk '{print $1}')
(( MISSING_LINKED_FRAMEWORK == 0 ))

printf '[5/8] Embedding the corrected ARM64 FVP runtime and replacement bootstrap\n'
mkdir -p "$GUEST_APP/PreloadedData" "$GUEST_APP/BootstrapTweaks"
cp -R "$WORK/Android-ARM64-SE.utm" "$GUEST_APP/PreloadedData/Android-ARM64-SE.utm"
xcrun --sdk iphoneos clang \
  -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc -fmodules -dynamiclib \
  -framework Foundation -install_name '@rpath/AndroidArm64GuestBootstrap.dylib' \
  "$ROOT/runtime/livecontainer-guest/AndroidArm64GuestBootstrap.m" \
  -o "$GUEST_APP/BootstrapTweaks/AndroidArm64GuestBootstrap.dylib"
python3 - "$GUEST_APP/LCAppInfo.plist" <<'PY'
from pathlib import Path
import plistlib
import sys
metadata = {
    "LCDataUUID": "AndroidArm64SERuntimeData",
    "LCContainers": [{"folderName": "AndroidArm64SERuntimeData", "name": "Android ARM64 SE"}],
    "LCTweakFolder": "../Applications/com.nightvibes33.androidiosemulator.arm64.se.app/BootstrapTweaks",
    "isJITNeeded": False,
    "dontInjectTweakLoader": False,
    "doUseLCBundleId": False,
    "doSymlinkInbox": False,
    "hideLiveContainer": False,
}
with Path(sys.argv[1]).open("wb") as stream:
    plistlib.dump(metadata, stream, fmt=plistlib.FMT_BINARY, sort_keys=False)
PY
plutil -lint "$GUEST_APP/LCAppInfo.plist"

printf '[6/8] Verifying exact AOSP FVP MMIO and no-JIT contract\n'
CONFIG="$GUEST_APP/PreloadedData/Android-ARM64-SE.utm/config.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :System:Architecture' "$CONFIG")" == aarch64 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :System:Target' "$CONFIG")" == virt ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :System:CPU' "$CONFIG")" == max ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :System:RngEnabled' "$CONFIG")" == false ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Networking:NetworkMode' "$CONFIG")" == none ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Drives:2:InterfaceType' "$CONFIG")" == none ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Drives:3:InterfaceType' "$CONFIG")" == none ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Debug:DebugLog' "$CONFIG")" == false ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Display:DisplayCard' "$CONFIG")" == virtio-gpu-pci ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :isJITNeeded' "$GUEST_APP/LCAppInfo.plist")" == false ]]
ADD_ARGS="$(/usr/libexec/PlistBuddy -c 'Print :System:AddArgs' "$CONFIG")"
grep -Fq 'androidboot.hardware=fvpbase' <<<"$ADD_ARGS"
grep -Fq 'androidboot.boot_devices=a003e00.virtio_mmio' <<<"$ADD_ARGS"
grep -Fq -- '-device virtio-blk-device,drive=drivesystem' <<<"$ADD_ARGS"
grep -Fq -- '-device virtio-blk-device,drive=driveuserdata' <<<"$ADD_ARGS"
grep -Fq -- '-device virtio-net-device,netdev=androidnet' <<<"$ADD_ARGS"
grep -Fq -- '-device virtio-rng-device' <<<"$ADD_ARGS"
! grep -Fq 'virtio-blk-pci' <<<"$ADD_ARGS"
! grep -Fq 'virtio-net-pci' <<<"$ADD_ARGS"
[[ -d "$GUEST_APP/Frameworks/qemu-aarch64-softmmu.framework" ]]
! find "$GUEST_APP/Frameworks" -maxdepth 1 -type d -name 'qemu-x86_64-softmmu.framework' -print -quit | grep -q .

printf '[7/8] Packaging unsigned no-JIT ARM64 IPA\n'
(
  cd "$WORK/package"
  zip -9 -qry "$OUT/$OUTPUT_IPA" Payload
)
unzip -t "$OUT/$OUTPUT_IPA" >/dev/null
zipinfo -1 "$OUT/$OUTPUT_IPA" > "$OUT/ipa-contents.txt"
grep -q 'Payload/Android iOSEmulator ARM64 SE.app/Frameworks/qemu-aarch64-softmmu.framework/' "$OUT/ipa-contents.txt"
! grep -q 'qemu-x86_64-softmmu.framework/' "$OUT/ipa-contents.txt"
grep -q 'PreloadedData/Android-ARM64-SE.utm/Images/system-qemu.raw.img' "$OUT/ipa-contents.txt"
grep -q 'PreloadedData/Android-ARM64-SE.utm/Images/userdata.raw.img' "$OUT/ipa-contents.txt"

printf '[8/8] Recording manifest and checksum\n'
IPA_SIZE="$(stat -f%z "$OUT/$OUTPUT_IPA")"
if (( IPA_SIZE >= GITHUB_RELEASE_LIMIT )); then
  echo "ARM64 IPA is $IPA_SIZE bytes and exceeds GitHub's 2 GiB release asset limit." >&2
  exit 1
fi
shasum -a 256 "$OUT/$OUTPUT_IPA" > "$OUT/$OUTPUT_IPA.sha256"
cat > "$OUT/build-manifest.txt" <<MANIFEST
Runtime architecture: aarch64
Android target: AOSP fvpbase (${VARIANT})
Execution mode: UTM SE interpreter
QEMU machine: virt,mte=on
QEMU CPU: max
AOSP hardware: fvpbase
Storage transport: virtio-mmio
Network transport: virtio-mmio
RNG transport: virtio-mmio
UTM generic ARM PCI storage: disabled
UTM generic ARM PCI network: disabled
Graphics: virtio-gpu-pci
System storage: sparse raw system-qemu image
Userdata storage: sparse raw userdata image
Direct kernel boot: yes
Boot animation: disabled by official AOSP FVP product configuration
Host dex optimization: enabled by official AOSP FVP product configuration
JIT required: no
UTM backend retained: qemu-aarch64-softmmu
x86_64 backend retained: no
Signing: unsigned; any compatible signing service may be used
IPA size: ${IPA_SIZE} bytes
Physical iPhone graphical boot: not yet verified
MANIFEST
printf 'Built no-JIT ARM64 AOSP FVP LiveContainer IPA: %s\n' "$OUT/$OUTPUT_IPA"
