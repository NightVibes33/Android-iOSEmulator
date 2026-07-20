import Foundation
import UIKit

struct DeviceSnapshot: Codable {
    let hardwareIdentifier: String
    let systemName: String
    let systemVersion: String
    let operatingSystemVersion: String
    let appVersion: String
    let buildNumber: String

    static func current() -> DeviceSnapshot {
        DeviceSnapshot(
            hardwareIdentifier: hardwareIdentifier(),
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        )
    }

    private static func hardwareIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
