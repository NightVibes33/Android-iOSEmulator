# Runtime boundary

This directory intentionally contains contracts rather than copied QEMU or Android binaries.

The project remains at Gate 0 until generated ARM64 code executes repeatedly on the target iOS device. After that result is recorded, Gate 1 imports the pinned UTM/QEMU source baseline and boots a minimal ARM64 Linux guest. Android FVP assets are introduced only after Linux boot is repeatable.

Large guest images are release artifacts and are never committed directly to Git. Each package must include a versioned manifest, exact byte lengths, SHA-256 hashes, Android build fingerprint, source revision, and notices.
