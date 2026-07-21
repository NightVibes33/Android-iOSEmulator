# Android-x86 boot baseline

The first bootable Android guest uses the official Android-x86 9.0-r2 x86_64 release.

- Source: Android-x86 official SourceForge release
- Filename: `android-x86_64-9.0-r2.iso`
- SHA-1: `1cc85b5ed7c830ff71aecf8405c7281a9c995aa0`
- Guest architecture: x86_64
- Machine: QEMU q35
- Execution: UTM SE threaded interpreter (no JIT)
- RAM: 2048 MiB
- CPUs: 2
- Persistent disk: 8 GiB qcow2

This image is selected because it is a complete bootable Android OS with documented QEMU support. It is not the final modern ARM64 AOSP target. Android performance under UTM SE on an iPhone is expected to be slow.
