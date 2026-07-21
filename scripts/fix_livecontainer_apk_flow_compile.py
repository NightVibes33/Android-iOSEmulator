#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path


def replace_required(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Could not find LiveContainer source block for {label}")
    return text.replace(old, new, 1)


def find_livecontainer_root(path: Path) -> Path:
    for parent in (path.parent, *path.parents):
        if (parent / "LiveContainer").is_dir() and (parent / "LiveContainerSwiftUI").is_dir():
            return parent
    raise SystemExit(f"Could not locate the LiveContainer checkout from {path}")


def patch_app_list(path: Path) -> None:
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
    optional_lookup = '''            let candidates = sharedModel.apps + sharedModel.hiddenApps
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
    final_lookup = '''            let candidates = sharedModel.apps + sharedModel.hiddenApps
            var matchedRuntime: LCAppModel?
            for candidate in candidates {
                let candidateName = candidate.appInfo.displayName() ?? ""
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
        if optional_lookup in text:
            text = text.replace(optional_lookup, final_lookup, 1)
        elif intermediate_lookup in text:
            text = text.replace(intermediate_lookup, final_lookup, 1)
        elif old_lookup in text:
            text = text.replace(old_lookup, final_lookup, 1)
        else:
            raise SystemExit("Could not find Android runtime lookup block")

    old_launch = r'''            androidAPKStore.updateStatus(for: app.id, status: "Launching Android runtime…")
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


def patch_preloaded_installer(root: Path) -> None:
    matches = list(root.rglob("LiveContainerSwiftUIApp.swift"))
    if not matches:
        raise SystemExit("Could not locate LiveContainerSwiftUIApp.swift")
    path = matches[0]
    text = path.read_text()

    old_method = r'''    static func installIfNeeded(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: LCPath.dataPath, withIntermediateDirectories: true)

        let installedApp = LCPath.bundlePath.appendingPathComponent(installedAppName, isDirectory: true)
        if !fileManager.fileExists(atPath: installedApp.path) {
            let bundledApp = Bundle.main.bundleURL
                .appendingPathComponent(bundledAppFolderName, isDirectory: true)
                .appendingPathComponent("\(bundledAppName).app", isDirectory: true)
            guard fileManager.fileExists(atPath: bundledApp.path) else {
                NSLog("[Android iOSEmulator] bundled UTM SE guest is missing")
                return
            }
            try fileManager.copyItem(at: bundledApp, to: installedApp)
        }

        let appInfoURL = installedApp.appendingPathComponent("LCAppInfo.plist")
'''
    new_method = r'''    private static func executableName(in appURL: URL, fileManager: FileManager) -> String? {
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
              let rawName = info["CFBundleExecutable"] as? String else {
            return nil
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        let executableURL = appURL.appendingPathComponent(name, isDirectory: false)
        guard fileManager.fileExists(atPath: executableURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return name
    }

    private static func repairUTMMetadataIfPossible(at appURL: URL, fileManager: FileManager) throws -> Bool {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        var info = (NSDictionary(contentsOf: infoURL) as? [String: Any]) ?? [:]
        let candidates = [
            info["CFBundleExecutable"] as? String,
            "UTM",
            "UTM SE",
            "UTM-SE"
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }

        var executableName: String?
        for candidate in candidates where !candidate.isEmpty {
            var isDirectory: ObjCBool = false
            let candidateURL = appURL.appendingPathComponent(candidate, isDirectory: false)
            if fileManager.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                executableName = candidate
                break
            }
        }
        guard let executableName else { return false }

        info["CFBundleExecutable"] = executableName
        if (info["CFBundleIdentifier"] as? String)?.isEmpty != false {
            info["CFBundleIdentifier"] = "com.utmapp.UTM-SE"
        }
        if (info["CFBundleName"] as? String)?.isEmpty != false {
            info["CFBundleName"] = "Android Runtime"
        }
        info["CFBundleDisplayName"] = "Android"
        let repairedData = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try repairedData.write(to: infoURL, options: .atomic)
        return true
    }

    private static func isRecoverableUTMBundle(_ appURL: URL, fileManager: FileManager) -> Bool {
        if let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
           let identifier = info["CFBundleIdentifier"] as? String,
           identifier.localizedCaseInsensitiveContains("utm") {
            return true
        }
        return ["UTM", "UTM SE", "UTM-SE"].contains { candidate in
            fileManager.fileExists(atPath: appURL.appendingPathComponent(candidate).path)
        }
    }

    static func installIfNeeded(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: LCPath.dataPath, withIntermediateDirectories: true)

        let bundledApp = Bundle.main.bundleURL
            .appendingPathComponent(bundledAppFolderName, isDirectory: true)
            .appendingPathComponent("\(bundledAppName).app", isDirectory: true)
        guard fileManager.fileExists(atPath: bundledApp.path),
              executableName(in: bundledApp, fileManager: fileManager) != nil else {
            throw NSError(
                domain: "AndroidiOSEmulator.PreloadedRuntime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The bundled UTM SE runtime is missing a valid Info.plist or executable."]
            )
        }

        let installedApp = LCPath.bundlePath.appendingPathComponent(installedAppName, isDirectory: true)
        let legacyUnknownApp = LCPath.bundlePath.appendingPathComponent("Unknown.app", isDirectory: true)

        if !fileManager.fileExists(atPath: installedApp.path),
           fileManager.fileExists(atPath: legacyUnknownApp.path),
           isRecoverableUTMBundle(legacyUnknownApp, fileManager: fileManager) {
            _ = try repairUTMMetadataIfPossible(at: legacyUnknownApp, fileManager: fileManager)
            try fileManager.moveItem(at: legacyUnknownApp, to: installedApp)
            NSLog("[Android iOSEmulator] recovered legacy Unknown.app as Android Runtime.app")
        }

        if fileManager.fileExists(atPath: installedApp.path),
           executableName(in: installedApp, fileManager: fileManager) == nil {
            let repaired = try repairUTMMetadataIfPossible(at: installedApp, fileManager: fileManager)
            if !repaired || executableName(in: installedApp, fileManager: fileManager) == nil {
                try fileManager.removeItem(at: installedApp)
            }
        }

        if !fileManager.fileExists(atPath: installedApp.path) {
            try fileManager.copyItem(at: bundledApp, to: installedApp)
        }

        guard let installedExecutable = executableName(in: installedApp, fileManager: fileManager) else {
            throw NSError(
                domain: "AndroidiOSEmulator.PreloadedRuntime",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Android Runtime.app has no valid CFBundleExecutable after recovery."]
            )
        }
        NSLog("[Android iOSEmulator] validated Android runtime executable: %@", installedExecutable)

        let appInfoURL = installedApp.appendingPathComponent("LCAppInfo.plist")
'''
    text = replace_required(text, old_method, new_method, "preloaded runtime validation")
    path.write_text(text)


def patch_lc_app_info(root: Path) -> None:
    path = root / "LiveContainerSwiftUI" / "Models" / "LCAppInfo.m"
    if not path.is_file():
        matches = list(root.rglob("LCAppInfo.m"))
        if not matches:
            raise SystemExit("Could not locate LCAppInfo.m")
        path = matches[0]
    text = path.read_text()

    old_migration = '''        if (_infoPlist[@"LCBundleIdentifier"]) {
            _infoPlist[@"CFBundleExecutable"] = _infoPlist[@"LCBundleExecutable"];
            _infoPlist[@"CFBundleIdentifier"] = _infoPlist[@"LCBundleIdentifier"];
            [_infoPlist removeObjectForKey:@"LCBundleExecutable"];
            [_infoPlist removeObjectForKey:@"LCBundleIdentifier"];
            [_infoPlist writeBinToFile:[NSString stringWithFormat:@"%@/Info.plist", bundlePath] atomically:YES];
        }
'''
    new_migration = '''        if (_infoPlist[@"LCBundleIdentifier"]) {
            id legacyExecutable = _infoPlist[@"LCBundleExecutable"];
            if ([legacyExecutable isKindOfClass:NSString.class] && [(NSString *)legacyExecutable length] > 0) {
                _infoPlist[@"CFBundleExecutable"] = legacyExecutable;
            }
            id legacyIdentifier = _infoPlist[@"LCBundleIdentifier"];
            if ([legacyIdentifier isKindOfClass:NSString.class] && [(NSString *)legacyIdentifier length] > 0) {
                _infoPlist[@"CFBundleIdentifier"] = legacyIdentifier;
            }
            [_infoPlist removeObjectForKey:@"LCBundleExecutable"];
            [_infoPlist removeObjectForKey:@"LCBundleIdentifier"];
            [_infoPlist writeBinToFile:[NSString stringWithFormat:@"%@/Info.plist", bundlePath] atomically:YES];
        }
'''
    text = replace_required(text, old_migration, new_migration, "safe legacy bundle metadata migration")

    old_exec_path = '''    NSFileManager* fm = NSFileManager.defaultManager;
    NSString *execPath = [NSString stringWithFormat:@"%@/%@", appPath, _infoPlist[@"CFBundleExecutable"]];
    
    // Update patch
'''
    new_exec_path = '''    NSFileManager* fm = NSFileManager.defaultManager;
    id executableValue = _infoPlist[@"CFBundleExecutable"];
    if (![executableValue isKindOfClass:NSString.class] || [(NSString *)executableValue length] == 0) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
        completetionHandler(NO, @"Info.plist is missing CFBundleExecutable. Reinstall or repair this app bundle.");
        return;
    }
    NSString *execPath = [appPath stringByAppendingPathComponent:(NSString *)executableValue];
    BOOL executableIsDirectory = NO;
    if (![fm fileExistsAtPath:execPath isDirectory:&executableIsDirectory] || executableIsDirectory) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
        completetionHandler(NO, [NSString stringWithFormat:@"App executable is missing: %@", execPath]);
        return;
    }
    
    // Update patch
