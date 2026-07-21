#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.build/livecontainer-utm-se"
OUT="$ROOT/build/full-livecontainer"
LC_TAG="${LC_TAG:-3.7.2}"
UTM_TAG="${UTM_TAG:-v5.0.2}"
LC_REPO="https://github.com/LiveContainer/LiveContainer.git"
UTM_IPA_URL="https://github.com/utmapp/UTM/releases/download/${UTM_TAG}/UTM-SE.ipa"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

echo "[1/7] Cloning LiveContainer ${LC_TAG}"
git clone --recursive --depth 1 --branch "$LC_TAG" "$LC_REPO" "$WORK/LiveContainer"

echo "[2/7] Downloading UTM SE ${UTM_TAG}"
curl --fail --location --retry 3 --retry-delay 2 "$UTM_IPA_URL" -o "$WORK/UTM-SE.ipa"
mkdir -p "$WORK/utm"
unzip -q "$WORK/UTM-SE.ipa" -d "$WORK/utm"
UTM_APP="$(find "$WORK/utm/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$UTM_APP" ]]; then
  echo "UTM SE application bundle was not found in the downloaded IPA." >&2
  exit 1
fi

echo "[3/7] Patching LiveContainer startup, APK flow and Xcode compatibility"
LC_APP_SOURCE="$(find "$WORK/LiveContainer" -type f -name 'LiveContainerSwiftUIApp.swift' -print -quit)"
if [[ -z "$LC_APP_SOURCE" ]]; then
  echo "Could not locate LiveContainerSwiftUIApp.swift in LiveContainer ${LC_TAG}." >&2
  find "$WORK/LiveContainer" -maxdepth 4 -type f -name '*App*.swift' -print >&2 || true
  exit 1
fi
printf 'LiveContainer startup source: %s\n' "$LC_APP_SOURCE"

LC_APP_LIST_SOURCE="$(find "$WORK/LiveContainer" -type f -name 'LCAppListView.swift' -print -quit)"
if [[ -z "$LC_APP_LIST_SOURCE" ]]; then
  echo "Could not locate LCAppListView.swift in LiveContainer ${LC_TAG}." >&2
  exit 1
fi
printf 'LiveContainer app list source: %s\n' "$LC_APP_LIST_SOURCE"

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
    private static let bundledFolderName = "PreloadedApps"
    private static let bundledAppName = "UTM SE"
    private static let installedAppName = "Android Runtime.app"

    static func installIfNeeded(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
        let destination = LCPath.bundlePath.appendingPathComponent(installedAppName, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else { return }

        guard let source = Bundle.main.url(
            forResource: bundledAppName,
            withExtension: "app",
            subdirectory: bundledFolderName
        ) else {
            NSLog("[Android iOSEmulator] bundled UTM SE guest is missing")
            return
        }

        try fileManager.copyItem(at: source, to: destination)
        NSLog("[Android iOSEmulator] installed bundled UTM SE guest at %@", destination.path)
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
        raise SystemExit('Could not find LiveContainer app-loading block')
    text = text.replace(needle, replacement, 1)

path.write_text(text)
PY

python3 "$ROOT/scripts/patch_livecontainer_apk_flow.py" "$LC_APP_LIST_SOURCE"
python3 "$ROOT/scripts/fix_livecontainer_apk_flow_compile.py" "$LC_APP_LIST_SOURCE"

echo "[4/7] Building the real LiveContainer frontend"
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

echo "[5/7] Embedding UTM SE as LiveContainer's preloaded Android runtime"
mkdir -p "$HOST_APP/PreloadedApps"
cp -R "$UTM_APP" "$HOST_APP/PreloadedApps/UTM SE.app"
find "$HOST_APP/PreloadedApps/UTM SE.app" -name '_CodeSignature' -type d -prune -exec rm -rf {} + || true
find "$HOST_APP/PreloadedApps/UTM SE.app" -name 'embedded.mobileprovision' -type f -delete || true

# Change only the user-visible name. CFBundleExecutable and CFBundleName must
# continue to match the compiled LiveContainer binary.
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

echo "[6/7] Packaging unsigned combined IPA"
PAYLOAD="$WORK/package/Payload"
mkdir -p "$PAYLOAD"
cp -R "$HOST_APP" "$PAYLOAD/Android iOSEmulator.app"
find "$PAYLOAD" -name '_CodeSignature' -type d -prune -exec rm -rf {} + || true
find "$PAYLOAD" -name 'embedded.mobileprovision' -type f -delete || true
(
  cd "$WORK/package"
  zip -qry "$OUT/Android-iOSEmulator-LiveContainer-UTM-SE-unsigned.ipa" Payload
)

echo "[7/7] Verifying package contents"
unzip -t "$OUT/Android-iOSEmulator-LiveContainer-UTM-SE-unsigned.ipa" >/dev/null
unzip -l "$OUT/Android-iOSEmulator-LiveContainer-UTM-SE-unsigned.ipa" > "$OUT/ipa-contents.txt"
grep -q 'PreloadedApps/UTM SE.app/' "$OUT/ipa-contents.txt"
if grep -Eq '(_CodeSignature|embedded.mobileprovision)' "$OUT/ipa-contents.txt"; then
  echo "The output unexpectedly contains signing artifacts." >&2
  exit 1
fi

shasum -a 256 "$OUT/Android-iOSEmulator-LiveContainer-UTM-SE-unsigned.ipa" \
  > "$OUT/Android-iOSEmulator-LiveContainer-UTM-SE-unsigned.ipa.sha256"
cat > "$OUT/build-manifest.txt" <<EOF
Host frontend: LiveContainer ${LC_TAG}
Guest runtime: UTM SE ${UTM_TAG}
Execution mode: QEMU threaded interpreter / no JIT
Target: iPhoneOS arm64
Signing: unsigned
Host executable: ${HOST_EXECUTABLE}
UTM executable: ${UTM_EXECUTABLE}
APK workflow: persistent LiveContainer library + Android runtime inbox + launch attempt
Preloaded guest path: PreloadedApps/UTM SE.app
First-launch installed guest: Documents/Applications/Android Runtime.app
EOF

echo "Built: $OUT/Android-iOSEmulator-LiveContainer-UTM-SE-unsigned.ipa"
