#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.build/livecontainer-guest"
OUT="$ROOT/build/livecontainer-guest"
UTM_TAG="${UTM_TAG:-v5.0.2}"
UTM_IPA_URL="https://github.com/utmapp/UTM/releases/download/${UTM_TAG}/UTM-SE.ipa"
ANDROID_DISK_NAME="bliss-android13-preinstalled.qcow2"
GUEST_BUNDLE_ID="com.nightvibes33.androidiosemulator.livecontainer"
GUEST_INSTALL_FOLDER="${GUEST_BUNDLE_ID}.app"
GUEST_CONTAINER="AndroidRuntimeData"
OUTPUT_IPA="Android-iOSEmulator-Android13-Preinstalled-LiveContainer-Guest-unsigned.ipa"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

for command in qemu-img 7zz mformat mcopy; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required to build the preinstalled Android 13 guest." >&2
    exit 1
  fi
done

printf '[1/8] Downloading official UTM SE %s\n' "$UTM_TAG"
curl --fail --location --retry 4 --retry-delay 2 "$UTM_IPA_URL" -o "$WORK/UTM-SE.ipa"
mkdir -p "$WORK/utm"
unzip -q "$WORK/UTM-SE.ipa" -d "$WORK/utm"
UTM_APP="$(find "$WORK/utm/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$UTM_APP" ]]; then
  echo "The downloaded UTM SE IPA does not contain a top-level application bundle." >&2
  exit 1
fi

printf '[2/8] Building a preinstalled BlissOS 16 / Android 13 disk\n'
bash "$ROOT/scripts/build_bliss_android13_disk.sh" \
  "$WORK/android13-disk-work" \
  "$WORK/$ANDROID_DISK_NAME"

printf '[3/8] Creating the Android 13 UTM bundle\n'
python3 "$ROOT/scripts/make_bliss_android13_utm.py" \
  --output "$WORK/Android.utm" \
  --disk "$WORK/$ANDROID_DISK_NAME"
plutil -lint "$WORK/Android.utm/config.plist"

printf '[4/8] Creating the real LiveContainer guest application\n'
PAYLOAD="$WORK/package/Payload"
GUEST_APP="$PAYLOAD/Android iOSEmulator.app"
mkdir -p "$PAYLOAD"
cp -R "$UTM_APP" "$GUEST_APP"
find "$GUEST_APP" -name '_CodeSignature' -type d -prune -exec rm -rf {} + || true
find "$GUEST_APP" -name 'embedded.mobileprovision' -type f -delete || true

INFO_PLIST="$GUEST_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $GUEST_BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Android iOSEmulator" "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Android iOSEmulator" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Android iOSEmulator" "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string Android iOSEmulator" "$INFO_PLIST"

mkdir -p "$GUEST_APP/PreloadedData"
cp -R "$WORK/Android.utm" "$GUEST_APP/PreloadedData/Android.utm"
cp "$WORK/$ANDROID_DISK_NAME.manifest.txt" "$GUEST_APP/PreloadedData/Android.utm/Android13RuntimeManifest.txt"

printf '[5/8] Compiling the Android 13 guest bootstrap tweak\n'
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

printf '[6/8] Verifying the preinstalled Android 13 guest layout\n'
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST")"
[[ "$BUNDLE_ID" == "$GUEST_BUNDLE_ID" ]]
[[ "$DISPLAY_NAME" == "Android iOSEmulator" ]]
[[ -n "$EXECUTABLE" && -f "$GUEST_APP/$EXECUTABLE" ]]
file "$GUEST_APP/$EXECUTABLE" | grep -q 'Mach-O 64-bit executable arm64'
file "$GUEST_APP/BootstrapTweaks/AndroidGuestBootstrap.dylib" | grep -q 'Mach-O 64-bit dynamically linked shared library arm64'
[[ -f "$GUEST_APP/PreloadedData/Android.utm/config.plist" ]]
[[ -f "$GUEST_APP/PreloadedData/Android.utm/Images/$ANDROID_DISK_NAME" ]]
[[ -f "$GUEST_APP/PreloadedData/Android.utm/Android13RuntimeManifest.txt" ]]
[[ -f "$GUEST_APP/LCAppInfo.plist" ]]
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
  find "$GUEST_APP" -mindepth 1 -type d -name '*.app' -print >&2
  exit 1
