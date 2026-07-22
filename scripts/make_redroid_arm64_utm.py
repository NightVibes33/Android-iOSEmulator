#!/usr/bin/env python3
"""Create an ARM64 UTM SE bundle for the prebuilt Redroid Linux guest."""

from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import sys
import uuid
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--guest-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def drive(name: str, path: str, image_type: str, interface: str = "none") -> dict[str, object]:
    return {
        "DriveName": name,
        "ImagePath": path,
        "ImageType": image_type,
        "InterfaceType": interface,
        "Removable": False,
    }


def build_config() -> dict[str, object]:
    cmdline = " ".join(
        (
            "root=/dev/vda",
            "rw",
            "rootwait",
            "rootfstype=ext4",
            "console=tty0",
            "console=ttyAMA0",
            "earlycon=pl011,0x09000000",
            "systemd.show_status=auto",
            "systemd.log_target=console",
            "loglevel=3",
            "quiet",
        )
    )
    return {
        "ConfigurationVersion": 2,
        "System": {
            "Architecture": "aarch64",
            "CPU": "max",
            "CPUFlags": [],
            "Memory": 2048,
            "CPUCount": 2,
            "Target": "virt",
            "BootDevice": "disk",
            "BootUefi": False,
            "RngEnabled": True,
            "JITCacheSize": 64,
            "ForceMulticore": False,
            "AddArgs": [f'-append "{cmdline}"', "-no-reboot"],
            "SystemUUID": str(uuid.UUID("f50ff673-d5cf-4be6-b04a-dcc68cf685ab")),
            "MachineProperties": "highmem=off",
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
            "DisplayCard": "virtio-gpu-pci",
            "ConsoleTheme": "Default",
            "ConsoleTextColor": "#ffffff",
            "ConsoleBackgroundColor": "#000000",
            "ConsoleFont": "Menlo-Regular",
            "ConsoleFontSize": 12,
            "ConsoleBlink": False,
            "ConsoleResizeCommand": "",
        },
        "Input": {"InputLegacy": False, "InputInvertScroll": False},
        "Networking": {
            "NetworkMode": "emulated",
            "IsolateGuest": False,
            "NetworkCard": "virtio-net-pci-non-transitional",
            "NetworkCardMAC": "52:54:00:41:4e:44",
            "PortForward": [],
        },
        "Printing": {},
        "Sound": {"SoundEnabled": False, "SoundCard": ""},
        "Sharing": {
            "ClipboardSharing": False,
            "DirectorySharing": False,
            "DirectoryReadOnly": True,
            "DirectoryName": "",
            "Usb3Support": False,
            "UsbRedirectMax": 0,
        },
        "Drives": [
            drive("kernel", "kernel", "kernel"),
            drive("initrd", "initrd.img", "initrd"),
            drive("rootfs", "redroid-arm64-rootfs.raw", "disk", "virtio"),
        ],
        "Debug": {"DebugLog": False, "IgnoreAllConfiguration": False},
        "Info": {
            "IconCustom": False,
            "Notes": (
                "No-JIT ARM64 Android stack: custom BinderFS Linux kernel, "
                "Redroid 13 arm64-only runtime, and automatic Weston/scrcpy display."
            ),
        },
    }


def main() -> int:
    args = parse_args()
    source = args.guest_dir.resolve()
    output = args.output.resolve()
    required = ("kernel", "initrd.img", "redroid-arm64-rootfs.raw", "build-manifest.txt")
    missing = [item for item in required if not (source / item).is_file()]
    if missing:
        raise FileNotFoundError("missing Redroid guest artifacts: " + ", ".join(missing))

    if output.exists():
        shutil.rmtree(output)
    images = output / "Images"
    images.mkdir(parents=True)
    for item in required:
        source_path = source / item
        destination_path = images / item
        if item == "redroid-arm64-rootfs.raw":
            try:
                os.link(source_path, destination_path)
            except OSError:
                shutil.copy2(source_path, destination_path)
        else:
            shutil.copy2(source_path, destination_path)

    config_path = output / "config.plist"
    with config_path.open("wb") as stream:
        plistlib.dump(build_config(), stream, fmt=plistlib.FMT_XML, sort_keys=False)

    with config_path.open("rb") as stream:
        config = plistlib.load(stream)
    assert config["System"]["Architecture"] == "aarch64"
    assert config["System"]["Target"] == "virt"
    assert config["System"]["CPU"] == "max"
    assert config["System"]["MachineProperties"] == "highmem=off"
    assert config["Display"]["DisplayCard"] == "virtio-gpu-pci"
    assert [drive["ImageType"] for drive in config["Drives"]] == ["kernel", "initrd", "disk"]
    print(f"Created no-JIT ARM64 Redroid UTM bundle: {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
