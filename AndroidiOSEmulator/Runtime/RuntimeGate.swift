import Foundation

struct RuntimePrerequisite: Identifiable, Codable {
    let id: String
    let title: String
    let passed: Bool
    let detail: String
}

struct RuntimeGateReport: Codable {
    let generatedAt: Date
    let prerequisites: [RuntimePrerequisite]

    var passed: Bool { prerequisites.allSatisfy(\.passed) }
    var blockers: [RuntimePrerequisite] { prerequisites.filter { !$0.passed } }
}

enum RuntimeGate {
    static func evaluate(
        signing: SigningSnapshot,
        route: RouteProbeResult?,
        probe: ProbeOutcome?,
        guestAssetsValidated: Bool,
        qemuRuntimeLinked: Bool
    ) -> RuntimeGateReport {
        RuntimeGateReport(
            generatedAt: Date(),
            prerequisites: [
                RuntimePrerequisite(
                    id: "development-signing",
                    title: "Development signing",
                    passed: signing.getTaskAllow == true,
                    detail: signing.getTaskAllowDescription
                ),
                RuntimePrerequisite(
                    id: "localdevvpn-route",
                    title: "LocalDevVPN route",
                    passed: route?.reachable == true,
                    detail: route?.message ?? "Not tested"
                ),
                RuntimePrerequisite(
                    id: "jit-generated-code",
                    title: "Executable memory",
                    passed: probe?.success == true,
                    detail: probe?.message ?? "Gate 0 probe has not passed"
                ),
                RuntimePrerequisite(
                    id: "qemu-runtime",
                    title: "QEMU runtime",
                    passed: qemuRuntimeLinked,
                    detail: qemuRuntimeLinked ? "Pinned runtime linked" : "Not imported until Gate 0 passes"
                ),
                RuntimePrerequisite(
                    id: "guest-assets",
                    title: "ARM64 guest assets",
                    passed: guestAssetsValidated,
                    detail: guestAssetsValidated ? "Manifest and hashes validated" : "No validated guest package"
                )
            ]
        )
    }
}
