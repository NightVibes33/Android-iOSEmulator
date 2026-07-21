#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.build/livecontainer-guest"
OUT="$ROOT/build/livecontainer-guest"
UTM_TAG="${UTM_TAG:-v5.0.2}"
UTM_IPA_URL="https://github.com/utmapp/UTM/releases/download/${UTM_TAG}/UTM-SE.ipa"
ANDROID_ISO_NAME="android-x86_64-9.0-r2.iso"
ANDROID_ISO_SHA1="1cc85b5ed7c830ff71aecf8405c7281a9c995aa0"
ANDROID_ISO_URL="${ANDROID_ISO_URL:-https://downloads.sourceforge.net/project/android-x86/Release%209.0/android-x86_64-9.0-r2.iso}"
GUEST_BUNDLE_ID="com.nightvibes33.androidiosemulator.livecontainer"
GUEST_INSTALL_FOLDER="${GUEST_BUNDLE_ID}.app"
GUEST_CONTAINER="AndroidRuntimeData"
OUTPUT_IPA="Android-iOSEmulator-LiveContainer-Guest-unsigned.ipa"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

if ! command -v qemu-img >/dev/null 2>&1; then
  echo "qemu-img is required to create the persistent Android disk." >&2
  exit 1
fi

printf '[1/8] Downloading official UTM SE %s\n' "$UTM_TAG"
curl --fail --location --retry 4 --retry-delay 2 "$UTM_IPA_URL" -o "$WORK/UTM-SE.ipa"
mkdir -p "$WORK/utm"
unzip -q "$WORK/UTM-SE.ipa" -d "$WORK/utm"
UTM_APP="$(find "$WORK/utm/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$UTM_APP" ]]; then
  echo "The downloaded UTM SE IPA does not contain a top-level application bundle." >&2
  exit 1
fi

printf '[2/8] Downloading and verifying Android-x86 9.0-r2\n'
curl --fail --location --retry 5 --retry-delay 3 "$ANDROID_ISO_URL" -o "$WORK/$ANDROID_ISO_NAME"
printf '%s  %s\n' "$ANDROID_ISO_SHA1" "$WORK/$ANDROID_ISO_NAME" | shasum -a 1 -c -

printf '[3/8] Creating the writable disk and Android UTM bundle\n'
qemu-img create -f qcow2 "$WORK/android-data.qcow2" 8G
qemu-img check "$WORK/android-data.qcow2"
python3 "$ROOT/scripts/make_android_x86_utm.py" \
  --output "$WORK/Android.utm" \
  --iso "$WORK/$ANDROID_ISO_NAME" \
  --disk "$WORK/android-data.qcow2"
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

printf '[5/8] Compiling the guest bootstrap tweak\n'
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
    "LCContainers": [{"folderName": container, "name": "Android"}],
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

printf '[6/8] Verifying guest layout before packaging\n'
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST")"
[[ "$BUNDLE_ID" == "$GUEST_BUNDLE_ID" ]]
[[ "$DISPLAY_NAME" == "Android iOSEmulator" ]]
[[ -n "$EXECUTABLE" && -f "$GUEST_APP/$EXECUTABLE" ]]
file "$GUEST_APP/$EXECUTABLE" | grep -q 'Mach-O 64-bit executable arm64'
file "$GUEST_APP/BootstrapTweaks/AndroidGuestBootstrap.dylib" | grep -q 'Mach-O 64-bit dynamically linked shared library arm64'
[[ -f "$GUEST_APP/PreloadedData/Android.utm/config.plist" ]]
[[ -f "$GUEST_APP/PreloadedData/Android.utm/Images/$ANDROID_ISO_NAME" ]]
[[ -f "$GUEST_APP/PreloadedData/Android.utm/Images/android-data.qcow2" ]]
[[ -f "$GUEST_APP/LCAppInfo.plist" ]]
if [[ -d "$GUEST_APP/PreloadedApps" ]]; then
  echo "Nested LiveContainer PreloadedApps directory is forbidden in the guest IPA." >&2
  exit 1
fi
if find "$GUEST_APP" -mindepth 1 -type d -name '*.app' -print -quit | grep -q .; then
  echo "A nested .app bundle was found. The LiveContainer guest must have one top-level app only." >&2
  find "$GUEST_APP" -mindepth 1 -type d -name '*.app' -print >&2
  exit 1
fi

printf '[7/8] Packaging the unsigned LiveContainer guest IPA\n'
(
  cd "$WORK/package"
  zip -qry "$OUT/$OUTPUT_IPA" Payload
)

printf '[8/8] Validating the final IPA\n'
unzip -t "$OUT/$OUTPUT_IPA" >/dev/null
unzip -l "$OUT/$OUTPUT_IPA" > "$OUT/ipa-contents.txt"
TOP_LEVEL_APPS="$(awk '/Payload\/[^/]+\.app\/$/ { count++ } END { print count+0 }' "$OUT/ipa-contents.txt")"
[[ "$TOP_LEVEL_APPS" == "1" ]]
grep -q 'Payload/Android iOSEmulator.app/LCAppInfo.plist' "$OUT/ipa-contents.txt"
grep -q 'Payload/Android iOSEmulator.app/BootstrapTweaks/AndroidGuestBootstrap.dylib' "$OUT/ipa-contents.txt"
grep -q 'Payload/Android iOSEmulator.app/PreloadedData/Android.utm/config.plist' "$OUT/ipa-contents.txt"
grep -q "Payload/Android iOSEmulator.app/PreloadedData/Android.utm/Images/$ANDROID_ISO_NAME" "$OUT/ipa-contents.txt"
if grep -q 'PreloadedApps/' "$OUT/ipa-contents.txt"; then
  echo "The final IPA still contains a nested app host." >&2
  exit 1
fi
if grep -Eq '(_CodeSignature|embedded.mobileprovision)' "$OUT/ipa-contents.txt"; then
  echo "The unsigned IPA unexpectedly contains signing artifacts." >&2
  exit 1
fi

shasum -a 256 "$OUT/$OUTPUT_IPA" > "$OUT/$OUTPUT_IPA.sha256"
cat > "$OUT/build-manifest.txt" <<EOF
Package type: LiveContainer guest IPA
Top-level app: Android iOSEmulator.app (UTM SE ${UTM_TAG})
Top-level executable: ${EXECUTABLE}
Bundle identifier: ${GUEST_BUNDLE_ID}
Expected LiveContainer installed folder: ${GUEST_INSTALL_FOLDER}
LiveContainer data container: ${GUEST_CONTAINER}
Guest bootstrap: BootstrapTweaks/AndroidGuestBootstrap.dylib
Bootstrap behavior: copies config and writable qcow2; symlinks the read-only ISO
Android guest: Android-x86 9.0-r2 x86_64
Execution mode: UTM SE QEMU TCI / no JIT
Nested LiveContainer host: absent
Nested .app bundles: absent
Signing: unsigned; import into a configured LiveContainer JITLess installation
Physical-device VM boot verification: pending
EOF

printf 'Built LiveContainer guest: %s\n' "$OUT/$OUTPUT_IPA"
