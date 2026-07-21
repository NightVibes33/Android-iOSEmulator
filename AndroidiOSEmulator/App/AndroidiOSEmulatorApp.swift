import SwiftUI

@main
struct AndroidiOSEmulatorApp: App {
    @StateObject private var model = AndroidAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
