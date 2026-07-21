#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.build/livecontainer-utm-se"
OUT="$ROOT/build/full-livecontainer"
LC_TAG="${LC_TAG:-3.7.2}"
UTM_TAG="${UTM_TAG:-v5.0.2}"
ANDROID_ISO_NAME="android-x86_64-9.0-r2.iso"
ANDROID_ISO_SHA1="1cc85b5ed7c830ff71aecf8405c7281a9c995aa0"
ANDROID_ISO_URL="${ANDROID_ISO_URL:-https://downloads.sourceforge.net/project/android-x86/Release%209.0/android-x86_64-9.0-r2.iso}"
LC_REPO="https://github.com/LiveContainer/LiveContainer.git"
UTM_IPA_URL="https://github.com/utmapp/UTM/releases/download/${UTM_TAG}/UTM-SE.ipa"
OUTPUT_IPA="Android-iOSEmulator-Full-Android-x86-unsigned.ipa"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

if ! command -v qemu-img >/dev/null 2>&1; then
  echo "qemu-img is required to create the persistent Android disk." >&2
  exit 1
fi

echo "[1/10] Cloning LiveContainer ${LC_TAG}"
git clone --recursive --depth 1 --branch "$LC_TAG" "$LC_REPO" "$WORK/LiveContainer"

echo "[2/10] Downloading UTM SE ${UTM_TAG}"
curl --fail --location --retry 3 --retry-delay 2 "$UTM_IPA_URL" -o "$WORK/UTM-SE.ipa"
mkdir -p "$WORK/utm"
unzip -q "$WORK/UTM-SE.ipa" -d "$WORK/utm"
UTM_APP="$(find "$WORK/utm/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$UTM_APP" ]]; then
  echo "UTM SE application bundle was not found in the downloaded IPA." >&2
  exit 1
fi

echo "[3/10] Downloading and verifying Android-x86 9.0-r2"
curl --fail --location --retry 5 --retry-delay 3 "$ANDROID_ISO_URL" -o "$WORK/$ANDROID_ISO_NAME"
printf '%s  %s\n' "$ANDROID_ISO_SHA1" "$WORK/$ANDROID_ISO_NAME" | shasum -a 1 -c -

echo "[4/10] Creating persistent Android disk and UTM bundle"
qemu-img create -f qcow2 "$WORK/android-data.qcow2" 8G
qemu-img check "$WORK/android-data.qcow2"
python3 "$ROOT/scripts/make_android_x86_utm.py" \
  --output "$WORK/Android.utm" \
  --iso "$WORK/$ANDROID_ISO_NAME" \
  --disk "$WORK/android-data.qcow2"
plutil -lint "$WORK/Android.utm/config.plist"

echo "[5/10] Patching LiveContainer startup and Xcode compatibility"
LC_APP_SOURCE="$(find "$WORK/LiveContainer" -type f -name 'LiveContainerSwiftUIApp.swift' -print -quit)"
if [[ -z "$LC_APP_SOURCE" ]]; then
  echo "Could not locate LiveContainerSwiftUIApp.swift in LiveContainer ${LC_TAG}." >&2
  find "$WORK/LiveContainer" -maxdepth 4 -type f -name '*App*.swift' -print >&2 || true
  exit 1
fi
printf 'LiveContainer startup source: %s\n' "$LC_APP_SOURCE"

LC_BOOTSTRAP_SOURCE="$(find "$WORK/LiveContainer" -type f -name 'LCBootstrap.m' -print -quit)"
if [[ -z "$LC_BOOTSTRAP_SOURCE" ]]; then
  echo "Could not locate LCBootstrap.m in LiveContainer ${LC_TAG}." >&2
  exit 1
fi
printf 'LiveContainer bootstrap source: %s\n' "$LC_BOOTSTRAP_SOURCE"

python3 - "$LC_BOOTSTRAP_SOURCE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
replacements = {
    'for(int i = 0; i < header->ncmds > 0; ++i) {':
        'for(int i = 0; i < header->ncmds; ++i) {',
    'static BOOL checkJITEnabled() {':
        'static BOOL checkJITEnabled(void) {',
}

for old, new in replacements.items():
    if old in text:
        text = text.replace(old, new)
    elif new not in text:
        raise SystemExit(f'Expected LiveContainer compatibility source was not found: {old}')

path.write_text(text)
PY

python3 - "$LC_APP_SOURCE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

