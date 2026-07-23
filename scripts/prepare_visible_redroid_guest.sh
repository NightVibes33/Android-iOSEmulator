#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <source-guest-directory> <output-directory>" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$(cd "$1" && pwd)"
OUT="$2"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "$SOURCE/." "$OUT/"
OUT="$(cd "$OUT" && pwd)"

RAW="$OUT/redroid-arm64-rootfs.raw"
QCOW="$OUT/redroid-arm64-rootfs.qcow2"
WESTON_PATH=/etc/systemd/system/weston-redroid.service
UI_PATH=/usr/local/sbin/start-redroid-ui
WESTON_SOURCE="$ROOT/runtime/guest-fixes/weston-redroid.service"
UI_SOURCE="$ROOT/runtime/guest-fixes/start-redroid-ui"

for required in "$RAW" "$OUT/kernel" "$OUT/initrd.img" "$OUT/build-manifest.txt" \
                "$WESTON_SOURCE" "$UI_SOURCE"; do
  [[ -f "$required" ]] || { echo "missing required file: $required" >&2; exit 1; }
done
grep -q '^CI Android boot verification: passed$' "$OUT/build-manifest.txt"
grep -q '^CI Android sys.boot_completed: 1$' "$OUT/build-manifest.txt"

printf '[visible-ui 1/5] Injecting Weston and Launcher3 startup fixes\n'
debugfs -w -R "rm $WESTON_PATH" "$RAW" >/dev/null 2>&1 || true
debugfs -w -R "write $WESTON_SOURCE $WESTON_PATH" "$RAW"
debugfs -w -R "set_inode_field $WESTON_PATH mode 0100644" "$RAW"

debugfs -w -R "rm $UI_PATH" "$RAW" >/dev/null 2>&1 || true
debugfs -w -R "write $UI_SOURCE $UI_PATH" "$RAW"
debugfs -w -R "set_inode_field $UI_PATH mode 0100755" "$RAW"

debugfs -R "cat $WESTON_PATH" "$RAW" > "$OUT/weston-redroid.service.installed"
debugfs -R "cat $UI_PATH" "$RAW" > "$OUT/start-redroid-ui.installed"
debugfs -R "stat $WESTON_PATH" "$RAW" > "$OUT/weston-redroid.service.stat"
debugfs -R "stat $UI_PATH" "$RAW" > "$OUT/start-redroid-ui.stat"

grep -Fq 'ExecStart=/usr/bin/weston --backend=drm-backend.so --idle-time=0' \
  "$OUT/weston-redroid.service.installed"
! grep -Fq -- '--tty=1' "$OUT/weston-redroid.service.installed"
grep -Fq 'Wayland display is ready' "$OUT/start-redroid-ui.installed"
grep -Fq 'pm disable-user --user 0 com.android.provision' "$OUT/start-redroid-ui.installed"
grep -Fq 'android.intent.category.HOME' "$OUT/start-redroid-ui.installed"
grep -Eq 'Mode:[[:space:]]+0644' "$OUT/weston-redroid.service.stat"
grep -Eq 'Mode:[[:space:]]+0755' "$OUT/start-redroid-ui.stat"
e2fsck -fn "$RAW"

cat >> "$OUT/build-manifest.txt" <<'EOF'
Visible UI fix: Weston 14 removed option --tty=1 eliminated
Visible UI fix: waits for /run/weston/wayland-0
Visible UI fix: Android provisioning marked complete
Visible UI fix: com.android.provision disabled for user 0
Visible UI fix: Launcher3 HOME explicitly launched
Visible UI display device: virtio-gpu-pci
Visible UI CI framebuffer verification: pending
EOF

printf '[visible-ui 2/5] Booting patched guest with graphical output\n'
MONITOR_SOCKET=/tmp/redroid-visible-fixed-monitor.sock
SERIAL_LOG="$OUT/visible-ui-fixed-serial.log"
QEMU_LOG="$OUT/visible-ui-fixed-qemu.log"
ANDROID_SCREEN="$OUT/android-launcher3.png"
DISPLAY_SCREEN="$OUT/virtio-gpu-launcher3.ppm"
ANDROID_STATE="$OUT/visible-ui-fixed-android-state.txt"
ANALYSIS="$OUT/visible-ui-fixed-analysis.json"
MONITOR_OUTPUT="$OUT/visible-ui-fixed-monitor.txt"
ADB_PORT=5557
rm -f "$MONITOR_SOCKET" "$SERIAL_LOG" "$QEMU_LOG" "$ANDROID_SCREEN" \
      "$DISPLAY_SCREEN" "$ANDROID_STATE" "$ANALYSIS" "$MONITOR_OUTPUT"

adb kill-server >/dev/null 2>&1 || true
adb start-server

qemu-system-aarch64 \
  -machine virt,highmem=off \
  -accel tcg,thread=multi \
  -cpu max \
  -smp 2 \
  -m 2048 \
  -kernel "$OUT/kernel" \
  -initrd "$OUT/initrd.img" \
  -append 'root=/dev/vda rw rootwait rootfstype=ext4 console=tty0 console=ttyAMA0 earlycon=pl011,0x09000000 systemd.show_status=yes systemd.log_target=console loglevel=6 consoleblank=0 vt.global_cursor_default=1' \
  -drive "if=none,file=$RAW,format=raw,id=rootfs,cache=unsafe" \
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
  echo 'Patched guest did not reach Android sys.boot_completed=1.' >&2
  tail -n 800 "$SERIAL_LOG" || true
  tail -n 300 "$QEMU_LOG" || true
  exit 1
fi

