#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <redroid-arm64-guest-directory>" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST_SOURCE="$(cd "$1" && pwd)"
WORK="$ROOT/.build/livecontainer-redroid-arm64-se"
OUT="$ROOT/build/livecontainer-redroid-arm64-se"
UTM_TAG="${UTM_TAG:-v5.0.3}"
UTM_IPA_URL="https://github.com/utmapp/UTM/releases/download/${UTM_TAG}/UTM-SE.ipa"
GUEST_BUNDLE_ID="com.nightvibes33.androidiosemulator.redroid.arm64.se"
GUEST_INSTALL_FOLDER="${GUEST_BUNDLE_ID}.app"
GUEST_CONTAINER="AndroidRedroidArm64SERuntimeData"
OUTPUT_IPA="Android-iOSEmulator-Redroid13-ARM64-SE-NoJIT-unsigned.ipa"
APP_NAME="Android iOSEmulator.app"
VM_NAME="Android-Redroid-ARM64-SE.utm"
DISK_NAME="redroid-arm64-rootfs.raw"
GITHUB_RELEASE_LIMIT=2147483648

for command in curl unzip zip zipinfo otool xcrun plutil python3 shasum file codesign xattr ditto; do
  command -v "$command" >/dev/null || { echo "missing build dependency: $command" >&2; exit 1; }
done
for required in kernel initrd.img "$DISK_NAME" build-manifest.txt; do
  [[ -f "$GUEST_SOURCE/$required" ]] || { echo "missing ARM64 guest artifact: $required" >&2; exit 1; }
done
grep -q '^CI Android boot verification: passed$' "$GUEST_SOURCE/build-manifest.txt" || {
  echo "refusing to package a guest that did not reach Android sys.boot_completed=1 in CI" >&2
  exit 1
}
grep -q '^Redroid image: docker.io/redroid/redroid:13.0.0_64only-240527$' "$GUEST_SOURCE/build-manifest.txt"
grep -q '^Host bootconfig masked from Android: yes$' "$GUEST_SOURCE/build-manifest.txt"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/utm" "$WORK/package/Payload" "$OUT"

printf '[1/9] Downloading official UTM SE %s\n' "$UTM_TAG"
curl --fail --location --retry 4 --retry-delay 2 "$UTM_IPA_URL" -o "$WORK/UTM-SE.ipa"
unzip -q "$WORK/UTM-SE.ipa" -d "$WORK/utm"
UTM_APP="$(find "$WORK/utm/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$UTM_APP" ]]

printf '[2/9] Creating the ARM64 no-JIT Redroid UTM bundle\n'
python3 "$ROOT/scripts/make_redroid_arm64_utm.py" \
  --guest-dir "$GUEST_SOURCE" \
  --output "$WORK/$VM_NAME"
plutil -lint "$WORK/$VM_NAME/config.plist"

printf '[3/9] Creating the import-safe LiveContainer guest application\n'
PAYLOAD="$WORK/package/Payload"
GUEST_APP="$PAYLOAD/$APP_NAME"
cp -R "$UTM_APP" "$GUEST_APP"
find "$GUEST_APP" -name '_CodeSignature' -type d -prune -exec rm -rf {} + || true
find "$GUEST_APP" -name 'embedded.mobileprovision' -type f -delete || true
xattr -cr "$GUEST_APP" || true
INFO_PLIST="$GUEST_APP/Info.plist"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
[[ -n "$EXECUTABLE" && -f "$GUEST_APP/$EXECUTABLE" ]]
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $GUEST_BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Android iOSEmulator' "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Android iOSEmulator' "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Android iOSEmulator' "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Add :CFBundleName string Android iOSEmulator' "$INFO_PLIST"
plutil -lint "$INFO_PLIST"

printf '[4/9] Retaining only dyld-required and ARM64 QEMU frameworks\n'
REQUIRED_QEMU_FRAMEWORKS=(qemu-m68k-softmmu.framework qemu-aarch64-softmmu.framework)
for framework in "${REQUIRED_QEMU_FRAMEWORKS[@]}"; do
  [[ -d "$GUEST_APP/Frameworks/$framework" ]] || { echo "UTM SE is missing $framework" >&2; exit 1; }
