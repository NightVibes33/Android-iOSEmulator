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
    intermediate_lookup = '''            let candidates = sharedModel.apps + sharedModel.hiddenApps
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
    final_lookup = '''            let candidates = sharedModel.apps + sharedModel.hiddenApps
            var matchedRuntime: LCAppModel?
            for candidate in candidates {
                let candidateName = candidate.appInfo.displayName()
                if candidate.appInfo.relativeBundlePath == "Android Runtime.app" ||
                    candidateName.localizedCaseInsensitiveContains("UTM SE") ||
                    candidateName.localizedCaseInsensitiveContains("Android Runtime") {
                    matchedRuntime = candidate
                    break
                }
            }
            guard let runtime = matchedRuntime else {
                throw "Android Runtime is missing. Reinstall the full Android iOSEmulator build."
            }
'''

    if final_lookup not in text:
        if intermediate_lookup in text:
            text = text.replace(intermediate_lookup, final_lookup, 1)
        elif old_lookup in text:
            text = text.replace(old_lookup, final_lookup, 1)
        else:
            raise SystemExit("Could not find Android runtime lookup block")

    old_launch = '''            androidAPKStore.updateStatus(for: app.id, status: "Launching Android runtime…")
            let launchURL = "androidiosemulator://install?request=\(request.requestID.uuidString)&apk=\(app.id.uuidString)"
            try await runtime.runApp(
                containerFolderName: container.folderName,
                urlStr: launchURL,
                forceJIT: false
            )
'''
    new_launch = '''            androidAPKStore.updateStatus(for: app.id, status: "Launching Android runtime…")
            try await runtime.runApp(
                containerFolderName: container.folderName,
                forceJIT: false
            )
'''
    if new_launch not in text:
        if old_launch not in text:
            raise SystemExit("Could not find Android runtime launch block")
        text = text.replace(old_launch, new_launch, 1)

    path.write_text(text)


if __name__ == "__main__":
    main()
