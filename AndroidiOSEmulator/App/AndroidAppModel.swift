import Darwin
import Foundation

struct AndroidPackageRecord: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        case imported
        case installing
        case installed
        case failed
    }

    let id: UUID
    var displayName: String
    var packageIdentifier: String
    var sourceFilename: String
    var storedFilename: String
    var byteCount: Int64
    var importedAt: Date
    var state: State
    var lastError: String?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

enum AndroidRuntimeMode: String, Codable, CaseIterable, Identifiable {
    case softwareEngine = "SE (No JIT)"
    case experimentalJIT = "JIT (Blocked)"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .softwareEngine:
            return "Threaded interpreter. Slower, but it does not require StikDebug, LocalDevVPN, pairing files, or a computer."
        case .experimentalJIT:
            return "Unavailable on the target iOS 27 beta because debugger attachment fails with E96."
        }
    }
}

enum AndroidRuntimePhase: String, Codable {
    case stopped
    case checking
    case blocked
    case starting
    case booting
    case running
    case stopping
    case failed
}

struct AndroidRuntimeAsset: Identifiable, Equatable {
    let id: String
    let title: String
    let filename: String
    let required: Bool
    let present: Bool
}

@MainActor
final class AndroidAppModel: ObservableObject {
    @Published private(set) var packages: [AndroidPackageRecord] = []
    @Published var runtimeMode: AndroidRuntimeMode = .softwareEngine
    @Published private(set) var runtimePhase: AndroidRuntimePhase = .checking
    @Published private(set) var runtimeDetail = "Checking the local Android runtime…"
    @Published private(set) var runtimeAssets: [AndroidRuntimeAsset] = []
    @Published private(set) var runtimeCoreAvailable = false
    @Published private(set) var logs: [String] = []
    @Published var isImporterPresented = false
    @Published var alertMessage: String?
    @Published private(set) var exportedLogURL: URL?

    private let fileManager = FileManager.default
    private let packagesDirectory: URL
    private let metadataURL: URL

    private typealias StartRuntimeFunction = @convention(c) () -> Int32
    private typealias StopRuntimeFunction = @convention(c) () -> Void
    private typealias InstallAndLaunchFunction = @convention(c) (UnsafePointer<CChar>) -> Int32

    init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        packagesDirectory = documents.appendingPathComponent("AndroidPackages", isDirectory: true)
        metadataURL = documents.appendingPathComponent("android-library.json")