done
UTM_SIZE_BEFORE_KIB="$(du -sk "$GUEST_APP" | awk '{print $1}')"
for framework_path in "$GUEST_APP"/Frameworks/qemu-*-softmmu.framework; do
  framework="$(basename "$framework_path")"
  case "$framework" in
    qemu-m68k-softmmu.framework|qemu-aarch64-softmmu.framework) ;;
    *) rm -rf "$framework_path" ;;
  esac
done
UTM_SIZE_AFTER_KIB="$(du -sk "$GUEST_APP" | awk '{print $1}')"
UTM_TRIMMED_KIB=$((UTM_SIZE_BEFORE_KIB - UTM_SIZE_AFTER_KIB))
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
otool -L "$GUEST_APP/$EXECUTABLE" > "$OUT/utm-executable-dependencies.txt"

printf '[5/9] Embedding the ARM64 Android runtime and bootstrap\n'
mkdir -p "$GUEST_APP/PreloadedData" "$GUEST_APP/BootstrapTweaks"
if ! cp -cR "$WORK/$VM_NAME" "$GUEST_APP/PreloadedData/$VM_NAME" 2>/dev/null; then
  cp -R "$WORK/$VM_NAME" "$GUEST_APP/PreloadedData/$VM_NAME"
fi
xcrun --sdk iphoneos clang \
  -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc -fmodules -dynamiclib \
  -framework Foundation -install_name '@rpath/AndroidRedroidGuestBootstrap.dylib' \
  "$ROOT/runtime/livecontainer-guest/AndroidRedroidGuestBootstrap.m" \
  -o "$GUEST_APP/BootstrapTweaks/AndroidRedroidGuestBootstrap.dylib"
python3 - "$GUEST_APP/LCAppInfo.plist" "$GUEST_INSTALL_FOLDER" "$GUEST_CONTAINER" <<'PY'
from pathlib import Path
import plistlib
import sys
output = Path(sys.argv[1])
install_folder = sys.argv[2]
container = sys.argv[3]
metadata = {
    "LCDataUUID": container,
    "LCContainers": [{"folderName": container, "name": "Android ARM64 No-JIT"}],
    "LCTweakFolder": f"../Applications/{install_folder}/BootstrapTweaks",
    "isJITNeeded": False,
    "dontInjectTweakLoader": False,
    "doUseLCBundleId": False,
    "doSymlinkInbox": False,
    "hideLiveContainer": False,
}
with output.open("wb") as stream:
    plistlib.dump(metadata, stream, fmt=plistlib.FMT_BINARY, sort_keys=False)
PY
plutil -lint "$GUEST_APP/LCAppInfo.plist"

printf '[6/9] Normalizing and smoke-signing every Mach-O for LiveContainer\n'
# LiveContainer re-signs every 64-bit Mach-O. Normalize file permissions, remove
# upstream signatures and install fresh ad-hoc signatures so each binary has a
# writable, structurally valid LC_CODE_SIGNATURE region before on-device signing.
find "$GUEST_APP" -type d -exec chmod 0755 {} +
find "$GUEST_APP" -type f -exec chmod u+rw,go+r {} +
xattr -cr "$GUEST_APP" || true
MACHO_LIST="$OUT/livecontainer-signable-machos.txt"
SIGNABILITY_REPORT="$OUT/livecontainer-signability-report.txt"
: > "$MACHO_LIST"
: > "$SIGNABILITY_REPORT"
MACHO_COUNT=0
while IFS= read -r -d '' candidate; do
  file_description="$(file -b "$candidate")"
  if grep -Eq 'Mach-O (universal binary|64-bit)' <<<"$file_description"; then
    chmod 0755 "$candidate"
    codesign --remove-signature "$candidate" >/dev/null 2>&1 || true
    codesign --force --sign - --timestamp=none "$candidate"
    codesign --verify --strict "$candidate"
    relative="${candidate#$GUEST_APP/}"
    printf '%s\n' "$relative" >> "$MACHO_LIST"
    printf 'PASS\t%s\t%s\n' "$relative" "$file_description" >> "$SIGNABILITY_REPORT"
    MACHO_COUNT=$((MACHO_COUNT + 1))
  fi
