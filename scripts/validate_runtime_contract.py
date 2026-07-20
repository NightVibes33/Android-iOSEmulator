#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
required = [
    ROOT / "AndroidiOSEmulator/Runtime/RuntimeState.swift",
    ROOT / "AndroidiOSEmulator/Runtime/RuntimeGate.swift",
    ROOT / "AndroidiOSEmulator/Runtime/GuestAssetManifest.swift",
    ROOT / "runtime/qemu/PINNED_BASELINE.md",
    ROOT / "runtime/android/guest-manifest.example.json",
]
missing = [str(path.relative_to(ROOT)) for path in required if not path.exists()]
if missing:
    raise SystemExit(f"Missing runtime contracts: {', '.join(missing)}")

manifest = json.loads((ROOT / "runtime/android/guest-manifest.example.json").read_text())
assert manifest["schemaVersion"] == 1
assert manifest["architecture"] == "arm64"
assert manifest["machine"] == "virt"
roles = {item["role"] for item in manifest["assets"]}
assert {"kernel", "initramfs"}.issubset(roles)

qemu_contract = (ROOT / "runtime/qemu/PINNED_BASELINE.md").read_text()
for token in ["aarch64-softmmu", "TCG", "split-WX", "TCTI"]:
    if token not in qemu_contract:
        raise SystemExit(f"QEMU contract is missing {token}")

print("Gate 1 runtime contracts validated.")
