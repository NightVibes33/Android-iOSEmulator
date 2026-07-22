#!/usr/bin/env bash
set -euo pipefail

# The complete boot-tested implementation is pinned to the commit below. Keep
# this small launcher focused on deterministic dependency corrections so newer
# CI and Android boot-verification work is not accidentally overwritten.
BASE_COMMIT="b7fdee1c1310ac01dea284daf79936d0d0ea9853"
BASE_BLOB="f1238c1e17501e53be3ddf64de5028fcf2d895df"
SCRCPY_VERSION="3.3.4"
SCRCPY_SERVER_SHA256="8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e"
REDROID_EXPECTED_DIGEST="sha256:5a42a569ee1d7c71796c0385e906cbaa4c3e0a162a56d9f26b29bdb1befac13b"
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

old_image = """truncate -s \"${ROOTFS_MIB}M\" \"$OUT/redroid-arm64-rootfs.raw\"
mkfs.ext4 -F -L redroidroot -d \"$ROOTFS\" -E lazy_itable_init=0,lazy_journal_init=0 \"$OUT/redroid-arm64-rootfs.raw\"
"""
new_image = """truncate -s \"${ROOTFS_MIB}M\" \"$OUT/redroid-arm64-rootfs.raw\"
mkfs.ext4 -F -L redroidroot -E lazy_itable_init=0,lazy_journal_init=0 \"$OUT/redroid-arm64-rootfs.raw\"
ROOTFS_IMAGE_MOUNT=\"$WORK/rootfs-image\"
mkdir -p \"$ROOTFS_IMAGE_MOUNT\"
mount -o loop \"$OUT/redroid-arm64-rootfs.raw\" \"$ROOTFS_IMAGE_MOUNT\"
fail_image_population() {
  echo \"ext4 image population verification failed: $1\" >&2
  find \"$ROOTFS_IMAGE_MOUNT/opt\" -maxdepth 5 -printf '%M %u:%g %s %p\\n' 2>/dev/null | tail -n 100 >&2 || true
  sync
  umount \"$ROOTFS_IMAGE_MOUNT\" || true
  exit 1
}
if ! rsync -aHAX --numeric-ids \"$ROOTFS/\" \"$ROOTFS_IMAGE_MOUNT/\"; then
  fail_image_population \"rsync -aHAX failed\"
fi
SOURCE_INIT=\"$ROOTFS/opt/redroid/bundle/rootfs/init\"
DEST_INIT=\"$ROOTFS_IMAGE_MOUNT/opt/redroid/bundle/rootfs/init\"
SOURCE_SERVER=\"$ROOTFS/opt/scrcpy/scrcpy-server\"
DEST_SERVER=\"$ROOTFS_IMAGE_MOUNT/opt/scrcpy/scrcpy-server\"
[[ -L \"$SOURCE_INIT\" ]] || fail_image_population \"source Android init is not the expected symlink\"
[[ -L \"$DEST_INIT\" ]] || fail_image_population \"Android init symlink is missing from the ext4 image\"
[[ -s \"$DEST_SERVER\" ]] || fail_image_population \"scrcpy server is missing from the ext4 image\"
SOURCE_INIT_LINK=\"$(readlink \"$SOURCE_INIT\")\"
DEST_INIT_LINK=\"$(readlink \"$DEST_INIT\")\"
[[ \"$SOURCE_INIT_LINK\" == \"$DEST_INIT_LINK\" ]] || fail_image_population \"Android init link differs: source=$SOURCE_INIT_LINK destination=$DEST_INIT_LINK\"
SOURCE_LINK_META=\"$(stat -c '%a:%u:%g:%s' \"$SOURCE_INIT\")\"
DEST_LINK_META=\"$(stat -c '%a:%u:%g:%s' \"$DEST_INIT\")\"
[[ \"$SOURCE_LINK_META\" == \"$DEST_LINK_META\" ]] || fail_image_population \"Android init symlink metadata differs: source=$SOURCE_LINK_META destination=$DEST_LINK_META\"
case \"$SOURCE_INIT_LINK\" in
  /*)
    SOURCE_INIT_TARGET=\"$ROOTFS/opt/redroid/bundle/rootfs$SOURCE_INIT_LINK\"
    DEST_INIT_TARGET=\"$ROOTFS_IMAGE_MOUNT/opt/redroid/bundle/rootfs$DEST_INIT_LINK\"
    ;;
  *)
    SOURCE_INIT_TARGET=\"$(dirname \"$SOURCE_INIT\")/$SOURCE_INIT_LINK\"
    DEST_INIT_TARGET=\"$(dirname \"$DEST_INIT\")/$DEST_INIT_LINK\"
    ;;
esac
[[ -f \"$SOURCE_INIT_TARGET\" ]] || fail_image_population \"source Android init target is missing: $SOURCE_INIT_LINK\"
[[ -f \"$DEST_INIT_TARGET\" ]] || fail_image_population \"Android init target is missing from the ext4 image: $DEST_INIT_LINK\"
SOURCE_INIT_META=\"$(stat -c '%a:%u:%g:%s' \"$SOURCE_INIT_TARGET\")\"
DEST_INIT_META=\"$(stat -c '%a:%u:%g:%s' \"$DEST_INIT_TARGET\")\"
[[ \"$SOURCE_INIT_META\" == \"$DEST_INIT_META\" ]] || fail_image_population \"Android init target metadata differs: source=$SOURCE_INIT_META destination=$DEST_INIT_META\"
SOURCE_INIT_SHA=\"$(sha256sum \"$SOURCE_INIT_TARGET\" | awk '{print $1}')\"
DEST_INIT_SHA=\"$(sha256sum \"$DEST_INIT_TARGET\" | awk '{print $1}')\"
[[ \"$SOURCE_INIT_SHA\" == \"$DEST_INIT_SHA\" ]] || fail_image_population \"Android init target checksum differs\"
SOURCE_SERVER_SHA=\"$(sha256sum \"$SOURCE_SERVER\" | awk '{print $1}')\"
DEST_SERVER_SHA=\"$(sha256sum \"$DEST_SERVER\" | awk '{print $1}')\"
[[ \"$SOURCE_SERVER_SHA\" == \"$DEST_SERVER_SHA\" ]] || fail_image_population \"scrcpy server checksum differs\"
printf 'Verified ext4 Android init symlink %s, target metadata %s and checksums.\\n' \"$DEST_INIT_LINK\" \"$DEST_INIT_META\"
sync
umount \"$ROOTFS_IMAGE_MOUNT\"
rmdir \"$ROOTFS_IMAGE_MOUNT\"
unset -f fail_image_population
"""
replacements.append((old_image, new_image, "ext4 image population"))

