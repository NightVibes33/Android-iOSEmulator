#!/usr/bin/env python3
from pathlib import Path

TARGET = Path('.github/workflows/build-redroid-arm64-se-livecontainer-ipa.yml')
text = TARGET.read_text(encoding='utf-8')

replacements = [
    (
        '''          TEST_DISK=.build/redroid-arm64-boot-test.raw
          QEMU_LOG=qemu-arm64-android-boot.log
          BOOT_PROPS=android-boot-properties.txt
          rm -f "$TEST_DISK" "$QEMU_LOG" "$BOOT_PROPS"
          cp --reflink=auto --sparse=always "$OUT/redroid-arm64-rootfs.raw" "$TEST_DISK"
''',
        '''          ROOT_DISK="$OUT/redroid-arm64-rootfs.raw"
          QEMU_LOG=qemu-arm64-android-boot.log
          BOOT_PROPS=android-boot-properties.txt
          rm -f "$QEMU_LOG" "$BOOT_PROPS"
          {
            echo "Redroid CI QEMU pre-launch diagnostics"
            echo "root_disk=$ROOT_DISK"
            stat "$ROOT_DISK"
            df -h
          } > "$QEMU_LOG"
''',
        'pre-launch disk setup',
    ),
    (
        '''              -drive "if=none,file=$TEST_DISK,format=raw,id=rootfs,cache=unsafe" \\
''',
        '''              -drive "if=none,file=$ROOT_DISK,format=raw,id=rootfs,cache=unsafe" \\
''',
        'QEMU root drive',
    ),
    (
        '''              -serial stdio \\
              -no-reboot >"$QEMU_LOG" 2>&1 &
''',
        '''              -serial stdio \\
              -snapshot \\
              -no-reboot >>"$QEMU_LOG" 2>&1 &
''',
        'QEMU snapshot launch',
    ),
]

for old, new, label in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'Expected exactly one {label} block, found {count}')
    text = text.replace(old, new)

for stale in ('TEST_DISK=', 'file=$TEST_DISK'):
    if stale in text:
        raise SystemExit(f'Stale snapshot-copy marker remains: {stale}')
for required in (
    'ROOT_DISK="$OUT/redroid-arm64-rootfs.raw"',
    '-snapshot \\',
    '>>"$QEMU_LOG" 2>&1 &',
    'Redroid CI QEMU pre-launch diagnostics',
):
    if required not in text:
        raise SystemExit(f'Missing required snapshot boot marker: {required}')

TARGET.write_text(text, encoding='utf-8')
print(f'Patched {TARGET} to use QEMU snapshot mode without an 8 GiB test-disk copy.')
