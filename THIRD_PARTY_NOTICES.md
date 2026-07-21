# Third-party source and license notices

This repository's combined full build uses the following upstream projects.

## LiveContainer

- Project: `LiveContainer/LiveContainer`
- Pinned source tag: `3.7.2`
- License: Apache License 2.0
- Role: complete iOS host frontend, guest library, import flow, container management, settings, multitasking and app launch infrastructure
- Local modification: first-launch bootstrap for a bundled UTM SE guest and product branding

## UTM / QEMU runtime

- Project: `utmapp/UTM`
- Pinned release: `v5.0.2`
- Asset: `UTM-SE.ipa`
- UTM frontend license: Apache License 2.0
- Runtime components: include QEMU and other GPL/LGPL software
- Role: no-JIT threaded-interpreter full-system emulation

Redistributors must preserve all upstream notices and comply with the source-distribution requirements of the GPL/LGPL components contained in UTM SE. This notice is not a replacement for the complete license files shipped by the upstream projects.

No proprietary Google applications, Google Play services, or proprietary Android system images are included by this repository.
