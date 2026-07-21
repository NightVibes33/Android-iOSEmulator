# Android iOSEmulator

A sideload-first native iOS project for running a compatible ARM64 Android guest locally through a QEMU/UTM-derived runtime.

## Active runtime direction

The temporary BlissOS x86_64 experiment is retired. It proved LiveContainer import and IPA packaging behavior, but it did not prove usable Android graphical boot on ARM iPhone hardware and can no longer publish releases.

The supported runtime target is now:

```text
AOSP fvp_mini-userdebug / fvp-userdebug
        ↓
ARM64 kernel + combined ramdisk
        ↓
QEMU aarch64-softmmu
        ↓
virt,mte=on + CPU=max
        ↓
VirtIO block, network, input and GPU devices
```

The new manual workflow is `.github/workflows/build-arm64-fvp-livecontainer-ipa.yml`. It accepts a SHA-256-verified AOSP FVP product-output archive containing:

- `kernel`
- `combined-ramdisk.img`
- `system-qemu.img`
- `userdata.img`

The workflow compresses the two disk images, creates an ARM64 UTM bundle, retains `qemu-aarch64-softmmu`, rejects `qemu-x86_64-softmmu`, and packages an unsigned development IPA.

## Current milestone: Gate 0 — JITProbe

The hardest dependency remains reliable executable-memory preparation on the real iPhone or iPad using **LocalDevVPN + StikDebug** on iOS 26/27.

The diagnostic IPA verifies:

- the app was signed for debugging (`get-task-allow`),
- LocalDevVPN exposes the local device route,
- StikDebug can attach to the app,
- a split read/write + read/execute ARM64 mapping can execute generated code,
- diagnostic output can be exported for failures such as `E96`.

The ARM64 packaging lane is implemented, but Android System UI boot on a physical iPhone is still a validation gate rather than a completed claim.

## Build

GitHub Actions uses the official `macos-26` Apple Silicon runner and packages unsigned real-device IPAs. The IPA must be signed after download with a development provisioning profile that preserves `get-task-allow`.

Run the Gate 0 diagnostic build locally on macOS 26:

```bash
brew install xcodegen
./scripts/build_unsigned_ipa.sh
```

Output:

```text
build/Android-iOSEmulator-unsigned.ipa
build/Android-iOSEmulator-unsigned.ipa.sha256
```

## Device setup

See [docs/DEVICE_SETUP.md](docs/DEVICE_SETUP.md). The complete architecture and hard gates are in [docs/CURRENT_PLAN.md](docs/CURRENT_PLAN.md).

## Safety and scope

This project runs user-supplied, compatible ARM64 APKs inside an isolated Android guest. It will not bypass Play Integrity, DRM, banking protections, or anti-cheat systems. Google Play services are not bundled.

## Licensing

The Gate 0 source in this repository is Apache-2.0. QEMU/UTM-derived components remain separated with their original GPL/LGPL/Apache notices and corresponding source obligations.
