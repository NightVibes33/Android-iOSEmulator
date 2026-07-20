import Foundation
import UIKit

enum ShortcutCoordinator {
    static let shortcutName = "Start Android iOSEmulator JIT"

    @MainActor
    static func runJITShortcut() -> Bool {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: shortcutName),
            URLQueryItem(name: "x-success", value: "androidiosemulator://jit-success"),
            URLQueryItem(name: "x-error", value: "androidiosemulator://jit-error"),
            URLQueryItem(name: "x-cancel", value: "androidiosemulator://jit-cancel")
        ]

        guard let url = components.url else { return false }
        UIApplication.shared.open(url)
        return true
    }
}
