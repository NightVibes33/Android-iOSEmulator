#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
PROJECT_PATH="${ROOT_DIR}/AndroidiOSEmulator.xcodeproj"
SCHEME="AndroidiOSEmulator"
CONFIGURATION="Release"
IPA_PATH="${BUILD_DIR}/Android-iOSEmulator-unsigned.ipa"

cd "${ROOT_DIR}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is required (brew install xcodegen)" >&2
  exit 1
fi

rm -rf "${BUILD_DIR}" "${PROJECT_PATH}"
mkdir -p "${BUILD_DIR}"

xcodegen generate --spec project.yml

xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  DEVELOPMENT_TEAM='' \
  CODE_SIGN_ENTITLEMENTS='' \
  clean build

APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}-iphoneos/AndroidiOSEmulator.app"
BINARY_PATH="${APP_PATH}/AndroidiOSEmulator"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: app product not found at ${APP_PATH}" >&2
  exit 1
fi

if [[ ! -f "${BINARY_PATH}" ]]; then
  echo "error: app executable not found at ${BINARY_PATH}" >&2
  exit 1
fi

ARCH_INFO="$(lipo -info "${BINARY_PATH}")"
echo "${ARCH_INFO}"
if [[ "${ARCH_INFO}" != *"arm64"* ]]; then
  echo "error: real-device binary does not contain arm64" >&2
  exit 1
fi

rm -rf "${APP_PATH}/_CodeSignature"
rm -f "${APP_PATH}/embedded.mobileprovision"
/usr/bin/xattr -cr "${APP_PATH}" || true

if codesign -dv "${APP_PATH}" >/dev/null 2>&1; then
  echo "error: app unexpectedly contains a valid code signature" >&2
  exit 1
fi

plutil -lint "${APP_PATH}/Info.plist"

PAYLOAD_ROOT="${BUILD_DIR}/package"
rm -rf "${PAYLOAD_ROOT}"
mkdir -p "${PAYLOAD_ROOT}/Payload"
/usr/bin/ditto "${APP_PATH}" "${PAYLOAD_ROOT}/Payload/AndroidiOSEmulator.app"

rm -f "${IPA_PATH}" "${IPA_PATH}.sha256"
(
  cd "${PAYLOAD_ROOT}"
  /usr/bin/zip -qry "${IPA_PATH}" Payload
)

shasum -a 256 "${IPA_PATH}" | tee "${IPA_PATH}.sha256"

if unzip -l "${IPA_PATH}" | grep -q '_CodeSignature'; then
  echo "error: IPA contains _CodeSignature" >&2
  exit 1
fi

if unzip -l "${IPA_PATH}" | grep -q 'embedded.mobileprovision'; then
  echo "error: IPA contains embedded.mobileprovision" >&2
  exit 1
fi

cat > "${BUILD_DIR}/build-manifest.txt" <<MANIFEST
Artifact: $(basename "${IPA_PATH}")
Runner OS: ${RUNNER_OS:-local}
Runner architecture: ${RUNNER_ARCH:-$(uname -m)}
macOS: $(sw_vers -productVersion)
Xcode: $(xcodebuild -version | tr '\n' ' ')
SDK: $(xcrun --sdk iphoneos --show-sdk-version)
Binary: ${ARCH_INFO}
Signing: unsigned; no embedded provisioning profile
Bundle ID: com.nightvibes.androidiosemulator
Deployment target: iOS 16.0
MANIFEST

cat "${BUILD_DIR}/build-manifest.txt"
echo "Unsigned IPA created: ${IPA_PATH}"
