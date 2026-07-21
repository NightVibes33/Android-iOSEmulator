#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: fix_livecontainer_apk_flow_compile.py <LCAppListView.swift>")

    path = Path(sys.argv[1])
    text = path.read_text()

    text = text.replace(
        "private struct AndroidAPKRecord: Codable, Identifiable, Hashable {",
        "struct AndroidAPKRecord: Codable, Identifiable, Hashable {",
        1,
    )
    text = text.replace(
        "private struct AndroidInstallRequest: Codable {",
        "struct AndroidInstallRequest: Codable {",
        1,
    )

    old_lookup = '''            let candidates = sharedModel.apps + sharedModel.hiddenApps
            guard let runtime = candidates.first(where: { model in
                model.appInfo.relativeBundlePath == "Android Runtime.app" ||
                model.displayName.localizedCaseInsensitiveContains("UTM SE") ||
                model.displayName.localizedCaseInsensitiveContains("Android Runtime")
            }) else {
                throw "Android Runtime is missing. Reinstall the full Android iOSEmulator build."
            }
'''
    new_lookup = '''            let candidates = sharedModel.apps + sharedModel.hiddenApps
            var matchedRuntime: LCAppModel?
            for candidate in candidates {
                if candidate.appInfo.relativeBundlePath == "Android Runtime.app" ||
                    candidate.displayName.localizedCaseInsensitiveContains("UTM SE") ||
                    candidate.displayName.localizedCaseInsensitiveContains("Android Runtime") {
                    matchedRuntime = candidate
                    break
                }
            }
            guard let runtime = matchedRuntime else {
                throw "Android Runtime is missing. Reinstall the full Android iOSEmulator build."
            }
'''

    if old_lookup not in text:
        if new_lookup not in text:
            raise SystemExit("Could not find Android runtime lookup block")
    else:
        text = text.replace(old_lookup, new_lookup, 1)

    path.write_text(text)


if __name__ == "__main__":
    main()
