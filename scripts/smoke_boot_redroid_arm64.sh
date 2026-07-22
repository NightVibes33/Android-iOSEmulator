#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <redroid-arm64-guest-directory>" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST_DIR="$(cd "$1" && pwd)"
KERNEL="$GUEST_DIR/kernel"
INITRD="$GUEST_DIR/initrd.img"
BASE_DISK="$GUEST_DIR/redroid-arm64-rootfs.raw"
MANIFEST="$GUEST_DIR/build-manifest.txt"
LOG="$GUEST_DIR/ci-smoke-boot.log"
RESULT="$GUEST_DIR/ci-smoke-result.json"
WORK="${SMOKE_WORK_DIR:-$ROOT/.build/redroid-arm64-smoke}"
SMOKE_DISK="$WORK/redroid-arm64-smoke.raw"
MOUNT_DIR="$WORK/mnt"
TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-900}"
MARKER='ANDROID_IOSEMULATOR_CI_SMOKE_OK root=/dev/vda systemd=1 binder=1 hwbinder=1 vndbinder=1 dma_heap=1'

for command in qemu-system-aarch64 losetup mount umount findmnt grep jq cp; do
  command -v "$command" >/dev/null || { echo "missing smoke-test dependency: $command" >&2; exit 1; }
done
for required in "$KERNEL" "$INITRD" "$BASE_DISK" "$MANIFEST"; do
  [[ -f "$required" ]] || { echo "missing guest artifact: $required" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$MOUNT_DIR"
cp --sparse=always "$BASE_DISK" "$SMOKE_DISK"
: > "$LOG"
rm -f "$RESULT"

LOOP_DEVICE=""
QEMU_PID=""
cleanup() {
  set +e
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill -TERM "$QEMU_PID" 2>/dev/null || true
    sleep 2
    kill -KILL "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    sudo umount "$MOUNT_DIR" || true
  fi
  if [[ -n "$LOOP_DEVICE" ]]; then
    sudo losetup -d "$LOOP_DEVICE" 2>/dev/null || true
  fi
}
trap cleanup EXIT

printf '[1/4] Injecting an isolated systemd smoke target into a sparse disk copy\n'
LOOP_DEVICE="$(sudo losetup --find --show "$SMOKE_DISK")"
sudo mount "$LOOP_DEVICE" "$MOUNT_DIR"

sudo tee "$MOUNT_DIR/usr/local/sbin/android-ci-smoke" >/dev/null <<'SMOKE'
#!/bin/sh
set -eu

ROOT_SOURCE="$(findmnt -n -o SOURCE /)"
[ "$ROOT_SOURCE" = /dev/vda ] || {
  echo "CI smoke failure: root is $ROOT_SOURCE instead of /dev/vda" >&2
  exit 1
}
[ -d /run/systemd/system ] || {
  echo "CI smoke failure: systemd is not PID 1" >&2
  exit 1
}
grep -qw binder /proc/filesystems || {
  echo "CI smoke failure: BinderFS is unavailable" >&2
  exit 1
}
mkdir -p /dev/binderfs
if ! mountpoint -q /dev/binderfs; then
  mount -t binder binder /dev/binderfs
fi
for node in binder hwbinder vndbinder; do
  if [ ! -e "/dev/$node" ] && [ -e "/dev/binderfs/$node" ]; then
    ln -s "/dev/binderfs/$node" "/dev/$node"
  fi
  [ -e "/dev/$node" ] || {
    echo "CI smoke failure: missing /dev/$node" >&2
    exit 1
  }
done
[ -e /dev/dma_heap/system ] || {
  echo "CI smoke failure: missing /dev/dma_heap/system" >&2
  exit 1
}

MARKER='ANDROID_IOSEMULATOR_CI_SMOKE_OK root=/dev/vda systemd=1 binder=1 hwbinder=1 vndbinder=1 dma_heap=1'
printf '%s\n' "$MARKER" | tee /dev/ttyAMA0
SMOKE
sudo chmod 0755 "$MOUNT_DIR/usr/local/sbin/android-ci-smoke"

sudo tee "$MOUNT_DIR/etc/systemd/system/android-ci-smoke.service" >/dev/null <<'SERVICE'
[Unit]
Description=Android iOSEmulator ARM64 boot contract smoke test
After=local-fs.target systemd-udev-settle.service
Wants=systemd-udev-settle.service
Before=android-ci-smoke.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/android-ci-smoke
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
SERVICE

sudo tee "$MOUNT_DIR/etc/systemd/system/android-ci-smoke.target" >/dev/null <<'TARGET'
[Unit]
Description=Android iOSEmulator ARM64 CI smoke target
Requires=android-ci-smoke.service
After=android-ci-smoke.service
AllowIsolate=yes
TARGET

sudo sync
sudo umount "$MOUNT_DIR"
sudo losetup -d "$LOOP_DEVICE"
LOOP_DEVICE=""

printf '[2/4] Booting the generated ARM64 kernel, initramfs and root disk in QEMU\n'
START_SECONDS="$(date +%s)"
qemu-system-aarch64 \
  -machine virt,highmem=off \
  -cpu max \
  -smp 2 \
  -m 2048 \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -append 'root=/dev/vda rw rootwait rootfstype=ext4 console=ttyAMA0 earlycon=pl011,0x09000000 systemd.unit=android-ci-smoke.target systemd.show_status=yes loglevel=4' \
  -drive if=none,file="$SMOKE_DISK",format=raw,id=rootfs,cache=unsafe \
  -device virtio-blk-device,drive=rootfs \
  -device virtio-rng-device \
  -netdev user,id=net0 \
  -device virtio-net-device,netdev=net0 \
  -nographic \
  -no-reboot \
  >"$LOG" 2>&1 &
QEMU_PID=$!

PASSED=false
for ((elapsed = 0; elapsed < TIMEOUT_SECONDS; elapsed += 2)); do
  if grep -Fqx "$MARKER" "$LOG"; then
    PASSED=true
    break
  fi
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    break
  fi
  sleep 2
done
END_SECONDS="$(date +%s)"
ELAPSED_SECONDS="$((END_SECONDS - START_SECONDS))"

printf '[3/4] Validating the serial boot contract\n'
if [[ "$PASSED" != true ]]; then
  echo "ARM64 smoke boot did not produce the required marker within ${TIMEOUT_SECONDS}s." >&2
  tail -n 300 "$LOG" >&2 || true
  exit 1
fi

grep -Fqx "$MARKER" "$LOG"
grep -Eq 'systemd\[[0-9]+\]|systemd [0-9]+' "$LOG"
grep -Eq 'VFS: Mounted root|Mounted root|EXT4-fs \(vda\)' "$LOG"

jq -n \
  --arg marker "$MARKER" \
  --argjson elapsed_seconds "$ELAPSED_SECONDS" \
  '{
    verified: true,
    architecture: "aarch64",
    qemu_machine: "virt,highmem=off",
    storage_transport: "virtio-mmio",
    root_device: "/dev/vda",
    systemd_reached: true,
    binder_devices: ["binder", "hwbinder", "vndbinder"],
    dma_heap_system_present: true,
    android_container_boot_completed: false,
    elapsed_seconds: $elapsed_seconds,
    marker: $marker
  }' > "$RESULT"

python3 - "$MANIFEST" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
prefixes = (
    "CI ARM64 Linux smoke boot:",
    "CI root disk mount:",
    "CI systemd reached:",
    "CI Binder devices:",
    "CI DMA-BUF system heap:",
)
lines = [line for line in lines if not line.startswith(prefixes)]
lines.extend(
    [
        "CI ARM64 Linux smoke boot: passed",
        "CI root disk mount: /dev/vda via VirtIO-MMIO",
        "CI systemd reached: yes",
        "CI Binder devices: binder,hwbinder,vndbinder",
        "CI DMA-BUF system heap: present",
    ]
)
path.write_text("\n".join(lines) + "\n")
PY

printf '[4/4] ARM64 smoke boot passed in %ss\n' "$ELAPSED_SECONDS"