helper = r'''
private enum AndroidPreloadedGuestInstaller {
    private static let bundledAppFolderName = "PreloadedApps"
    private static let bundledAppName = "UTM SE"
    private static let installedAppName = "Android Runtime.app"
    private static let bundledDataFolderName = "PreloadedData"
    private static let bundledVMName = "Android.utm"
    private static let containerFolderName = "AndroidRuntimeData"

    static func installIfNeeded(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: LCPath.dataPath, withIntermediateDirectories: true)

        let installedApp = LCPath.bundlePath.appendingPathComponent(installedAppName, isDirectory: true)
        if !fileManager.fileExists(atPath: installedApp.path) {
            let bundledApp = Bundle.main.bundleURL
                .appendingPathComponent(bundledAppFolderName, isDirectory: true)
                .appendingPathComponent("\(bundledAppName).app", isDirectory: true)
            guard fileManager.fileExists(atPath: bundledApp.path) else {
                NSLog("[Android iOSEmulator] bundled UTM SE guest is missing")
                return
            }
            try fileManager.copyItem(at: bundledApp, to: installedApp)
        }

        let appInfoURL = installedApp.appendingPathComponent("LCAppInfo.plist")
        var appInfo = (NSDictionary(contentsOf: appInfoURL) as? [String: Any]) ?? [:]
        appInfo["LCDataUUID"] = containerFolderName
        appInfo["LCContainers"] = [[
            "folderName": containerFolderName,
            "name": "Android"
        ]]
        appInfo["isJITNeeded"] = false
        appInfo["dontInjectTweakLoader"] = true
        appInfo["dontLoadTweakLoader"] = true
        let appInfoData = try PropertyListSerialization.data(
            fromPropertyList: appInfo,
            format: .binary,
            options: 0
        )
        try appInfoData.write(to: appInfoURL, options: .atomic)

        let container = LCPath.dataPath.appendingPathComponent(containerFolderName, isDirectory: true)
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)

        let guestInfo = NSDictionary(contentsOf: installedApp.appendingPathComponent("Info.plist"))
        let guestIdentifier = guestInfo?["CFBundleIdentifier"] as? String ?? "com.utmapp.UTM-SE"
        let containerInfo: [String: Any] = [
            "appIdentifier": guestIdentifier,
            "name": "Android",
            "keychainGroupId": 0,
            "isolateAppGroup": false,
            "spoofIdentifierForVendor": false
        ]
        let containerInfoData = try PropertyListSerialization.data(
            fromPropertyList: containerInfo,
            format: .binary,
            options: 0
        )
        try containerInfoData.write(
            to: container.appendingPathComponent("LCContainerInfo.plist"),
            options: .atomic
        )

        let installedVM = documents.appendingPathComponent(bundledVMName, isDirectory: true)
        if !fileManager.fileExists(atPath: installedVM.path) {
            let bundledVM = Bundle.main.bundleURL
                .appendingPathComponent(bundledDataFolderName, isDirectory: true)
                .appendingPathComponent(bundledVMName, isDirectory: true)
            guard fileManager.fileExists(atPath: bundledVM.path) else {
                NSLog("[Android iOSEmulator] bundled Android.utm guest is missing")
                return
            }
            try fileManager.copyItem(at: bundledVM, to: installedVM)
        }

        NSLog("[Android iOSEmulator] Android runtime and VM are ready at %@", installedVM.path)
    }
}

'''

anchor = '@main\nstruct LiveContainerSwiftUIApp'
if helper.strip() not in text:
    if anchor not in text:
        raise SystemExit('Could not find LiveContainer SwiftUI app declaration')
    text = text.replace(anchor, helper + anchor, 1)

needle = '''        do {
             // load apps
'''
replacement = '''        do {
            try AndroidPreloadedGuestInstaller.installIfNeeded(fileManager: fm)
             // load apps
'''
if replacement not in text:
    if needle not in text:
        # Upstream spacing changed in some tags; use the stable comment anchor.
        comment = '            // load apps\n'
        if comment not in text:
            raise SystemExit('Could not find LiveContainer app-loading block')
        text = text.replace(comment, '            try AndroidPreloadedGuestInstaller.installIfNeeded(fileManager: fm)\n' + comment, 1)
    else:
        text = text.replace(needle, replacement, 1)

path.write_text(text)
PY

echo "[6/10] Building the real LiveContainer frontend"
cd "$WORK/LiveContainer"
FILE_TYPE="project"
FILE_TO_BUILD="$(find . -maxdepth 1 -name '*.xcworkspace' -print -quit)"
if [[ -n "$FILE_TO_BUILD" ]]; then
  FILE_TYPE="workspace"
else
  FILE_TO_BUILD="$(find . -maxdepth 1 -name '*.xcodeproj' -print -quit)"
fi
if [[ -z "$FILE_TO_BUILD" ]]; then
  echo "No LiveContainer workspace or project found." >&2
  exit 1
fi

