#!/usr/bin/env python3
"""Create a deterministic legacy UTM bundle for Android-x86.

UTM 5 still imports legacy QEMU configuration bundles and migrates them to the
current schema on first save. The legacy format is intentionally used here
because it is stable, plist-based, and can be generated without linking UTM.
"""

from __future__ import annotations

import argparse
import plistlib
import shutil
import sys
import uuid
from pathlib import Path


def build_config() -> dict[str, object]:
    return {
        "ConfigurationVersion": 2,
        "System": {
            "Architecture": "x86_64",
            "CPU": "default",
            "CPUFlags": [],
            "Memory": 2048,
            "CPUCount": 2,
            "Target": "q35",
            "BootDevice": "cd",
            "BootUefi": True,
            "RngEnabled": True,
            "JITCacheSize": 0,
            "ForceMulticore": False,
            "AddArgs": [],
            "SystemUUID": "a42c3eba-4ff8-4ceb-a28c-95bc21e4d785",
            "MachineProperties": "",
            "UseHypervisor": False,
            "RTCUseLocalTime": False,
            "ForcePS2Controller": False,
        },
        "Display": {
            "ConsoleOnly": False,
            "DisplayFitScreen": True,
            "DisplayRetina": False,
            "DisplayUpscaler": "linear",
            "DisplayDownscaler": "linear",
            "ConsoleTheme": "Default",
            "ConsoleTextColor": "#ffffff",
            "ConsoleBackgroundColor": "#000000",
            "ConsoleFont": "Menlo-Regular",
            "ConsoleFontSize": 12,
            "ConsoleBlink": True,
            "ConsoleResizeCommand": "",
            "DisplayCard": "VGA",
        },
        "Input": {
            "InputLegacy": False,
            "InputInvertScroll": False,
        },
        "Networking": {
            "NetworkMode": "emulated",
            "IsolateGuest": False,
            "NetworkCard": "rtl8139",
            "NetworkCardMAC": "52:54:00:12:34:56",
            "PortForward": [],
        },
        "Printing": {},
        "Sound": {
            "SoundEnabled": True,
            "SoundCard": "AC97",
        },
        "Sharing": {
            "ClipboardSharing": False,
            "DirectorySharing": False,
            "DirectoryReadOnly": True,
            "DirectoryName": "",
            "Usb3Support": False,
            "UsbRedirectMax": 0,
        },
        "Drives": [
            {
                "DriveName": "androidcd",
                "ImagePath": "android-x86_64-9.0-r2.iso",
                "ImageType": "cd",
                "InterfaceType": "ide",
                "Removable": False,
            },
            {
                "DriveName": "androiddisk",
                "ImagePath": "android-data.qcow2",
                "ImageType": "disk",
                "InterfaceType": "ide",
                "Removable": False,
            },
        ],
        "Debug": {
            "DebugLog": True,
            "IgnoreAllConfiguration": False,
        },
        "Info": {
            "IconCustom": False,
            "Notes": (
                "Android iOSEmulator boot guest. The ISO boots Android-x86 "
                "9.0-r2; install to the persistent disk for writable storage."
            ),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--iso", required=True, type=Path)
    parser.add_argument("--disk", required=True, type=Path)
    args = parser.parse_args()

    for path, label in ((args.iso, "ISO"), (args.disk, "persistent disk")):
        if not path.is_file():
            parser.error(f"{label} does not exist: {path}")

    bundle = args.output.resolve()
    images = bundle / "Images"
    if bundle.exists():
        shutil.rmtree(bundle)
    images.mkdir(parents=True)

    shutil.copy2(args.iso, images / "android-x86_64-9.0-r2.iso")
    shutil.copy2(args.disk, images / "android-data.qcow2")

    with (bundle / "config.plist").open("wb") as stream:
        plistlib.dump(build_config(), stream, fmt=plistlib.FMT_XML, sort_keys=False)

    # Structural validation catches accidental key/name changes before packaging.
    with (bundle / "config.plist").open("rb") as stream:
        decoded = plistlib.load(stream)
    assert decoded["System"]["Architecture"] == "x86_64"
    assert decoded["System"]["Target"] == "q35"
    assert decoded["System"]["UseHypervisor"] is False
    assert decoded["Drives"][0]["ImageType"] == "cd"
    assert decoded["Drives"][1]["ImageType"] == "disk"
    assert (images / "android-x86_64-9.0-r2.iso").is_file()
    assert (images / "android-data.qcow2").is_file()

    print(f"Created UTM bundle: {bundle}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
