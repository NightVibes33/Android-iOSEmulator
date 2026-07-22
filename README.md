# Android iOSEmulator

A sideload-first iOS project for running an ARM64 Android environment locally through a QEMU/UTM-derived runtime.

## Active no-JIT runtime

The BlissOS x86_64 experiment is retired. It proved LiveContainer import and IPA packaging, but it did not prove usable Android boot on ARM iPhone hardware.

The active iPhone 16 / iOS 27 beta fallback is now:

```text
Unsigned LiveContainer guest with isJITNeeded=false
        ↓
UTM SE qemu-aarch64-softmmu interpreter
        ↓
QEMU virt + direct ARM64 kernel/initramfs boot
        ↓
Minimal ARM64 Linux with a 4K-page BinderFS kernel
        ↓
runc + Redroid 13 arm64-only Android container
        ↓
Weston + fullscreen scrcpy display bridge
```

This path uses no x86 Android guest, no JIT, no Hypervisor.framework, no KVM, no GRUB, and no installer ISO.

## Self-contained build

The workflow `.github/workflows/build-redroid-arm64-se-livecontainer-ipa.yml` now builds every required guest component:

1. Ubuntu cross-compiles Linux ARM64 with Binder IPC, BinderFS, VirtIO and VirtIO-GPU support.
2. It downloads and records the digest of the Redroid 13 arm64-only container image.
3. It creates a persistent sparse raw ext4 guest disk and direct-boot kernel/initramfs.
4. A sparse-aware Zstandard archive transfers the guest to the macOS packaging job.
5. macOS embeds it into UTM SE and produces one import-safe unsigned LiveContainer IPA.

No external AOSP FVP product archive is required.

The expected release asset is:

```text
Android-iOSEmulator-Redroid13-ARM64-SE-NoJIT-unsigned.ipa
```

## Enforced package contract

CI rejects the build unless all of the following are true:

- guest architecture is `aarch64`,
- LiveContainer metadata contains `isJITNeeded=false`,
- `qemu-aarch64-softmmu` is present,
- `qemu-x86_64-softmmu` is absent,
- the kernel contains Binder IPC, BinderFS and 4K ARM64 pages,
- the final archive begins with `Info.plist`, the executable and `LCAppInfo.plist`,
- the final IPA metadata can be extracted and parsed exactly as LiveContainer reads it,
- the entire release remains one IPA below GitHub's 2 GiB asset limit.

## No-JIT speed profile

The no-JIT configuration minimizes work without making false acceleration claims:

- native ARM64 guest code with no x86 translation,
- direct kernel boot,
- two virtual CPUs and 2048 MiB RAM,
- sparse raw root storage,
- Android boot animation disabled,
- software Android rendering at 720 × 1280, 320 dpi and 15 FPS,
- UTM debug logging, sound and USB redirection disabled,
- persistent Android `/data` across launches.

UTM SE still interprets guest instructions, so it will be slower than JIT-enabled UTM. The first physical-device test must establish whether it is usable on the iPhone 16.

## Current validation gates

### Gate SE-0 — CI build

Build the kernel, guest disk and complete IPA without an external artifact. Validate architecture, BinderFS, Redroid version, LiveContainer metadata and archive ordering.

### Gate SE-1 — ARM64 Linux boot

Boot the direct ARM64 kernel on the physical iPhone and verify systemd, VirtIO storage, networking and DRM.

### Gate SE-2 — Android boot

Verify the Redroid container reaches ADB and reports `sys.boot_completed=1` while preserving `/data`.

### Gate SE-3 — Android interface

Verify Weston and scrcpy display the launcher, touch reaches Android, and the app remains alive under iOS memory pressure.

Physical iPhone boot is still a validation gate, not a completed claim.

## Future native AOSP lane

The existing AOSP FVP scripts remain research infrastructure for a future direct Android guest. They are not the current release blocker because public reusable FVP product images are unavailable and a full AOSP build is much heavier than the self-contained Redroid lane.

## Safety and scope

The project runs compatible ARM64 APKs inside an isolated Android environment. It does not bypass Play Integrity, DRM, banking protections or anti-cheat systems. Google Play services are not bundled.

## Licensing

QEMU, UTM, Linux, Debian, Redroid and Android-derived components retain their respective licenses and notices. Release builds must include all notices and corresponding-source obligations required by those components.
