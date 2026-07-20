import Foundation
import Security

struct SigningSnapshot: Codable {
    let getTaskAllow: Bool?
    let extendedVirtualAddressing: Bool?
    let increasedMemoryLimit: Bool?

    var getTaskAllowDescription: String {
        switch getTaskAllow {
        case true: return "Enabled"
        case false: return "Missing"
        case nil: return "Unknown"
        }
    }
}

enum EntitlementInspector {
    static func current() -> SigningSnapshot {
        SigningSnapshot(
            getTaskAllow: booleanValue(for: "get-task-allow"),
            extendedVirtualAddressing: booleanValue(for: "com.apple.developer.kernel.extended-virtual-addressing"),
            increasedMemoryLimit: booleanValue(for: "com.apple.developer.kernel.increased-memory-limit")
        )
    }

    private static func booleanValue(for key: String) -> Bool? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)?.takeRetainedValue() else {
            return false
        }
        return value as? Bool
    }
}
