import Foundation
import UIKit

enum ShortcutCoordinator {
    static let shortcutName = "Start Android iOSEmulator JIT"
    static let targetBundleID = "com.nightvibes.androidiosemulator"

    @MainActor
    static func createShortcut() -> Bool {
        guard let url = URL(string: "shortcuts://create-shortcut") else { return false }
        UIApplication.shared.open(url)
        return true
    }

    @MainActor
    static func openConfiguredShortcut() -> Bool {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "open-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: shortcutName)]

        guard let url = components.url else { return false }
        UIApplication.shared.open(url)
        return true
    }

    @MainActor
    static func copyShortcutName() {
        UIPasteboard.general.string = shortcutName
    }

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
