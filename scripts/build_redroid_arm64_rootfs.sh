#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK_DIR:-$ROOT/.build/redroid-arm64-rootfs}"
OUT="${OUT_DIR:-$ROOT/build/redroid-arm64-guest}"
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
KERNEL_TAG="${KERNEL_TAG:-v6.12.95}"
# Pin the dated Android 13 arm64-only image instead of a mutable latest tag.
REDROID_IMAGE="${REDROID_IMAGE:-docker.io/redroid/redroid:13.0.0_64only-240527}"
REDROID_EXPECTED_DIGEST_PREFIX="${REDROID_EXPECTED_DIGEST_PREFIX:-sha256:c815ac1b1d5b}"
ROOTFS_MIN_MIB="${ROOTFS_MIN_MIB:-8192}"

if [[ "$(uname -s)" != Linux ]]; then
  echo "This script builds the ARM64 guest on Linux." >&2
  exit 1
fi
if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (the GitHub workflow uses sudo)." >&2
  exit 1
fi

for command in debootstrap qemu-aarch64-static aarch64-linux-gnu-gcc make git skopeo umoci python3 mkfs.ext4 rsync cpio xz jq; do
  command -v "$command" >/dev/null || { echo "missing build dependency: $command" >&2; exit 1; }
done

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"
ROOTFS="$WORK/rootfs"
KERNEL_SRC="$WORK/linux"
OCI_DIR="$WORK/redroid-oci"
BUNDLE="$ROOTFS/opt/redroid/bundle"
REDROID_INSPECT="$WORK/redroid-inspect.json"

printf '[1/10] Creating minimal Debian ARM64 root filesystem\n'
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

printf '[2/10] Installing boot, container and display userspace\n'
chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  systemd-sysv systemd-resolved dbus udev initramfs-tools kmod procps iproute2 iptables nftables \
  ca-certificates curl runc adb scrcpy weston xwayland seatd libgl1-mesa-dri mesa-vulkan-drivers \
  e2fsprogs util-linux jq
chroot "$ROOTFS" apt-get clean
rm -rf "$ROOTFS/var/lib/apt/lists/"*

printf '[3/10] Building a 4K-page ARM64 kernel with the complete Redroid contract\n'
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
  --enable CONFIG_CGROUP_SCHED \
  --enable CONFIG_FAIR_GROUP_SCHED \
  --enable CONFIG_CGROUP_FREEZER \
  --enable CONFIG_CGROUP_PIDS \
  --enable CONFIG_CGROUP_CPUACCT \
  --enable CONFIG_CGROUP_BPF \
  --enable CONFIG_BLK_CGROUP \
  --enable CONFIG_MEMCG \
  --enable CONFIG_BPF_SYSCALL \
  --enable CONFIG_SECCOMP \
  --enable CONFIG_SECCOMP_FILTER \
  --enable CONFIG_OVERLAY_FS \
  --enable CONFIG_VETH \
  --enable CONFIG_TUN \
  --enable CONFIG_BRIDGE \
  --enable CONFIG_BRIDGE_NETFILTER \
  --enable CONFIG_NETFILTER \
  --enable CONFIG_NF_TABLES \
  --enable CONFIG_NF_NAT \
  --enable CONFIG_NF_CONNTRACK \
  --enable CONFIG_IP_NF_IPTABLES \
  --enable CONFIG_IP_NF_NAT \
  --enable CONFIG_IPV6 \
  --enable CONFIG_VIRTIO \
  --enable CONFIG_VIRTIO_PCI \
  --enable CONFIG_VIRTIO_MMIO \
  --enable CONFIG_VIRTIO_BLK \
  --enable CONFIG_VIRTIO_NET \
  --enable CONFIG_HW_RANDOM_VIRTIO \
  --enable CONFIG_DRM \
  --enable CONFIG_DRM_VIRTIO_GPU \
  --enable CONFIG_DRM_FBDEV_EMULATION \
  --enable CONFIG_VT \
  --enable CONFIG_VT_CONSOLE \
  --enable CONFIG_FRAMEBUFFER_CONSOLE \
  --enable CONFIG_INPUT_EVDEV \
  --enable CONFIG_DEVTMPFS \
  --enable CONFIG_DEVTMPFS_MOUNT \
  --enable CONFIG_EXT4_FS \
  --enable CONFIG_TMPFS \
  --enable CONFIG_TMPFS_POSIX_ACL \
  --enable CONFIG_DMABUF_HEAPS \
  --enable CONFIG_DMABUF_HEAPS_SYSTEM
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
for required_config in \
  CONFIG_ANDROID_BINDER_IPC=y \
  CONFIG_ANDROID_BINDERFS=y \
  CONFIG_ARM64_4K_PAGES=y \
  CONFIG_NAMESPACES=y \
  CONFIG_CGROUPS=y \
  CONFIG_MEMCG=y \
  CONFIG_SECCOMP=y \
  CONFIG_OVERLAY_FS=y \
  CONFIG_IPV6=y \
  CONFIG_VIRTIO_PCI=y \
  CONFIG_VIRTIO_BLK=y \
  CONFIG_VIRTIO_NET=y \
  CONFIG_DRM_VIRTIO_GPU=y \
  CONFIG_DMABUF_HEAPS=y \
  CONFIG_DMABUF_HEAPS_SYSTEM=y; do
  grep -qx "$required_config" .config || { echo "kernel config missing: $required_config" >&2; exit 1; }
