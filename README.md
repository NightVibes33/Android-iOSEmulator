# Android iOSEmulator

A sideload-first native iOS project for running a compatible ARM64 Android guest locally through a QEMU/UTM-derived runtime.

## Active runtime direction

The temporary BlissOS x86_64 experiment is retired. It proved LiveContainer import and IPA packaging behavior, but it did not prove usable Android graphical boot on ARM iPhone hardware and can no longer publish releases.

The active iOS 27 beta fallback is now:

```text
AOSP fvp_mini-userdebug / fvp-userdebug
        ↓
ARM64 kernel + combined ramdisk
        ↓
UTM SE qemu-aarch64-softmmu interpreter
        ↓
virt,mte=on + CPU=max
        ↓
Direct kernel boot + sparse raw VirtIO disks
        ↓
No JIT requirement and no x86 translation
```

UTM SE is deliberately used for this lane because it does not require JIT. It is slower than normal UTM, so physical-device boot time and full Android UI usability remain validation gates.

The manual workflow is `.github/workflows/build-arm64-fvp-livecontainer-ipa.yml`. It accepts a SHA-256-verified AOSP FVP product-output archive containing:

- `kernel`
- `combined-ramdisk.img`
- `system-qemu.img`
- `userdata.img`

The workflow creates sparse raw system and userdata disks, packages a direct-boot ARM64 UTM bundle, retains `qemu-aarch64-softmmu`, rejects `qemu-x86_64-softmmu`, verifies `isJITNeeded=false`, and packages an unsigned LiveContainer IPA.

## No-JIT speed profile

The no-JIT profile applies every host-side optimization that does not change the official AOSP FVP hardware contract:

- direct kernel/initramfs boot with no GRUB, ISO or installer,
- native ARM64 guest with no x86 instruction translation,
- one vCPU for `fvp_mini` and two vCPUs for full System UI,
- 1536 MiB for `mini` and 2048 MiB for `full`,
- sparse raw system/userdata disks instead of compressed QCOW2 runtime disks,
- disabled UTM debug logging, sound, USB redirection and console blinking.

The official AOSP FVP product configuration supplies the guest-side fast-boot settings, including disabled boot animation and host-side dex optimization.

## Current validation gates

### Gate SE-1 — ARM64 shell

Build `fvp_mini-userdebug`, package the no-JIT `mini` IPA, install it on the target iPhone, and verify that Android reaches a stable shell repeatedly.

### Gate SE-2 — Android System UI

Build `fvp-userdebug`, package the no-JIT `full` IPA, and verify that Zygote, System Server and SurfaceFlinger reach a usable Android interface without iOS memory-pressure termination.

### Optional Gate JIT

The original LocalDevVPN + StikDebug executable-memory work remains an optional acceleration lane. It is not required by the ARM64 SE IPA and does not block no-JIT testing.

The ARM64 packaging lane is implemented, but physical-device Android boot has not yet been proven.

## Build

GitHub Actions uses the official `macos-26` Apple Silicon runner and packages unsigned real-device IPAs. The no-JIT SE artifact may be signed with any signing method that can install UTM SE; it does not request JIT.

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
