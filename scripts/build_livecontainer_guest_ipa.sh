#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.build/livecontainer-guest"
OUT="$ROOT/build/livecontainer-guest"
UTM_TAG="${UTM_TAG:-v5.0.2}"
UTM_IPA_URL="https://github.com/utmapp/UTM/releases/download/${UTM_TAG}/UTM-SE.ipa"
ANDROID_DISK_NAME="bliss-android13-preinstalled.qcow2"
GUEST_BUNDLE_ID="com.nightvibes33.androidiosemulator.android13.importsafe"
GUEST_APP_BASENAME="AndroidIOSEmulator.app"
GUEST_EXECUTABLE="AndroidIOSEmulator"
GUEST_INSTALL_FOLDER="${GUEST_BUNDLE_ID}.app"
GUEST_CONTAINER="AndroidRuntimeData"
OUTPUT_IPA="Android-iOSEmulator-Android13-ImportSafe-LiveContainer-Guest-unsigned.ipa"
GITHUB_RELEASE_LIMIT=2147483648

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

for command in qemu-img 7zz mformat mcopy otool zip unzip tar; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required to build the preinstalled Android 13 guest." >&2
    exit 1
  fi
done

printf '[1/10] Downloading official UTM SE %s\n' "$UTM_TAG"
curl --fail --location --retry 4 --retry-delay 2 "$UTM_IPA_URL" -o "$WORK/UTM-SE.ipa"
mkdir -p "$WORK/utm"
unzip -q "$WORK/UTM-SE.ipa" -d "$WORK/utm"
UTM_APP="$(find "$WORK/utm/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$UTM_APP" ]]; then
  echo "The downloaded UTM SE IPA does not contain a top-level application bundle." >&2
  exit 1
fi

printf '[2/10] Building a compact preinstalled BlissOS 16 / Android 13 disk\n'
bash "$ROOT/scripts/build_bliss_android13_disk.sh" \
  "$WORK/android13-disk-work" \
  "$WORK/$ANDROID_DISK_NAME"

printf '[3/10] Creating the Android 13 UTM bundle\n'
python3 "$ROOT/scripts/make_bliss_android13_utm.py" \
  --output "$WORK/Android.utm" \
  --disk "$WORK/$ANDROID_DISK_NAME"
plutil -lint "$WORK/Android.utm/config.plist"

printf '[4/10] Creating an import-safe LiveContainer guest application\n'
PAYLOAD="$WORK/package/Payload"
GUEST_APP="$PAYLOAD/$GUEST_APP_BASENAME"
mkdir -p "$PAYLOAD"
cp -R "$UTM_APP" "$GUEST_APP"
find "$GUEST_APP" -name '_CodeSignature' -type d -prune -exec rm -rf {} + || true
find "$GUEST_APP" -name 'embedded.mobileprovision' -type f -delete || true

INFO_PLIST="$GUEST_APP/Info.plist"
ORIGINAL_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
if [[ -z "$ORIGINAL_EXECUTABLE" || ! -f "$GUEST_APP/$ORIGINAL_EXECUTABLE" ]]; then
  echo "UTM SE is missing its declared executable." >&2
  exit 1
fi
mv "$GUEST_APP/$ORIGINAL_EXECUTABLE" "$GUEST_APP/$GUEST_EXECUTABLE"
EXECUTABLE="$GUEST_EXECUTABLE"

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $GUEST_BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Android iOSEmulator" "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Android iOSEmulator" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName AndroidIOSEmulator" "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string AndroidIOSEmulator" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$INFO_PLIST"
plutil -convert binary1 "$INFO_PLIST"
plutil -lint "$INFO_PLIST"

