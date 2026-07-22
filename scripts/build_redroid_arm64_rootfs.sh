#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK_DIR:-$ROOT/.build/redroid-arm64-rootfs}"
OUT="${OUT_DIR:-$ROOT/build/redroid-arm64-guest}"
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
KERNEL_TAG="${KERNEL_TAG:-v6.12.95}"
REDROID_IMAGE="${REDROID_IMAGE:-docker.io/redroid/redroid:13.0.0_64only-latest}"
ROOTFS_MIN_MIB="${ROOTFS_MIN_MIB:-8192}"

if [[ "$(uname -s)" != Linux ]]; then
  echo "This script builds the ARM64 guest on Linux." >&2
  exit 1
fi
if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (the GitHub workflow uses sudo)." >&2
  exit 1
fi

for command in debootstrap qemu-aarch64-static aarch64-linux-gnu-gcc make git skopeo umoci python3 mkfs.ext4 rsync cpio xz; do
  command -v "$command" >/dev/null || { echo "missing build dependency: $command" >&2; exit 1; }
done

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"
ROOTFS="$WORK/rootfs"
KERNEL_SRC="$WORK/linux"
OCI_DIR="$WORK/redroid-oci"
BUNDLE="$ROOTFS/opt/redroid/bundle"

printf '[1/9] Creating minimal Debian ARM64 root filesystem\n'
debootstrap --arch=arm64 --foreign --variant=minbase "$DEBIAN_SUITE" "$ROOTFS" "$DEBIAN_MIRROR"
install -m 0755 "$(command -v qemu-aarch64-static)" "$ROOTFS/usr/bin/qemu-aarch64-static"
chroot "$ROOTFS" /debootstrap/debootstrap --second-stage

cat > "$ROOTFS/etc/apt/sources.list" <<APT

deb $DEBIAN_MIRROR $DEBIAN_SUITE main

deb $DEBIAN_MIRROR $DEBIAN_SUITE-updates main

deb http://security.debian.org/debian-security $DEBIAN_SUITE-security main
APT
printf 'android-arm64\n' > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'HOSTS'
127.0.0.1 localhost
127.0.1.1 android-arm64
::1 localhost ip6-localhost ip6-loopback
HOSTS
cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
exit 101
POLICY
chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"

printf '[2/9] Installing the small boot and display userspace\n'
chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  systemd-sysv systemd-resolved dbus udev initramfs-tools kmod procps iproute2 iptables nftables \
  ca-certificates curl runc adb scrcpy weston xwayland seatd libgl1-mesa-dri mesa-vulkan-drivers \
  e2fsprogs util-linux jq
chroot "$ROOTFS" apt-get clean
rm -rf "$ROOTFS/var/lib/apt/lists/"*

printf '[3/9] Building a 4K-page ARM64 kernel with Android BinderFS\n'
git clone --depth 1 --branch "$KERNEL_TAG" \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$KERNEL_SRC"
pushd "$KERNEL_SRC" >/dev/null
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
scripts/config \
  --enable CONFIG_ANDROID_BINDER_IPC \
  --enable CONFIG_ANDROID_BINDERFS \
  --set-str CONFIG_ANDROID_BINDER_DEVICES 'binder,hwbinder,vndbinder' \
  --enable CONFIG_ARM64_4K_PAGES \
  --disable CONFIG_ARM64_16K_PAGES \
  --disable CONFIG_ARM64_64K_PAGES \
  --enable CONFIG_NAMESPACES \
  --enable CONFIG_UTS_NS \
  --enable CONFIG_IPC_NS \
  --enable CONFIG_USER_NS \
  --enable CONFIG_PID_NS \
  --enable CONFIG_NET_NS \
  --enable CONFIG_CGROUPS \
  --enable CONFIG_CGROUP_FREEZER \
  --enable CONFIG_CGROUP_PIDS \
  --enable CONFIG_CGROUP_CPUACCT \
  --enable CONFIG_MEMCG \
  --enable CONFIG_SECCOMP \
  --enable CONFIG_SECCOMP_FILTER \
  --enable CONFIG_OVERLAY_FS \
  --enable CONFIG_VETH \
  --enable CONFIG_BRIDGE \
  --enable CONFIG_BRIDGE_NETFILTER \
  --enable CONFIG_NETFILTER \
  --enable CONFIG_NF_NAT \
  --enable CONFIG_NF_CONNTRACK \
  --enable CONFIG_VIRTIO \
  --enable CONFIG_VIRTIO_PCI \
  --enable CONFIG_VIRTIO_MMIO \
  --enable CONFIG_VIRTIO_BLK \
  --enable CONFIG_VIRTIO_NET \
  --enable CONFIG_DRM \
  --enable CONFIG_DRM_VIRTIO_GPU \
  --enable CONFIG_INPUT_EVDEV \
  --enable CONFIG_DEVTMPFS \
  --enable CONFIG_DEVTMPFS_MOUNT \
  --enable CONFIG_EXT4_FS \
  --enable CONFIG_TMPFS \
  --enable CONFIG_TMPFS_POSIX_ACL \
  --enable CONFIG_DMABUF_HEAPS \
  --enable CONFIG_DMABUF_HEAPS_SYSTEM
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make -j"$(nproc)" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image modules
KERNEL_RELEASE="$(make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- kernelrelease)"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH="$ROOTFS" modules_install
install -m 0644 arch/arm64/boot/Image "$ROOTFS/boot/vmlinuz-$KERNEL_RELEASE"
popd >/dev/null

