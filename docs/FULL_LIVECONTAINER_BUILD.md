# Full LiveContainer frontend + UTM SE runtime build

## Product decision

Android iOSEmulator uses the actual LiveContainer application as its host frontend. This preserves LiveContainer's complete iPhone/iPad UI and UX instead of recreating a partial visual imitation.

The retained host features include:

- app-library cards and banners
- search and sorting
- file and URL importing
- per-app settings
- multiple data containers
- storage management
- native share-sheet handling
- multitasking and window UI where supported
- LiveContainer's phone and tablet layout behavior

The preloaded guest is UTM SE, which supplies QEMU's threaded-interpreter system-emulation runtime without StikDebug or another JIT service.

## Pinned upstream inputs

- LiveContainer source tag: `3.7.2`
- UTM SE release: `v5.0.2`
- UTM asset: `UTM-SE.ipa`
- Target: unsigned arm64 iPhoneOS IPA

The build script clones LiveContainer recursively, patches its existing SwiftUI startup code, compiles the real LiveContainer host, embeds UTM SE under `PreloadedApps/UTM SE.app`, and packages the combined unsigned IPA.

## First-launch behavior

Before LiveContainer scans its normal app directory, the injected bootstrap copies the bundled UTM SE application to:

```text
Documents/Applications/Android Runtime.app
```

LiveContainer then discovers it through its normal `LCAppInfo` and `LCAppModel` paths. This means the runtime appears through the same library, settings, container and launch UI as any other LiveContainer guest.

## Runtime boundary

This combined build contains a real no-JIT system emulator, but it is not yet a preconfigured Android OS image. The remaining Android-specific layer is:

1. Bundle or download a legally redistributable ARM64 Android/AOSP guest image.
2. Generate a UTM configuration for QEMU `virt` and TCTI execution.
3. Place the configuration and guest disks in the UTM SE data container during bootstrap.
4. Replace generic UTM navigation with an Android-first launch handoff where practical.
5. Add APK import-to-guest installation through a serial or network control bridge.

The build must never claim that Android booted unless UTM SE actually reaches the Android guest and returns observable boot state.

## Licensing and redistribution

LiveContainer is Apache-2.0 licensed. UTM's frontend is Apache-2.0, but its packaged runtime includes QEMU and other GPL/LGPL components. Any redistributed combined IPA must preserve notices, provide corresponding source as required, and document exact upstream revisions and local modifications.

Android guest images must be sourced and redistributed separately according to their own licenses. Google Play services and proprietary Google applications are not included.
