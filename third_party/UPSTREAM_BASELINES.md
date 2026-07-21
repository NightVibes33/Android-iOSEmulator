# Upstream baselines

This project uses two upstream projects for separate purposes. They are not interchangeable.

## LiveContainer application-shell reference

- Repository: `LiveContainer/LiveContainer`
- Pinned reference reviewed for this conversion: `e370a92dfc03ce109ebce00ed4a7cfc64ad1c801`
- License: Apache License 2.0
- Reused concepts: responsive iPhone/iPad app library, package importing, persistent app metadata, native settings and file-sharing flows.
- Not reused as an Android runtime: LiveContainer loads patched iOS Mach-O executables. APK/DEX/Android ELF execution requires the separate emulator runtime below.

## UTM/QEMU SE runtime target

- Repository: `utmapp/UTM`
- Pinned integration target: `fb61bfe86a2cc39bb3bc884636fa55414f317acb`
- Runtime mode: threaded interpreter / SE, without JIT.
- Required exported host ABI:
  - `android_qemu_se_start`
  - `android_qemu_se_stop`
  - `android_guest_install_and_launch`
- Required guest assets under the application bundle's `GuestAssets` directory:
  - `Image`
  - `initramfs.img`
  - `system.img`
  - `userdata.img`
  - optional `vendor.img`

## Licensing boundary

The application shell is original project code informed by LiveContainer's public UX architecture. Any source later copied from LiveContainer must preserve Apache-2.0 notices.

UTM/QEMU-derived runtime code must preserve its applicable GPL/LGPL notices and source-availability obligations. Runtime binaries and guest images must not be committed until their redistribution terms and exact source revisions are recorded.
