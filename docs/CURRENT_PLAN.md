# Current committed no-JIT ARM64 plan

## Product contract

Android iOSEmulator is a sideload-first iOS application. Its target is a compatible ARM64 Android environment that runs locally, preserves app data, installs user-provided APK/APKS/XAPK packages, and exposes touch, keyboard, networking, files, audio, diagnostics and lifecycle controls through an iOS-native frontend.

The project does not use a cloud Android machine as its primary runtime.

## Active no-JIT execution chain

```text
Unsigned Android iOSEmulator LiveContainer guest
        ↓
isJITNeeded=false
        ↓
UTM SE qemu-aarch64-softmmu interpreter
        ↓
QEMU virt + direct kernel/initramfs boot
        ↓
Minimal ARM64 Linux guest
        ↓
4K-page kernel with Binder IPC + BinderFS
        ↓
runc + Redroid 13 arm64-only
        ↓
Weston DRM compositor + fullscreen scrcpy
```

This lane is intended for the iPhone 16 on iOS 27 beta 3 where a dependable JIT path is unavailable. It uses no x86 Android guest, no Hypervisor.framework, no KVM, no Cuttlefish host, no GRUB and no installer ISO.

UTM SE performs interpreter execution. Matching the guest architecture removes x86 translation overhead, but it does not make the VM equivalent to native execution.

## Why the lane changed

The direct AOSP FVP design remains technically useful, but Google does not publish a reusable product-output archive containing all four required images. Building all of AOSP requires substantially more storage and compute than the standard repository runner.

The active lane therefore builds a smaller Linux host and embeds the official Redroid 13 arm64-only Android container. This removes the external AOSP archive blocker while keeping Android and the VM architecture ARM64.

## Build pipeline

### Linux guest job

- create a minimal Debian ARM64 root filesystem,
- cross-compile Linux 6.12.95 for ARM64,
- force 4K pages,
- build Binder IPC and BinderFS into the kernel,
- enable namespaces, cgroups, overlayfs, VirtIO block/network/GPU and DMA-BUF heaps,
- download the Redroid 13 arm64-only OCI image,
- record its resolved digest,
- configure a privileged local runc container with persistent `/data`,
- install Weston and scrcpy services,
- create a sparse raw ext4 root disk,
- generate kernel, initramfs, manifest and SHA-256 records.

### Transfer job boundary

The raw guest disk is sparse and has a large logical size. CI transfers it as a sparse-aware Zstandard archive rather than uploading the expanded raw image directly.

### macOS packaging job

- download official UTM SE,
- retain only dyld-required and ARM64 QEMU frameworks,
- create an `aarch64` QEMU `virt` bundle,
- boot the ARM64 kernel and initramfs directly,
- attach the raw root disk through VirtIO,
- set LiveContainer `isJITNeeded=false`,
- compile the runtime replacement bootstrap,
- reproduce the proven import-safe IPA entry ordering,
- extract and validate final metadata from the completed IPA,
- publish one complete unsigned IPA only when all checks pass.

## Hard gates

### Gate SE-0 — Reproducible CI artifact

Exit requirements:

- Linux kernel and guest disk build without an external AOSP archive,
- final architecture is `aarch64`,
- kernel contains Binder IPC, BinderFS and 4K ARM64 pages,
- Redroid reports Android 13 arm64-only in the build manifest,
- resolved container digest is recorded,
- final QEMU target is `virt`,
- `qemu-aarch64-softmmu` is present,
- `qemu-x86_64-softmmu` is absent,
- LiveContainer metadata contains `isJITNeeded=false`,
- final IPA metadata is readable after extraction,
- final release is one IPA below 2 GiB.

### Gate SE-1 — Linux boot on iPhone

- delete any stale LiveContainer runtime,
- import and sign the new IPA,
- boot on the physical iPhone 16,
- verify the ARM64 kernel reaches systemd,
- verify `/dev/vda`, VirtIO networking and VirtIO-GPU,
- verify Binder devices exist,
- repeat cold boot three times,
- capture time to Linux userspace and any iOS memory-pressure termination.

Exit requirement: repeatable ARM64 Linux boot without JIT.

### Gate SE-2 — Android services

- launch the Redroid runc service,
- verify `binder`, `hwbinder` and `vndbinder`,
- establish local ADB,
- verify `sys.boot_completed=1`,
- preserve Android `/data` across relaunch,
- collect logcat, dmesg and runc diagnostics on failure.

Exit requirement: repeatable Android 13 boot with persistent data.

### Gate SE-3 — Android interface

- start Weston on VirtIO DRM,
- attach scrcpy to local Redroid ADB,
- display Android at 720 × 1280, 320 dpi and 15 FPS,
- verify touch and keyboard input,
- verify launcher stability under iOS memory pressure.

Exit requirement: a usable Android launcher appears on the physical iPhone.

### Gate SE-4 — APK platform

- inspect APK/APKS/XAPK metadata,
- detect ABI, SDK, splits, permissions and signatures,
- install through Android PackageInstaller or ADB sessions,
- launch, update, force-stop and uninstall packages,
- expose installed applications as native iOS library cards.

Exit requirement: representative ARM64 applications install, launch and retain data.

### Gate SE-5 — Device integration

- multitouch and pointer IDs,
- hardware keyboard, mouse and controller support,
- Android audio output and microphone bridge,
- files, clipboard and orientation,
- dynamic resolution and frame pacing,
- lifecycle recovery and diagnostic bundles.

Exit requirement: ordinary compatible Android applications are usable without developer controls.

## Fast no-JIT profile

- ARM64 guest and Android container only,
- direct kernel boot,
- two vCPUs,
- 2048 MiB guest RAM,
- sparse raw root disk,
- Android boot animation disabled,
- guest software renderer,
- 15 FPS output target,
- UTM debug logging disabled,
- sound and USB redirection disabled until base boot passes,
- persistent Android data.

These settings reduce avoidable work. They do not remove the fundamental cost of UTM SE interpreter execution.

## Future direct AOSP lane

The AOSP FVP scripts remain in the repository for future native Android guest development. That lane can return after either:

- a verified reusable FVP product archive is available, or
- a sufficiently large self-hosted build machine is connected.

A direct AOSP guest would remove the Linux-container and scrcpy layers, but it is not allowed to block the current no-JIT physical-device test.

## Optional JIT acceleration

LocalDevVPN and StikDebug work remains an optional acceleration lane. It may replace UTM SE only after executable ARM64 code generation is proven repeatedly on the exact iOS 27 device.

## Runtime boundaries

- no Hypervisor.framework on iPhone,
- no Cuttlefish/KVM dependency,
- no x86 Android guest,
- no x86-only APK translation requirement,
- no bundled Google Play Store or proprietary Google Mobile Services,
- no integrity, DRM, banking or anti-cheat bypasses.

## Distribution

The active artifact is:

```text
Android-iOSEmulator-Redroid13-ARM64-SE-NoJIT-unsigned.ipa
```

GitHub publishes the unsigned IPA only after CI validation. Physical-device boot remains unproven until the Gate SE-1 through SE-3 tests pass on the iPhone 16.
