import Foundation

/// Shared directory ownership rules for download cleanup, recovery and the installer worker.
nonisolated enum AppUpdateStorage {
    static let applicationName = "ChopChop.app"
    static let archivePrefix = "installer-"
    static let stagingPrefix = ".ChopChop-update-"
    static let jobFile = "job.json"
    static let workerReadyFile = "worker-ready"
    static let workerErrorFile = "worker-error.json"
    static let workerLockFile = "worker.lock"

    static var archiveDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChopChop/App Updates", isDirectory: true)
    }

    static func isArchiveDirectory(_ url: URL) -> Bool { isOwnedName(url.lastPathComponent, prefix: archivePrefix) }
    static func isStagingDirectory(_ url: URL) -> Bool { isOwnedName(url.lastPathComponent, prefix: stagingPrefix) }

    private static func isOwnedName(_ name: String, prefix: String) -> Bool {
        name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }
}
