import Foundation

/// Stable on-disk layout shared by engine startup, installation and recovery.
/// These names are persistence identifiers; changing them requires a migration.
nonisolated struct EngineStorage: Sendable {
    static let supportDirectoryName = "ChopChop"
    static let installationsDirectoryName = "Engines"
    static let executableName = "aria2-next"

    let supportDirectory: URL
    var installations: URL { supportDirectory.appendingPathComponent(Self.installationsDirectoryName, isDirectory: true) }
    var manifest: URL { supportDirectory.appendingPathComponent("installed-engine.json") }
    var session: URL { supportDirectory.appendingPathComponent("aria2.session") }
    var versionMarker: URL { supportDirectory.appendingPathComponent("engine-version") }
    var log: URL { supportDirectory.appendingPathComponent("aria2.log") }
    var state: URL { supportDirectory.deletingLastPathComponent().appendingPathComponent("aria2-next", isDirectory: true) }
    var sessionBackups: URL { supportDirectory.appendingPathComponent("Session Backups", isDirectory: true) }
    var updateBackups: URL { supportDirectory.appendingPathComponent("Engine Update Backups", isDirectory: true) }

    func executable(installation directory: String) -> URL {
        installations.appendingPathComponent(directory, isDirectory: true).appendingPathComponent(Self.executableName)
    }
}