done
grep -qx 'CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"' .config
make -j"$(nproc)" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image modules
KERNEL_RELEASE="$(make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- kernelrelease)"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH="$ROOTFS" modules_install
install -m 0644 arch/arm64/boot/Image "$ROOTFS/boot/vmlinuz-$KERNEL_RELEASE"
popd >/dev/null

printf '[4/10] Resolving and pinning the official ARM64 Redroid 13 image\n'
skopeo inspect --override-os linux --override-arch arm64 "docker://$REDROID_IMAGE" > "$REDROID_INSPECT"
REDROID_ARCH="$(jq -r .Architecture "$REDROID_INSPECT")"
REDROID_OS="$(jq -r .Os "$REDROID_INSPECT")"
REDROID_DIGEST="$(jq -r .Digest "$REDROID_INSPECT")"
[[ "$REDROID_ARCH" == arm64 ]]
[[ "$REDROID_OS" == linux ]]
[[ "$REDROID_DIGEST" == "$REDROID_EXPECTED_DIGEST_PREFIX"* ]] || {
  echo "Redroid ARM64 digest changed: expected prefix $REDROID_EXPECTED_DIGEST_PREFIX, got $REDROID_DIGEST" >&2
  exit 1
}
REDROID_RESOLVED_IMAGE="docker.io/redroid/redroid@$REDROID_DIGEST"
skopeo copy --override-os linux --override-arch arm64 \
  "docker://$REDROID_RESOLVED_IMAGE" "oci:$OCI_DIR:latest"
mkdir -p "$ROOTFS/opt/redroid"
umoci unpack --image "$OCI_DIR:latest" "$BUNDLE"
mkdir -p "$ROOTFS/var/lib/redroid/data"

printf '[5/10] Converting the OCI bundle to a privileged local Android service\n'
python3 - "$BUNDLE/config.json" <<'PY'
from __future__ import annotations
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
config = json.loads(path.read_text())
process = config.setdefault("process", {})
args = list(process.get("args") or ["/init", "qemu=1", "androidboot.hardware=redroid"])
for value in (
    "qemu=1",
    "androidboot.hardware=redroid",
    "androidboot.redroid_width=720",
    "androidboot.redroid_height=1280",
    "androidboot.redroid_dpi=320",
    "androidboot.redroid_fps=15",
    "androidboot.redroid_gpu_mode=guest",
    "androidboot.use_memfd=true",
    "androidboot.redroid_net_ndns=1",
    "androidboot.redroid_net_dns1=10.0.2.3",
    "ro.bootanim.disable=1",
    "ro.adb.secure=0",
    "ro.secure=0",
):
    if value not in args:
        args.append(value)
