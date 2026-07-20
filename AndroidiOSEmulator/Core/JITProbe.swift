import Foundation

enum ProbeProtocol: Int32, CaseIterable, Identifiable, Codable {
    case universal = 0
    case utmLegacy = 1

    var id: Int32 { rawValue }

    var title: String {
        switch self {
        case .universal: return "Universal iOS 26/27"
        case .utmLegacy: return "UTM legacy"
        }
    }

    var scriptName: String {
        switch self {
        case .universal: return "universal.js"
        case .utmLegacy: return "UTM-Dolphin.js"
        }
    }
}

struct ProbeOutcome: Codable {
    let timestamp: Date
    let protocolName: String
    let debuggerAttached: Bool
    let success: Bool
    let statusCode: Int32
    let message: String
    let writableAddress: String
    let executableAddress: String
    let regionLength: UInt64
    let generatedResult: Int32
}

enum JITProbeRunner {
    static var debuggerAttached: Bool {
        jitprobe_is_debugger_attached() != 0
    }

    static func run(protocol selectedProtocol: ProbeProtocol) -> ProbeOutcome {
        var writable: UInt64 = 0
        var executable: UInt64 = 0
        var length: UInt64 = 0
        var generatedResult: Int32 = 0

        let code = jitprobe_run(
            selectedProtocol.rawValue,
            &writable,
            &executable,
            &length,
            &generatedResult
        )

        let message: String
        if let rawMessage = jitprobe_last_error() {
            message = String(cString: rawMessage)
        } else {
            message = "JIT probe returned no diagnostic message"
        }

        return ProbeOutcome(
            timestamp: Date(),
            protocolName: selectedProtocol.title,
            debuggerAttached: debuggerAttached,
            success: code == 0 && generatedResult == 42,
            statusCode: code,
            message: message,
            writableAddress: String(format: "0x%llx", writable),
            executableAddress: String(format: "0x%llx", executable),
            regionLength: length,
            generatedResult: generatedResult
        )
    }
}
