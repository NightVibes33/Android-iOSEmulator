import SwiftUI

struct ContentView: View {
    @ObservedObject var model: DiagnosticsModel
    @State private var showingShortcutSetup = false

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

                    Text("Assign \(model.selectedProtocol.scriptName) to Android iOSEmulator in StikDebug before testing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Set Up JIT Shortcut") {
                        showingShortcutSetup = true
                    }

                    Button("Open Configured Shortcut") {
                        _ = ShortcutCoordinator.openConfiguredShortcut()
                    }

                    Button("Run Configured Shortcut") {
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
                    Text("The shortcut cannot be empty. It must contain StikDebug's Enable JIT action with App set to Android iOSEmulator. Do not execute the probe until StikDebug has attached and the selected script matches the selected protocol.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Android iOSEmulator")
            .sheet(isPresented: $showingShortcutSetup) {
                shortcutSetupSheet
            }
        }
    }

    private var shortcutSetupSheet: some View {
        NavigationStack {
            List {
                Section("Required shortcut") {
                    Text(ShortcutCoordinator.shortcutName)
                        .font(.headline.monospaced())
                        .textSelection(.enabled)

                    Button("Copy Exact Shortcut Name") {
                        ShortcutCoordinator.copyShortcutName()
                    }
                }

                Section("Add exactly one action") {
                    SetupStep(number: 1, text: "Open the empty shortcut and tap Add Action.")
                    SetupStep(number: 2, text: "Search for Enable JIT.")
                    SetupStep(number: 3, text: "Choose Enable JIT from StikDebug, not another app.")
                    SetupStep(number: 4, text: "Tap the blue App field inside the action.")
                    SetupStep(number: 5, text: "Select Android iOSEmulator (\(ShortcutCoordinator.targetBundleID)).")
                    SetupStep(number: 6, text: "Rename the shortcut exactly as shown above, then run it once manually and approve any prompts.")
                }

                Section("Open Shortcuts") {
                    Button("Create a New Shortcut") {
                        _ = ShortcutCoordinator.createShortcut()
                    }

                    Button("Open Existing Shortcut") {
                        _ = ShortcutCoordinator.openConfiguredShortcut()
                    }
                }

                Section("Expected action") {
                    Text("StikDebug → Enable JIT → App: Android iOSEmulator")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Set Up JIT Shortcut")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingShortcutSetup = false
                    }
                }
            }
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

private struct SetupStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(number))
                .font(.caption.bold())
                .frame(width: 24, height: 24)
                .background(.secondary.opacity(0.15), in: Circle())
            Text(text)
                .font(.callout)
        }
        .padding(.vertical, 2)
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
