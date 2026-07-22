# Current committed FVP plan

## Product contract

Android iOSEmulator is a sideload-first native iOS application. Its First Best Version runs a compatible ARM64 Android guest locally, installs user-provided APK/APKS/XAPK packages, preserves app data, and provides native iOS touch, audio, networking, files, keyboard, mouse, controller, rotation, diagnostics, and snapshot integration.

The product does not depend on App Store distribution and does not use a cloud Android machine as its primary runtime.

## Active no-JIT execution chain

```text
Development- or ad-hoc-signed Android iOSEmulator ARM64 SE
        ↓
LiveContainer imports the guest with isJITNeeded=false
        ↓
UTM SE qemu-aarch64-softmmu interpreter
        ↓
QEMU virt,mte=on + CPU=max
        ↓
Direct ARM64 kernel + combined initramfs boot
        ↓
Official AOSP FVP system-qemu + userdata images on raw VirtIO disks
```

This lane is designed for devices where JIT cannot currently be enabled. It uses no x86 guest, no GRUB, no ISO installer, no Hypervisor.framework, and no Cuttlefish/KVM dependency.

UTM SE remains much slower than normal JIT-enabled UTM. The no-JIT lane is therefore a compatibility and feasibility path, not a claim that full Android will already be fast.

## No-JIT hard gates

### Gate SE-0 — Artifact contract

Exit requirements:

- official AOSP FVP product output is SHA-256 verified,
- required images are `kernel`, `combined-ramdisk.img`, `system-qemu.img`, and `userdata.img`,
- final guest architecture is `aarch64`,
- final QEMU target is `virt,mte=on`,
- `qemu-aarch64-softmmu` is present and `qemu-x86_64-softmmu` is absent,
- LiveContainer metadata contains `isJITNeeded=false`,
- system and userdata runtime disks are sparse raw images,
- the VM boots directly from the kernel and initramfs.

### Gate SE-1 — ARM64 shell

- package `fvp_mini-userdebug`,
- boot on the actual target iPhone,
- verify kernel, init, ADB/serial shell and clean shutdown,
- repeat cold boot at least three times,
- record time to first Android shell and any iOS memory-pressure termination.

Exit requirement: repeatable local ARM64 Android shell without JIT.

### Gate SE-2 — Android System UI

- package `fvp-userdebug`,
- verify Zygote, System Server and SurfaceFlinger,
- verify VirtIO GPU output and touch input,
- preserve userdata across relaunch,
- confirm the app survives long enough to reach a usable launcher.

Exit requirement: Android reaches System UI and preserves data on the physical iPhone.

### Gate SE-3 — APK platform

- implement native APK/APKS/XAPK inspection,
- detect ABI, minimum SDK, splits, permissions, and signatures,
- transfer packages through VirtIO serial,
- install through Android PackageInstaller sessions,
- launch, update, force-stop, and uninstall packages,
- expose installed apps as native iOS library cards.

Exit requirement: representative ARM64 apps install, launch, and retain data.

### Gate SE-4 — Device integration

- multitouch and pointer IDs,
- hardware keyboard, mouse, and controllers,
- Android audio output and microphone bridge,
- files, clipboard, orientation, and dynamic resolution,
- QEMU user-mode networking,
- iOS lifecycle and memory-pressure recovery.

Exit requirement: normal Android apps are usable without developer controls.

### Gate SE-5 — First Best Version

- adaptive frame pacing and thermals,
- multiple isolated Android instances,
- clean snapshots and cloning,
- startup recovery and diagnostic bundles,
- compatibility reporting,
- optional switch to JIT acceleration when a reliable iOS 27 method is available.

## Fast-boot profile

The host profile is intentionally conservative for UTM SE:

- one vCPU and 1536 MiB for `fvp_mini`,
- two vCPUs and 2048 MiB for full System UI,
- raw system and userdata disks,
- UTM debug logging disabled,
- sound and USB redirection disabled until the base boot is proven,
- no bootloader or installer stage.

The official AOSP FVP product configuration remains responsible for guest-side optimizations such as disabled boot animation and host-side dex optimization.

## Optional JIT acceleration lane

The JIT work remains available but no longer blocks no-JIT testing:

```text
Development-signed Android iOSEmulator
        ↓
LocalDevVPN loopback route
        ↓
StikDebug/debugserver attachment
        ↓
Executable-region preparation
        ↓
UTM-derived QEMU ARM64 TCG JIT runtime
```

The optional lane must still prove generated ARM64 code execution on the actual device before it can replace UTM SE.

## Runtime boundaries

- There is no Hypervisor.framework dependency on iPhone.
- Cuttlefish host infrastructure is not embedded because it requires Linux/KVM.
- The Android guest is ARM64-first.
- x86-only APK translation is not an FVP requirement.
- Google Play Store and proprietary Google Mobile Services are not bundled.
- The project does not bypass integrity, DRM, banking, or anti-cheat checks.

## Distribution

Two artifacts are planned:

- `Android-iOSEmulator-AOSP-FVP-ARM64-SE-NoJIT-mini-unsigned.ipa` — shell validation and diagnostics.
- `Android-iOSEmulator-AOSP-FVP-ARM64-SE-NoJIT-full-unsigned.ipa` — full Android System UI validation.

An optional JIT IPA may return later only after the iOS 27 executable-memory path is proven. GitHub publishes unsigned IPA artifacts; users sign them with a compatible certificate.
