import CryptoKit
import Foundation

struct GuestAsset: Codable, Hashable {
    enum Role: String, Codable {
        case kernel
        case initramfs
        case system
        case vendor
        case userdataTemplate
        case deviceTree
    }

    let role: Role
    let fileName: String
    let byteCount: UInt64
    let sha256: String
    let required: Bool
}

struct GuestAssetManifest: Codable {
    let schemaVersion: Int
    let product: String
    let androidBuildFingerprint: String
    let architecture: String
    let machine: String
    let assets: [GuestAsset]

    func validate(in directory: URL) throws {
        guard schemaVersion == 1 else {
            throw RuntimeFailure(stage: "assets", code: "manifest-schema", message: "Unsupported guest manifest schema \(schemaVersion)", recovery: "Use a manifest produced by the matching release workflow.")
        }
        guard architecture == "arm64", machine == "virt" else {
            throw RuntimeFailure(stage: "assets", code: "guest-target", message: "Guest must target arm64 QEMU virt", recovery: "Download the ARM64 FVP guest assets.")
        }

        for asset in assets where asset.required {
            let url = directory.appendingPathComponent(asset.fileName)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw RuntimeFailure(stage: "assets", code: "missing-\(asset.role.rawValue)", message: "Missing \(asset.fileName)", recovery: "Re-import the matching guest asset package.")
            }
            guard UInt64(values.fileSize ?? -1) == asset.byteCount else {
                throw RuntimeFailure(stage: "assets", code: "size-\(asset.role.rawValue)", message: "Unexpected size for \(asset.fileName)", recovery: "Delete and re-download the guest asset package.")
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest.caseInsensitiveCompare(asset.sha256) == .orderedSame else {
                throw RuntimeFailure(stage: "assets", code: "hash-\(asset.role.rawValue)", message: "SHA-256 mismatch for \(asset.fileName)", recovery: "Do not boot this image; re-download it from the release.")
            }
        }
    }
}
