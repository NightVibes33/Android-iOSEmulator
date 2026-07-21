#!/usr/bin/env python3
"""Package an official AOSP FVP ARM64 product output as a UTM QEMU bundle."""

from __future__ import annotations

import argparse
import plistlib
import shutil
import sys
import uuid
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--product-out", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--variant", choices=("mini", "full"), default="mini")
    parser.add_argument("--system-image-name", default="system-qemu.img")
    parser.add_argument("--userdata-image-name", default="userdata.img")
    return parser.parse_args()


def require_product_out(product_out: Path, system_name: str, userdata_name: str) -> None:
    required_files = ("kernel", "combined-ramdisk.img", system_name, userdata_name)
    missing = [name for name in required_files if not (product_out / name).is_file()]
    if missing:
        formatted = ", ".join(missing)
        raise FileNotFoundError(f"AOSP FVP product output is missing: {formatted}")


def drive(name: str, image_path: str, image_type: str, interface: str = "none") -> dict[str, object]:
    return {
        "DriveName": name,
        "ImagePath": image_path,
        "ImageType": image_type,
        "InterfaceType": interface,
        "Removable": False,
    }


def build_config(system_name: str, userdata_name: str, variant: str) -> dict[str, object]:
    memory_mib = 2048 if variant == "mini" else 4096
    kernel_command_line = " ".join(
        (
            "console=ttyAMA0",
            "earlyprintk=ttyAMA0",
            "androidboot.hardware=qemu",
            "androidboot.boot_devices=a003e00.virtio_mmio",
            "androidboot.serialno=ANDROIDIOSEMULATOR",
            "loglevel=7",
        )
    )

    return {
        "ConfigurationVersion": 2,
        "System": {
            "Architecture": "aarch64",
            "CPU": "max",
            "CPUFlags": [],
            "Memory": memory_mib,
            "CPUCount": 2,
            "Target": "virt",
            "BootDevice": "disk",
            "BootUefi": False,
            "RngEnabled": True,
            "JITCacheSize": 1024,
            "ForceMulticore": False,
            "AddArgs": [
                f'-append "{kernel_command_line}"',
                "-no-reboot",
            ],
            "SystemUUID": str(uuid.UUID("95db9a58-caa9-4b1e-96e0-0a52ea7bad84")),
            "MachineProperties": "mte=on",
            "UseHypervisor": False,
            "RTCUseLocalTime": False,
            "ForcePS2Controller": False,
        },
        "Display": {
            "ConsoleOnly": variant == "mini",
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
            "DisplayCard": "virtio-gpu-pci",
        },
        "Input": {"InputLegacy": False, "InputInvertScroll": False},
        "Networking": {
            "NetworkMode": "emulated",
            "IsolateGuest": False,
            "NetworkCard": "virtio-net-pci-non-transitional",
            "NetworkCardMAC": "52:54:00:41:52:4d",
            "PortForward": [],
        },
        "Printing": {},
        "Sound": {"SoundEnabled": False, "SoundCard": ""},
        "Sharing": {
            "ClipboardSharing": False,
            "DirectorySharing": False,
            "DirectoryReadOnly": True,
            "DirectoryName": "",
            "Usb3Support": True,
            "UsbRedirectMax": 0,
        },
        "Drives": [
            drive("kernel", "kernel", "kernel"),
            drive("initrd", "combined-ramdisk.img", "initrd"),
            drive("system", system_name, "disk", "virtio"),
            drive("userdata", userdata_name, "disk", "virtio"),
        ],
        "Debug": {"DebugLog": True, "IgnoreAllConfiguration": False},
        "Info": {
            "IconCustom": False,
            "Notes": (
                "Official AOSP FVP ARM64 product output adapted to QEMU virt. "
                f"Variant: {variant}. No x86 guest translation is used."
            ),
        },
    }


def main() -> int:
    args = parse_args()
    product_out = args.product_out.resolve()
    bundle = args.output.resolve()
    require_product_out(product_out, args.system_image_name, args.userdata_image_name)

    if bundle.exists():
        shutil.rmtree(bundle)
    images = bundle / "Images"
    images.mkdir(parents=True)

    shutil.copy2(product_out / "kernel", images / "kernel")
    shutil.copy2(product_out / "combined-ramdisk.img", images / "combined-ramdisk.img")
    shutil.copy2(product_out / args.system_image_name, images / args.system_image_name)
    shutil.copy2(product_out / args.userdata_image_name, images / args.userdata_image_name)

    config = build_config(args.system_image_name, args.userdata_image_name, args.variant)
    config_path = bundle / "config.plist"
    with config_path.open("wb") as stream:
        plistlib.dump(config, stream, fmt=plistlib.FMT_XML, sort_keys=False)

    with config_path.open("rb") as stream:
        decoded = plistlib.load(stream)
    assert decoded["System"]["Architecture"] == "aarch64"
    assert decoded["System"]["CPU"] == "max"
    assert decoded["System"]["Target"] == "virt"
    assert decoded["System"]["MachineProperties"] == "mte=on"
    assert decoded["Display"]["DisplayCard"] == "virtio-gpu-pci"
    assert [entry["ImageType"] for entry in decoded["Drives"]] == [
        "kernel",
        "initrd",
        "disk",
        "disk",
    ]
    for required in ("kernel", "combined-ramdisk.img", args.system_image_name, args.userdata_image_name):
        assert (images / required).is_file()

    print(f"Created AOSP FVP ARM64 UTM bundle: {bundle}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
