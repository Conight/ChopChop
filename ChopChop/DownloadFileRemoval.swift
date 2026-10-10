import Foundation
import AppKit

nonisolated enum DownloadTaskTrashPath {
    static func isReportedUserContentPath(_ path: String) -> Bool {
        let trimmed = path.trimmedForEngine
        guard !trimmed.isEmpty, trimmed != "/", trimmed != "." else { return false }
        return trimmed.hasPrefix("/")
    }
}

nonisolated struct DownloadTaskTrashPlan: Equatable, Sendable {
    var primaryTargets: [URL]
    var companionTargets: [URL]
}

nonisolated enum DownloadTaskFileTrash {
    static func plan(for task: DownloadTask, fileManager: FileManager = .default) -> DownloadTaskTrashPlan {
        let destinationURL = task.destination.trimmedForEngine.isEmpty
            ? nil
            : URL(fileURLWithPath: task.destination).standardizedFileURL
        let reportedURLs = uniqueURLs(
            task.files
                .map(\.path)
                .filter(DownloadTaskTrashPath.isReportedUserContentPath)
                .map { URL(fileURLWithPath: $0).standardizedFileURL }
                .filter { url in
                    guard url.path != "/" else { return false }
                    guard let destinationURL else { return true }
                    return url.path != destinationURL.path
                }
        )
        if task.isTorrentLike, let destinationURL, destinationURL.path != "/",
           task.torrentDirectory == destinationURL.path, !reportedURLs.isEmpty,
           reportedURLs.allSatisfy({ $0.path.hasPrefix(destinationURL.path + "/") }) {
            return DownloadTaskTrashPlan(primaryTargets: [destinationURL], companionTargets: [])
        }
        let primaryTargets = primaryTargets(
            for: reportedURLs,
            destinationURL: destinationURL,
            fileManager: fileManager
        )
        let companionTargets = companionTargets(for: primaryTargets, task: task, destinationURL: destinationURL)
        return DownloadTaskTrashPlan(primaryTargets: primaryTargets, companionTargets: companionTargets)
    }

    static func moveTaskFilesToTrash(_ task: DownloadTask, fileManager: FileManager = .default) throws {
        let plan = plan(for: task, fileManager: fileManager)
        guard !plan.primaryTargets.isEmpty else {
            throw DownloadFileTrashError.noReportedFiles(taskName: task.name)
        }

        var failures: [DownloadFileTrashError] = []
        for target in plan.primaryTargets {
            do {
                // fileExists also returns false on access errors. Only a missing path is success.
                guard try DownloadFilePresence.exists(at: target, fileManager: fileManager) else { continue }
                try fileManager.trashItem(at: target, resultingItemURL: nil)
            } catch {
                // Finder may remove a file between our check and the Trash operation.
                if DownloadFilePresence.isMissing(error) { continue }
                failures.append(
                    .moveToTrashFailed(path: target.path, reason: error.localizedDescription)
                )
            }
        }

        if let failure = failures.first {
            throw failure
        }
        for companion in plan.companionTargets where fileManager.fileExists(atPath: companion.path) {
            try? fileManager.trashItem(at: companion, resultingItemURL: nil)
        }
    }

    /// When the engine cannot be contacted, do not touch any potentially open files.
    /// An already absent payload can still have its history record removed.
    static func allReportedFilesAreMissing(_ task: DownloadTask, fileManager: FileManager = .default) throws -> Bool {
        let targets = plan(for: task, fileManager: fileManager).primaryTargets
        guard !targets.isEmpty else { return false }
        for target in targets {
            if try DownloadFilePresence.exists(at: target, fileManager: fileManager) { return false }
        }
        return true
    }

    private static func primaryTargets(
        for reportedURLs: [URL],
        destinationURL: URL?,
        fileManager: FileManager
    ) -> [URL] {
        guard reportedURLs.count > 1, let destinationURL else {
            return reportedURLs
        }
        let firstChildren = reportedURLs.compactMap {
            firstChildURL(of: $0, under: destinationURL)
        }
        guard firstChildren.count == reportedURLs.count,
              let commonChild = firstChildren.first,
              firstChildren.allSatisfy({ $0.path == commonChild.path }) else {
            return reportedURLs
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: commonChild.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return [commonChild]
        }
        return reportedURLs
    }

    private static func firstChildURL(of url: URL, under destinationURL: URL) -> URL? {
        let destinationPath = destinationURL.path.hasSuffix("/")
            ? destinationURL.path
            : destinationURL.path + "/"
        guard url.path.hasPrefix(destinationPath) else { return nil }
        let suffix = String(url.path.dropFirst(destinationPath.count))
        guard let childName = suffix.split(separator: "/", maxSplits: 1).first,
              !childName.isEmpty else { return nil }
        return destinationURL.appendingPathComponent(String(childName)).standardizedFileURL
    }

    private static func companionTargets(
        for primaryTargets: [URL],
        task: DownloadTask,
        destinationURL: URL?
    ) -> [URL] {
        var companions = primaryTargets.map {
            URL(fileURLWithPath: $0.path + ".aria2").standardizedFileURL
        }
        if let destinationURL,
           let infoHash = task.infoHash?.trimmedForEngine,
           !infoHash.isEmpty {
            companions.append(
                destinationURL
                    .appendingPathComponent(infoHash + ".aria2")
                    .standardizedFileURL
            )
        }
        return uniqueURLs(companions)
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []
        for url in urls where seen.insert(url.path).inserted {
            unique.append(url)
        }
        return unique
    }
}

nonisolated enum DownloadFileTrashError: LocalizedError, Equatable, Sendable {
    case noReportedFiles(taskName: String)
    case moveToTrashFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .noReportedFiles(let taskName):
            String(localized: "Aria2 Next did not report any file paths for \(taskName), so ChopChop cannot move files to Trash safely.")
        case .moveToTrashFailed(let path, let reason):
            String(localized: "Could not move \(path) to Trash.\n\(reason)")
        }
    }
}
