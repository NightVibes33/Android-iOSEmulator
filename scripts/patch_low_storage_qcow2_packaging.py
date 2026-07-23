#!/usr/bin/env python3
"""Patch the verified ARM64 guest packager to use a compressed QCOW2 disk."""

from __future__ import annotations

import sys
from pathlib import Path


RAW_DISK = "redroid-arm64-rootfs.raw"
QCOW_DISK = "redroid-arm64-rootfs.qcow2"
RAW_IPA = "Android-iOSEmulator-Redroid13-ARM64-SE-NoJIT-unsigned.ipa"
LOW_STORAGE_IPA = "Android-iOSEmulator-Redroid13-ARM64-SE-NoJIT-LowStorage-unsigned.ipa"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected one {label} marker, found {count}")
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit(
            f"usage: {sys.argv[0]} <make-utm-script> <ipa-packager-script>"
        )

    make_path = Path(sys.argv[1])
    packager_path = Path(sys.argv[2])

    make_text = make_path.read_text()
    raw_occurrences = make_text.count(RAW_DISK)
    if raw_occurrences < 3:
        raise SystemExit(
            f"expected at least three UTM raw-disk markers, found {raw_occurrences}"
        )
    make_text = make_text.replace(RAW_DISK, QCOW_DISK)
    if RAW_DISK in make_text or QCOW_DISK not in make_text:
        raise SystemExit("failed to replace the UTM disk name")
    make_path.write_text(make_text)

    packager_text = packager_path.read_text()
    packager_text = replace_once(
        packager_text,
        f'OUTPUT_IPA="{RAW_IPA}"',
        f'OUTPUT_IPA="{LOW_STORAGE_IPA}"',
        "output IPA",
    )
    packager_text = replace_once(
        packager_text,
        f'DISK_NAME="{RAW_DISK}"',
        f'DISK_NAME="{QCOW_DISK}"',
        "root disk",
    )
    packager_text = replace_once(
        packager_text,
        "Root disk: sparse raw ext4\n",
        "Root disk: compressed writable QCOW2 containing ext4\n"
        "Low-storage package: yes\n"
        "Raw 8192 MiB extraction avoided: yes\n",
        "root disk manifest",
    )
    if RAW_IPA in packager_text or f'DISK_NAME="{RAW_DISK}"' in packager_text:
        raise SystemExit("raw package markers remain after patching")
    if LOW_STORAGE_IPA not in packager_text or QCOW_DISK not in packager_text:
        raise SystemExit("low-storage package markers are missing")
    packager_path.write_text(packager_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
