import Foundation

nonisolated enum DownloadTaskRPCOperations {
    static func pause(_ task: DownloadTask, using client: Aria2RPCClient) async throws {
        do {
            if task.isTorrentLike {
                try await client.forcePause(task.id)
            } else {
                try await client.pause(task.id)
            }
        } catch where isTaskAlreadyAbsent(error) {
            return
        }
    }

    static func resume(_ task: DownloadTask, using client: Aria2RPCClient) async throws {
        do {
            try await client.resume(task.id)
        } catch where isTaskAlreadyAbsent(error) {
            return
        }
    }

    static func remove(_ task: DownloadTask, using client: Aria2RPCClient) async throws {
        switch task.removalAction {
        case .removeActiveDownload:
            do {
                try await client.forceRemove(task.id)
            } catch where isTaskAlreadyAbsent(error) {
                try await removeDownloadResultIfPresent(task.id, using: client)
                return
            }
            await removeDownloadResultBestEffort(task.id, using: client)
        case .removeDownloadResult:
            try await removeDownloadResultIfPresent(task.id, using: client)
        }
    }

    static func pauseAll(_ tasks: [DownloadTask], using client: Aria2RPCClient) async throws -> Int {
        let pausableTasks = tasks.filter { $0.primaryControlAction == .pause || ($0.isAvailableInEngine && $0.isSharing) }
        var failedMessages: [String] = []

        for task in pausableTasks {
            do {
                try await client.forcePause(task.id)
            } catch where isTaskAlreadyAbsent(error) {
                continue
            } catch {
                failedMessages.append(error.localizedDescription)
            }
        }

        if let firstFailure = failedMessages.first {
            throw DownloadTaskOperationError.batchPauseFailed(
                failedCount: failedMessages.count,
                totalCount: pausableTasks.count,
                firstFailure: firstFailure
            )
        }
        return pausableTasks.count
    }

    private static func removeDownloadResultIfPresent(_ gid: String, using client: Aria2RPCClient) async throws {
        do {
            try await client.removeDownloadResult(gid)
        } catch where isTaskAlreadyAbsent(error) {
            return
        }
    }

    private static func removeDownloadResultBestEffort(_ gid: String, using client: Aria2RPCClient) async {
        do {
            try await client.removeDownloadResult(gid)
        } catch {
            return
        }
    }

    private static func isTaskAlreadyAbsent(_ error: Error) -> Bool {
        guard case RPCError.serverError(_, let message) = error else { return false }
        let lowered = message.lowercased()
        return lowered.contains("active download not found") ||
            lowered.contains("download result not found") ||
            (lowered.contains("gid") && lowered.contains("not found"))
    }
}

nonisolated enum DownloadTaskOperationError: LocalizedError, Equatable, Sendable {
    case batchPauseFailed(failedCount: Int, totalCount: Int, firstFailure: String)
    case bitTorrentMetadataTimedOut(reason: String)
    case bitTorrentContentNotSelectable(status: String)

    var errorDescription: String? {
        switch self {
        case .batchPauseFailed(let failedCount, let totalCount, let firstFailure):
            String(localized: "Could not pause \(failedCount) of \(totalCount) tasks.\n\(firstFailure)")
        case .bitTorrentMetadataTimedOut(let reason):
            String(localized: "Torrent metadata did not become available.\n\(reason)")
        case .bitTorrentContentNotSelectable(let status):
            String(localized: "Torrent files cannot be selected because the content task is \(status). Remove it and add the Magnet again.")
        }
    }
}
