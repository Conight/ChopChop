import Foundation

nonisolated enum DownloadFilePresence {
    static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            return error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
        }
        return error.domain == NSPOSIXErrorDomain && (error.code == Int(ENOENT) || error.code == Int(ENOTDIR))
    }

    static func exists(at url: URL, fileManager: FileManager = .default) throws -> Bool {
        do { _ = try fileManager.attributesOfItem(atPath: url.path); return true }
        catch where isMissing(error) { return false }
    }
}

/// App-owned safety state: independent of RPC errors and retained across engine refreshes.
/// No additional file paths, names or credentials are stored in history.
nonisolated enum TorrentFileIssue: String, Codable, Hashable, Sendable, LocalizedError {
    case missing, changed, unreadable

    var title: String {
        switch self {
        case .missing: String(localized: "Downloaded files missing")
        case .changed: String(localized: "Downloaded files changed")
        case .unreadable: String(localized: "Downloaded files unavailable")
        }
    }

    var errorDescription: String? { explanation }

    var explanation: String {
        let reason = switch self {
        case .missing: String(localized: "One or more downloaded files were moved or deleted.")
        case .changed: String(localized: "One or more downloaded files no longer match the expected size.")
        case .unreadable: String(localized: "One or more downloaded files cannot be read. Check the disk and folder permissions.")
        }
        return reason + " " + String(localized: "Restore the files to their original location, then recheck downloaded pieces before resuming. To download again, remove this task and add it again.")
    }
}

nonisolated enum TorrentFileSafety {
    /// Metadata-only checks run off the UI actor. Hash validation belongs to the engine's
    /// explicit recheck operation. Skipped, empty and unfinished files are not required.
    static func issue(for task: DownloadTask, fileManager: FileManager = .default) -> TorrentFileIssue? {
        guard task.isTorrentLike, !task.isFetchingMetadata, !task.requiresFileSelection,
              !task.isChecking || task.torrentFileIssue != nil else { return nil }
        let expected = task.files.filter { $0.isSelected && $0.length > 0
            && (task.isSharing || task.torrentFileIssue != nil || $0.completedLength >= $0.length) }
        if task.torrentFileIssue != nil && expected.isEmpty { return .unreadable }
        for file in expected {
            guard DownloadTaskTrashPath.isReportedUserContentPath(file.path) else { return .unreadable }
            do {
                let attributes = try fileManager.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber else { return .unreadable }
                guard size.int64Value == file.length else { return .changed }
                guard fileManager.isReadableFile(atPath: file.path) else { return .unreadable }
            } catch { return DownloadFilePresence.isMissing(error) ? .missing : .unreadable }
        }
        return nil
    }

    @concurrent
    static func issues(in tasks: [DownloadTask], previous: [DownloadTask] = []) async -> [String: TorrentFileIssue] {
        var issues: [String: TorrentFileIssue] = [:]
        let oldTasks = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for var task in tasks where task.isTorrentLike {
            if Task.isCancelled { break }
            // The engine can notice an unlink first and reset its counters. Inspect the
            // last reported completed files too, while respecting the current selection.
            if let old = oldTasks[task.id] {
                let oldFiles = Dictionary(old.files.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
                for index in task.files.indices {
                    if let file = oldFiles[task.files[index].index], file.isSelected,
                       file.path == task.files[index].path, file.length == task.files[index].length {
                        task.files[index].completedLength = max(task.files[index].completedLength, file.completedLength)
                    }
                }
                if old.hasCompletedPayload { task.isChecking = false }
            }
            if let issue = issue(for: task) { issues[task.id] = issue }
        }
        return issues
    }
}

extension DownloadStore {
    func trashFilesAfterRemoval(_ task: DownloadTask, engineTaskRemoved: Bool) throws {
        if engineTaskRemoved || !engineController.hasLaunchedProcess || task.removalAction == .removeDownloadResult {
            try DownloadTaskFileTrash.moveTaskFilesToTrash(task)
        } else if try !DownloadTaskFileTrash.allReportedFilesAreMissing(task) {
            throw EngineError.notRunning
        }
    }

    func validateTorrentFilesBeforeResume(_ task: DownloadTask) async throws {
        let current = tasks.first { $0.id == task.id } ?? task
        guard current.isTorrentLike else { return }
        if let issue = current.torrentFileIssue { throw issue }
        let session = engineSessionID
        let issues = await TorrentFileSafety.issues(in: [current])
        guard session == engineSessionID, !Task.isCancelled, !isShuttingDown else { throw CancellationError() }
        if let issue = issues[current.id] {
            if let index = tasks.firstIndex(where: { $0.id == current.id }) {
                tasks[index].torrentFileIssue = issue
                cancelSchedule(current.id)
                persistTaskHistory()
            }
            throw issue
        }
    }
}
