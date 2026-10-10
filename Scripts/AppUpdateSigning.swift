import CryptoKit
import Darwin
import Foundation
import Security

/// Private keys are read from Keychain locally or a scoped CI environment secret; never printed.
@main struct AppUpdateSigning {
    static let account = "ed25519-v1"
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let configurationFile = arguments.first else { throw SigningError.usage }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configurationFile))) as? [String: Any] ?? [:]
        let configuration = try ReleaseConfiguration(info: info)
        let service = configuration.signingKeychainService
        let args = Array(arguments.dropFirst())
        guard let command = args.first else { throw SigningError.usage }
        let key: Curve25519.Signing.PrivateKey
        if command == "create-key" {
            guard args.count == 1 else { throw SigningError.usage }
            let generated = Curve25519.Signing.PrivateKey()
            let status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                    kSecAttrAccount: account, kSecValueData: generated.rawRepresentation,
                                    kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else { throw SigningError.keychain }
            key = try loadKey(service: service)
        } else { key = try loadKey(service: service) }
        if command == "export-key" {
            guard args.count == 2 else { throw SigningError.usage }
            let descriptor = open(args[1], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw SigningError.keychain }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try file.write(contentsOf: Data(key.rawRepresentation.base64EncodedString().utf8))
            try file.close()
            return
        }
        if command == "create-key" || command == "public-key" {
            print(key.publicKey.rawRepresentation.base64EncodedString()); return
        }
        guard command == "sign", args.count == 4 else { throw SigningError.usage }
        let app = URL(fileURLWithPath: args[1]), archive = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == configuration.bundleIdentifier,
              try ReleaseConfiguration(bundle: bundle) == configuration,
              let tag = bundle.object(forInfoDictionaryKey: "ChopChopReleaseVersion") as? String,
              let version = AppVersion(tag), tag == "v\(version)",
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, Int(build).map({ $0 > 0 }) == true,
              let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
              bundle.object(forInfoDictionaryKey: "ChopChopUpdatePublicKey") as? String == key.publicKey.rawRepresentation.base64EncodedString(),
              archive.lastPathComponent == AppUpdateManifest.filename(for: version),
              let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= AppUpdateManifest.maximumSize else { throw SigningError.package }
        let handle = try FileHandle(forReadingFrom: archive); defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty { digest.update(data: data) }
        let manifest = AppUpdateManifest(schema: 1, version: version.description, buildNumber: build,
            bundleIdentifier: configuration.bundleIdentifier, architecture: "arm64", minimumSystemVersion: minimum,
            filename: archive.lastPathComponent, size: Int64(size), sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            codeDirectoryHash: try AppUpdateManifest.codeHash(at: app))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(manifest)
        let signed = SignedAppUpdate(payload: payload, signature: try key.signature(for: payload))
        _ = try signed.verified(publicKey: key.publicKey.rawRepresentation.base64EncodedString(), version: version, bundleIdentifier: configuration.bundleIdentifier)
        try encoder.encode(signed).write(to: output, options: .atomic)
        print("Signed update manifest: \(output.lastPathComponent)")
    }
    static func loadKey(service: String) throws -> Curve25519.Signing.PrivateKey {
        if let encoded = ProcessInfo.processInfo.environment["CHOPCHOP_UPDATE_PRIVATE_KEY"] {
            guard let data = Data(base64Encoded: encoded) else { throw SigningError.keychain }
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw SigningError.keychain }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }
    enum SigningError: Error {
        case usage, keychain, package
    }
}
