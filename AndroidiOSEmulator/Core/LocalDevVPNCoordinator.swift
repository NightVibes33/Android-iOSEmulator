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

private final class RouteProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var connection: NWConnection?
    private let continuation: CheckedContinuation<RouteProbeResult, Never>
    private let host: String
    private let port: UInt16

    init(
        continuation: CheckedContinuation<RouteProbeResult, Never>,
        host: String,
        port: UInt16
    ) {
        self.continuation = continuation
        self.host = host
        self.port = port
    }

    func attach(connection: NWConnection) {
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    func finish(reachable: Bool, message: String) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let activeConnection = connection
        lock.unlock()

        activeConnection?.cancel()
        continuation.resume(returning: RouteProbeResult(
            timestamp: Date(),
            host: host,
            port: port,
            reachable: reachable,
            message: message
        ))
    }
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
        let targetHost = host
        let targetPort = port

        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.nightvibes.androidiosemulator.route-probe")
            let connection = NWConnection(
                host: NWEndpoint.Host(targetHost),
                port: NWEndpoint.Port(rawValue: targetPort)!,
                using: .tcp
            )
            let completion = RouteProbeCompletion(
                continuation: continuation,
                host: targetHost,
                port: targetPort
            )
            completion.attach(connection: connection)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(
                        reachable: true,
                        message: "LocalDevVPN debug route accepted a TCP connection"
                    )
                case .failed(let error):
                    completion.finish(
                        reachable: false,
                        message: "Connection failed: \(error.localizedDescription)"
                    )
                case .cancelled:
                    break
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                completion.finish(
                    reachable: false,
                    message: "Timed out connecting to \(targetHost):\(targetPort)"
                )
            }
        }
    }
}
