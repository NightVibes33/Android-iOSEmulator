#!/usr/bin/env python3
"""Patch an extracted Android iOSEmulator app for a visible UTM display."""

from __future__ import annotations

import plistlib
import shlex
import sys
from pathlib import Path

NEW_BUNDLE_ID = "com.nightvibes33.androidiosemulator.redroid.arm64.se.visible"
NEW_DATA_UUID = "AndroidRedroidArm64SEVisibleData"
BUILD_MARKER = "redroid13-arm64-se-lowstorage-visible-v1"
VM_NAME = "Android-Redroid-ARM64-SE.utm"


def load_plist(path: Path) -> tuple[dict, plistlib.PlistFormat]:
    raw = path.read_bytes()
    fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist00") else plistlib.FMT_XML
    return plistlib.loads(raw), fmt


def save_plist(path: Path, value: dict, fmt: plistlib.PlistFormat) -> None:
    path.write_bytes(plistlib.dumps(value, fmt=fmt, sort_keys=False))


def patch_kernel_append(argument: str) -> str:
    prefix = '-append "'
    if not argument.startswith(prefix) or not argument.endswith('"'):
        raise SystemExit(f"unexpected kernel append argument: {argument!r}")
    command_line = argument[len(prefix):-1]
    tokens = shlex.split(command_line)

    replacements = {
        "systemd.show_status=auto": "systemd.show_status=yes",
        "loglevel=3": "loglevel=6",
    }
    tokens = [replacements.get(token, token) for token in tokens if token != "quiet"]
    for required in (
        "console=tty0",
        "console=ttyAMA0",
        "systemd.show_status=yes",
        "systemd.log_target=console",
        "loglevel=6",
        "consoleblank=0",
        "vt.global_cursor_default=1",
    ):
        key = required.split("=", 1)[0]
        if key in {"console"}:
            if required not in tokens:
                tokens.append(required)
        elif not any(token == required or token.startswith(key + "=") for token in tokens):
            tokens.append(required)

    if "quiet" in tokens:
        raise SystemExit("quiet remained in the visible boot command line")
    return '-append "' + " ".join(tokens) + '"'


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <extracted-app-directory>")

    app = Path(sys.argv[1]).resolve()
    info_path = app / "Info.plist"
    lc_info_path = app / "LCAppInfo.plist"
    config_path = app / "PreloadedData" / VM_NAME / "config.plist"
    for path in (info_path, lc_info_path, config_path):
        if not path.is_file():
            raise FileNotFoundError(path)

    info, info_fmt = load_plist(info_path)
    old_bundle_id = info.get("CFBundleIdentifier")
    if not isinstance(old_bundle_id, str) or not old_bundle_id:
        raise SystemExit("missing original CFBundleIdentifier")
    info["CFBundleIdentifier"] = NEW_BUNDLE_ID
    info["CFBundleDisplayName"] = "Android iOSEmulator Visible"
    info["CFBundleName"] = "Android iOSEmulator Visible"
    info["AndroidVisibleDisplayBuild"] = BUILD_MARKER
    save_plist(info_path, info, info_fmt)

    lc_info, lc_fmt = load_plist(lc_info_path)
    lc_info["LCDataUUID"] = NEW_DATA_UUID
    lc_info["LCContainers"] = [
        {"folderName": NEW_DATA_UUID, "name": "Android ARM64 Visible"}
    ]
    lc_info["LCTweakFolder"] = (
        f"../Applications/{NEW_BUNDLE_ID}.app/BootstrapTweaks"
    )
    lc_info["isJITNeeded"] = False
    save_plist(lc_info_path, lc_info, lc_fmt)

    config, config_fmt = load_plist(config_path)
    display = config.setdefault("Display", {})
    old_card = display.get("DisplayCard")
    if old_card not in {"virtio-gpu-pci", "virtio-ramfb"}:
        raise SystemExit(f"unexpected original display card: {old_card!r}")
    display["ConsoleOnly"] = False
    display["DisplayCard"] = "virtio-ramfb"
    display["DisplayFitScreen"] = True
    display["DisplayRetina"] = False
    display["DisplayUpscaler"] = "linear"
    display["DisplayDownscaler"] = "linear"

    system = config.setdefault("System", {})
    add_args = list(system.get("AddArgs") or [])
    append_indexes = [i for i, value in enumerate(add_args) if isinstance(value, str) and value.startswith('-append "')]
    if len(append_indexes) != 1:
        raise SystemExit(f"expected one kernel append argument, found {len(append_indexes)}")
    index = append_indexes[0]
    add_args[index] = patch_kernel_append(add_args[index])
    system["AddArgs"] = add_args

    info_section = config.setdefault("Info", {})
    existing_notes = str(info_section.get("Notes") or "").strip()
    visible_note = (
        "Visible display build: UTM virtio-ramfb, framebuffer boot status, "
        "and fresh LiveContainer data container."
    )
    info_section["Notes"] = f"{existing_notes}\n{visible_note}".strip()
    info_section["VisibleDisplayBuild"] = BUILD_MARKER
    save_plist(config_path, config, config_fmt)

    # Re-read everything so malformed output cannot be packaged.
    verified_info, _ = load_plist(info_path)
    verified_lc, _ = load_plist(lc_info_path)
    verified_config, _ = load_plist(config_path)
    assert verified_info["CFBundleIdentifier"] == NEW_BUNDLE_ID
    assert verified_info["AndroidVisibleDisplayBuild"] == BUILD_MARKER
    assert verified_lc["LCDataUUID"] == NEW_DATA_UUID
    assert verified_lc["isJITNeeded"] is False
    assert verified_config["Display"]["DisplayCard"] == "virtio-ramfb"
    assert verified_config["Display"]["DisplayFitScreen"] is True
    append_value = next(value for value in verified_config["System"]["AddArgs"] if value.startswith('-append "'))
    assert "systemd.show_status=yes" in append_value
    assert "loglevel=6" in append_value
    assert "consoleblank=0" in append_value
    assert " quiet " not in f" {append_value} "

    print(f"Patched display card: {old_card} -> virtio-ramfb")
    print(f"Patched bundle identifier: {old_bundle_id} -> {NEW_BUNDLE_ID}")
    print(f"Fresh data container: {NEW_DATA_UUID}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