done < <(find "$GUEST_APP" -type f -print0)
(( MACHO_COUNT > 0 ))
grep -Fxq "$EXECUTABLE" "$MACHO_LIST"
grep -Fxq 'Frameworks/qemu-m68k-softmmu.framework/qemu-m68k-softmmu' "$MACHO_LIST"
grep -Fxq 'Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu' "$MACHO_LIST"
grep -Fxq 'BootstrapTweaks/AndroidRedroidGuestBootstrap.dylib' "$MACHO_LIST"
printf 'Mach-O count: %s\nAll binaries writable: yes\nExisting signatures normalized: yes\nAd-hoc signing smoke test: passed\n' \
  "$MACHO_COUNT" >> "$SIGNABILITY_REPORT"

printf '[7/9] Verifying the no-JIT ARM64 guest contract\n'
CONFIG="$GUEST_APP/PreloadedData/$VM_NAME/config.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :System:Architecture' "$CONFIG")" == aarch64 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :System:Target' "$CONFIG")" == virt ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :System:CPU' "$CONFIG")" == max ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :System:MachineProperties' "$CONFIG")" == highmem=off ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :isJITNeeded' "$GUEST_APP/LCAppInfo.plist")" == false ]]
[[ -f "$GUEST_APP/PreloadedData/$VM_NAME/Images/$DISK_NAME" ]]
[[ -f "$GUEST_APP/PreloadedData/$VM_NAME/Images/kernel" ]]
[[ -f "$GUEST_APP/PreloadedData/$VM_NAME/Images/initrd.img" ]]
[[ -d "$GUEST_APP/Frameworks/qemu-aarch64-softmmu.framework" ]]
! find "$GUEST_APP/Frameworks" -maxdepth 1 -type d -name 'qemu-x86_64-softmmu.framework' -print -quit | grep -q .
file "$GUEST_APP/$EXECUTABLE" | grep -q 'Mach-O 64-bit executable arm64'
file "$GUEST_APP/BootstrapTweaks/AndroidRedroidGuestBootstrap.dylib" | grep -q 'Mach-O 64-bit dynamically linked shared library arm64'

printf '[8/9] Packaging with the proven LiveContainer archive ordering\n'
ZIP_LIST="$WORK/zip-file-order.txt"
(
  cd "$WORK/package"
  python3 - "$EXECUTABLE" "$DISK_NAME" > "$ZIP_LIST" <<'PY'
from pathlib import Path
import os
import sys
executable, disk_name = sys.argv[1:]
root = Path("Payload")
app = root / "Android iOSEmulator.app"
leading = [root, app, app / "Info.plist", app / executable, app / "LCAppInfo.plist"]
all_paths = []
for current, dirs, files in os.walk(root):
    current_path = Path(current)
    all_paths.extend(current_path / item for item in dirs)
    all_paths.extend(current_path / item for item in files)
leading_set = {str(path) for path in leading}
remaining = [path for path in all_paths if str(path) not in leading_set]
remaining.sort(key=lambda path: (path.name == disk_name, path.is_file(), str(path).lower()))
for path in [*leading, *remaining]:
    if path.exists() or path.is_symlink():
        text = str(path)
        if path.is_dir() and not text.endswith("/"):
            text += "/"
        print(text)
PY
  rm -f "$OUT/$OUTPUT_IPA"
  COPYFILE_DISABLE=1 zip -9 -q -X "$OUT/$OUTPUT_IPA" -@ < "$ZIP_LIST"
)

printf '[9/9] Re-reading final IPA and rechecking every embedded signature\n'
unzip -t "$OUT/$OUTPUT_IPA" >/dev/null
zipinfo -1 "$OUT/$OUTPUT_IPA" > "$OUT/archive-entry-order.txt"
unzip -l "$OUT/$OUTPUT_IPA" > "$OUT/ipa-contents.txt"
[[ "$(sed -n '1p' "$OUT/archive-entry-order.txt")" == 'Payload/' ]]
[[ "$(sed -n '2p' "$OUT/archive-entry-order.txt")" == "Payload/$APP_NAME/" ]]
[[ "$(sed -n '3p' "$OUT/archive-entry-order.txt")" == "Payload/$APP_NAME/Info.plist" ]]
[[ "$(sed -n '4p' "$OUT/archive-entry-order.txt")" == "Payload/$APP_NAME/$EXECUTABLE" ]]
[[ "$(sed -n '5p' "$OUT/archive-entry-order.txt")" == "Payload/$APP_NAME/LCAppInfo.plist" ]]
tail -n 1 "$OUT/archive-entry-order.txt" | grep -q "Payload/$APP_NAME/PreloadedData/$VM_NAME/Images/$DISK_NAME"
! grep -q 'qemu-x86_64-softmmu.framework/' "$OUT/ipa-contents.txt"
! grep -Eq '(_CodeSignature|embedded.mobileprovision)' "$OUT/ipa-contents.txt"

