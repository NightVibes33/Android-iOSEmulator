#!/usr/bin/env python3
"""Package an official AOSP FVP ARM64 product output as a UTM QEMU bundle."""

from __future__ import annotations

import argparse
import plistlib
import shutil
import sys
import uuid
from pathlib import Path


SYSTEM_DRIVE_ID = "drivesystem"
USERDATA_DRIVE_ID = "driveuserdata"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--product-out", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--variant", choices=("mini", "full"), default="mini")
    parser.add_argument("--execution-mode", choices=("interpreter", "jit"), default="interpreter")
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


def build_config(
    system_name: str,
    userdata_name: str,
    variant: str,
    execution_mode: str,
) -> dict[str, object]:
    # Keep the no-JIT guest small enough to reduce iOS memory-pressure termination.
    memory_mib = 1536 if variant == "mini" else 2048
    cpu_count = 1 if variant == "mini" else 2
    jit_cache_mib = 64 if execution_mode == "interpreter" else 512

    # Match device/generic/goldfish/fvpbase/run_qemu rather than UTM's generic
    # ARM Linux defaults. In particular, Android identifies itself as fvpbase
    # and expects the first block device on QEMU virt's MMIO transport.
    kernel_command_line = " ".join(
        (
            "qemu=1",
            "console=ttyAMA0",
            "earlyprintk=ttyAMA0",
            "androidboot.hardware=fvpbase",
            "androidboot.boot_devices=a003e00.virtio_mmio",
            "androidboot.serialno=ANDROIDIOSEMULATOR",
            "androidboot.force_normal_boot=1",
            "printk.devkmsg=on",
            "buildvariant=userdebug",
            "loglevel=4",
            "quiet",
        )
    )

    # UTM maps its generic `virtio` drive choice to virtio-blk-pci on ARM64.
    # AOSP FVP expects virtio-blk-device (MMIO), so keep disk backends unattached
    # in the normal drive list and attach the devices explicitly here.
    qemu_arguments = [
        "-global virtio-mmio.force-legacy=false",
        f"-device virtio-blk-device,drive={SYSTEM_DRIVE_ID}",
        f"-device virtio-blk-device,drive={USERDATA_DRIVE_ID}",
        "-netdev user,id=androidnet,hostfwd=tcp::5555-:5555",
        "-device virtio-net-device,netdev=androidnet,mac=52:54:00:41:52:4d",
        "-device virtio-rng-device",
        f'-append "{kernel_command_line}"',
        "-no-reboot",
    ]

    return {
        "ConfigurationVersion": 2,
        "System": {
            "Architecture": "aarch64",
            "CPU": "max",
            "CPUFlags": [],
            "Memory": memory_mib,
            "CPUCount": cpu_count,
            "Target": "virt",
            "BootDevice": "disk",
            "BootUefi": False,
            # Disabled here because UTM otherwise adds virtio-rng-pci. The
            # AOSP-compatible MMIO RNG is attached in AddArgs.
            "RngEnabled": False,
            "JITCacheSize": jit_cache_mib,
            "ForceMulticore": False,
            "AddArgs": qemu_arguments,
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
            "ConsoleBlink": False,
            "ConsoleResizeCommand": "",
            "DisplayCard": "virtio-gpu-pci",
        },
        "Input": {"InputLegacy": False, "InputInvertScroll": False},
        # UTM's generated ARM NIC is PCI. Disable it and attach the official
        # AOSP-compatible virtio-net-device (MMIO) in AddArgs.
        "Networking": {
            "NetworkMode": "none",
            "IsolateGuest": False,
            "NetworkCard": "virtio-net-pci",
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
            "Usb3Support": False,
            "UsbRedirectMax": 0,
        },
        "Drives": [
            drive("kernel", "kernel", "kernel"),
            drive("initrd", "combined-ramdisk.img", "initrd"),
            drive("system", system_name, "disk", "none"),
            drive("userdata", userdata_name, "disk", "none"),
        ],
        # Serial logging can be re-enabled for diagnosis, but is disabled in the fast profile.
        "Debug": {"DebugLog": False, "IgnoreAllConfiguration": False},
        "Info": {
            "IconCustom": False,
            "Notes": (
                "Official AOSP FVP ARM64 product output adapted to QEMU virt. "
                f"Variant: {variant}. Execution mode: {execution_mode}. "
                "Direct kernel boot with AOSP fvpbase and VirtIO MMIO storage/network; "
                "no x86 guest translation."
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

    config = build_config(
        args.system_image_name,
        args.userdata_image_name,
        args.variant,
        args.execution_mode,
    )
    config_path = bundle / "config.plist"
    with config_path.open("wb") as stream:
        plistlib.dump(config, stream, fmt=plistlib.FMT_XML, sort_keys=False)

    with config_path.open("rb") as stream:
        decoded = plistlib.load(stream)
    assert decoded["System"]["Architecture"] == "aarch64"
    assert decoded["System"]["CPU"] == "max"
    assert decoded["System"]["Target"] == "virt"
    assert decoded["System"]["MachineProperties"] == "mte=on"
    assert decoded["System"]["RngEnabled"] is False
    assert decoded["System"]["Memory"] <= 2048
    assert decoded["System"]["CPUCount"] in (1, 2)
    assert decoded["Display"]["DisplayCard"] == "virtio-gpu-pci"
    assert decoded["Networking"]["NetworkMode"] == "none"
    assert decoded["Debug"]["DebugLog"] is False
    assert [entry["ImageType"] for entry in decoded["Drives"]] == [
        "kernel",
        "initrd",
        "disk",
        "disk",
    ]
    assert [entry["InterfaceType"] for entry in decoded["Drives"][2:]] == ["none", "none"]
    add_args = decoded["System"]["AddArgs"]
    assert any("androidboot.hardware=fvpbase" in argument for argument in add_args)
    assert any("androidboot.boot_devices=a003e00.virtio_mmio" in argument for argument in add_args)
    assert f"-device virtio-blk-device,drive={SYSTEM_DRIVE_ID}" in add_args
    assert f"-device virtio-blk-device,drive={USERDATA_DRIVE_ID}" in add_args
    assert any(argument.startswith("-device virtio-net-device") for argument in add_args)
    assert "-device virtio-rng-device" in add_args
    for required in ("kernel", "combined-ramdisk.img", args.system_image_name, args.userdata_image_name):
        assert (images / required).is_file()

    print(f"Created AOSP FVP ARM64 UTM bundle: {bundle}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
