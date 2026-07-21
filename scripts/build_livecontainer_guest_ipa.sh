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
GITHUB_RELEASE_LIMIT=2147483648

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

for command in qemu-img 7zz mformat mcopy otool zip; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required to build the preinstalled Android 13 guest." >&2
    exit 1
  fi
done

printf '[1/9] Downloading official UTM SE %s\n' "$UTM_TAG"
curl --fail --location --retry 4 --retry-delay 2 "$UTM_IPA_URL" -o "$WORK/UTM-SE.ipa"
mkdir -p "$WORK/utm"
unzip -q "$WORK/UTM-SE.ipa" -d "$WORK/utm"
UTM_APP="$(find "$WORK/utm/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$UTM_APP" ]]; then
  echo "The downloaded UTM SE IPA does not contain a top-level application bundle." >&2
  exit 1
fi

printf '[2/9] Building a compact preinstalled BlissOS 16 / Android 13 disk\n'
bash "$ROOT/scripts/build_bliss_android13_disk.sh" \
  "$WORK/android13-disk-work" \
  "$WORK/$ANDROID_DISK_NAME"

printf '[3/9] Creating the Android 13 UTM bundle\n'
python3 "$ROOT/scripts/make_bliss_android13_utm.py" \
  --output "$WORK/Android.utm" \
  --disk "$WORK/$ANDROID_DISK_NAME"
plutil -lint "$WORK/Android.utm/config.plist"

printf '[4/9] Creating the real LiveContainer guest application\n'
PAYLOAD="$WORK/package/Payload"
GUEST_APP="$PAYLOAD/Android iOSEmulator.app"
mkdir -p "$PAYLOAD"
cp -R "$UTM_APP" "$GUEST_APP"
find "$GUEST_APP" -name '_CodeSignature' -type d -prune -exec rm -rf {} + || true
find "$GUEST_APP" -name 'embedded.mobileprovision' -type f -delete || true

INFO_PLIST="$GUEST_APP/Info.plist"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
if [[ -z "$EXECUTABLE" || ! -f "$GUEST_APP/$EXECUTABLE" ]]; then
  echo "UTM SE is missing its declared executable." >&2
  exit 1
fi

printf '[5/9] Keeping the QEMU frameworks required by dyld and Android x86_64\n'
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

# These firmware blobs are for non-x86 guest machines. The m68k framework remains
# because the UTM SE executable itself strongly links it during dlopen.
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

# Prevent the exact device failure: every @rpath framework strongly linked by
# the UTM SE Mach-O must still exist at its expected path before packaging.
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

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $GUEST_BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Android iOSEmulator" "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Android iOSEmulator" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Android iOSEmulator" "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string Android iOSEmulator" "$INFO_PLIST"

mkdir -p "$GUEST_APP/PreloadedData"
cp -R "$WORK/Android.utm" "$GUEST_APP/PreloadedData/Android.utm"
cp "$WORK/$ANDROID_DISK_NAME.manifest.txt" "$GUEST_APP/PreloadedData/Android.utm/Android13RuntimeManifest.txt"

printf '[6/9] Compiling the Android 13 guest bootstrap tweak\n'
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

printf '[7/9] Verifying the preinstalled Android 13 guest layout\n'
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST")"
[[ "$BUNDLE_ID" == "$GUEST_BUNDLE_ID" ]]
[[ "$DISPLAY_NAME" == "Android iOSEmulator" ]]
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

printf '[8/9] Packaging the unsigned Android 13 LiveContainer guest IPA\n'
(
  cd "$WORK/package"
  zip -9 -qry "$OUT/$OUTPUT_IPA" Payload
)

printf '[9/9] Validating the final dyld-safe single-file IPA\n'
unzip -t "$OUT/$OUTPUT_IPA" >/dev/null
unzip -l "$OUT/$OUTPUT_IPA" > "$OUT/ipa-contents.txt"
TOP_LEVEL_APPS="$(unzip -Z1 "$OUT/$OUTPUT_IPA" | grep -Ec '^Payload/[^/]+\.app/$')"
[[ "$TOP_LEVEL_APPS" == "1" ]]
grep -q 'Payload/Android iOSEmulator.app/LCAppInfo.plist' "$OUT/ipa-contents.txt"
grep -q 'Payload/Android iOSEmulator.app/BootstrapTweaks/AndroidGuestBootstrap.dylib' "$OUT/ipa-contents.txt"
grep -q 'Payload/Android iOSEmulator.app/PreloadedData/Android.utm/config.plist' "$OUT/ipa-contents.txt"
grep -q "Payload/Android iOSEmulator.app/PreloadedData/Android.utm/Images/$ANDROID_DISK_NAME" "$OUT/ipa-contents.txt"
for framework in "${REQUIRED_QEMU_FRAMEWORKS[@]}"; do
  grep -q "Payload/Android iOSEmulator.app/Frameworks/$framework/" "$OUT/ipa-contents.txt"
done
for framework in "${UNUSED_QEMU_FRAMEWORKS[@]}"; do
  if grep -q "Payload/Android iOSEmulator.app/Frameworks/$framework/" "$OUT/ipa-contents.txt"; then
    echo "The final IPA still contains unused framework: $framework" >&2
    exit 1
  fi
done
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

IPA_SIZE="$(stat -f%z "$OUT/$OUTPUT_IPA")"
if (( IPA_SIZE >= GITHUB_RELEASE_LIMIT )); then
  echo "The dyld-safe IPA is ${IPA_SIZE} bytes and exceeds the single GitHub release asset limit of ${GITHUB_RELEASE_LIMIT} bytes." >&2
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
Persistent Android data: 3 GiB ext4 image inside the guest disk
Nested LiveContainer host: absent
Nested .app bundles: absent
Release delivery: one complete IPA asset; split parts forbidden
Signing: unsigned; import into a configured LiveContainer JITLess installation
IPA size: ${IPA_SIZE} bytes
Physical-device graphical boot verification: pending
EOF

printf 'Built dyld-safe preinstalled Android 13 LiveContainer guest: %s\n' "$OUT/$OUTPUT_IPA"
