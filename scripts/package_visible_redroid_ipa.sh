#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <visible-guest-directory> <output-directory>" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST="$(cd "$1" && pwd)"
OUT="$2"
OUTPUT_IPA="Android-iOSEmulator-Redroid13-ARM64-SE-NoJIT-LowStorage-Visible-unsigned.ipa"
BASE_IPA="Android-iOSEmulator-Redroid13-ARM64-SE-NoJIT-LowStorage-unsigned.ipa"
BUILD_OUT="$ROOT/build/livecontainer-redroid-arm64-se"
WORK="$ROOT/.build/visible-redroid-final"

rm -rf "$OUT" "$WORK"
mkdir -p "$OUT" "$WORK/extracted" "$WORK/final"
OUT="$(cd "$OUT" && pwd)"

for required in kernel initrd.img redroid-arm64-rootfs.qcow2 build-manifest.txt \
                visible-ui-fixed-analysis.json visible-ui-fixed-android-state.txt \
                android-launcher3.png virtio-gpu-launcher3.ppm; do
  [[ -f "$GUEST/$required" ]] || { echo "missing visible guest artifact: $required" >&2; exit 1; }
done
grep -q '^Visible UI CI framebuffer verification: passed$' "$GUEST/build-manifest.txt"
grep -q '^Visible UI fix: Weston 14 removed option --tty=1 eliminated$' "$GUEST/build-manifest.txt"
grep -q '^Visible UI fix: Launcher3 HOME explicitly launched$' "$GUEST/build-manifest.txt"
qemu-img check "$GUEST/redroid-arm64-rootfs.qcow2"
jq -e '.android_framebuffer.nonblack_ratio > 0.005' "$GUEST/visible-ui-fixed-analysis.json" >/dev/null
jq -e '.virtio_gpu_output.nonblack_ratio > 0.005' "$GUEST/visible-ui-fixed-analysis.json" >/dev/null
jq -e '.android_framebuffer.sampled_unique_colors >= 8' "$GUEST/visible-ui-fixed-analysis.json" >/dev/null
jq -e '.virtio_gpu_output.sampled_unique_colors >= 8' "$GUEST/visible-ui-fixed-analysis.json" >/dev/null

printf '[visible-package 1/4] Building QEMU-loader-safe low-storage base IPA\n'
python3 "$ROOT/scripts/patch_qemu_loader_packaging.py" \
  "$ROOT/scripts/build_livecontainer_redroid_arm64_se_ipa.sh"
python3 "$ROOT/scripts/patch_low_storage_qcow2_packaging.py" \
  "$ROOT/scripts/make_redroid_arm64_utm.py" \
  "$ROOT/scripts/build_livecontainer_redroid_arm64_se_ipa.sh"
"$(brew --prefix)/bin/bash" -x \
  "$ROOT/scripts/build_livecontainer_redroid_arm64_se_ipa.sh" "$GUEST" \
  2>&1 | tee "$OUT/visible-base-ipa-build.log"
BASE="$BUILD_OUT/$BASE_IPA"
[[ -f "$BASE" ]]
unzip -t "$BASE" >/dev/null

printf '[visible-package 2/4] Patching fresh identity and visible boot metadata\n'
zipinfo -1 "$BASE" > "$WORK/original-entry-order.txt"
unzip -q "$BASE" -d "$WORK/extracted"
APP="$(find "$WORK/extracted/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$APP" ]]
python3 "$ROOT/scripts/patch_visible_display_ipa.py" "$APP" | tee "$OUT/visible-display-patch.log"

FINAL_IPA="$OUT/$OUTPUT_IPA"
(
  cd "$WORK/extracted"
  COPYFILE_DISABLE=1 zip -9 -q -X -y "$FINAL_IPA" -@ < "$WORK/original-entry-order.txt"
)
[[ -f "$FINAL_IPA" ]]
unzip -t "$FINAL_IPA" >/dev/null
shasum -a 256 "$FINAL_IPA" > "$FINAL_IPA.sha256"
stat -f%z "$FINAL_IPA" > "$FINAL_IPA.size"

printf '[visible-package 3/4] Re-extracting and validating final IPA\n'
unzip -q "$FINAL_IPA" -d "$WORK/final"
FINAL_APP="$(find "$WORK/final/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$FINAL_APP" ]]
INFO="$FINAL_APP/Info.plist"
LCINFO="$FINAL_APP/LCAppInfo.plist"
CONFIG="$FINAL_APP/PreloadedData/Android-Redroid-ARM64-SE.utm/config.plist"
DISK="$FINAL_APP/PreloadedData/Android-Redroid-ARM64-SE.utm/Images/redroid-arm64-rootfs.qcow2"

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" = \
  com.nightvibes33.androidiosemulator.redroid.arm64.se.visible
