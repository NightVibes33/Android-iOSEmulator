#!/usr/bin/env python3
from __future__ import annotations

import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
required = [
    ROOT / "project.yml",
    ROOT / "AndroidiOSEmulator/Config/Info.plist",
    ROOT / "AndroidiOSEmulator/Config/AndroidiOSEmulator.entitlements",
    ROOT / ".github/workflows/build-unsigned-ipa.yml",
]

missing = [str(path.relative_to(ROOT)) for path in required if not path.exists()]
if missing:
    raise SystemExit(f"Missing required files: {', '.join(missing)}")

for relative in [
    "AndroidiOSEmulator/Config/Info.plist",
    "AndroidiOSEmulator/Config/AndroidiOSEmulator.entitlements",
]:
    with (ROOT / relative).open("rb") as handle:
        plistlib.load(handle)

workflow = (ROOT / ".github/workflows/build-unsigned-ipa.yml").read_text()
build_script = (ROOT / "scripts/build_unsigned_ipa.sh").read_text()
checks = {
    "macos-26 runner": "runs-on: macos-26" in workflow,
    "unsigned build": "CODE_SIGNING_ALLOWED=NO" in build_script,
    "artifact upload": "actions/upload-artifact@v4" in workflow,
    "real-device SDK": "-sdk iphoneos" in build_script,
}

failed = [name for name, passed in checks.items() if not passed]
if failed:
    raise SystemExit(f"Repository validation failed: {', '.join(failed)}")

print("Repository structure and unsigned IPA workflow validation passed.")
