import Foundation

nonisolated struct EngineInstallation: Equatable, Sendable {
    var executableURL: URL
    var version: EngineVersion
}

nonisolated enum EngineSetupState: Equatable, Sendable {
    case unchecked, checking, ready, required, installing(EngineInstallationProgress), failed(String)
    var requiresInstallation: Bool {
        switch self {
        case .required, .installing, .failed: true
        default: false
        }
    }
    var isInstalling: Bool {
        if case .installing = self { return true }
        return false
    }
    var statusLabel: String? {
        switch self {
        case .unchecked, .ready: nil
        case .checking: "Checking engine"
        case .required: "Download required"
        case .installing(let progress): progress.sidebarDescription
        case .failed: "Installation failed"
        }
    }
}

nonisolated protocol EngineInstallationManaging: Sendable {
    func localInstallation() async -> EngineInstallation?
    func latestRelease() async throws -> EngineRelease
    func activate(_ installation: EngineInstallation) async throws
    func backupRuntimeState() async throws -> EngineRuntimeBackup?
    func install(_ release: EngineRelease, progress: @escaping @Sendable (EngineInstallationProgress) async -> Void) async throws -> EngineInstallation
}

/// Manages installations in the application's own data directory; never changes the app bundle.
nonisolated struct EngineInstallationManager: EngineInstallationManaging {
    var supportDirectory: URL
    private var manifestURL: URL { supportDirectory.appendingPathComponent("installed-engine.json") }
    static let releasesURL = URL(string: "https://github.com/AnInsomniacy/aria2-next/releases/latest")!

    init(supportDirectory: URL? = nil) {
        self.supportDirectory = supportDirectory ?? (try? Aria2NextPaths.supportDirectory()) ?? FileManager.default.temporaryDirectory
    }

    private struct Manifest: Codable {
        var version: EngineVersion
        var directory: String
        var sha256: String
    }

    @concurrent func localInstallation() async -> EngineInstallation? {
        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard UUID(uuidString: manifest.directory) != nil else { return nil }
            let url = supportDirectory.appendingPathComponent("Engines/\(manifest.directory)/aria2-next")
            guard FileManager.default.isExecutableFile(atPath: url.path),
                  try EngineDownload.sha256(Data(contentsOf: url)) == manifest.sha256 else { return nil }
            _ = try await EngineDownload.runTool("/usr/bin/codesign", arguments: ["--verify", "--strict", url.path])
            return EngineInstallation(executableURL: url, version: manifest.version)
        } catch { return nil }
    }

    func latestRelease() async throws -> EngineRelease { try await EngineDownload.latestRelease() }

    @concurrent func install(_ release: EngineRelease, progress: @escaping @Sendable (EngineInstallationProgress) async -> Void) async throws -> EngineInstallation {
        let engines = supportDirectory.appendingPathComponent("Engines", isDirectory: true)
        try FileManager.default.createDirectory(at: engines, withIntermediateDirectories: true)
        let bookmark = try engines.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        await progress(.init(stage: .connecting))
        let directory = try await EngineInstallerRequest().install(version: release.version.description, directoryBookmark: bookmark,
                                                                  progress: progress)
        guard UUID(uuidString: directory) != nil else { throw EngineInstallationError.invalidExecutable }
        let folder = engines.appendingPathComponent(directory, isDirectory: true)
        var verified = false
        defer { if !verified { try? FileManager.default.removeItem(at: folder) } }
        try Task.checkCancellation()
        let executable = folder.appendingPathComponent("aria2-next")
        await progress(.init(stage: .testing))
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw EngineInstallationError.installationFailed("The installer did not produce an engine executable. Retry the download.")
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw EngineInstallationError.installationFailed("macOS did not allow the downloaded engine to run. Reinstall the latest version of ChopChop and retry.")
        }
        // Verify it actually executes under the parent app's sandbox before returning the staged installation.
        let output = try await EngineDownload.runTool(executable.path, arguments: ["--version"])
        guard output.contains("Aria2 Next version \(release.version)\n") else { throw EngineInstallationError.invalidExecutable }
        try Task.checkCancellation()
        verified = true
        return EngineInstallation(executableURL: executable, version: release.version)
    }

    /// Commit only after verification and, for a running engine, successful RPC startup.
    @concurrent func activate(_ installation: EngineInstallation) async throws {
        let executable = installation.executableURL
        let folder = executable.deletingLastPathComponent()
        guard UUID(uuidString: folder.lastPathComponent) != nil,
              folder.deletingLastPathComponent().standardizedFileURL == supportDirectory.appendingPathComponent("Engines").standardizedFileURL,
              executable.lastPathComponent == "aria2-next" else { throw EngineInstallationError.invalidExecutable }
        let manifest = Manifest(version: installation.version, directory: folder.lastPathComponent,
                                sha256: EngineDownload.sha256(try Data(contentsOf: executable)))
        try Task.checkCancellation()
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
    }

    func backupRuntimeState() async throws -> EngineRuntimeBackup? {
        try await EngineRuntimeBackup.create(supportDirectory: supportDirectory)
    }
}

/// Snapshot only engine-owned session/recovery state, after its process has stopped.
/// Download payloads and application preferences are not part of this snapshot.
nonisolated struct EngineRuntimeBackup: Sendable {
    let directory: URL
    let supportDirectory: URL
    private var sources: [URL] {
        [supportDirectory.appendingPathComponent("aria2.session"),
         supportDirectory.appendingPathComponent("engine-version"),
         supportDirectory.deletingLastPathComponent().appendingPathComponent("aria2-next")]
    }

    @concurrent static func create(supportDirectory: URL) async throws -> Self {
        let backup = Self(directory: supportDirectory.appendingPathComponent("Engine Update Backups/\(UUID().uuidString)"),
                          supportDirectory: supportDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: backup.directory, withIntermediateDirectories: true)
        do {
            for source in backup.sources where fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: backup.directory.appendingPathComponent(source.lastPathComponent))
            }
            return backup
        } catch {
            try? fm.removeItem(at: backup.directory)
            throw error
        }
    }

    @concurrent func restore() async throws {
        let fm = FileManager.default
        for destination in sources {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            let source = directory.appendingPathComponent(destination.lastPathComponent)
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: destination) }
        }
    }

    @concurrent func discard() async { try? FileManager.default.removeItem(at: directory) }
}
