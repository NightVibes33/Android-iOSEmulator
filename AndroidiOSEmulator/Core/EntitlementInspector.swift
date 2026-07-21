import Foundation

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
        let result = key.withCString { pointer in
            jitprobe_entitlement_boolean(pointer)
        }

        switch result {
        case 1: return true
        case 0: return false
        default: return nil
        }
    }
}