old_binder_service = """printf '[6/10] Installing BinderFS, Android and fullscreen UI services\\n'
cat > "$ROOTFS/usr/local/sbin/start-redroid" <<'START'
#!/bin/sh
set -eu
mkdir -p /var/lib/redroid/data /run/redroid /dev/binderfs
if ! mountpoint -q /dev/binderfs; then
  mount -t binder binder /dev/binderfs
fi
grep -qw binder /proc/filesystems
for node in binder hwbinder vndbinder; do
"""
new_binder_service = """printf '[6/10] Installing BinderFS, Android and fullscreen UI services\\n'
cat > "$WORK/binderfs-device.c" <<'BINDERFS_ALLOCATOR'
#include <errno.h>
#include <fcntl.h>
#include <linux/android/binder.h>
#include <linux/android/binderfs.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv) {
    int fd;
    int result = 0;

    if (argc < 2) {
        fprintf(stderr, "usage: %s <binder-name>...\\n", argv[0]);
        return 64;
    }

    fd = open("/dev/binderfs/binder-control", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        perror("open binder-control");
        return 1;
    }

    for (int i = 1; i < argc; i++) {
        struct binderfs_device device = {0};
        char path[256];
        size_t length = strlen(argv[i]);

        if (length == 0 || length >= BINDERFS_MAX_NAME) {
            fprintf(stderr, "invalid binder device name: %s\\n", argv[i]);
            result = 1;
            continue;
        }

        snprintf(path, sizeof(path), "/dev/binderfs/%s", argv[i]);
        if (access(path, F_OK) == 0) {
            if (chmod(path, 0666) < 0) {
                perror("chmod existing binder device");
                result = 1;
            }
            continue;
        }

        memcpy(device.name, argv[i], length + 1);
        if (ioctl(fd, BINDER_CTL_ADD, &device) < 0) {
            if (errno != EEXIST) {
                fprintf(stderr, "BINDER_CTL_ADD %s: %s\\n", argv[i], strerror(errno));
                result = 1;
                continue;
            }
        }
        if (chmod(path, 0666) < 0) {
            fprintf(stderr, "chmod %s: %s\\n", path, strerror(errno));
            result = 1;
        }
    }

    close(fd);
    return result;
}
BINDERFS_ALLOCATOR
aarch64-linux-gnu-gcc -O2 -Wall -Wextra "$WORK/binderfs-device.c" -o "$WORK/binderfs-device"
install -m 0755 "$WORK/binderfs-device" "$ROOTFS/usr/local/sbin/binderfs-device"

cat > "$ROOTFS/usr/local/sbin/start-redroid" <<'START'
#!/bin/sh
set -eu
mkdir -p /var/lib/redroid/data /run/redroid /dev/binderfs
if ! mountpoint -q /dev/binderfs; then
  mount -t binder binder /dev/binderfs
fi
grep -qw binder /proc/filesystems
/usr/local/sbin/binderfs-device binder hwbinder vndbinder
for node in binder hwbinder vndbinder; do
"""
replacements.append((old_binder_service, new_binder_service, "BinderFS device allocator"))

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

