# Android-x86 boot baseline

The first bootable Android guest uses the official Android-x86 9.0-r2 x86_64 release.

- Filename: `android-x86_64-9.0-r2.iso`
- SHA-1: `1cc85b5ed7c830ff71aecf8405c7281a9c995aa0`
- Guest: x86_64 / QEMU q35
- Runtime: UTM SE threaded interpreter, no JIT
- RAM: 2048 MiB
- CPUs: 2
- Persistent disk: 8 GiB qcow2

This is a complete bootable Android OS with documented QEMU support. It is the first real boot gate, not the final modern ARM64 AOSP target. Performance on an ARM iPhone under UTM SE is expected to be slow.
