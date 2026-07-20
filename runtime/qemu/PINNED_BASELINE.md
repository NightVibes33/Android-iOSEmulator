# QEMU runtime import contract

Gate 1 will import a pinned UTM-maintained QEMU baseline only after Gate 0 passes on a physical iOS 26/27 device.

Required configuration:

- target: `aarch64-softmmu`
- machine: `virt`
- acceleration: TCG only
- one reusable split-WX TCG code cache
- iOS 26/27 StikDebug region preparation adapter
- TCTI/threaded-interpreter fallback build
- VirtIO block, net, serial, input, and initial display devices only

Every imported source revision, patch, generated file, and license must be recorded in a machine-readable lock file. No QEMU binary is accepted without reproducible source and license notices.
