# Current committed FVP plan

## Product contract

Android iOSEmulator is a sideload-first native iOS application. Its First Best Version runs a compatible ARM64 Android guest locally, installs user-provided APK/APKS/XAPK packages, preserves app data, and provides native iOS touch, audio, networking, files, keyboard, mouse, controller, rotation, diagnostics, and snapshot integration.

The product does not depend on App Store distribution and does not use a cloud Android machine as its primary runtime.

## Verified execution chain

```text
Development-signed Android iOSEmulator
        ↓
LocalDevVPN loopback route (10.7.0.0 ↔ 10.7.0.1)
        ↓
StikDebug remote-device services and debugserver attachment
        ↓
iOS 26/27 breakpoint-assisted executable-region preparation
        ↓
UTM-derived QEMU ARM64 TCG runtime
        ↓
Custom AOSP ARM64 guest
```

LocalDevVPN supplies the on-device route; it is not the JIT engine. StikDebug performs pairing, device-service discovery, debugger attachment, heartbeat handling, and target-specific JIT preparation.

## Hard gates

### Gate 0 — JIT foundation

Deliver and test the app currently in this repository.

Exit requirements:

- real-device unsigned IPA builds on `macos-26`,
- a development signer preserves `get-task-allow`,
- LocalDevVPN endpoint is reachable,
- StikDebug attaches without `E96`,
- generated ARM64 code returns the expected value repeatedly,
- diagnostics survive app relaunch and can be exported.

No full Android work is accepted until Gate 0 passes on the actual target device.

### Gate 1 — QEMU foundation

- import a pinned UTM/QEMU baseline with full license notices,
- retain only `aarch64-softmmu` and required devices,
- integrate the proven split-WX/JIT handshake,
- provide a non-JIT threaded-interpreter build,
- boot a minimal ARM64 Linux kernel on a real device.

Exit requirement: repeatable local Linux boot after the guided JIT flow.

### Gate 2 — Android foundation

- build AOSP `fvp_mini-userdebug`,
- boot shell and establish ADB/guest-agent transport,
- move to full `fvp-userdebug`,
- add persistent userdata and clean shutdown,
- create `android_iosemulator_arm64-userdebug`.

Exit requirement: Android reaches System UI and preserves data.

### Gate 3 — APK platform

- implement native APK/APKS/XAPK inspection,
- detect ABI, minimum SDK, splits, permissions, and signatures,
- transfer packages through VirtIO serial,
- install through Android PackageInstaller sessions,
- launch, update, force-stop, and uninstall packages,
- expose installed apps as native iOS library cards.

Exit requirement: representative ARM64 apps install, launch, and retain data.

### Gate 4 — Device integration

- multitouch and pointer IDs,
- hardware keyboard, mouse, and controllers,
- Android audio output and microphone bridge,
- files, clipboard, orientation, and dynamic resolution,
- QEMU user-mode networking,
- iOS lifecycle and memory-pressure recovery.

Exit requirement: normal Android apps are usable without developer controls.

### Gate 5 — First Best Version

- accelerated Android graphics through a supported VirtIO GPU host path,
- adaptive frame pacing and thermals,
- multiple isolated Android instances,
- snapshots, cloning, and disposable sessions,
- polished setup and recovery for LocalDevVPN/StikDebug,
- compatibility reporting and diagnostic bundles.

## JIT protocols

The probe supports two target-side protocols:

1. **Universal iOS 26/27 protocol** — `brk #0xf00d`, with command ID in `x16`. Region preparation uses command `1`; detach uses command `0`. Assign `universal.js` to Android iOSEmulator in StikDebug.
2. **UTM legacy protocol** — `brk #0x69`, with region address and length in `x0/x1`. Assign `UTM-Dolphin.js` in StikDebug.

The universal protocol is the FVP target. The UTM protocol remains available for isolating compatibility failures.

## Runtime boundaries

- There is no Hypervisor.framework dependency on iPhone/iPad.
- QEMU TCG performs software translation; JIT accelerates generated host code.
- Cuttlefish host infrastructure is not embedded because it requires Linux/KVM.
- The Android guest is ARM64-first. x86-only APK translation is not an FVP requirement.
- Google Play Store and proprietary Google Mobile Services are not bundled.
- The project does not bypass integrity, DRM, banking, or anti-cheat checks.

## Distribution

Two artifacts are planned:

- `Android-iOSEmulator-JIT.ipa` — development-signed after download; requires StikDebug and LocalDevVPN.
- `Android-iOSEmulator-SE.ipa` — non-JIT interpreter fallback for diagnostics and light workloads.

GitHub only publishes unsigned IPA artifacts. End users sign with their own development profile.
