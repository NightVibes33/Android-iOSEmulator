#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <mini|full> [output-directory]" >&2
  exit 64
fi

VARIANT="$1"
[[ "$VARIANT" == mini || "$VARIANT" == full ]]
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${2:-$ROOT/build/aosp-fvp-product-out-$VARIANT}"
AOSP_ROOT="${AOSP_ROOT:-$ROOT/.build/aosp-android-15-r6}"
AOSP_MANIFEST_TAG="${AOSP_MANIFEST_TAG:-android-15.0.0_r6}"
JOBS="${AOSP_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)}"
MIN_FREE_GIB="${AOSP_MIN_FREE_GIB:-400}"
MIN_RAM_GIB="${AOSP_MIN_RAM_GIB:-64}"

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo "AOSP Android 15 must be built on 64-bit x86 Linux." >&2
  exit 2
fi

FREE_KIB="$(df -Pk "$(dirname "$AOSP_ROOT")" | awk 'NR==2 {print $4}')"
RAM_KIB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
if (( FREE_KIB < MIN_FREE_GIB * 1024 * 1024 )); then
  echo "Need at least ${MIN_FREE_GIB} GiB free for a supported AOSP checkout/build; found $((FREE_KIB / 1024 / 1024)) GiB." >&2
  exit 3
fi
if (( RAM_KIB < MIN_RAM_GIB * 1024 * 1024 )); then
  echo "Need at least ${MIN_RAM_GIB} GiB RAM for the supported source-build fallback; found $((RAM_KIB / 1024 / 1024)) GiB." >&2
  exit 4
fi

for command in git curl python3 zip unzip make sha256sum; do
  command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 5; }
done

if ! command -v repo >/dev/null; then
  mkdir -p "$HOME/bin"
  curl --fail --location --retry 4 \
    https://storage.googleapis.com/git-repo-downloads/repo \
    -o "$HOME/bin/repo"
  chmod 0755 "$HOME/bin/repo"
  export PATH="$HOME/bin:$PATH"
fi
repo version

mkdir -p "$AOSP_ROOT"
cd "$AOSP_ROOT"
if [[ ! -d .repo ]]; then
  repo init \
    --partial-clone \
    --clone-filter=blob:limit=10M \
    --no-clone-bundle \
    -u https://android.googlesource.com/platform/manifest \
    -b "$AOSP_MANIFEST_TAG"
fi
repo sync -c --fail-fast --no-clone-bundle -j"$JOBS"

# shellcheck disable=SC1091
source build/envsetup.sh
if [[ "$VARIANT" == mini ]]; then
  export FVP_MULTILIB_BUILD=false
  TARGET=fvp_mini-userdebug
else
  TARGET=fvp-userdebug
fi
lunch "$TARGET"

if command -v ccache >/dev/null; then
  export USE_CCACHE=1
  export CCACHE_EXEC="$(command -v ccache)"
  ccache -M "${CCACHE_MAXSIZE:-50G}"
fi

m -j"$JOBS"
PRODUCT_OUT="$(get_build_var PRODUCT_OUT)"
for required in kernel combined-ramdisk.img system-qemu.img userdata.img; do
  test -s "$PRODUCT_OUT/$required" || { echo "AOSP did not produce $required" >&2; exit 6; }
done

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
for required in kernel combined-ramdisk.img system-qemu.img userdata.img; do
  cp --sparse=always "$PRODUCT_OUT/$required" "$OUTPUT/$required"
done

(
  cd "$OUTPUT"
  sha256sum kernel combined-ramdisk.img system-qemu.img userdata.img > SHA256SUMS
  cat > BUILD-METADATA.txt <<EOF
AOSP manifest: ${AOSP_MANIFEST_TAG}
Lunch target: ${TARGET}
Variant: ${VARIANT}
FVP multilib: $([[ "$VARIANT" == mini ]] && echo disabled || echo default)
Required output set: verified
EOF
)
printf 'Built verified AOSP FVP product output: %s\n' "$OUTPUT"