fi

printf '[7/8] Packaging the unsigned Android 13 LiveContainer guest IPA\n'
(
  cd "$WORK/package"
  zip -qry "$OUT/$OUTPUT_IPA" Payload
)

printf '[8/8] Validating the final IPA\n'
unzip -t "$OUT/$OUTPUT_IPA" >/dev/null
unzip -l "$OUT/$OUTPUT_IPA" > "$OUT/ipa-contents.txt"
TOP_LEVEL_APPS="$(unzip -Z1 "$OUT/$OUTPUT_IPA" | grep -Ec '^Payload/[^/]+\.app/$')"
[[ "$TOP_LEVEL_APPS" == "1" ]]
grep -q 'Payload/Android iOSEmulator.app/LCAppInfo.plist' "$OUT/ipa-contents.txt"
grep -q 'Payload/Android iOSEmulator.app/BootstrapTweaks/AndroidGuestBootstrap.dylib' "$OUT/ipa-contents.txt"
grep -q 'Payload/Android iOSEmulator.app/PreloadedData/Android.utm/config.plist' "$OUT/ipa-contents.txt"
grep -q "Payload/Android iOSEmulator.app/PreloadedData/Android.utm/Images/$ANDROID_DISK_NAME" "$OUT/ipa-contents.txt"
grep -q 'Payload/Android iOSEmulator.app/PreloadedData/Android.utm/Android13RuntimeManifest.txt' "$OUT/ipa-contents.txt"
if grep -q '\.iso$' "$OUT/ipa-contents.txt"; then
  echo "The final IPA unexpectedly contains an installer ISO." >&2
  exit 1
fi
if grep -q 'PreloadedApps/' "$OUT/ipa-contents.txt"; then
  echo "The final IPA still contains a nested app host." >&2
  exit 1
fi
if grep -Eq '(_CodeSignature|embedded.mobileprovision)' "$OUT/ipa-contents.txt"; then
  echo "The unsigned IPA unexpectedly contains signing artifacts." >&2
  exit 1
fi

shasum -a 256 "$OUT/$OUTPUT_IPA" > "$OUT/$OUTPUT_IPA.sha256"
IPA_SIZE="$(stat -f%z "$OUT/$OUTPUT_IPA")"
cat > "$OUT/build-manifest.txt" <<EOF
Package type: LiveContainer guest IPA
Top-level app: Android iOSEmulator.app (UTM SE ${UTM_TAG})
Top-level executable: ${EXECUTABLE}
Bundle identifier: ${GUEST_BUNDLE_ID}
Expected LiveContainer installed folder: ${GUEST_INSTALL_FOLDER}
LiveContainer data container: ${GUEST_CONTAINER}
Guest bootstrap: BootstrapTweaks/AndroidGuestBootstrap.dylib
Android guest: BlissOS 16.9.7 / Android 13 x86_64
Android state: preinstalled persistent disk
Installer ISO: absent
Debug console boot: disabled
Boot target: disk / UEFI / zero-second GRUB
Execution mode: UTM SE QEMU TCI / no JIT
Persistent Android data: 3 GiB ext4 image inside the guest disk
Nested LiveContainer host: absent
Nested .app bundles: absent
Signing: unsigned; import into a configured LiveContainer JITLess installation
IPA size: ${IPA_SIZE} bytes
Physical-device graphical boot verification: pending
EOF

printf 'Built preinstalled Android 13 LiveContainer guest: %s\n' "$OUT/$OUTPUT_IPA"
