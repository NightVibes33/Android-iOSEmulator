import Foundation
import Network
import UIKit

struct RouteProbeResult: Codable {
    let timestamp: Date
    let host: String
    let port: UInt16
    let reachable: Bool
    let message: String
}

enum LocalDevVPNCoordinator {
    static let host = "10.7.0.1"
    static let port: UInt16 = 49_152

    @MainActor
    static func openEnableCallback() -> Bool {
        guard let url = URL(string: "localdevvpn://enable?scheme=androidiosemulator") else {
            return false
        }
        UIApplication.shared.open(url)
        return true
    }

    static func probe(timeout: TimeInterval = 4.0) async -> RouteProbeResult {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.nightvibes.androidiosemulator.route-probe")
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            let lock = NSLock()
            var completed = false

            func finish(reachable: Bool, message: String) {
                lock.lock()
                defer { lock.unlock() }
                guard !completed else { return }
                completed = true
                connection.cancel()
                continuation.resume(returning: RouteProbeResult(
                    timestamp: Date(),
                    host: host,
                    port: port,
                    reachable: reachable,
                    message: message
                ))
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(reachable: true, message: "LocalDevVPN debug route accepted a TCP connection")
                case .failed(let error):
                    finish(reachable: false, message: "Connection failed: \(error.localizedDescription)")
                case .cancelled:
                    break
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(reachable: false, message: "Timed out connecting to \(host):\(port)")
            }
        }
    }
}
