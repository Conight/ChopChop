import CryptoKit
import Foundation
import Security

nonisolated enum AppUpdateChannel: String, CaseIterable, Sendable {
    case stable, prerelease
    static func initial(for version: AppVersion?) -> Self { version?.prerelease.isEmpty == false ? .prerelease : .stable }
}

/// The exact payload bytes are signed, avoiding JSON canonicalization differences.
nonisolated struct SignedAppUpdate: Codable, Sendable {
    let payload: Data
    let signature: Data

    func verified(publicKey: String, version: AppVersion) throws -> AppUpdateManifest {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { throw AppUpdateError.signingNotConfigured }
        guard payload.count < 32_768, key.isValidSignature(signature, for: payload),
              let manifest = try? JSONDecoder().decode(AppUpdateManifest.self, from: payload),
              manifest.schema == 1, manifest.version == version.description,
              manifest.bundleIdentifier == "com.conight.ChopChop", manifest.architecture == "arm64",
              manifest.filename == AppUpdateManifest.filename(for: version),
              manifest.size > 0, manifest.size <= AppUpdateManifest.maximumSize,
              [40, 64].contains(manifest.codeDirectoryHash.count),
              manifest.codeDirectoryHash.allSatisfy({ "0123456789abcdef".contains($0) }),
              manifest.sha256.count == 64, manifest.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              Int(manifest.buildNumber).map({ $0 > 0 }) == true else { throw AppUpdateError.invalidSignature }
        return manifest
    }
}

nonisolated struct AppUpdateManifest: Codable, Equatable, Sendable {
    let schema: Int
    let version: String
    let buildNumber: String
    let bundleIdentifier: String
    let architecture: String
    let minimumSystemVersion: String
    let filename: String
    let size: Int64
    let sha256: String
    let codeDirectoryHash: String
    static let maximumSize: Int64 = 512 * 1_024 * 1_024

    static func filename(for version: AppVersion) -> String { "ChopChop-v\(version)-macos-arm64.dmg" }
    static func manifestName(for version: AppVersion) -> String { "ChopChop-v\(version)-update.json" }
    static func assetURL(version: AppVersion, name: String) -> URL {
        URL(string: "https://github.com/Conight/ChopChop/releases/download/v\(version)/\(name)")!
    }

    static func codeHash(at url: URL) throws -> String {
        var code: SecStaticCode?; var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { throw AppUpdateError.invalidApplication }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func verifyArchive(_ url: URL) throws {
        try Self.verifyArchive(url, size: size, sha256: sha256)
    }

    static func verifyArchive(_ url: URL, size: Int64, sha256: String) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var count: Int64 = 0
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            count += Int64(data.count)
            guard count <= size else { throw AppUpdateError.invalidSignature }
            digest.update(data: data)
        }
        guard count == size, digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw AppUpdateError.invalidSignature
        }
    }
}

nonisolated struct AppUpdateProgress: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable { case connecting, downloading, verifying, preparing }
    let stage: Stage
    var completedBytes: Int64 = 0
    var totalBytes: Int64? = nil
    var bytesPerSecond: Double = 0
    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

nonisolated enum AppUpdateError: String, Error, Codable, Equatable, Sendable {
    case offline, rateLimited, invalidResponse, noCompatibleRelease, serviceUnavailable
    case signingNotConfigured, invalidSignature, unsupportedSystem, installLocation, invalidApplication
    case installerUnavailable, installationFailed, downloadFailed, openingInstallerFailed
    case terminationTimedOut
}

nonisolated enum AppUpdateInstallationStatus: String, Sendable { case waitingForExit, terminationTimedOut, failed }

@objc(ChopChopAppUpdateInstallerProtocol)
nonisolated protocol AppUpdateInstallerProtocol {
    func prepare(version: String, reply: @escaping @Sendable (String?, String?) -> Void)
    func install(token: String, reply: @escaping @Sendable (Bool, String?) -> Void)
    func resumeUpdate(version: String, reply: @escaping @Sendable (String?, String?) -> Void)
    func updateInstallationStatus(token: String, reply: @escaping @Sendable (String) -> Void)
    func discardUpdate(reply: @escaping @Sendable () -> Void)
}

@objc(ChopChopAppUpdateProgressReporting)
nonisolated protocol AppUpdateProgressReporting {
    func reportAppUpdateProgress(_ data: Data)
}

/// Integrity metadata for downloading a DMG. It does not authorize automatic app replacement.
nonisolated struct AppUpdateArchive: Equatable, Sendable {
    let version: AppVersion
    let size: Int64
    var sha256: String?
    var filename: String { AppUpdateManifest.filename(for: version) }

    static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    static func checksum(from data: Data, filename: String) throws -> String {
        guard data.count < 8_192 else { throw AppUpdateError.invalidSignature }
        let entries = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[1] == filename || parts[1] == "*" + filename else { return nil }
            return String(parts[0])
        }
        guard entries.count == 1, let hash = entries.first, validDigest(hash) else { throw AppUpdateError.invalidSignature }
        return hash
    }
}

nonisolated struct DownloadedAppUpdateArchive: Codable, Equatable, Sendable {
    let url: URL
    let size: Int64
    let sha256: String
    @concurrent func verify() async throws {
        try Task.checkCancellation()
        try AppUpdateManifest.verifyArchive(url, size: size, sha256: sha256)
        try Task.checkCancellation()
    }
}
