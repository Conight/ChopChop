import Foundation

/// A recovery hint, never authority to execute or replace an app. Both paths revalidate their payload.
@MainActor final class AppUpdateRecoveryStore {
    struct Pending: Codable {
        let release: AppRelease
        let archive: DownloadedAppUpdateArchive?
    }
    private let defaults: UserDefaults
    private let archiveDirectory: URL
    private static let key = "appUpdates.pending"

    init(defaults: UserDefaults, archiveDirectory: URL? = nil) {
        self.defaults = defaults
        self.archiveDirectory = archiveDirectory ?? AppUpdateStorage.archiveDirectory
    }
    func save(_ release: AppRelease, archive: DownloadedAppUpdateArchive? = nil) {
        defaults.set(try? JSONEncoder().encode(Pending(release: release, archive: archive)), forKey: Self.key)
    }
    func clear() { defaults.removeObject(forKey: Self.key) }
    func load(current: AppVersion?, channel: AppUpdateChannel) -> Pending? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        guard data.count < 131_072, let pending = try? JSONDecoder().decode(Pending.self, from: data),
              current.map({ pending.release.version > $0 }) ?? true,
              channel == .prerelease || pending.release.version.prerelease.isEmpty,
              pending.release.notes.count <= AppRelease.maximumNotesLength else { clear(); return nil }
        if let archive = pending.archive {
            let job = archive.url.deletingLastPathComponent()
            guard archive.url.isFileURL, archive.url == archive.url.resolvingSymlinksInPath(),
                  job.deletingLastPathComponent().resolvingSymlinksInPath() == archiveDirectory.resolvingSymlinksInPath(),
                  AppUpdateStorage.isArchiveDirectory(job),
                  archive.url.lastPathComponent == pending.release.archive.filename,
                  archive.size > 0, archive.size <= AppUpdateManifest.maximumSize,
                  archive.size == pending.release.archiveSize, AppUpdateArchive.validDigest(archive.sha256),
                  FileManager.default.fileExists(atPath: archive.url.path) else { clear(); return nil }
        } else if !pending.release.supportsInstallation { clear(); return nil }
        return pending
    }
}