printf '[4/9] Downloading and unpacking the official ARM64 Redroid 13 image\n'
skopeo copy --override-os linux --override-arch arm64 \
  "docker://$REDROID_IMAGE" "oci:$OCI_DIR:latest"
mkdir -p "$ROOTFS/opt/redroid"
umoci unpack --image "$OCI_DIR:latest" "$BUNDLE"
mkdir -p "$ROOTFS/var/lib/redroid/data"

printf '[5/9] Converting the OCI bundle to a privileged local Android service\n'
python3 - "$BUNDLE/config.json" <<'PY'
from __future__ import annotations
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
config = json.loads(path.read_text())
process = config.setdefault("process", {})
args = list(process.get("args") or ["/init"])
for value in (
    "androidboot.redroid_width=720",
    "androidboot.redroid_height=1280",
    "androidboot.redroid_dpi=320",
    "androidboot.redroid_fps=15",
    "androidboot.redroid_gpu_mode=guest",
    "androidboot.use_memfd=1",
    "ro.bootanim.disable=1",
):
    if value not in args:
        args.append(value)
process["args"] = args
process["terminal"] = False
process["noNewPrivileges"] = False
process["cwd"] = "/"
process["user"] = {"uid": 0, "gid": 0}
all_caps = [
    "CAP_AUDIT_CONTROL", "CAP_AUDIT_READ", "CAP_AUDIT_WRITE", "CAP_BLOCK_SUSPEND",
    "CAP_BPF", "CAP_CHECKPOINT_RESTORE", "CAP_CHOWN", "CAP_DAC_OVERRIDE",
    "CAP_DAC_READ_SEARCH", "CAP_FOWNER", "CAP_FSETID", "CAP_IPC_LOCK",
    "CAP_IPC_OWNER", "CAP_KILL", "CAP_LEASE", "CAP_LINUX_IMMUTABLE",
    "CAP_MAC_ADMIN", "CAP_MAC_OVERRIDE", "CAP_MKNOD", "CAP_NET_ADMIN",
    "CAP_NET_BIND_SERVICE", "CAP_NET_BROADCAST", "CAP_NET_RAW", "CAP_PERFMON",
    "CAP_SETFCAP", "CAP_SETGID", "CAP_SETPCAP", "CAP_SETUID", "CAP_SYS_ADMIN",
    "CAP_SYS_BOOT", "CAP_SYS_CHROOT", "CAP_SYS_MODULE", "CAP_SYS_NICE",
    "CAP_SYS_PACCT", "CAP_SYS_PTRACE", "CAP_SYS_RAWIO", "CAP_SYS_RESOURCE",
    "CAP_SYS_TIME", "CAP_SYS_TTY_CONFIG", "CAP_SYSLOG", "CAP_WAKE_ALARM",
]
process["capabilities"] = {key: all_caps for key in ("bounding", "effective", "inheritable", "permitted", "ambient")}
config.setdefault("root", {})["readonly"] = False
config["hostname"] = "redroid"
config["mounts"] = [mount for mount in config.get("mounts", []) if mount.get("destination") not in {"/data", "/dev/binder", "/dev/hwbinder", "/dev/vndbinder"}]
config["mounts"].extend([
    {"destination": "/data", "type": "none", "source": "/var/lib/redroid/data", "options": ["rbind", "rw"]},
    {"destination": "/dev/binder", "type": "none", "source": "/dev/binder", "options": ["rbind", "rw"]},
    {"destination": "/dev/hwbinder", "type": "none", "source": "/dev/hwbinder", "options": ["rbind", "rw"]},
    {"destination": "/dev/vndbinder", "type": "none", "source": "/dev/vndbinder", "options": ["rbind", "rw"]},
])
linux = config.setdefault("linux", {})
linux["namespaces"] = [ns for ns in linux.get("namespaces", []) if ns.get("type") != "network"]
linux["maskedPaths"] = []
linux["readonlyPaths"] = []
linux.setdefault("resources", {})["devices"] = [{"allow": True, "access": "rwm"}]
path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
PY

