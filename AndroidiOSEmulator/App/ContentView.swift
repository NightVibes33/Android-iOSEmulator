import SwiftUI

struct ContentView: View {
    @ObservedObject var model: DiagnosticsModel

    var body: some View {
        NavigationStack {
            List {
                Section("Gate 0 status") {
                    StatusRow(
                        title: "Development entitlement",
                        value: model.signing.getTaskAllowDescription,
                        passed: model.signing.getTaskAllow == true
                    )
                    StatusRow(
                        title: "Debugger attached",
                        value: model.debuggerAttached ? "Yes" : "No",
                        passed: model.debuggerAttached
                    )
                    StatusRow(
                        title: "Local route",
                        value: routeStatus,
                        passed: model.routeResult?.reachable == true
                    )
                    StatusRow(
                        title: "Generated code",
                        value: probeStatus,
                        passed: model.probeOutcome?.success == true
                    )
                }

                Section("1. LocalDevVPN") {
                    Text("Creates the on-device route StikDebug uses. It does not enable JIT by itself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Enable LocalDevVPN") {
                        model.enableLocalDevVPN()
                    }

                    Button {
                        model.probeLocalRoute()
                    } label: {
                        HStack {
                            Text("Probe Local Route")
                            Spacer()
                            if model.isProbingRoute { ProgressView() }
                        }
                    }
                    .disabled(model.isProbingRoute)
                }

                Section("2. StikDebug") {
                    Picker("JIT protocol", selection: $model.selectedProtocol) {
                        ForEach(ProbeProtocol.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }

                    Text("Assign \(model.selectedProtocol.scriptName) to this app in StikDebug before testing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Run StikDebug Shortcut") {
                        model.runShortcut()
                    }
                }

                Section("3. Execute") {
                    Button {
                        model.runProbe()
                    } label: {
                        HStack {
                            Text("Execute JIT Probe")
                            Spacer()
                            if model.isRunningProbe { ProgressView() }
                        }
                    }
                    .disabled(model.isRunningProbe)

                    if let outcome = model.probeOutcome {
                        LabeledContent("Result", value: outcome.success ? "PASS" : "FAIL")
                        LabeledContent("Status code", value: String(outcome.statusCode))
                        LabeledContent("Generated value", value: String(outcome.generatedResult))
                        LabeledContent("RW alias", value: outcome.writableAddress)
                        LabeledContent("RX alias", value: outcome.executableAddress)
                        Text(outcome.message)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Section("Diagnostics") {
                    Button("Refresh Signing Status") {
                        model.refreshSigning()
                    }

                    Button("Create Diagnostic JSON") {
                        model.exportDiagnostics()
                    }

                    if let exportURL = model.exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share Diagnostic JSON", systemImage: "square.and.arrow.up")
                        }
                    }

                    DisclosureGroup("Live log") {
                        ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }

                Section("Important") {
                    Text("Do not tap Execute JIT Probe unless StikDebug is attached and the selected script matches the selected protocol. A mismatched breakpoint handler can stop or terminate the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Android iOSEmulator")
        }
    }

    private var routeStatus: String {
        guard let result = model.routeResult else { return "Not tested" }
        return result.reachable ? "Reachable" : "Unavailable"
    }

    private var probeStatus: String {
        guard let outcome = model.probeOutcome else { return "Not run" }
        return outcome.success ? "Returned 42" : "Failed"
    }
}

private struct StatusRow: View {
    let title: String
    let value: String
    let passed: Bool

    var body: some View {
        HStack {
            Image(systemName: passed ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(passed ? .green : .orange)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