'''
    text = replace_required(text, old_exec_path, new_exec_path, "executable path validation")
    path.write_text(text)


def patch_macho_mapper(root: Path) -> None:
    path = root / "LiveContainer" / "LCMachOUtils.m"
    if not path.is_file():
        matches = list(root.rglob("LCMachOUtils.m"))
        if not matches:
            raise SystemExit("Could not locate LCMachOUtils.m")
        path = matches[0]
    text = path.read_text()

    old_open = '''NSString *LCParseMachO(const char *path, bool readOnly, LCParseMachOCallback callback) {
    int fd = open(path, readOnly ? O_RDONLY : O_RDWR, (mode_t)readOnly ? 0400 : 0600);
    struct stat s;
    fstat(fd, &s);
    void *map = mmap(NULL, s.st_size, readOnly ? PROT_READ : (PROT_READ | PROT_WRITE), readOnly ? MAP_PRIVATE : MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        return [NSString stringWithFormat:@"Failed to map %s: %s", path, strerror(errno)];
    }
'''
    new_open = '''NSString *LCParseMachO(const char *path, bool readOnly, LCParseMachOCallback callback) {
    if (path == NULL || path[0] == '\\0') {
        return @"Failed to map executable: path is missing";
    }

    int fd = open(path, readOnly ? O_RDONLY : O_RDWR, (mode_t)readOnly ? 0400 : 0600);
    if (fd < 0) {
        return [NSString stringWithFormat:@"Failed to open %s: %s", path, strerror(errno)];
    }

    struct stat s = {0};
    if (fstat(fd, &s) != 0) {
        int code = errno;
        close(fd);
        return [NSString stringWithFormat:@"Failed to stat %s: %s", path, strerror(code)];
    }
    if (s.st_size <= 0) {
        close(fd);
        return [NSString stringWithFormat:@"Cannot map empty executable: %s", path];
    }

    void *map = mmap(NULL, s.st_size, readOnly ? PROT_READ : (PROT_READ | PROT_WRITE), readOnly ? MAP_PRIVATE : MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        int code = errno;
        close(fd);
        return [NSString stringWithFormat:@"Failed to map %s: %s", path, strerror(code)];
    }
'''
    text = replace_required(text, old_open, new_open, "safe Mach-O mapping")
    path.write_text(text)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: fix_livecontainer_apk_flow_compile.py <LCAppListView.swift>")

    app_list_path = Path(sys.argv[1]).resolve()
    root = find_livecontainer_root(app_list_path)
    patch_app_list(app_list_path)
    patch_preloaded_installer(root)
    patch_lc_app_info(root)
    patch_macho_mapper(root)


if __name__ == "__main__":
    main()