printf '[6/9] Installing automatic Android and fullscreen UI services\n'
cat > "$ROOTFS/usr/local/sbin/start-redroid" <<'START'
#!/bin/sh
set -eu
mkdir -p /var/lib/redroid/data /run/redroid
for node in binder hwbinder vndbinder; do
  count=0
  while [ ! -e "/dev/$node" ] && [ "$count" -lt 30 ]; do
    count=$((count + 1))
    sleep 1
  done
  [ -e "/dev/$node" ] || { echo "missing /dev/$node" >&2; exit 1; }
done
runc delete -f redroid >/dev/null 2>&1 || true
exec runc run --bundle /opt/redroid/bundle redroid
START
chmod 0755 "$ROOTFS/usr/local/sbin/start-redroid"

cat > "$ROOTFS/usr/local/sbin/start-redroid-ui" <<'UI'
#!/bin/sh
set -eu
export XDG_RUNTIME_DIR=/run/weston
export WAYLAND_DISPLAY=wayland-0
export SDL_VIDEODRIVER=wayland
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
adb start-server >/dev/null 2>&1 || true
until adb connect 127.0.0.1:5555 >/dev/null 2>&1 && adb -s 127.0.0.1:5555 get-state 2>/dev/null | grep -q device; do
  sleep 2
done
exec scrcpy -s 127.0.0.1:5555 --fullscreen --no-audio --max-fps=15 --video-bit-rate=4M --stay-awake
UI
chmod 0755 "$ROOTFS/usr/local/sbin/start-redroid-ui"

cat > "$ROOTFS/etc/systemd/system/redroid.service" <<'SERVICE'
[Unit]
Description=ARM64 Redroid Android container
After=systemd-udevd.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/start-redroid
ExecStop=-/usr/bin/runc kill redroid KILL
ExecStopPost=-/usr/bin/runc delete -f redroid
Restart=on-failure
RestartSec=3
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
SERVICE

cat > "$ROOTFS/etc/systemd/system/weston-redroid.service" <<'WESTON'
[Unit]
Description=Weston display for Android
After=systemd-udev-settle.service
Conflicts=getty@tty1.service

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/weston
ExecStartPre=/usr/bin/mkdir -p /run/weston
ExecStartPre=/usr/bin/chmod 0700 /run/weston
ExecStart=/usr/bin/weston --backend=drm-backend.so --tty=1 --idle-time=0 --config=/etc/xdg/weston/weston.ini
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical.target
WESTON

cat > "$ROOTFS/etc/systemd/system/redroid-ui.service" <<'UISERVICE'
[Unit]
Description=Fullscreen Android display bridge
After=weston-redroid.service redroid.service
Requires=weston-redroid.service redroid.service

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/weston
Environment=WAYLAND_DISPLAY=wayland-0
Environment=SDL_VIDEODRIVER=wayland
ExecStart=/usr/local/sbin/start-redroid-ui
Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
UISERVICE

mkdir -p "$ROOTFS/etc/xdg/weston" "$ROOTFS/etc/systemd/network" "$ROOTFS/etc/systemd/system/graphical.target.wants" "$ROOTFS/etc/systemd/system/multi-user.target.wants"
cat > "$ROOTFS/etc/xdg/weston/weston.ini" <<'WESTONINI'
[core]
backend=drm-backend.so
idle-time=0
xwayland=true