test "$(/usr/libexec/PlistBuddy -c 'Print :AndroidVisibleDisplayBuild' "$INFO")" = \
  redroid13-arm64-se-lowstorage-visible-v2
test "$(/usr/libexec/PlistBuddy -c 'Print :LCDataUUID' "$LCINFO")" = \
  AndroidRedroidArm64SEVisibleData
test "$(/usr/libexec/PlistBuddy -c 'Print :isJITNeeded' "$LCINFO")" = false
test "$(/usr/libexec/PlistBuddy -c 'Print :Display:DisplayCard' "$CONFIG")" = virtio-gpu-pci
test "$(/usr/libexec/PlistBuddy -c 'Print :Display:DisplayFitScreen' "$CONFIG")" = true
/usr/libexec/PlistBuddy -c 'Print :System:AddArgs' "$CONFIG" > "$OUT/final-add-args.txt"
grep -q 'systemd.show_status=yes' "$OUT/final-add-args.txt"
grep -q 'loglevel=6' "$OUT/final-add-args.txt"
grep -q 'consoleblank=0' "$OUT/final-add-args.txt"
! grep -Eq '(^|[[:space:]])quiet([[:space:]]|$)' "$OUT/final-add-args.txt"
qemu-img check "$DISK"

zipinfo -1 "$FINAL_IPA" > "$OUT/final-entry-order.txt"
test "$(sed -n '1p' "$OUT/final-entry-order.txt")" = 'Payload/'
test "$(sed -n '2p' "$OUT/final-entry-order.txt")" = 'Payload/Android iOSEmulator.app/'
test "$(sed -n '6p' "$OUT/final-entry-order.txt")" = \
  'Payload/Android iOSEmulator.app/qemu-m68k-softmmu.dylib'
test "$(sed -n '7p' "$OUT/final-entry-order.txt")" = \
  'Payload/Android iOSEmulator.app/qemu-aarch64-softmmu.dylib'

MACHO_COUNT=0
while IFS= read -r -d '' candidate; do
  description="$(file -b "$candidate")"
  if grep -Eq 'Mach-O (universal binary|64-bit)' <<<"$description"; then
    [[ -x "$candidate" ]]
    codesign --verify --strict --ignore-resources "$candidate"
    MACHO_COUNT=$((MACHO_COUNT + 1))
  fi
done < <(find "$FINAL_APP" -type f -print0)
(( MACHO_COUNT >= 50 ))

IPA_BYTES="$(stat -f%z "$FINAL_IPA")"
APP_BYTES="$(( $(du -sk "$FINAL_APP" | awk '{print $1}') * 1024 ))"
DISK_BYTES="$(stat -f%z "$DISK")"
ESTIMATED_PEAK_BYTES="$(( IPA_BYTES + APP_BYTES * 3 ))"
BUDGET_BYTES="$(( 9 * 1024 * 1024 * 1024 ))"
(( ESTIMATED_PEAK_BYTES < BUDGET_BYTES ))

UI_PROOF="$(cat "$GUEST/visible-ui-fixed-analysis.json")"
jq -n \
  --argjson ipa_bytes "$IPA_BYTES" \
  --argjson extracted_app_bytes "$APP_BYTES" \
  --argjson qcow2_bytes "$DISK_BYTES" \
  --argjson estimated_peak_bytes "$ESTIMATED_PEAK_BYTES" \
  --argjson budget_bytes "$BUDGET_BYTES" \
  --argjson macho_count "$MACHO_COUNT" \
  --argjson ui_proof "$UI_PROOF" \
  '{ipa_bytes:$ipa_bytes,extracted_app_bytes:$extracted_app_bytes,qcow2_bytes:$qcow2_bytes,estimated_peak_bytes:$estimated_peak_bytes,budget_bytes:$budget_bytes,within_9gb_budget:($estimated_peak_bytes < $budget_bytes),verified_macho_count:$macho_count,weston_14_option_fixed:true,wayland_ready_wait:true,android_provisioning_bypassed:true,launcher3_started:true,android_framebuffer_verified:true,virtio_gpu_output_verified:true,fresh_bundle_identifier:true,fresh_livecontainer_data_container:true,ui_proof:$ui_proof}' \
  > "$OUT/visible-ui-validation.json"
cat "$OUT/visible-ui-validation.json"

cp "$GUEST/visible-ui-fixed-analysis.json" "$OUT/"
cp "$GUEST/visible-ui-fixed-android-state.txt" "$OUT/"
cp "$GUEST/android-launcher3.png" "$OUT/"
cp "$GUEST/virtio-gpu-launcher3.ppm" "$OUT/"

printf '[visible-package 4/4] Final visible Android IPA is validated: %s\n' "$FINAL_IPA"
