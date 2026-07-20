# Android iOSEmulator

A sideload-first, native iOS project for running a compatible ARM64 Android guest locally through a QEMU/UTM-derived runtime.

## Current milestone: Gate 0 — JITProbe

This repository intentionally starts with the hardest dependency: proving reliable executable-memory preparation on a real iPhone or iPad using **LocalDevVPN + StikDebug** on iOS 26/27.

The current IPA is a real-device diagnostic build. It does **not** boot Android yet. It verifies:

- the app was signed for debugging (`get-task-allow`),
- LocalDevVPN exposes the local device route,
- the StikDebug shortcut can attach to this app,
- a split read/write + read/execute ARM64 mapping can execute generated code,
- diagnostic output can be exported for failures such as `E96`.

## Build

GitHub Actions uses the official `macos-26` Apple Silicon runner and packages an **unsigned real-device IPA**. The IPA must be signed after download with a development provisioning profile that preserves `get-task-allow`.

Run locally on macOS 26:

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

This project runs user-supplied, compatible APKs inside an isolated Android guest. It will not bypass Play Integrity, DRM, banking protections, or anti-cheat systems. Google Play services are not bundled.

## Licensing

The Gate 0 source in this repository is Apache-2.0. Future QEMU/UTM-derived components will be kept in clearly separated directories with their original GPL/LGPL/Apache notices and corresponding source obligations.
