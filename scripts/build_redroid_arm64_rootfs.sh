#!/usr/bin/env bash
set -euo pipefail

# The complete boot-tested implementation is pinned to the commit below. Keep
# this small launcher focused on deterministic dependency corrections so newer
# CI and Android boot-verification work is not accidentally overwritten.
BASE_COMMIT="b7fdee1c1310ac01dea284daf79936d0d0ea9853"
BASE_BLOB="f1238c1e17501e53be3ddf64de5028fcf2d895df"
SCRCPY_VERSION="3.3.4"
SCRCPY_SERVER_SHA256="8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHED_IMPL="$ROOT/scripts/.build_redroid_arm64_rootfs.impl.sh"
BUILD_WORK="$ROOT/.build/redroid-arm64-rootfs"

cleanup() {
  rm -f "$PATCHED_IMPL"
}
trap cleanup EXIT

git -C "$ROOT" fetch --no-tags --depth=1 origin "$BASE_COMMIT"
git -C "$ROOT" show "$BASE_COMMIT:scripts/build_redroid_arm64_rootfs.sh" > "$PATCHED_IMPL"
[[ "$(git hash-object "$PATCHED_IMPL")" == "$BASE_BLOB" ]] || {
  echo "Pinned Redroid builder blob verification failed." >&2
  exit 1
}

python3 - "$PATCHED_IMPL" "$SCRCPY_VERSION" "$SCRCPY_SERVER_SHA256" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
scrcpy_version = sys.argv[2]
scrcpy_server_sha256 = sys.argv[3]
text = path.read_text()

replacements = []

old_sources = """cat > \"$ROOTFS/etc/apt/sources.list\" <<APT
deb $DEBIAN_MIRROR $DEBIAN_SUITE main
deb $DEBIAN_MIRROR $DEBIAN_SUITE-updates main
deb http://security.debian.org/debian-security $DEBIAN_SUITE-security main
APT
"""
new_sources = """cat > \"$ROOTFS/etc/apt/sources.list\" <<APT
deb $DEBIAN_MIRROR $DEBIAN_SUITE main
deb $DEBIAN_MIRROR $DEBIAN_SUITE-updates main
deb http://security.debian.org/debian-security $DEBIAN_SUITE-security main
deb $DEBIAN_MIRROR $DEBIAN_SUITE-backports main contrib
APT
"""
replacements.append((old_sources, new_sources, "Debian sources"))

old_install = """chroot \"$ROOTFS\" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
  systemd-sysv systemd-resolved dbus udev initramfs-tools kmod procps iproute2 iptables nftables \\
  ca-certificates curl runc adb scrcpy weston xwayland seatd libgl1-mesa-dri mesa-vulkan-drivers \\
  e2fsprogs util-linux jq
chroot \"$ROOTFS\" apt-get clean
"""
new_install = f"""chroot \"$ROOTFS\" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
  systemd-sysv systemd-resolved dbus udev initramfs-tools kmod procps iproute2 iptables nftables \\
  ca-certificates curl runc adb weston xwayland seatd libgl1-mesa-dri mesa-vulkan-drivers \\
  e2fsprogs util-linux jq
chroot \"$ROOTFS\" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
  -t \"$DEBIAN_SUITE-backports\" scrcpy
mkdir -p \"$ROOTFS/opt/scrcpy\"
curl --fail --location --retry 4 --retry-delay 2 \\
  \"https://github.com/Genymobile/scrcpy/releases/download/v{scrcpy_version}/scrcpy-server-v{scrcpy_version}\" \\
  -o \"$ROOTFS/opt/scrcpy/scrcpy-server\"
printf '%s  %s\\n' \"{scrcpy_server_sha256}\" \"$ROOTFS/opt/scrcpy/scrcpy-server\" | sha256sum --check
chmod 0644 \"$ROOTFS/opt/scrcpy/scrcpy-server\"
chroot \"$ROOTFS\" apt-get clean
"""
replacements.append((old_install, new_install, "package installation"))

old_unpack = """umoci unpack --image \"$OCI_DIR:latest\" \"$BUNDLE\"
mkdir -p \"$ROOTFS/var/lib/redroid/data\"
"""
new_unpack = """umoci unpack --image \"$OCI_DIR:latest\" \"$BUNDLE\"
rm -rf \"$OCI_DIR\"
mkdir -p \"$ROOTFS/var/lib/redroid/data\"
"""
replacements.append((old_unpack, new_unpack, "OCI cleanup"))

old_ui_env = """export XDG_RUNTIME_DIR=/run/weston
export WAYLAND_DISPLAY=wayland-0
export SDL_VIDEODRIVER=wayland
"""
new_ui_env = """export XDG_RUNTIME_DIR=/run/weston
export WAYLAND_DISPLAY=wayland-0
export SDL_VIDEODRIVER=wayland
export SCRCPY_SERVER_PATH=/opt/scrcpy/scrcpy-server
"""
replacements.append((old_ui_env, new_ui_env, "scrcpy server environment"))

old_ui_service_env = """Environment=XDG_RUNTIME_DIR=/run/weston
Environment=WAYLAND_DISPLAY=wayland-0
Environment=SDL_VIDEODRIVER=wayland
"""
new_ui_service_env = """Environment=XDG_RUNTIME_DIR=/run/weston
Environment=WAYLAND_DISPLAY=wayland-0
Environment=SDL_VIDEODRIVER=wayland
Environment=SCRCPY_SERVER_PATH=/opt/scrcpy/scrcpy-server
"""
replacements.append((old_ui_service_env, new_ui_service_env, "systemd scrcpy server environment"))

old_verify = """test -x \"$ROOTFS/usr/bin/scrcpy\"
jq -e '.linux.maskedPaths | index(\"/proc/bootconfig\") != null' \"$BUNDLE/config.json\" >/dev/null
"""
new_verify = """test -x \"$ROOTFS/usr/bin/scrcpy\"
test -s \"$ROOTFS/opt/scrcpy/scrcpy-server\"
printf '%s  %s\\n' \"$SCRCPY_SERVER_SHA256\" \"$ROOTFS/opt/scrcpy/scrcpy-server\" | sha256sum --check
jq -e '.linux.maskedPaths | index(\"/proc/bootconfig\") != null' \"$BUNDLE/config.json\" >/dev/null
"""
replacements.append((old_verify, new_verify, "scrcpy server verification"))

for old, new, label in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Could not locate {label} block exactly once; found {count}")
    text = text.replace(old, new)

path.write_text(text)
PY

chmod 0755 "$PATCHED_IMPL"
export SCRCPY_SERVER_SHA256

set +e
bash "$PATCHED_IMPL" "$@"
BUILD_STATUS=$?
set -e

if [[ "$BUILD_STATUS" -eq 0 ]]; then
  # The finalized kernel/initramfs/root disk live under build/. The expanded
  # Debian tree, Linux object tree and unpack staging are no longer needed and
  # otherwise consume several additional gigabytes during the QEMU boot proof.
  rm -rf "$BUILD_WORK"
  mkdir -p "$BUILD_WORK"
fi

exit "$BUILD_STATUS"