IMPORT_CHECK="$WORK/livecontainer-import-check"
rm -rf "$IMPORT_CHECK"
mkdir -p "$IMPORT_CHECK"
ditto -x -k "$OUT/$OUTPUT_IPA" "$IMPORT_CHECK"
EXTRACTED_APP="$IMPORT_CHECK/Payload/$APP_NAME"
ARCHIVE_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$EXTRACTED_APP/Info.plist")"
ARCHIVE_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$EXTRACTED_APP/Info.plist")"
ARCHIVE_JIT="$(/usr/libexec/PlistBuddy -c 'Print :isJITNeeded' "$EXTRACTED_APP/LCAppInfo.plist")"
[[ "$ARCHIVE_BUNDLE_ID" == "$GUEST_BUNDLE_ID" ]]
[[ "$ARCHIVE_EXECUTABLE" == "$EXECUTABLE" ]]
[[ "$ARCHIVE_JIT" == false ]]
FINAL_MACHO_COUNT=0
while IFS= read -r relative; do
  [[ -n "$relative" ]]
  extracted_binary="$EXTRACTED_APP/$relative"
  [[ -f "$extracted_binary" ]]
  [[ -x "$extracted_binary" ]]
  codesign --verify --strict "$extracted_binary"
  FINAL_MACHO_COUNT=$((FINAL_MACHO_COUNT + 1))
done < "$MACHO_LIST"
[[ "$FINAL_MACHO_COUNT" -eq "$MACHO_COUNT" ]]
printf 'bundleIdentifier=%s\nexecutable=%s\nisJITNeeded=%s\nsignableMachOCount=%s\n' \
  "$ARCHIVE_BUNDLE_ID" "$ARCHIVE_EXECUTABLE" "$ARCHIVE_JIT" "$FINAL_MACHO_COUNT" \
  > "$OUT/livecontainer-import-metadata.txt"

IPA_SIZE="$(stat -f%z "$OUT/$OUTPUT_IPA")"
if (( IPA_SIZE >= GITHUB_RELEASE_LIMIT )); then
  echo "The complete IPA is ${IPA_SIZE} bytes and exceeds GitHub's 2 GiB release limit." >&2
  exit 1
fi
shasum -a 256 "$OUT/$OUTPUT_IPA" > "$OUT/$OUTPUT_IPA.sha256"
cat > "$OUT/build-manifest.txt" <<MANIFEST
Package type: LiveContainer guest IPA
Guest architecture: aarch64
Android runtime: Redroid 13 64-bit only
Redroid image: docker.io/redroid/redroid:13.0.0_64only-240527
Host guest: minimal ARM64 Linux with BinderFS and DMA-BUF system heap
Host bootconfig masked from Android: yes
CI Android boot verification: passed
Execution mode: UTM SE interpreter / no JIT
JIT required by LiveContainer: no
QEMU target: virt
QEMU backend retained: aarch64-softmmu
x86_64 backend retained: no
Display: virtio-gpu + Weston + scrcpy
Android rendering: software guest renderer
Root disk: sparse raw ext4
LiveContainer minimum version: 3.7.0
LiveContainer import metadata: extracted and validated from final IPA
Archive order: Info.plist, executable and LCAppInfo.plist before root disk
Unknown.app fallback: blocked by final archive checks
Mach-O file permissions: normalized writable and executable
Embedded Mach-O signatures: stripped and replaced with validated ad-hoc signatures
LiveContainer signing smoke test: passed for ${MACHO_COUNT} Mach-O binaries
Removed unused QEMU frameworks: ${UTM_TRIMMED_KIB} KiB
Signing: developer provisioning absent; LiveContainer must replace ad-hoc signatures on device
IPA size: ${IPA_SIZE} bytes
Physical iPhone boot verification: pending
MANIFEST
printf 'Built LiveContainer-signable no-JIT ARM64 Android IPA: %s\n' "$OUT/$OUTPUT_IPA"