process["args"] = args
process["terminal"] = False
process["noNewPrivileges"] = False
process["cwd"] = "/"
process["user"] = {"uid": 0, "gid": 0}
process.pop("apparmorProfile", None)
process.pop("selinuxLabel", None)
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

remove_destinations = {"/data", "/dev/binder", "/dev/hwbinder", "/dev/vndbinder", "/dev/dma_heap"}
mounts = [mount for mount in config.get("mounts", []) if mount.get("destination") not in remove_destinations]
for mount in mounts:
    if mount.get("destination") in {"/sys", "/sys/fs/cgroup"}:
        options = [option for option in mount.get("options", []) if option != "ro"]
        if "rw" not in options:
            options.append("rw")
        mount["options"] = options
mounts.extend([
    {"destination": "/data", "type": "none", "source": "/var/lib/redroid/data", "options": ["rbind", "rw"]},
    {"destination": "/dev/binder", "type": "none", "source": "/dev/binder", "options": ["rbind", "rw"]},
    {"destination": "/dev/hwbinder", "type": "none", "source": "/dev/hwbinder", "options": ["rbind", "rw"]},
    {"destination": "/dev/vndbinder", "type": "none", "source": "/dev/vndbinder", "options": ["rbind", "rw"]},
    {"destination": "/dev/dma_heap", "type": "none", "source": "/dev/dma_heap", "options": ["rbind", "rw"]},
])
config["mounts"] = mounts

linux = config.setdefault("linux", {})
# Share the guest Linux network namespace so QEMU's localhost forward reaches ADB.
linux["namespaces"] = [ns for ns in linux.get("namespaces", []) if ns.get("type") not in {"network", "cgroup"}]
# Redroid's maintainer documents host /proc/bootconfig as a startup hazard.
masked = list(linux.get("maskedPaths") or [])
for value in ("/proc/bootconfig", "/proc/device-tree"):
    if value not in masked:
        masked.append(value)
linux["maskedPaths"] = masked
linux["readonlyPaths"] = list(linux.get("readonlyPaths") or [])
linux.pop("seccomp", None)
linux.setdefault("resources", {})["devices"] = [{"allow": True, "access": "rwm"}]
path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
PY

printf '[6/10] Installing BinderFS, Android and fullscreen UI services\n'
cat > "$ROOTFS/usr/local/sbin/start-redroid" <<'START'
#!/bin/sh
set -eu
mkdir -p /var/lib/redroid/data /run/redroid /dev/binderfs
if ! mountpoint -q /dev/binderfs; then
  mount -t binder binder /dev/binderfs
fi
grep -qw binder /proc/filesystems
for node in binder hwbinder vndbinder; do
  if [ ! -e "/dev/$node" ] && [ -e "/dev/binderfs/$node" ]; then
    ln -s "/dev/binderfs/$node" "/dev/$node"
  fi
  count=0
  while [ ! -e "/dev/$node" ] && [ "$count" -lt 30 ]; do
    count=$((count + 1))
    sleep 1
  done
  [ -e "/dev/$node" ] || { echo "missing /dev/$node" >&2; exit 1; }
done
count=0
while [ ! -e /dev/dma_heap/system ] && [ "$count" -lt 30 ]; do
  count=$((count + 1))
  sleep 1
