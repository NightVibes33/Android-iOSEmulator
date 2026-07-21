#!/usr/bin/env python3
"""Create a deterministic UTM SE bundle for a preinstalled Android 13 disk."""

from __future__ import annotations

import argparse
import plistlib
import shutil
import sys
from pathlib import Path


def build_config(disk_name: str) -> dict[str, object]:
    return {
        "ConfigurationVersion": 2,
        "System": {
            "Architecture": "x86_64",
            # UTM omits -cpu entirely for an x86_64 guest on an ARM iPhone when
            # this is "default". QEMU then falls back to qemu64, which does not
            # reliably expose the SSE4.2 capability required by BlissOS 16.
            # The TCG "max" model exposes all instructions implemented by this
            # QEMU build, including SSE4.2, without depending on host passthrough.
            "CPU": "max",
            "CPUFlags": [],
            "Memory": 3072,
            "CPUCount": 2,
            "Target": "q35",
            "BootDevice": "disk",
            "BootUefi": True,
            "RngEnabled": True,
            "JITCacheSize": 0,
            "ForceMulticore": False,
            "AddArgs": [],
            "SystemUUID": "a42c3eba-4ff8-4ceb-a28c-95bc21e4d785",
            "MachineProperties": "vmport=off",
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
        "Input": {"InputLegacy": False, "InputInvertScroll": False},
        "Networking": {
            "NetworkMode": "emulated",
            "IsolateGuest": False,
            "NetworkCard": "rtl8139",
            "NetworkCardMAC": "52:54:00:12:34:56",
            "PortForward": [],
        },
        "Printing": {},
        "Sound": {"SoundEnabled": True, "SoundCard": "AC97"},
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
                "DriveName": "androiddisk",
                "ImagePath": disk_name,
                "ImageType": "disk",
                "InterfaceType": "ide",
                "Removable": False,
            }
        ],
        "Debug": {"DebugLog": True, "IgnoreAllConfiguration": False},
        "Info": {
            "IconCustom": False,
            "Notes": (
                "Preinstalled BlissOS 16 / Android 13 guest. Boots from the "
                "bundled persistent disk with no installer ISO or debug shell. "
                "Uses QEMU TCG CPU=max so BlissOS receives SSE4.2."
            ),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--disk", required=True, type=Path)
    args = parser.parse_args()

    if not args.disk.is_file():
        parser.error(f"preinstalled disk does not exist: {args.disk}")

    bundle = args.output.resolve()
    images = bundle / "Images"
    if bundle.exists():
        shutil.rmtree(bundle)
    images.mkdir(parents=True)

    destination_disk = images / args.disk.name
    shutil.copy2(args.disk, destination_disk)

    with (bundle / "config.plist").open("wb") as stream:
        plistlib.dump(
            build_config(destination_disk.name),
            stream,
            fmt=plistlib.FMT_XML,
            sort_keys=False,
        )

    with (bundle / "config.plist").open("rb") as stream:
        decoded = plistlib.load(stream)
    assert decoded["System"]["Architecture"] == "x86_64"
    assert decoded["System"]["CPU"] == "max"
    assert decoded["System"]["Target"] == "q35"
    assert decoded["System"]["UseHypervisor"] is False
    assert decoded["System"]["BootDevice"] == "disk"
    assert len(decoded["Drives"]) == 1
    assert decoded["Drives"][0]["ImageType"] == "disk"
    assert destination_disk.is_file()
    print(f"Created preinstalled Android 13 UTM bundle: {bundle}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