old_bundle_init_verify = """test -x \"$BUNDLE/rootfs/init\"
"""
new_bundle_init_verify = """test -L \"$BUNDLE/rootfs/init\"
BUNDLE_INIT_LINK=\"$(readlink \"$BUNDLE/rootfs/init\")\"
case \"$BUNDLE_INIT_LINK\" in
  /*) BUNDLE_INIT_TARGET=\"$BUNDLE/rootfs$BUNDLE_INIT_LINK\" ;;
  *) BUNDLE_INIT_TARGET=\"$BUNDLE/rootfs/$(dirname \"$BUNDLE_INIT_LINK\")/$(basename \"$BUNDLE_INIT_LINK\")\" ;;
esac
test -x \"$BUNDLE_INIT_TARGET\"
"""
replacements.append((old_bundle_init_verify, new_bundle_init_verify, "Android init static verification"))

old_verify = """test -x \"$ROOTFS/usr/bin/scrcpy\"
jq -e '.linux.maskedPaths | index(\"/proc/bootconfig\") != null' \"$BUNDLE/config.json\" >/dev/null
"""
new_verify = """test -x \"$ROOTFS/usr/bin/scrcpy\"
test -x \"$ROOTFS/usr/local/sbin/binderfs-device\"
test -s \"$ROOTFS/opt/scrcpy/scrcpy-server\"
printf '%s  %s\\n' \"$SCRCPY_SERVER_SHA256\" \"$ROOTFS/opt/scrcpy/scrcpy-server\" | sha256sum --check
jq -e '.linux.maskedPaths | index(\"/proc/bootconfig\") != null' \"$BUNDLE/config.json\" >/dev/null
"""
replacements.append((old_verify, new_verify, "scrcpy server verification"))

old_manifest = """Root filesystem: sparse raw ext4
Root filesystem size: ${ROOTFS_MIB} MiB
"""
new_manifest = """Root filesystem: sparse raw ext4
BinderFS device allocation: binder-control BINDER_CTL_ADD helper
Root filesystem metadata: ownership, hardlinks, ACLs and xattrs preserved
Root filesystem size: ${ROOTFS_MIB} MiB
"""
replacements.append((old_manifest, new_manifest, "root filesystem manifest"))

for old, new, label in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Could not locate {label} block exactly once; found {count}")
    text = text.replace(old, new)

path.write_text(text)
PY

chmod 0755 "$PATCHED_IMPL"
export SCRCPY_SERVER_SHA256
# The base builder performs a starts-with comparison; exporting the full digest
# makes that check an exact digest pin while preserving the pinned implementation.
export REDROID_EXPECTED_DIGEST_PREFIX="$REDROID_EXPECTED_DIGEST"

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