        do {
            try fileManager.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)
        } catch {
            alertMessage = "Could not create the Android package library: \(error.localizedDescription)"
        }

        loadLibrary()
        refreshRuntimeAvailability()
        log("Android library initialized with \(packages.count) package(s)")
    }

    var canStartRuntime: Bool {
        runtimeMode == .softwareEngine && runtimeCoreAvailable && runtimeAssets.filter(\.required).allSatisfy(\.present)
    }

    var canImportPackages: Bool { true }

    var statusTitle: String {
        switch runtimePhase {
        case .stopped: return "Ready"
        case .checking: return "Checking"
        case .blocked: return "Runtime Required"
        case .starting: return "Starting"
        case .booting: return "Booting Android"
        case .running: return "Android Running"
        case .stopping: return "Stopping"
        case .failed: return "Runtime Failed"
        }
    }

    func refreshRuntimeAvailability() {
        runtimePhase = .checking
        runtimeCoreAvailable = resolveSymbol("android_qemu_se_start") != nil

        let requirements: [(String, String, Bool)] = [
            ("kernel", "Image", true),
            ("initramfs", "initramfs.img", true),
            ("system", "system.img", true),
            ("vendor", "vendor.img", false),
            ("userdata", "userdata.img", true)
        ]

        runtimeAssets = requirements.map { id, filename, required in
            let present = Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "GuestAssets") != nil
            return AndroidRuntimeAsset(
                id: id,
                title: id.capitalized,
                filename: filename,
                required: required,
                present: present
            )
        }

        if canStartRuntime {
            runtimePhase = .stopped
            runtimeDetail = "The local SE runtime and required guest assets are installed."
        } else {
            runtimePhase = .blocked
            let missing = runtimeAssets.filter { $0.required && !$0.present }.map(\.filename)
            if !runtimeCoreAvailable {
                runtimeDetail = "The phone interface is installed, but the UTM/QEMU SE bridge has not been linked into this build."
            } else if !missing.isEmpty {
                runtimeDetail = "The SE runtime is linked, but guest assets are missing: \(missing.joined(separator: ", "))."
            } else {
                runtimeDetail = "The runtime is unavailable in this build."
            }
        }
        log("Runtime check: core=\(runtimeCoreAvailable), requiredAssets=\(runtimeAssets.filter(\.required).filter(\.present).count)/\(runtimeAssets.filter(\.required).count)")
    }

    func importPackage(from sourceURL: URL) {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let supportedExtensions = Set(["apk", "apks", "xapk"])
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            alertMessage = "Choose an APK, APKS, or XAPK package."
            return
        }

        do {
            let resourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .nameKey])
            let displayName = sourceURL.deletingPathExtension().lastPathComponent
            let uniqueName = "\(UUID().uuidString).\(fileExtension)"
            let destination = packagesDirectory.appendingPathComponent(uniqueName)
            try fileManager.copyItem(at: sourceURL, to: destination)

            let record = AndroidPackageRecord(
                id: UUID(),
                displayName: displayName.isEmpty ? "Android App" : displayName,
                packageIdentifier: provisionalPackageIdentifier(for: displayName),
                sourceFilename: resourceValues.name ?? sourceURL.lastPathComponent,
                storedFilename: uniqueName,
                byteCount: Int64(resourceValues.fileSize ?? 0),
                importedAt: Date(),
                state: .imported,
                lastError: nil
            )
            packages.insert(record, at: 0)
            saveLibrary()
            log("Imported \(record.sourceFilename) (\(record.formattedSize))")
        } catch {
            alertMessage = "The package could not be imported: \(error.localizedDescription)"
            log("Package import failed: \(error.localizedDescription)")
        }
    }

    func deletePackage(_ package: AndroidPackageRecord) {
        let packageURL = packagesDirectory.appendingPathComponent(package.storedFilename)
        do {
            if fileManager.fileExists(atPath: packageURL.path) {
                try fileManager.removeItem(at: packageURL)
            }
            packages.removeAll { $0.id == package.id }
            saveLibrary()
            log("Deleted \(package.displayName)")
        } catch {
            alertMessage = "Could not delete \(package.displayName): \(error.localizedDescription)"
        }
    }

    func startRuntime() {
        guard runtimeMode == .softwareEngine else {
            alertMessage = "The JIT runtime is blocked on this iOS build. Use SE (No JIT)."
            return
        }
        guard canStartRuntime else {
            refreshRuntimeAvailability()
            alertMessage = runtimeDetail
            return
        }
        guard let pointer = resolveSymbol("android_qemu_se_start") else {
            alertMessage = "The SE runtime bridge is missing."
            return
        }

        runtimePhase = .starting
        runtimeDetail = "Starting the local ARM64 virtual machine…"
        log("Starting UTM/QEMU SE runtime")
        let function = unsafeBitCast(pointer, to: StartRuntimeFunction.self)

        Task.detached(priority: .userInitiated) {
            let result = function()
            await MainActor.run {
                if result == 0 {
                    self.runtimePhase = .running
                    self.runtimeDetail = "The Android guest is running locally on this device."
                    self.log("SE runtime started successfully")
                } else {
                    self.runtimePhase = .failed
                    self.runtimeDetail = "The SE runtime exited with status \(result)."
                    self.log("SE runtime failed with status \(result)")
                }
            }
        }
    }

    func stopRuntime() {
        guard runtimePhase == .running || runtimePhase == .booting || runtimePhase == .starting else { return }
        runtimePhase = .stopping
        runtimeDetail = "Stopping Android safely…"
        if let pointer = resolveSymbol("android_qemu_se_stop") {
            let function = unsafeBitCast(pointer, to: StopRuntimeFunction.self)
            function()
        }
        runtimePhase = .stopped
        runtimeDetail = "Android is stopped."
        log("Runtime stopped")
    }

    func launch(_ package: AndroidPackageRecord) {
        guard runtimePhase == .running else {
            alertMessage = canStartRuntime ? "Start Android before launching an app." : runtimeDetail
            return
        }
        guard let pointer = resolveSymbol("android_guest_install_and_launch") else {
            alertMessage = "The APK installation bridge is not linked into this build yet."
            return
        }

        let packageURL = packagesDirectory.appendingPathComponent(package.storedFilename)
        let function = unsafeBitCast(pointer, to: InstallAndLaunchFunction.self)
        let result = packageURL.path.withCString { function($0) }
        if result == 0 {
            updatePackage(package.id, state: .installed, error: nil)
            log("Launched \(package.displayName)")
        } else {
            updatePackage(package.id, state: .failed, error: "Guest bridge status \(result)")
            alertMessage = "Android could not install or launch this package. Status: \(result)."
        }
    }

    func exportLogs() {
        let formatter = ISO8601DateFormatter()
        let filename = "Android-iOSEmulator-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-"))-log.txt"
        let url = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        do {
            try logs.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            exportedLogURL = url
            log("Exported runtime log")
        } catch {
            alertMessage = "Could not export logs: \(error.localizedDescription)"
        }
    }

    private func resolveSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        return dlsym(handle, name)
    }

    private func loadLibrary() {
        guard fileManager.fileExists(atPath: metadataURL.path) else { return }
        do {
            let data = try Data(contentsOf: metadataURL)
            packages = try JSONDecoder().decode([AndroidPackageRecord].self, from: data)
        } catch {
            packages = []
            log("Could not read package metadata: \(error.localizedDescription)")
        }
    }

    private func saveLibrary() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(packages).write(to: metadataURL, options: .atomic)
        } catch {
            alertMessage = "Could not save the package library: \(error.localizedDescription)"
        }
    }

    private func updatePackage(_ id: UUID, state: AndroidPackageRecord.State, error: String?) {
        guard let index = packages.firstIndex(where: { $0.id == id }) else { return }
        packages[index].state = state
        packages[index].lastError = error
        saveLibrary()
    }

    private func provisionalPackageIdentifier(for name: String) -> String {
        let normalized = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let slug = String(normalized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "imported.\(slug.isEmpty ? UUID().uuidString.lowercased() : slug)"
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        logs.append("[\(timestamp)] \(message)")
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }
}