printf '[5/10] Keeping every QEMU framework required by dyld and Android x86_64\n'
REQUIRED_QEMU_FRAMEWORKS=(
  qemu-m68k-softmmu.framework
  qemu-x86_64-softmmu.framework
)
UNUSED_QEMU_FRAMEWORKS=(
  qemu-aarch64-softmmu.framework
  qemu-i386-softmmu.framework
  qemu-ppc-softmmu.framework
  qemu-ppc64-softmmu.framework
  qemu-riscv64-softmmu.framework
)
for framework in "${REQUIRED_QEMU_FRAMEWORKS[@]}"; do
  if [[ ! -d "$GUEST_APP/Frameworks/$framework" ]]; then
    echo "UTM SE is missing required framework: $framework" >&2
    exit 1
  fi
done

UTM_SIZE_BEFORE_KIB="$(du -sk "$GUEST_APP" | awk '{print $1}')"
for framework in "${UNUSED_QEMU_FRAMEWORKS[@]}"; do
  rm -rf "$GUEST_APP/Frameworks/$framework"
done

# These firmware blobs are for non-x86 guest machines. qemu-m68k remains because
# the UTM SE executable strongly links it while being loaded by LiveContainer.
rm -f \
  "$GUEST_APP/qemu/edk2-arm-code.fd" \
  "$GUEST_APP/qemu/edk2-aarch64-code.fd" \
  "$GUEST_APP/qemu/edk2-aarch64-secure-code.fd" \
  "$GUEST_APP/qemu/edk2-riscv-code.fd" \
  "$GUEST_APP/qemu/edk2-riscv-vars.fd" \
  "$GUEST_APP/qemu/edk2-loongarch64-code.fd" \
  "$GUEST_APP/qemu/edk2-loongarch64-vars.fd" \
  "$GUEST_APP/qemu/skiboot.lid" \
  "$GUEST_APP/qemu/openbios-sparc64"
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
if (( MISSING_LINKED_FRAMEWORK != 0 )); then
  exit 1
fi

otool -L "$GUEST_APP/$EXECUTABLE" > "$OUT/utm-executable-dependencies.txt"
grep -q '@rpath/qemu-m68k-softmmu.framework/qemu-m68k-softmmu' "$OUT/utm-executable-dependencies.txt"

mkdir -p "$GUEST_APP/PreloadedData"
cp -R "$WORK/Android.utm" "$GUEST_APP/PreloadedData/Android.utm"
cp "$WORK/$ANDROID_DISK_NAME.manifest.txt" "$GUEST_APP/PreloadedData/Android.utm/Android13RuntimeManifest.txt"

printf '[6/10] Compiling the Android 13 guest bootstrap tweak\n'
mkdir -p "$GUEST_APP/BootstrapTweaks"
xcrun --sdk iphoneos clang \
  -arch arm64 \
  -miphoneos-version-min=15.0 \
  -fobjc-arc \
  -fmodules \
  -dynamiclib \
  -framework Foundation \
  -install_name '@rpath/AndroidGuestBootstrap.dylib' \
  "$ROOT/runtime/livecontainer-guest/AndroidGuestBootstrap.m" \
  -o "$GUEST_APP/BootstrapTweaks/AndroidGuestBootstrap.dylib"

python3 - "$GUEST_APP/LCAppInfo.plist" "$GUEST_INSTALL_FOLDER" "$GUEST_CONTAINER" <<'PY'
from pathlib import Path
import plistlib
import sys

