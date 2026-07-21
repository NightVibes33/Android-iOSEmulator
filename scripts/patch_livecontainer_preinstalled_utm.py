#!/usr/bin/env python3
"""Patch LiveContainer so a bundled UTM SE app is copied into its app library.

The UTM app is injected into the final archive after LiveContainer compiles. On the
first host launch this patch copies it into Documents/Applications where the normal
LiveContainer discovery, signing, container, and launch paths can manage it.
"""

from pathlib import Path
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_livecontainer_preinstalled_utm.py <LiveContainer checkout>", file=sys.stderr)
        return 2

    root = Path(sys.argv[1]).resolve()
    target = root / "LiveContainerSwiftUI/App/LiveContainerSwiftUIApp.swift"
    source = target.read_text(encoding="utf-8")

    struct_marker = "struct LiveContainerSwiftUIApp : SwiftUI.App {\n"
    helper = '''struct LiveContainerSwiftUIApp : SwiftUI.App {\n    private static func installBundledUTMIfNeeded(fileManager fm: FileManager) {\n        let destination = LCPath.bundlePath.appendingPathComponent("UTM SE.app", isDirectory: true)\n        guard !fm.fileExists(atPath: destination.path) else { return }\n        guard let resourceRoot = Bundle.main.resourceURL else {\n            NSLog("[Android iOSEmulator] Missing application resource directory")\n            return\n        }\n        let source = resourceRoot\n            .appendingPathComponent("PreinstalledApps", isDirectory: true)\n            .appendingPathComponent("UTM SE.app", isDirectory: true)\n        guard fm.fileExists(atPath: source.path) else {\n            NSLog("[Android iOSEmulator] Bundled UTM SE guest is missing")\n            return\n        }\n\n        do {\n            try fm.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)\n            try fm.copyItem(at: source, to: destination)\n            UserDefaults.standard.set(false, forKey: "LCShowWelcomeMessage")\n            NSLog("[Android iOSEmulator] Installed bundled UTM SE guest")\n        } catch {\n            NSLog("[Android iOSEmulator] Failed to install bundled UTM SE: \\(error)")\n        }\n    }\n'''

    if struct_marker not in source:
        raise RuntimeError("LiveContainer app struct marker not found; upstream changed")
    source = source.replace(struct_marker, helper, 1)

    init_marker = "    init() {\n        let fm = FileManager()\n"
    init_replacement = "    init() {\n        let fm = FileManager()\n        Self.installBundledUTMIfNeeded(fileManager: fm)\n"
    if init_marker not in source:
        raise RuntimeError("LiveContainer init marker not found; upstream changed")
    source = source.replace(init_marker, init_replacement, 1)

    target.write_text(source, encoding="utf-8")
    print(f"Patched {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
