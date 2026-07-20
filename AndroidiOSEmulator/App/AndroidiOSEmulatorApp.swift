import SwiftUI

@main
struct AndroidiOSEmulatorApp: App {
    @StateObject private var diagnostics = DiagnosticsModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: diagnostics)
                .onOpenURL { url in
                    diagnostics.handle(url: url)
                }
        }
    }
}