output = Path(sys.argv[1])
install_folder = sys.argv[2]
container = sys.argv[3]
metadata = {
    "LCDataUUID": container,
    "LCContainers": [{"folderName": container, "name": "Android 13"}],
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

printf '[7/10] Verifying the preinstalled Android 13 guest layout\n'
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
DECLARED_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST")"
PACKAGE_TYPE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$INFO_PLIST")"
[[ "$BUNDLE_ID" == "$GUEST_BUNDLE_ID" ]]
[[ "$DECLARED_EXECUTABLE" == "$EXECUTABLE" ]]
[[ "$DISPLAY_NAME" == "Android iOSEmulator" ]]
[[ "$PACKAGE_TYPE" == "APPL" ]]
[[ -f "$GUEST_APP/$EXECUTABLE" ]]
file "$GUEST_APP/$EXECUTABLE" | grep -q 'Mach-O 64-bit executable arm64'
file "$GUEST_APP/BootstrapTweaks/AndroidGuestBootstrap.dylib" | grep -q 'Mach-O 64-bit dynamically linked shared library arm64'
for framework in "${REQUIRED_QEMU_FRAMEWORKS[@]}"; do
  [[ -d "$GUEST_APP/Frameworks/$framework" ]]
done
for framework in "${UNUSED_QEMU_FRAMEWORKS[@]}"; do
  [[ ! -e "$GUEST_APP/Frameworks/$framework" ]]
done
[[ -f "$GUEST_APP/PreloadedData/Android.utm/config.plist" ]]
[[ -f "$GUEST_APP/PreloadedData/Android.utm/Images/$ANDROID_DISK_NAME" ]]
[[ -f "$GUEST_APP/PreloadedData/Android.utm/Android13RuntimeManifest.txt" ]]
[[ -f "$GUEST_APP/LCAppInfo.plist" ]]
grep -q 'QCOW2 compression: zlib' "$GUEST_APP/PreloadedData/Android.utm/Android13RuntimeManifest.txt"
if find "$GUEST_APP/PreloadedData/Android.utm/Images" -type f -name '*.iso' -print -quit | grep -q .; then
  echo "The Android 13 guest must not contain an installer ISO." >&2
  exit 1
fi
if [[ -d "$GUEST_APP/PreloadedApps" ]]; then
  echo "Nested LiveContainer PreloadedApps directory is forbidden in the guest IPA." >&2
  exit 1
fi
if find "$GUEST_APP" -mindepth 1 -type d -name '*.app' -print -quit | grep -q .; then
  echo "A nested .app bundle was found. The LiveContainer guest must have one top-level app only." >&2
  exit 1
fi

printf '[8/10] Packaging metadata first and the large Android disk last\n'
ARCHIVE_APP="Payload/$GUEST_APP_BASENAME"
ARCHIVE_DISK="$ARCHIVE_APP/PreloadedData/Android.utm/Images/$ANDROID_DISK_NAME"
python3 - "$WORK/package" "$WORK/ipa-file-order.txt" "$ARCHIVE_APP" "$EXECUTABLE" "$ARCHIVE_DISK" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
output = Path(sys.argv[2])
app = sys.argv[3]
executable = sys.argv[4]
disk = sys.argv[5]

entries = set()
for path in root.rglob("*"):
    relative = path.relative_to(root).as_posix()
    if path.is_dir():
        relative += "/"
    entries.add(relative)

priority = [
    "Payload/",
    f"{app}/",
    f"{app}/Info.plist",
    f"{app}/LCAppInfo.plist",
    f"{app}/{executable}",
    f"{app}/BootstrapTweaks/",
    f"{app}/BootstrapTweaks/AndroidGuestBootstrap.dylib",
    f"{app}/PreloadedData/",
    f"{app}/PreloadedData/Android.utm/",
    f"{app}/PreloadedData/Android.utm/config.plist",
    f"{app}/PreloadedData/Android.utm/Android13RuntimeManifest.txt",
]
missing = [item for item in priority + [disk] if item not in entries]
if missing:
    raise SystemExit(f"archive ordering references missing entries: {missing}")

ordered = []
seen = set()
for item in priority:
    if item not in seen:
        ordered.append(item)
        seen.add(item)
for item in sorted(entries):
    if item != disk and item not in seen:
        ordered.append(item)
        seen.add(item)
ordered.append(disk)

output.write_text("\n".join(ordered) + "\n", encoding="utf-8")
PY
(
  cd "$WORK/package"
  COPYFILE_DISABLE=1 zip -9 -q -y "$OUT/$OUTPUT_IPA" -@ < "$WORK/ipa-file-order.txt"
)
cp "$WORK/ipa-file-order.txt" "$OUT/ipa-file-order.txt"

printf '[9/10] Validating archive order, metadata, executable, and dyld dependencies\n'
unzip -t "$OUT/$OUTPUT_IPA" >/dev/null
unzip -l "$OUT/$OUTPUT_IPA" > "$OUT/ipa-contents.txt"
unzip -Z1 "$OUT/$OUTPUT_IPA" > "$OUT/verified-contents.txt"
python3 - "$OUT/$OUTPUT_IPA" "$ARCHIVE_APP" "$EXECUTABLE" "$GUEST_BUNDLE_ID" "$ARCHIVE_DISK" <<'PY'
from pathlib import Path
import plistlib
import sys
import zipfile

ipa = Path(sys.argv[1])
app = sys.argv[2]
executable = sys.argv[3]
bundle_id = sys.argv[4]
disk = sys.argv[5]
expected_prefix = [
    "Payload/",
    f"{app}/",
    f"{app}/Info.plist",
    f"{app}/LCAppInfo.plist",
    f"{app}/{executable}",
]
with zipfile.ZipFile(ipa) as archive:
    names = archive.namelist()
    if names[: len(expected_prefix)] != expected_prefix:
        raise SystemExit(f"metadata is not first in IPA: {names[:len(expected_prefix)]}")
    if names[-1] != disk:
        raise SystemExit(f"Android disk is not the final IPA entry: {names[-1]}")
    info = plistlib.loads(archive.read(f"{app}/Info.plist"))
    if info.get("CFBundleIdentifier") != bundle_id:
        raise SystemExit("CFBundleIdentifier mismatch inside IPA")
    if info.get("CFBundleExecutable") != executable:
        raise SystemExit("CFBundleExecutable mismatch inside IPA")
    if info.get("CFBundlePackageType") != "APPL":
        raise SystemExit("CFBundlePackageType is not APPL")
    executable_info = archive.getinfo(f"{app}/{executable}")
    if executable_info.file_size <= 0:
        raise SystemExit("declared executable is empty")
PY

TOP_LEVEL_APPS="$(grep -Ec '^Payload/[^/]+\.app/$' "$OUT/verified-contents.txt")"
[[ "$TOP_LEVEL_APPS" == "1" ]]
grep -q "^$ARCHIVE_APP/Info.plist$" "$OUT/verified-contents.txt"
grep -q "^$ARCHIVE_APP/LCAppInfo.plist$" "$OUT/verified-contents.txt"
grep -q "^$ARCHIVE_APP/$EXECUTABLE$" "$OUT/verified-contents.txt"
grep -q "^$ARCHIVE_APP/BootstrapTweaks/AndroidGuestBootstrap.dylib$" "$OUT/verified-contents.txt"
grep -q "^$ARCHIVE_APP/PreloadedData/Android.utm/config.plist$" "$OUT/verified-contents.txt"
grep -q "^$ARCHIVE_DISK$" "$OUT/verified-contents.txt"
for framework in "${REQUIRED_QEMU_FRAMEWORKS[@]}"; do
  grep -q "^$ARCHIVE_APP/Frameworks/$framework/" "$OUT/verified-contents.txt"
done
for framework in "${UNUSED_QEMU_FRAMEWORKS[@]}"; do
  if grep -q "^$ARCHIVE_APP/Frameworks/$framework/" "$OUT/verified-contents.txt"; then
    echo "The final IPA still contains unused framework: $framework" >&2
    exit 1
  fi
done
if grep -q '\.iso$' "$OUT/verified-contents.txt"; then
  echo "The final IPA unexpectedly contains an installer ISO." >&2
  exit 1
fi
if grep -q 'PreloadedApps/' "$OUT/verified-contents.txt"; then
  echo "The final IPA still contains a nested app host." >&2
  exit 1
fi
if grep -Eq '(_CodeSignature|embedded.mobileprovision)' "$OUT/verified-contents.txt"; then
  echo "The unsigned IPA unexpectedly contains signing artifacts." >&2
  exit 1
fi

printf '[10/10] Extracting with libarchive and rejecting Unknown.app metadata failures\n'
EXTRACT_TEST="$WORK/livecontainer-libarchive-extract"
rm -rf "$EXTRACT_TEST"
mkdir -p "$EXTRACT_TEST"
tar -xf "$OUT/$OUTPUT_IPA" -C "$EXTRACT_TEST"
EXTRACTED_APP="$EXTRACT_TEST/$ARCHIVE_APP"
EXTRACTED_INFO="$EXTRACTED_APP/Info.plist"
EXTRACTED_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$EXTRACTED_INFO")"
EXTRACTED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$EXTRACTED_INFO")"
[[ "$EXTRACTED_EXECUTABLE" == "$EXECUTABLE" ]]
[[ "$EXTRACTED_BUNDLE_ID" == "$GUEST_BUNDLE_ID" ]]
[[ -f "$EXTRACTED_APP/$EXTRACTED_EXECUTABLE" ]]
[[ -f "$EXTRACT_TEST/$ARCHIVE_DISK" ]]
EXPECTED_DISK_SHA="$(awk '{print $1; exit}' "$WORK/$ANDROID_DISK_NAME.sha256")"
EXTRACTED_DISK_SHA="$(shasum -a 256 "$EXTRACT_TEST/$ARCHIVE_DISK" | awk '{print $1}')"
[[ "$EXPECTED_DISK_SHA" == "$EXTRACTED_DISK_SHA" ]]
cat > "$OUT/livecontainer-import-validation.txt" <<EOF2
Archive metadata first: yes
Archive Android disk last: yes
Libarchive extraction: passed
Extracted app folder: $GUEST_APP_BASENAME
Extracted bundle identifier: $EXTRACTED_BUNDLE_ID
Extracted executable: $EXTRACTED_EXECUTABLE
Extracted Android disk SHA-256: $EXTRACTED_DISK_SHA
Unknown.app fallback prevented by validated metadata: yes
EOF2
rm -rf "$EXTRACT_TEST"

IPA_SIZE="$(stat -f%z "$OUT/$OUTPUT_IPA")"
if (( IPA_SIZE >= GITHUB_RELEASE_LIMIT )); then
  echo "The import-safe IPA is ${IPA_SIZE} bytes and exceeds the single GitHub release asset limit of ${GITHUB_RELEASE_LIMIT} bytes." >&2
  exit 1
fi

shasum -a 256 "$OUT/$OUTPUT_IPA" > "$OUT/$OUTPUT_IPA.sha256"
cat > "$OUT/build-manifest.txt" <<EOF2
Package type: LiveContainer guest IPA
Top-level app: $GUEST_APP_BASENAME (UTM SE ${UTM_TAG})
Top-level executable: ${EXECUTABLE}
Bundle identifier: ${GUEST_BUNDLE_ID}
Expected LiveContainer installed folder: ${GUEST_INSTALL_FOLDER}
LiveContainer data container: ${GUEST_CONTAINER}
Guest bootstrap: BootstrapTweaks/AndroidGuestBootstrap.dylib
Android guest: BlissOS 16.9.7 / Android 13 x86_64
Android state: preinstalled persistent disk
Android disk compression: qcow2 zlib
Installer ISO: absent
Debug console boot: disabled
Boot target: disk / UEFI / zero-second GRUB
Execution mode: UTM SE QEMU TCI / no JIT
UTM required QEMU frameworks: m68k and x86_64 retained
UTM executable dependencies: validated with otool
Removed unused QEMU frameworks and firmware: ${UTM_TRIMMED_KIB} KiB
LiveContainer import metadata: first archive entries
Android disk archive position: final entry
LiveContainer libarchive extraction: passed with disk SHA verification
Unknown.app fallback: guarded by import-safe archive order and clean bundle identity
Nested LiveContainer host: absent
Nested .app bundles: absent
Release delivery: one complete IPA asset; split parts forbidden
Signing: unsigned; import into a configured LiveContainer JITLess installation
IPA size: ${IPA_SIZE} bytes
Physical-device graphical boot verification: pending
EOF2

printf 'Built import-safe preinstalled Android 13 LiveContainer guest: %s\n' "$OUT/$OUTPUT_IPA"
