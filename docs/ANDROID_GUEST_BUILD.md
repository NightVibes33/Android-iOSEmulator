# Android guest build

The full IPA packages three layers:

1. LiveContainer 3.7.2 provides the complete iPhone/iPad UI, app library, search, settings, data containers and launch flow.
2. UTM SE 5.0.2 provides the no-JIT QEMU threaded-interpreter runtime.
3. Android-x86 9.0-r2 provides the first complete bootable Android guest.

## First-launch layout

LiveContainer installs the nested UTM SE app as `Documents/Applications/Android Runtime.app` and writes `LCAppInfo.plist` so its default container is `AndroidRuntimeData`.

The mapped UTM home contains:

```text
Data/Application/AndroidRuntimeData/
├── LCContainerInfo.plist
└── Documents/
    └── Android.utm/
        ├── config.plist
        └── Images/
            ├── android-x86_64-9.0-r2.iso
            └── android-data.qcow2
```

UTM opens with the Android VM already visible. The ISO is first in the drive order and presents the Android-x86 live/installer menu. The 8 GiB qcow2 disk is writable and intended for persistent installation.

## Limits that remain

- Android-x86 is x86_64 and therefore uses full CPU emulation on ARM iPhones.
- UTM SE uses a threaded interpreter without JIT, so boot and installation will be slow.
- CI verifies package structure, checksums, executables, plist validity and the qcow2 image. CI cannot prove that Android reaches its graphical launcher on a physical iPhone.
- The modern ARM64 AOSP guest replaces Android-x86 only after this first complete boot path is proven on-device.

The build manifest must continue to state that physical-device Android boot verification is pending until a real-device test produces boot logs or a launcher screenshot.
