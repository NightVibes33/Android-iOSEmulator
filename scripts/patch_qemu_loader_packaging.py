#!/usr/bin/env python3
"""Patch the ARM64 LiveContainer packager with early @loader_path QEMU copies."""

from __future__ import annotations

import sys
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing patch marker: {label}")
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <packager-script>")

    path = Path(sys.argv[1])
    text = path.read_text()

    text = replace_once(
        text,
        "codesign xattr ditto; do",
        "codesign xattr ditto install_name_tool; do",
        "command dependencies",
    )
    text = text.replace(
        'codesign --verify --strict "$candidate"',
        'codesign --verify --strict --ignore-resources "$candidate"',
    )
    text = text.replace(
        'codesign --verify --strict "$extracted_binary"',
        'codesign --verify --strict --ignore-resources "$extracted_binary"',
    )

    dependency_marker = (
        'otool -L "$GUEST_APP/$EXECUTABLE" > '
        '"$OUT/utm-executable-dependencies.txt"\n'
    )
    dependency_patch = dependency_marker + r'''

# LiveContainer's libarchive path can leave late framework entries absent while
# still returning success. Create independent regular-file QEMU copies beside
# the executable and relocate both strong load commands to @loader_path.
QEMU_M68K_ROOT="qemu-m68k-softmmu.dylib"
QEMU_AARCH64_ROOT="qemu-aarch64-softmmu.dylib"
cp -f "$GUEST_APP/Frameworks/qemu-m68k-softmmu.framework/qemu-m68k-softmmu" \
  "$GUEST_APP/$QEMU_M68K_ROOT"
cp -f "$GUEST_APP/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu" \
  "$GUEST_APP/$QEMU_AARCH64_ROOT"
chmod 0755 "$GUEST_APP/$QEMU_M68K_ROOT" "$GUEST_APP/$QEMU_AARCH64_ROOT"
install_name_tool \
  -change '@rpath/qemu-m68k-softmmu.framework/qemu-m68k-softmmu' \
          '@loader_path/qemu-m68k-softmmu.dylib' \
  "$GUEST_APP/$EXECUTABLE"
install_name_tool \
  -change '@rpath/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu' \
          '@loader_path/qemu-aarch64-softmmu.dylib' \
  "$GUEST_APP/$EXECUTABLE"
otool -L "$GUEST_APP/$EXECUTABLE" > "$OUT/utm-executable-dependencies-relocated.txt"
grep -Fq '@loader_path/qemu-m68k-softmmu.dylib' "$OUT/utm-executable-dependencies-relocated.txt"
grep -Fq '@loader_path/qemu-aarch64-softmmu.dylib' "$OUT/utm-executable-dependencies-relocated.txt"
! grep -Fq '@rpath/qemu-m68k-softmmu.framework/qemu-m68k-softmmu' "$OUT/utm-executable-dependencies-relocated.txt"
! grep -Fq '@rpath/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu' "$OUT/utm-executable-dependencies-relocated.txt"
'''
    text = replace_once(
        text,
        dependency_marker,
        dependency_patch,
        "QEMU dependency report",
    )

    tweak_check = (
        "grep -Fxq 'BootstrapTweaks/AndroidRedroidGuestBootstrap.dylib' "
        '"$MACHO_LIST"'
    )
    text = replace_once(
        text,
        tweak_check,
        tweak_check
        + "\ngrep -Fxq 'qemu-m68k-softmmu.dylib' \"$MACHO_LIST\""
        + "\ngrep -Fxq 'qemu-aarch64-softmmu.dylib' \"$MACHO_LIST\"",
        "root QEMU signability checks",
    )

    old_leading = (
        'leading = [root, app, app / "Info.plist", app / executable, '
        'app / "LCAppInfo.plist"]'
    )
    new_leading = "\n".join(
        [
            "leading = [",
            "    root,",
            "    app,",
            '    app / "Info.plist",',
            "    app / executable,",
            '    app / "LCAppInfo.plist",',
            '    app / "qemu-m68k-softmmu.dylib",',
            '    app / "qemu-aarch64-softmmu.dylib",',
            '    app / "Frameworks",',
            '    app / "Frameworks/qemu-m68k-softmmu.framework",',
            '    app / "Frameworks/qemu-m68k-softmmu.framework/qemu-m68k-softmmu",',
            '    app / "Frameworks/qemu-aarch64-softmmu.framework",',
            '    app / "Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu",',
            "]",
        ]
    )
    text = replace_once(text, old_leading, new_leading, "archive leading list")

    archive_marker = (
        '[[ "$(sed -n \'5p\' "$OUT/archive-entry-order.txt")" == '
        '"Payload/$APP_NAME/LCAppInfo.plist" ]]\n'
    )
    archive_patch = archive_marker + r'''[[ "$(sed -n '6p' "$OUT/archive-entry-order.txt")" == "Payload/$APP_NAME/qemu-m68k-softmmu.dylib" ]]
[[ "$(sed -n '7p' "$OUT/archive-entry-order.txt")" == "Payload/$APP_NAME/qemu-aarch64-softmmu.dylib" ]]
grep -Fxq "Payload/$APP_NAME/Frameworks/qemu-m68k-softmmu.framework/qemu-m68k-softmmu" "$OUT/archive-entry-order.txt"
grep -Fxq "Payload/$APP_NAME/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu" "$OUT/archive-entry-order.txt"
'''
    text = replace_once(
        text,
        archive_marker,
        archive_patch,
        "archive entry checks",
    )

    manifest_marker = "Removed unused QEMU frameworks: ${UTM_TRIMMED_KIB} KiB\n"
    manifest_patch = (
        "QEMU loader path: @loader_path root copies\n"
        "QEMU root copies archive entries: 6 and 7\n"
        "Original QEMU frameworks retained as fallback: yes\n"
        + manifest_marker
    )
    text = replace_once(
        text,
        manifest_marker,
        manifest_patch,
        "manifest QEMU loader contract",
    )

    path.write_text(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
