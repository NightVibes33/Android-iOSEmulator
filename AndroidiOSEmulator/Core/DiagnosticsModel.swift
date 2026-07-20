import Foundation

struct DiagnosticBundle: Codable {
    let generatedAt: Date
    let device: DeviceSnapshot
    let signing: SigningSnapshot
    let selectedProtocol: ProbeProtocol
    let debuggerAttached: Bool
    let routeResult: RouteProbeResult?
    let probeOutcome: ProbeOutcome?
    let callbackState: String
    let logs: [String]
}

@MainActor
final class DiagnosticsModel: ObservableObject {
    @Published var selectedProtocol: ProbeProtocol = .universal
    @Published private(set) var signing = EntitlementInspector.current()
    @Published private(set) var routeResult: RouteProbeResult?
    @Published private(set) var probeOutcome: ProbeOutcome?
    @Published private(set) var callbackState = "None"
    @Published private(set) var logs: [String] = []
    @Published private(set) var isProbingRoute = false
    @Published private(set) var isRunningProbe = false
    @Published private(set) var exportURL: URL?

    var debuggerAttached: Bool { JITProbeRunner.debuggerAttached }

    init() {
        log("Gate 0 diagnostics initialized")
        refreshSigning()
    }

    func refreshSigning() {
        signing = EntitlementInspector.current()
        log("get-task-allow: \(signing.getTaskAllowDescription)")
        objectWillChange.send()
    }

    func enableLocalDevVPN() {
        let opened = LocalDevVPNCoordinator.openEnableCallback()
        log(opened ? "Opened LocalDevVPN enable callback" : "Could not create LocalDevVPN URL")
    }

    func probeLocalRoute() {
        guard !isProbingRoute else { return }
        isProbingRoute = true
        log("Probing 10.7.0.1:49152")

        Task {
            let result = await LocalDevVPNCoordinator.probe()
            routeResult = result
            isProbingRoute = false
            log(result.message)
        }
    }

    func runShortcut() {
        let opened = ShortcutCoordinator.runJITShortcut()
        log(opened ? "Opened JIT shortcut" : "Could not create Shortcuts URL")
    }

    func runProbe() {
        guard !isRunningProbe else { return }
        isRunningProbe = true
        log("Starting \(selectedProtocol.title) probe; assigned StikDebug script must be \(selectedProtocol.scriptName)")

        let selected = selectedProtocol
        Task.detached(priority: .userInitiated) {
            let outcome = JITProbeRunner.run(protocol: selected)
            await MainActor.run {
                self.probeOutcome = outcome
                self.isRunningProbe = false
                self.log(outcome.message)
                self.objectWillChange.send()
            }
        }
    }

    func handle(url: URL) {
        callbackState = url.host ?? url.absoluteString
        log("Received callback: \(url.absoluteString)")
        refreshSigning()
    }

    func exportDiagnostics() {
        let bundle = DiagnosticBundle(
            generatedAt: Date(),
            device: .current(),
            signing: signing,
            selectedProtocol: selectedProtocol,
            debuggerAttached: debuggerAttached,
            routeResult: routeResult,
            probeOutcome: probeOutcome,
            callbackState: callbackState,
            logs: logs
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(bundle)
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let formatter = ISO8601DateFormatter()
            let safeTimestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = directory.appendingPathComponent("Android-iOSEmulator-JIT-\(safeTimestamp).json")
            try data.write(to: url, options: .atomic)
            exportURL = url
            log("Wrote diagnostic JSON: \(url.lastPathComponent)")
        } catch {
            log("Diagnostic export failed: \(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        logs.append("[\(formatter.string(from: Date()))] \(message)")
        if logs.count > 250 {
            logs.removeFirst(logs.count - 250)
        }
    }
}
