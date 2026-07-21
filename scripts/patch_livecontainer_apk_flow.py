#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path


SUPPORT_CODE = r'''
private struct AndroidAPKRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    let originalFileName: String
    let storedFileName: String
    let installedAt: Date
    var lastAttemptAt: Date?
    var lastStatus: String
    let sizeBytes: Int64
}

private struct AndroidInstallRequest: Codable {
    let requestID: UUID
    let apkID: UUID
    let displayName: String
    let apkFileName: String
    let requestedAt: Date
    let action: String
}

@MainActor
private final class AndroidAPKStore: ObservableObject {
    @Published private(set) var apps: [AndroidAPKRecord] = []

    private let fileManager = FileManager.default

    private var rootURL: URL {
        LCPath.docPath.appendingPathComponent("AndroidApps", isDirectory: true)
    }

    private var packagesURL: URL {
        rootURL.appendingPathComponent("Packages", isDirectory: true)
    }

    private var catalogURL: URL {
        rootURL.appendingPathComponent("catalog.json")
    }

    init() {
        load()
    }

    func install(from sourceURL: URL) throws -> AndroidAPKRecord {
        guard sourceURL.pathExtension.lowercased() == "apk" else {
            throw "Only .apk packages can be added to the Android library."
        }

        try fileManager.createDirectory(at: packagesURL, withIntermediateDirectories: true)
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let identifier = UUID()
        let storedFileName = "\(identifier.uuidString).apk"
        let destinationURL = packagesURL.appendingPathComponent(storedFileName)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let fileSize = (try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let fallbackName = sourceURL.deletingPathExtension().lastPathComponent
        let record = AndroidAPKRecord(
            id: identifier,
            displayName: fallbackName.isEmpty ? "Android App" : fallbackName,
            originalFileName: sourceURL.lastPathComponent,
            storedFileName: storedFileName,
            installedAt: Date(),
            lastAttemptAt: nil,
            lastStatus: "Ready to launch",
            sizeBytes: Int64(fileSize)
        )
        apps.insert(record, at: 0)
        try save()
        return record
    }

    func packageURL(for app: AndroidAPKRecord) -> URL {
        packagesURL.appendingPathComponent(app.storedFileName)
    }

    func remove(_ app: AndroidAPKRecord) throws {
        let packageURL = packageURL(for: app)
        if fileManager.fileExists(atPath: packageURL.path) {
            try fileManager.removeItem(at: packageURL)
        }
        apps.removeAll { $0.id == app.id }
        try save()
    }

    func updateStatus(for id: UUID, status: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[index].lastAttemptAt = Date()
        apps[index].lastStatus = status
        try? save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: catalogURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        apps = (try? decoder.decode([AndroidAPKRecord].self, from: data)) ?? []
    }

    private func save() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(apps).write(to: catalogURL, options: .atomic)
    }
}

private struct AndroidAPKBanner: View {
    let app: AndroidAPKRecord
    let launch: () -> Void
    let remove: () -> Void

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: app.sizeBytes, countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: launch) {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(.green.opacity(0.16))
                        .frame(width: 58, height: 58)
                        .overlay {
                            Image(systemName: "shippingbox.fill")
                                .font(.system(size: 25, weight: .semibold))
                                .foregroundStyle(.green)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("Android APK • \(sizeText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(app.lastStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "play.fill")
                        .foregroundStyle(.green)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Run Android app", systemImage: "play.fill", action: launch)
                Button("Delete", systemImage: "trash", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .padding(6)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

'''