[shell]
background-color=0xff000000
panel-position=none
locking=false
animation=none
startup-animation=none
WESTONINI
cat > "$ROOTFS/etc/systemd/network/20-virtio.network" <<'NETWORK'
[Match]
Name=en* eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes
NETWORK
ln -sf /lib/systemd/system/systemd-networkd.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
ln -sf /lib/systemd/system/systemd-resolved.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/systemd-resolved.service"
rm -f "$ROOTFS/etc/resolv.conf"
ln -s /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
ln -sf /etc/systemd/system/redroid.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/redroid.service"
ln -sf /etc/systemd/system/weston-redroid.service "$ROOTFS/etc/systemd/system/graphical.target.wants/weston-redroid.service"
ln -sf /etc/systemd/system/redroid-ui.service "$ROOTFS/etc/systemd/system/graphical.target.wants/redroid-ui.service"
ln -sf /lib/systemd/system/graphical.target "$ROOTFS/etc/systemd/system/default.target"

printf '[7/9] Finalizing initramfs and guest filesystem\n'
cat > "$ROOTFS/etc/fstab" <<'FSTAB'
/dev/vda / ext4 rw,noatime,errors=remount-ro 0 1
FSTAB
chroot "$ROOTFS" depmod -a "$KERNEL_RELEASE"
chroot "$ROOTFS" update-initramfs -c -k "$KERNEL_RELEASE"
rm -f "$ROOTFS/usr/sbin/policy-rc.d" "$ROOTFS/usr/bin/qemu-aarch64-static"
rm -rf "$ROOTFS/tmp/"* "$ROOTFS/var/tmp/"* "$ROOTFS/var/cache/apt/archives/"*
: > "$ROOTFS/etc/machine-id"

USED_KIB="$(du -sk "$ROOTFS" | awk '{print $1}')"
ROOTFS_MIB="$(( (USED_KIB * 5 / 4 + 524288 + 1023) / 1024 ))"
if (( ROOTFS_MIB < ROOTFS_MIN_MIB )); then ROOTFS_MIB="$ROOTFS_MIN_MIB"; fi
truncate -s "${ROOTFS_MIB}M" "$OUT/redroid-arm64-rootfs.raw"
mkfs.ext4 -F -L redroidroot -d "$ROOTFS" -E lazy_itable_init=0,lazy_journal_init=0 "$OUT/redroid-arm64-rootfs.raw"
install -m 0644 "$KERNEL_SRC/arch/arm64/boot/Image" "$OUT/kernel"
install -m 0644 "$ROOTFS/boot/initrd.img-$KERNEL_RELEASE" "$OUT/initrd.img"

printf '[8/9] Verifying Binder, architecture and Android payload\n'
grep -q '^CONFIG_ANDROID_BINDER_IPC=y$' "$KERNEL_SRC/.config"
grep -q '^CONFIG_ANDROID_BINDERFS=y$' "$KERNEL_SRC/.config"
grep -q '^CONFIG_ARM64_4K_PAGES=y$' "$KERNEL_SRC/.config"
test -f "$BUNDLE/rootfs/system/build.prop"
grep -Eq '^ro.build.version.release=13' "$BUNDLE/rootfs/system/build.prop"
test -x "$BUNDLE/rootfs/init"
test -x "$ROOTFS/usr/bin/runc"
test -x "$ROOTFS/usr/bin/scrcpy"
e2fsck -fn "$OUT/redroid-arm64-rootfs.raw"

printf '[9/9] Recording reproducible build manifest\n'
REDROID_DIGEST="$(skopeo inspect --override-os linux --override-arch arm64 "docker://$REDROID_IMAGE" | jq -r .Digest)"
cat > "$OUT/build-manifest.txt" <<EOF2
Guest architecture: aarch64
Execution mode: UTM SE threaded interpreter (no JIT)
Linux kernel tag: $KERNEL_TAG
Linux kernel release: $KERNEL_RELEASE
Linux page size: 4K
Binder IPC: built in
BinderFS: enabled
Android runtime: Redroid 13 64-bit only
Redroid image: $REDROID_IMAGE
Redroid digest: $REDROID_DIGEST
Android rendering: guest software renderer
Display bridge: Weston + scrcpy at 15 FPS
Root filesystem: sparse raw ext4
Root filesystem size: ${ROOTFS_MIB} MiB
External AOSP product archive required: no
Physical iPhone boot verified: no
EOF2
sha256sum "$OUT/kernel" "$OUT/initrd.img" "$OUT/redroid-arm64-rootfs.raw" > "$OUT/SHA256SUMS"
printf 'Built no-JIT ARM64 Redroid guest in %s\n' "$OUT"