xcodebuild archive \
  -archivePath "$WORK/LiveContainerArchive" \
  -scheme LiveContainer \
  -"$FILE_TYPE" "$FILE_TO_BUILD" \
  -sdk iphoneos \
  -arch arm64 \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  | tee "$OUT/xcodebuild.log"

HOST_APP="$(find "$WORK/LiveContainerArchive.xcarchive/Products/Applications" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$HOST_APP" ]]; then
  echo "Archived LiveContainer app was not found." >&2
  exit 1
fi

echo "[7/10] Embedding UTM SE and the Android VM"
mkdir -p "$HOST_APP/PreloadedApps" "$HOST_APP/PreloadedData"
cp -R "$UTM_APP" "$HOST_APP/PreloadedApps/UTM SE.app"
cp -R "$WORK/Android.utm" "$HOST_APP/PreloadedData/Android.utm"
find "$HOST_APP/PreloadedApps/UTM SE.app" -name '_CodeSignature' -type d -prune -exec rm -rf {} + || true
find "$HOST_APP/PreloadedApps/UTM SE.app" -name 'embedded.mobileprovision' -type f -delete || true

/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Android" "$HOST_APP/PreloadedApps/UTM SE.app/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Android" "$HOST_APP/PreloadedApps/UTM SE.app/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Android iOSEmulator" "$HOST_APP/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Android iOSEmulator" "$HOST_APP/Info.plist"

HOST_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$HOST_APP/Info.plist")"
UTM_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$HOST_APP/PreloadedApps/UTM SE.app/Info.plist")"
if [[ ! -f "$HOST_APP/$HOST_EXECUTABLE" ]]; then
  echo "Host CFBundleExecutable does not exist: $HOST_EXECUTABLE" >&2
  exit 1
fi
if [[ ! -f "$HOST_APP/PreloadedApps/UTM SE.app/$UTM_EXECUTABLE" ]]; then
  echo "UTM SE CFBundleExecutable does not exist: $UTM_EXECUTABLE" >&2
  exit 1
fi
file "$HOST_APP/$HOST_EXECUTABLE"
file "$HOST_APP/PreloadedApps/UTM SE.app/$UTM_EXECUTABLE"

echo "[8/10] Packaging unsigned full IPA"
PAYLOAD="$WORK/package/Payload"
mkdir -p "$PAYLOAD"
cp -R "$HOST_APP" "$PAYLOAD/Android iOSEmulator.app"
find "$PAYLOAD" -name '_CodeSignature' -type d -prune -exec rm -rf {} + || true
find "$PAYLOAD" -name 'embedded.mobileprovision' -type f -delete || true
(
  cd "$WORK/package"
  zip -qry "$OUT/$OUTPUT_IPA" Payload
)

echo "[9/10] Verifying package contents"
unzip -t "$OUT/$OUTPUT_IPA" >/dev/null
unzip -l "$OUT/$OUTPUT_IPA" > "$OUT/ipa-contents.txt"
grep -q 'PreloadedApps/UTM SE.app/' "$OUT/ipa-contents.txt"
grep -q 'PreloadedData/Android.utm/config.plist' "$OUT/ipa-contents.txt"
grep -q "PreloadedData/Android.utm/Images/$ANDROID_ISO_NAME" "$OUT/ipa-contents.txt"
grep -q 'PreloadedData/Android.utm/Images/android-data.qcow2' "$OUT/ipa-contents.txt"
if grep -Eq '(_CodeSignature|embedded.mobileprovision)' "$OUT/ipa-contents.txt"; then
  echo "The output unexpectedly contains signing artifacts." >&2
  exit 1
fi

echo "[10/10] Writing checksums and manifest"
shasum -a 256 "$OUT/$OUTPUT_IPA" > "$OUT/$OUTPUT_IPA.sha256"
cat > "$OUT/build-manifest.txt" <<EOF
Host frontend: LiveContainer ${LC_TAG}
Guest runtime: UTM SE ${UTM_TAG}
Android guest: Android-x86 9.0-r2 x86_64
Android ISO SHA-1: ${ANDROID_ISO_SHA1}
Execution mode: QEMU threaded interpreter / no JIT
VM machine: q35
VM memory: 2048 MiB
VM CPUs: 2
Persistent disk: 8 GiB qcow2
Target: iPhoneOS arm64
Signing: unsigned
Host executable: ${HOST_EXECUTABLE}
UTM executable: ${UTM_EXECUTABLE}
Preloaded app: PreloadedApps/UTM SE.app
Preloaded VM: PreloadedData/Android.utm
LiveContainer data folder: AndroidRuntimeData
First boot: Android-x86 ISO live/installer menu
Physical iPhone Android boot verification: pending
EOF

echo "Built: $OUT/$OUTPUT_IPA"
