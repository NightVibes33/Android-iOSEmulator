#!/usr/bin/env bash
set -euo pipefail

# The complete boot-tested implementation is pinned to the commit below. Keep
# this small launcher focused on deterministic dependency corrections so newer
# CI and Android boot-verification work is not accidentally overwritten.
BASE_COMMIT="b7fdee1c1310ac01dea284daf79936d0d0ea9853"
BASE_BLOB="f1238c1e17501e53be3ddf64de5028fcf2d895df"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHED_IMPL="$ROOT/scripts/.build_redroid_arm64_rootfs.impl.sh"

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

python3 - "$PATCHED_IMPL" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

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

old_install = """chroot \"$ROOTFS\" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
  systemd-sysv systemd-resolved dbus udev initramfs-tools kmod procps iproute2 iptables nftables \\
  ca-certificates curl runc adb scrcpy weston xwayland seatd libgl1-mesa-dri mesa-vulkan-drivers \\
  e2fsprogs util-linux jq
chroot \"$ROOTFS\" apt-get clean
"""
new_install = """chroot \"$ROOTFS\" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
  systemd-sysv systemd-resolved dbus udev initramfs-tools kmod procps iproute2 iptables nftables \\
  ca-certificates curl runc adb weston xwayland seatd libgl1-mesa-dri mesa-vulkan-drivers \\
  e2fsprogs util-linux jq
chroot \"$ROOTFS\" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
  -t \"$DEBIAN_SUITE-backports\" scrcpy
chroot \"$ROOTFS\" apt-get clean
"""

if text.count(old_sources) != 1:
    raise SystemExit("Could not locate the pinned Debian sources block exactly once")
if text.count(old_install) != 1:
    raise SystemExit("Could not locate the pinned package installation block exactly once")

text = text.replace(old_sources, new_sources)
text = text.replace(old_install, new_install)
path.write_text(text)
PY

chmod 0755 "$PATCHED_IMPL"
exec bash "$PATCHED_IMPL" "$@"
