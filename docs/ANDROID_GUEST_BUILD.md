# Android guest build

The full product combines LiveContainer's actual UI/UX, its APK-first catalog/import flow, UTM SE's no-JIT QEMU runtime, and a preloaded Android-x86 VM.

LiveContainer creates this mapped UTM home on first launch:

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

UTM opens with Android already visible. The ISO presents the live/installer menu and the qcow2 disk provides 8 GiB for persistent installation.

CI verifies the official ISO checksum, qcow2 validity, UTM plist, LiveContainer and UTM executables, APK-flow compilation, nested VM assets, and unsigned packaging. CI cannot prove Android reaches the graphical launcher on a physical iPhone, so the manifest must report physical boot verification as pending until an on-device test succeeds.