METHODS = r'''
    @MainActor
    func startInstallAPK(_ fileURL: URL) async {
        do {
            installprogressVisible = true
            _ = try androidAPKStore.install(from: fileURL)
            installprogressVisible = false
        } catch {
            installprogressVisible = false
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    @MainActor
    func launchAndroidAPK(_ app: AndroidAPKRecord) async {
        do {
            let candidates = sharedModel.apps + sharedModel.hiddenApps
            guard let runtime = candidates.first(where: { model in
                model.appInfo.relativeBundlePath == "Android Runtime.app" ||
                model.displayName.localizedCaseInsensitiveContains("UTM SE") ||
                model.displayName.localizedCaseInsensitiveContains("Android Runtime")
            }) else {
                throw "Android Runtime is missing. Reinstall the full Android iOSEmulator build."
            }

            let container = try ensureAndroidRuntimeContainer(runtime)
            let dataRoot = runtime.uiIsShared ? LCPath.lcGroupDataPath : LCPath.dataPath
            let guestDocuments = dataRoot
                .appendingPathComponent(container.folderName, isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
            let inboxURL = guestDocuments.appendingPathComponent("AndroidInbox", isDirectory: true)
            try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)

            let sourceURL = androidAPKStore.packageURL(for: app)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw "The stored APK file is missing. Delete this entry and import it again."
            }

            let queuedAPKURL = inboxURL.appendingPathComponent(app.storedFileName)
            if FileManager.default.fileExists(atPath: queuedAPKURL.path) {
                try FileManager.default.removeItem(at: queuedAPKURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: queuedAPKURL)

            let request = AndroidInstallRequest(
                requestID: UUID(),
                apkID: app.id,
                displayName: app.displayName,
                apkFileName: app.storedFileName,
                requestedAt: Date(),
                action: "install-and-launch"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(request).write(
                to: inboxURL.appendingPathComponent("pending-install.json"),
                options: .atomic
            )

            androidAPKStore.updateStatus(for: app.id, status: "Launching Android runtime…")
            let launchURL = "androidiosemulator://install?request=\(request.requestID.uuidString)&apk=\(app.id.uuidString)"
            try await runtime.runApp(
                containerFolderName: container.folderName,
                urlStr: launchURL,
                forceJIT: false
            )
        } catch {
            androidAPKStore.updateStatus(for: app.id, status: "Launch failed")
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    @MainActor
    func ensureAndroidRuntimeContainer(_ runtime: LCAppModel) throws -> LCContainer {
        if let selected = runtime.uiSelectedContainer {
            return selected
        }
        if let existing = runtime.uiContainers.first {
            runtime.uiSelectedContainer = existing
            runtime.uiDefaultDataFolder = existing.folderName
            runtime.appInfo.dataUUID = existing.folderName
            return existing
        }

        guard let bundleIdentifier = runtime.appInfo.bundleIdentifier() else {
            throw "Android Runtime has no bundle identifier."
        }

        let folderName = UUID().uuidString
        let container = LCContainer(
            folderName: folderName,
            name: "Android Runtime",
            isShared: runtime.uiIsShared
        )
        runtime.uiContainers.append(container)
        runtime.uiSelectedContainer = container
        runtime.uiDefaultDataFolder = folderName
        runtime.appInfo.containers = runtime.uiContainers
        runtime.appInfo.dataUUID = folderName
        container.makeLCContainerInfoPlist(
            appIdentifier: bundleIdentifier,
            keychainGroupId: Int.random(in: 0..<SharedModel.keychainAccessGroupCount)
        )
        if !appDataFolderNames.contains(folderName) {
            appDataFolderNames.append(folderName)
        }
        return container
    }

'''


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Could not find LiveContainer anchor for {label}")
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_livecontainer_apk_flow.py <LCAppListView.swift>")

    path = Path(sys.argv[1])
    text = path.read_text()

    text = replace_once(
        text,
        "struct AppReplaceOption : Hashable {",
        SUPPORT_CODE + "struct AppReplaceOption : Hashable {",
        "Android APK support types",
    )

    text = replace_once(
        text,
        "    @State var choosingIPA = false\n",
        "    @State var choosingIPA = false\n    @StateObject private var androidAPKStore = AndroidAPKStore()\n",
        "Android APK store state",
    )

    filtered_anchor = """    var filteredHiddenApps: [LCAppModel] {
        let apps = sortedHiddenApps
        if searchContext.debouncedQuery.isEmpty || !sharedModel.isHiddenAppUnlocked {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
"""
    filtered_replacement = filtered_anchor + """
    var filteredAndroidApps: [AndroidAPKRecord] {
        if searchContext.debouncedQuery.isEmpty {
            return androidAPKStore.apps
        }
        return androidAPKStore.apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
            $0.originalFileName.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
        }
    }
"""
    text = replace_once(text, filtered_anchor, filtered_replacement, "Android APK search")

    app_list_anchor = """                LazyVStack {
                    ForEach(filteredApps, id: \\.self) { app in
"""
    android_section = """                if !filteredAndroidApps.isEmpty {
                    LazyVStack(spacing: 10) {
                        HStack {
                            Text("Android Apps")
                                .font(.system(.title2).bold())
                            Spacer()
                            Text("\\(filteredAndroidApps.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(filteredAndroidApps) { app in
                            AndroidAPKBanner(
                                app: app,
                                launch: { Task { await launchAndroidAPK(app) } },
                                remove: {
                                    do {
                                        try androidAPKStore.remove(app)
                                    } catch {
                                        errorInfo = error.localizedDescription
                                        errorShow = true
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top)
                }

""" + app_list_anchor
    text = replace_once(text, app_list_anchor, android_section, "Android APK app list")

    text = replace_once(
        text,
        "let appCount = sharedModel.isHiddenAppUnlocked ? filteredApps.count + filteredHiddenApps.count : filteredApps.count",
        "let appCount = (sharedModel.isHiddenAppUnlocked ? filteredApps.count + filteredHiddenApps.count : filteredApps.count) + filteredAndroidApps.count",
        "combined app count",
    )

    menu_anchor = """                                Button("lc.appList.installFromIpa".loc, systemImage: "doc.badge.plus", action: {
                                    choosingIPA = true
                                })
"""
    menu_replacement = """                                Button("Install APK", systemImage: "shippingbox.badge.plus", action: {
                                    choosingIPA = true
                                })
                                Button("lc.appList.installFromIpa".loc, systemImage: "doc.badge.plus", action: {
                                    choosingIPA = true
                                })
"""
    text = replace_once(text, menu_anchor, menu_replacement, "Install APK menu")

    importer_anchor = """        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
            Task { await startInstallApp(fileUrls[0]) }
        }, onDismiss: {
            choosingIPA = false
        })
"""
    importer_replacement = """        .betterFileImporter(
            isPresented: $choosingIPA,
            types: [.ipa, .tipa, UTType(filenameExtension: "apk")!],
            multiple: false,
            callback: { fileUrls in
                Task {
                    let selectedURL = fileUrls[0]
                    if selectedURL.pathExtension.lowercased() == "apk" {
                        await startInstallAPK(selectedURL)
                    } else {
                        await startInstallApp(selectedURL)
                    }
                }
            },
            onDismiss: {
                choosingIPA = false
            }
        )
"""
    text = replace_once(text, importer_anchor, importer_replacement, "APK file importer")

    text = replace_once(
        text,
        "    func startInstallApp(_ fileUrl:URL) async {",
        METHODS + "    func startInstallApp(_ fileUrl:URL) async {",
        "APK install and launch methods",
    )

    path.write_text(text)


if __name__ == "__main__":
    main()
