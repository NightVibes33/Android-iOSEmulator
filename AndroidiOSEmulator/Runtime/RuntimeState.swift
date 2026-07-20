import Foundation

enum RuntimePhase: String, Codable, CaseIterable {
    case locked
    case prerequisitesReady
    case preparingExecutableMemory
    case startingRuntime
    case bootingGuest
    case running
    case stopping
    case failed
}

struct RuntimeFailure: Error, Codable, Equatable {
    let stage: String
    let code: String
    let message: String
    let recovery: String
}

struct RuntimeStatus: Codable, Equatable {
    var phase: RuntimePhase = .locked
    var detail: String = "Gate 0 has not passed on this device"
    var failure: RuntimeFailure?
}