done
[ -e /dev/dma_heap/system ] || { echo "missing /dev/dma_heap/system" >&2; exit 1; }
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
until [ "$(adb -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
  sleep 2
done
exec scrcpy -s 127.0.0.1:5555 --fullscreen --no-audio --max-fps=15 --video-bit-rate=4M --stay-awake
UI
chmod 0755 "$ROOTFS/usr/local/sbin/start-redroid-ui"

cat > "$ROOTFS/etc/systemd/system/redroid.service" <<'SERVICE'
[Unit]
Description=ARM64 Redroid Android container
After=systemd-udevd.service systemd-networkd-wait-online.service
Wants=systemd-networkd-wait-online.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/start-redroid
ExecStop=-/usr/bin/runc kill redroid KILL
ExecStopPost=-/usr/bin/runc delete -f redroid
Restart=on-failure
RestartSec=3
TimeoutStartSec=0
StandardOutput=journal+console
StandardError=journal+console

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
StandardOutput=journal+console
StandardError=journal+console

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
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=graphical.target
UISERVICE

mkdir -p "$ROOTFS/etc/xdg/weston" "$ROOTFS/etc/systemd/network" \
  "$ROOTFS/etc/systemd/system/graphical.target.wants" "$ROOTFS/etc/systemd/system/multi-user.target.wants"
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
ln -sf /lib/systemd/system/systemd-networkd-wait-online.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/systemd-networkd-wait-online.service"
ln -sf /lib/systemd/system/systemd-resolved.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/systemd-resolved.service"
rm -f "$ROOTFS/etc/resolv.conf"
ln -s /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
ln -sf /etc/systemd/system/redroid.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/redroid.service"
ln -sf /etc/systemd/system/weston-redroid.service "$ROOTFS/etc/systemd/system/graphical.target.wants/weston-redroid.service"
ln -sf /etc/systemd/system/redroid-ui.service "$ROOTFS/etc/systemd/system/graphical.target.wants/redroid-ui.service"
ln -sf /lib/systemd/system/graphical.target "$ROOTFS/etc/systemd/system/default.target"

printf '[7/10] Finalizing initramfs and guest filesystem\n'
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

printf '[8/10] Verifying Binder, DMA-BUF, OCI masks and Android payload\n'
grep -q '^CONFIG_ANDROID_BINDER_IPC=y$' "$KERNEL_SRC/.config"
grep -q '^CONFIG_ANDROID_BINDERFS=y$' "$KERNEL_SRC/.config"
grep -q '^CONFIG_ARM64_4K_PAGES=y$' "$KERNEL_SRC/.config"
grep -q '^CONFIG_DMABUF_HEAPS_SYSTEM=y$' "$KERNEL_SRC/.config"
test -f "$BUNDLE/rootfs/system/build.prop"
grep -Eq '^ro.build.version.release=13' "$BUNDLE/rootfs/system/build.prop"
test -x "$BUNDLE/rootfs/init"
test -x "$ROOTFS/usr/bin/runc"
test -x "$ROOTFS/usr/bin/scrcpy"
jq -e '.linux.maskedPaths | index("/proc/bootconfig") != null' "$BUNDLE/config.json" >/dev/null
jq -e '.mounts | map(.destination) | index("/dev/dma_heap") != null' "$BUNDLE/config.json" >/dev/null
jq -e '.process.args | index("androidboot.use_memfd=true") != null' "$BUNDLE/config.json" >/dev/null
e2fsck -fn "$OUT/redroid-arm64-rootfs.raw"

printf '[9/10] Recording reproducible build manifest\n'
cat > "$OUT/build-manifest.txt" <<EOF2
Guest architecture: aarch64
Execution mode: UTM SE threaded interpreter (no JIT)
Linux kernel tag: $KERNEL_TAG
Linux kernel release: $KERNEL_RELEASE
Linux page size: 4K
Binder IPC: built in
BinderFS: enabled and mounted before Android
Binder devices: binder,hwbinder,vndbinder
DMA-BUF system heap: built in and passed into Android
IPv6: enabled
Android runtime: Redroid 13 64-bit only
Redroid image: $REDROID_IMAGE
Redroid resolved image: $REDROID_RESOLVED_IMAGE
Redroid digest: $REDROID_DIGEST
Redroid digest prefix verified: $REDROID_EXPECTED_DIGEST_PREFIX
Host bootconfig masked from Android: yes
Android rendering: guest software renderer
Display bridge: Weston + scrcpy at 15 FPS
Root filesystem: sparse raw ext4
Root filesystem size: ${ROOTFS_MIB} MiB
External AOSP product archive required: no
CI Android boot verification: pending
Physical iPhone boot verified: no
EOF2

printf '[10/10] Recording checksums\n'
sha256sum "$OUT/kernel" "$OUT/initrd.img" "$OUT/redroid-arm64-rootfs.raw" > "$OUT/SHA256SUMS"
printf 'Built no-JIT ARM64 Redroid guest in %s\n' "$OUT"