DEVICE="127.0.0.1:$ADB_PORT"
printf '[visible-ui 3/5] Waiting for Weston, Launcher3 and scrcpy\n'
READY=0
for _ in $(seq 1 360); do
  FOCUS="$(adb -s "$DEVICE" shell dumpsys window 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' || true)"
  if grep -qi 'launcher3' <<<"$FOCUS" && \
     grep -Fq 'Wayland display is ready' "$SERIAL_LOG" && \
     grep -Fq 'Resolved Android HOME activity:' "$SERIAL_LOG" && \
     grep -Fq 'scrcpy 3.3.4' "$SERIAL_LOG"; then
    READY=1
    break
  fi
  sleep 1
done
if [[ "$READY" -ne 1 ]]; then
  echo 'Launcher3/scrcpy graphical path did not become ready.' >&2
  adb -s "$DEVICE" shell dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' || true
  tail -n 1200 "$SERIAL_LOG" || true
  exit 1
fi
sleep 30

{
  echo '=== Android version and ABI ==='
  adb -s "$DEVICE" shell getprop ro.build.version.release
  adb -s "$DEVICE" shell getprop ro.product.cpu.abi
  echo '=== HOME activity ==='
  adb -s "$DEVICE" shell cmd package resolve-activity --brief \
    -a android.intent.action.MAIN -c android.intent.category.HOME
  echo '=== focused window ==='
  adb -s "$DEVICE" shell dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'
  echo '=== provisioning ==='
  adb -s "$DEVICE" shell settings get global device_provisioned
  adb -s "$DEVICE" shell settings get secure user_setup_complete
  echo '=== disabled provision package ==='
  adb -s "$DEVICE" shell pm list packages -d | grep com.android.provision || true
} | tee "$ANDROID_STATE"

grep -qi 'launcher3' "$ANDROID_STATE"
test "$(adb -s "$DEVICE" shell settings get global device_provisioned | tr -d '\r')" = 1
test "$(adb -s "$DEVICE" shell settings get secure user_setup_complete | tr -d '\r')" = 1
adb -s "$DEVICE" shell pm list packages -d | tr -d '\r' | grep -Fq 'package:com.android.provision'

adb -s "$DEVICE" exec-out screencap -p > "$ANDROID_SCREEN"
test -s "$ANDROID_SCREEN"

python3 - "$MONITOR_SOCKET" "$DISPLAY_SCREEN" "$MONITOR_OUTPUT" <<'PY'
import os
import socket
import sys
import time

socket_path, output_path, monitor_output = sys.argv[1:]
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
    time.sleep(4)
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
open(monitor_output, 'wb').write(b''.join(chunks))
PY
test -s "$DISPLAY_SCREEN"

python3 - "$ANDROID_SCREEN" "$DISPLAY_SCREEN" "$ANALYSIS" <<'PY'
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
    sampled = pixels[::max(1, count // 100000)]
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
    'android_framebuffer': stats(sys.argv[1]),
    'virtio_gpu_output': stats(sys.argv[2]),
}
Path(sys.argv[3]).write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
if result['android_framebuffer']['nonblack_ratio'] <= 0.005:
    raise SystemExit('Android framebuffer is still effectively black')
if result['android_framebuffer']['sampled_unique_colors'] < 8:
    raise SystemExit('Android framebuffer has too little visual content')
if result['virtio_gpu_output']['nonblack_ratio'] <= 0.005:
    raise SystemExit('QEMU display is still effectively black')
if result['virtio_gpu_output']['sampled_unique_colors'] < 8:
    raise SystemExit('QEMU display has too little visual content')
PY

! grep -Fq 'fatal: unhandled option: --tty=1' "$SERIAL_LOG"
! grep -Fq 'wayland not available' "$SERIAL_LOG"
grep -Fq "Output 'Virtual-1' enabled" "$SERIAL_LOG"
grep -Fq 'Wayland display is ready' "$SERIAL_LOG"
grep -Fq 'Resolved Android HOME activity:' "$SERIAL_LOG"
grep -Fq 'scrcpy 3.3.4' "$SERIAL_LOG"

cleanup
trap - EXIT
sed -i 's/^Visible UI CI framebuffer verification: pending$/Visible UI CI framebuffer verification: passed/' \
  "$OUT/build-manifest.txt"
grep -q '^Visible UI CI framebuffer verification: passed$' "$OUT/build-manifest.txt"

printf '[visible-ui 4/5] Converting patched raw disk to compressed QCOW2\n'
RAW_SIZE="$(stat -c%s "$RAW")"
rm -f "$QCOW"
qemu-img convert -p -f raw -O qcow2 -c \
  -o cluster_size=65536,lazy_refcounts=on \
  "$RAW" "$QCOW"
qemu-img check "$QCOW"
qemu-img info --output=json "$QCOW" | tee "$OUT/visible-ui-qcow2-info.json"
test "$(jq -r .format "$OUT/visible-ui-qcow2-info.json")" = qcow2
test "$(jq -r '."virtual-size"' "$OUT/visible-ui-qcow2-info.json")" = "$RAW_SIZE"
QCOW_SIZE="$(stat -c%s "$QCOW")"
test "$QCOW_SIZE" -lt 3758096384
cat >> "$OUT/build-manifest.txt" <<EOF
Visible UI QCOW2 size bytes: $QCOW_SIZE
Visible UI virtual capacity preserved: yes
Low-storage conversion: compressed writable QCOW2
Low-storage raw size bytes: $RAW_SIZE
Low-storage QCOW2 size bytes: $QCOW_SIZE
Low-storage virtual capacity preserved: yes
EOF
rm -f "$RAW"
test ! -e "$RAW"

printf '[visible-ui 5/5] Visible guest is prepared and verified\n'
