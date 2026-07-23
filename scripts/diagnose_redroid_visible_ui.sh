#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <utm-vm-directory>" >&2
  exit 64
fi

VM="$(cd "$1" && pwd)"
ADB_PORT="${ADB_PORT:-5557}"
PYTHON="${DIAGNOSTIC_PYTHON:-.diagnostic-venv/bin/python}"
MONITOR_SOCKET="${MONITOR_SOCKET:-/tmp/redroid-visible-monitor.sock}"
SERIAL_LOG="${SERIAL_LOG:-redroid-visible-serial.log}"
QEMU_LOG="${QEMU_LOG:-redroid-visible-qemu.log}"
DISPLAY_DUMP="${DISPLAY_DUMP:-virtio-gpu.ppm}"

for required in Images/kernel Images/initrd.img Images/redroid-arm64-rootfs.qcow2; do
  test -f "$VM/$required"
done
command -v qemu-system-aarch64 >/dev/null
command -v adb >/dev/null
test -x "$PYTHON"

rm -f "$MONITOR_SOCKET" "$SERIAL_LOG" "$QEMU_LOG" \
  android-screencap.png "$DISPLAY_DUMP" qemu-monitor-output.txt \
  android-visible-diagnostic.txt visible-ui-analysis.json

adb kill-server >/dev/null 2>&1 || true
adb start-server

qemu-system-aarch64 \
  -machine virt,highmem=off \
  -accel tcg,thread=multi \
  -cpu max \
  -smp 2 \
  -m 2048 \
  -kernel "$VM/Images/kernel" \
  -initrd "$VM/Images/initrd.img" \
  -append 'root=/dev/vda rw rootwait rootfstype=ext4 console=tty0 console=ttyAMA0 earlycon=pl011,0x09000000 systemd.show_status=yes systemd.log_target=console loglevel=6 consoleblank=0 vt.global_cursor_default=1' \
  -drive "if=none,file=$VM/Images/redroid-arm64-rootfs.qcow2,format=qcow2,id=rootfs,cache=unsafe" \
  -device virtio-blk-pci,drive=rootfs \
  -device virtio-gpu-pci \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$ADB_PORT-:5555" \
  -device virtio-net-pci,netdev=net0,romfile= \
  -device virtio-rng-pci \
  -display vnc=127.0.0.1:1 \
  -monitor "unix:$MONITOR_SOCKET,server=on,wait=off" \
  -serial "file:$SERIAL_LOG" \
  -snapshot \
  -no-reboot >"$QEMU_LOG" 2>&1 &
QEMU_PID=$!

cleanup() {
  kill "$QEMU_PID" >/dev/null 2>&1 || true
  wait "$QEMU_PID" >/dev/null 2>&1 || true
  adb disconnect "127.0.0.1:$ADB_PORT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

BOOTED=0
for _ in $(seq 1 2700); do
  adb connect "127.0.0.1:$ADB_PORT" >/dev/null 2>&1 || true
  if [[ "$(adb -s "127.0.0.1:$ADB_PORT" get-state 2>/dev/null || true)" == device ]]; then
    VALUE="$(adb -s "127.0.0.1:$ADB_PORT" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [[ "$VALUE" == 1 ]]; then
      BOOTED=1
      break
    fi
  fi
  kill -0 "$QEMU_PID" 2>/dev/null || break
  sleep 1
done

if [[ "$BOOTED" -ne 1 ]]; then
  tail -n 500 "$SERIAL_LOG" || true
  tail -n 200 "$QEMU_LOG" || true
  exit 1
fi

DEVICE="127.0.0.1:$ADB_PORT"
{
  echo '=== properties ==='
  adb -s "$DEVICE" shell getprop ro.build.version.release
  adb -s "$DEVICE" shell getprop ro.product.cpu.abi
  echo '=== display ==='
  adb -s "$DEVICE" shell wm size || true
  adb -s "$DEVICE" shell wm density || true
  echo '=== home resolution ==='
  adb -s "$DEVICE" shell cmd package resolve-activity --brief \
    -a android.intent.action.MAIN -c android.intent.category.HOME || true
  echo '=== relevant packages ==='
  adb -s "$DEVICE" shell pm list packages | grep -Ei 'launcher|systemui|settings' || true
  echo '=== current focus before start ==='
  adb -s "$DEVICE" shell dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' || true
  echo '=== start home ==='
  adb -s "$DEVICE" shell am start -W \
    -a android.intent.action.MAIN -c android.intent.category.HOME || true
  echo '=== current focus after start ==='
  adb -s "$DEVICE" shell dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' || true
} | tee android-visible-diagnostic.txt

sleep 45
adb -s "$DEVICE" exec-out screencap -p > android-screencap.png
test -s android-screencap.png

python3 - "$MONITOR_SOCKET" "$DISPLAY_DUMP" <<'PY'
import os
import socket
import sys
import time

socket_path, output_path = sys.argv[1:]
deadline = time.time() + 20
while not os.path.exists(socket_path):
    if time.time() > deadline:
        raise SystemExit('monitor socket did not appear')
    time.sleep(0.2)
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.connect(socket_path)
    sock.settimeout(2)
    try:
        sock.recv(65536)
    except Exception:
        pass
    sock.sendall(f'screendump {output_path}\n'.encode())
    time.sleep(3)
    sock.sendall(b'info display\n')
    time.sleep(1)
    chunks = []
    while True:
        try:
            data = sock.recv(65536)
        except Exception:
            break
        if not data:
            break
        chunks.append(data)
open('qemu-monitor-output.txt', 'wb').write(b''.join(chunks))
PY

test -s "$DISPLAY_DUMP"

"$PYTHON" - "$DISPLAY_DUMP" <<'PY'
from pathlib import Path
from PIL import Image
import json
import sys


def stats(path):
    image = Image.open(path).convert('RGB')
    pixels = list(image.getdata())
    count = len(pixels)
    nonblack = sum(1 for r, g, b in pixels if max(r, g, b) > 12)
    bright = sum(1 for r, g, b in pixels if max(r, g, b) > 48)
    sampled = pixels[::max(1, count // 50000)]
    return {
        'width': image.width,
        'height': image.height,
        'nonblack_pixels': nonblack,
        'nonblack_ratio': nonblack / count,
        'bright_pixels': bright,
        'bright_ratio': bright / count,
        'sampled_unique_colors': len(set(sampled)),
    }

result = {
    'android_framebuffer': stats('android-screencap.png'),
    'virtio_gpu_output': stats(sys.argv[1]),
}
Path('visible-ui-analysis.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
PY

cleanup
trap - EXIT
