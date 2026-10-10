import Foundation

/// Public identity embedded by Xcode from Configuration/Release.xcconfig.
/// Runtime configuration never comes from an update response or the environment.
nonisolated struct ReleaseConfiguration: Equatable, Sendable {
    let repository: String
    let bundleIdentifier: String
    let publicKey: String

    static let current: Self = {
        guard let configuration = try? Self(bundle: .main) else {
            preconditionFailure("Missing or invalid release configuration in Info.plist")
        }
        return configuration
    }()

    init(repository: String, bundleIdentifier: String, publicKey: String) throws {
        guard repository.range(of: #"\A[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*\z"#, options: .regularExpression) != nil,
              bundleIdentifier.range(of: #"\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z"#, options: .regularExpression) != nil,
              Data(base64Encoded: publicKey)?.count == 32 else { throw ConfigurationError.invalid }
        self.repository = repository
        self.bundleIdentifier = bundleIdentifier
        self.publicKey = publicKey
    }

    init(info: [String: Any]) throws {
        guard let repository = info["ChopChopReleaseRepository"] as? String,
              let identifier = info["ChopChopAppIdentifier"] as? String,
              let key = info["ChopChopUpdatePublicKey"] as? String else { throw ConfigurationError.invalid }
        try self.init(repository: repository, bundleIdentifier: identifier, publicKey: key)
    }

    init(bundle: Bundle) throws { try self.init(info: bundle.infoDictionary ?? [:]) }

    var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }
    var releasesAPI: URL { URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")! }
    var userGuideURL: URL { URL(string: repositoryURL.absoluteString + "#install")! }
    var issuesURL: URL { repositoryURL.appendingPathComponent("issues/new/choose") }
    var installerIdentifier: String { bundleIdentifier + ".EngineInstaller" }
    var signingKeychainService: String { bundleIdentifier + ".update-signing" }

    func releaseURL(version: AppVersion) -> URL {
        repositoryURL.appendingPathComponent("releases/tag/v\(version)")
    }

    func assetURL(version: AppVersion, name: String) -> URL {
        repositoryURL.appendingPathComponent("releases/download/v\(version)").appendingPathComponent(name)
    }

    enum ConfigurationError: Error { case invalid }
}
