#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <work-directory> <output-qcow2>" >&2
  exit 64
fi

WORK="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUTPUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
BLISS_VERSION="${BLISS_VERSION:-16.9.7}"
BLISS_BUILD_DATE="${BLISS_BUILD_DATE:-20241011}"
BLISS_ISO_NAME="${BLISS_ISO_NAME:-Bliss-Go-v${BLISS_VERSION}-x86_64-OFFICIAL-foss-${BLISS_BUILD_DATE}.iso}"
BLISS_BASE_URL="${BLISS_BASE_URL:-https://downloads.sourceforge.net/project/blissos-x86/Official/BlissOS16/FOSS/Go}"
BLISS_ISO_URL="${BLISS_ISO_URL:-${BLISS_BASE_URL}/${BLISS_ISO_NAME}}"
BLISS_SHA256_URL="${BLISS_SHA256_URL:-${BLISS_ISO_URL}.sha256}"
DISK_SIZE_GIB="${DISK_SIZE_GIB:-8}"
DATA_SIZE_GIB="${DATA_SIZE_GIB:-3}"

for command in curl 7zz mformat mmd mcopy mdir qemu-img truncate; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required" >&2
    exit 1
  fi
done

MKFS_EXT4="$(command -v mkfs.ext4 || true)"
if [[ -z "$MKFS_EXT4" ]] && command -v brew >/dev/null 2>&1; then
  MKFS_EXT4="$(brew --prefix e2fsprogs)/sbin/mkfs.ext4"
fi
if [[ ! -x "$MKFS_EXT4" ]]; then
  echo "mkfs.ext4 from e2fsprogs is required" >&2
  exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK/download" "$WORK/extracted" "$(dirname "$OUTPUT")"
ISO="$WORK/download/$BLISS_ISO_NAME"
CHECKSUM_FILE="$ISO.sha256"

printf '[android13 1/7] Downloading BlissOS %s (Android 13)\n' "$BLISS_VERSION"
curl --fail --location --retry 5 --retry-delay 5 "$BLISS_ISO_URL" -o "$ISO"
curl --fail --location --retry 5 --retry-delay 5 "$BLISS_SHA256_URL" -o "$CHECKSUM_FILE"
EXPECTED_SHA256="$(tr -d '\r' < "$CHECKSUM_FILE" | awk 'NF {print $1; exit}')"
if [[ ! "$EXPECTED_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "The downloaded BlissOS checksum file is invalid." >&2
  cat "$CHECKSUM_FILE" >&2
  exit 1
fi
printf '%s  %s\n' "$EXPECTED_SHA256" "$ISO" | shasum -a 256 -c -

printf '[android13 2/7] Extracting the Android 13 runtime files\n'
7zz x -y "$ISO" "-o$WORK/extracted" >/dev/null
KERNEL="$(find "$WORK/extracted" -type f -name kernel -print -quit)"
INITRD="$(find "$WORK/extracted" -type f -name initrd.img -print -quit)"
SYSTEM_IMAGE="$(find "$WORK/extracted" -type f \( -name system.sfs -o -name system.efs -o -name system.img \) -print -quit)"
EFI_BOOT="$(find "$WORK/extracted" -type d -path '*/EFI/BOOT' -print -quit)"
for required in "$KERNEL" "$INITRD" "$SYSTEM_IMAGE" "$EFI_BOOT"; do
  if [[ -z "$required" || ! -e "$required" ]]; then
    echo "The BlissOS ISO is missing a required boot component." >&2
    find "$WORK/extracted" -maxdepth 4 -type f -print >&2
    exit 1
  fi
done
SYSTEM_BASENAME="$(basename "$SYSTEM_IMAGE")"

printf '[android13 3/7] Creating persistent Android data storage\n'
DATA_IMAGE="$WORK/data.img"
truncate -s "${DATA_SIZE_GIB}G" "$DATA_IMAGE"
"$MKFS_EXT4" -F -b 4096 -L data "$DATA_IMAGE" >/dev/null

printf '[android13 4/7] Building a bootable preinstalled Android disk\n'
RAW_DISK="$WORK/bliss-android13-preinstalled.raw"
truncate -s "${DISK_SIZE_GIB}G" "$RAW_DISK"
mformat -i "$RAW_DISK" -F -v ANDROID13 ::
mmd -i "$RAW_DISK" ::/EFI ::/EFI/BOOT ::/boot ::/boot/grub ::/blissos
mcopy -s -o -i "$RAW_DISK" "$EFI_BOOT"/* ::/EFI/BOOT/
mcopy -o -i "$RAW_DISK" "$KERNEL" ::/blissos/kernel
mcopy -o -i "$RAW_DISK" "$INITRD" ::/blissos/initrd.img
mcopy -o -i "$RAW_DISK" "$SYSTEM_IMAGE" "::/blissos/$SYSTEM_BASENAME"
mcopy -o -i "$RAW_DISK" "$DATA_IMAGE" ::/blissos/data.img
printf 'Android 13 preinstalled runtime\n' > "$WORK/android.boot"
mcopy -o -i "$RAW_DISK" "$WORK/android.boot" ::/blissos/android.boot

cat > "$WORK/grub.cfg" <<'EOF'
set timeout=0
set default=0

menuentry "Android iOSEmulator — Android 13" {
    search --file --no-floppy --set=root /blissos/android.boot
    linux /blissos/kernel root=/dev/ram0 SRC=/blissos DATA= androidboot.hardware=android_x86_64 androidboot.selinux=permissive quiet nomodeset VULKAN=0
    initrd /blissos/initrd.img
}
EOF
for target in ::/EFI/BOOT/grub.cfg ::/EFI/BOOT/android.cfg ::/boot/grub/grub.cfg ::/grub.cfg; do
  mcopy -o -i "$RAW_DISK" "$WORK/grub.cfg" "$target"
done

printf '[android13 5/7] Verifying the preinstalled filesystem\n'
mdir -i "$RAW_DISK" ::/EFI/BOOT/BOOTX64.EFI >/dev/null
mdir -i "$RAW_DISK" ::/EFI/BOOT/grub.cfg >/dev/null
mdir -i "$RAW_DISK" ::/blissos/kernel >/dev/null
mdir -i "$RAW_DISK" ::/blissos/initrd.img >/dev/null
mdir -i "$RAW_DISK" "::/blissos/$SYSTEM_BASENAME" >/dev/null
mdir -i "$RAW_DISK" ::/blissos/data.img >/dev/null

printf '[android13 6/7] Compressing the installed disk as qcow2\n'
rm -f "$OUTPUT"
qemu-img convert -p -f raw -O qcow2 -c "$RAW_DISK" "$OUTPUT"
qemu-img check "$OUTPUT"

printf '[android13 7/7] Recording disk metadata\n'
qemu-img info --output=json "$OUTPUT" > "$OUTPUT.info.json"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
cat > "$OUTPUT.manifest.txt" <<EOF
Android version: 13
Distribution: BlissOS ${BLISS_VERSION} x86_64 FOSS Go
Source image: ${BLISS_ISO_NAME}
Source SHA-256: ${EXPECTED_SHA256}
Install mode: preinstalled manual disk
Boot mode: UEFI, zero-second GRUB menu
Installer ISO bundled: no
Debug console enabled: no
Persistent data image: ${DATA_SIZE_GIB} GiB ext4
Virtual disk capacity: ${DISK_SIZE_GIB} GiB
System image: ${SYSTEM_BASENAME}
EOF
printf 'Created preinstalled Android 13 disk: %s\n' "$OUTPUT"
