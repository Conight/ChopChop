import Foundation

/// Streams to a private staging file; the delegate owns Foundation's temporary URL before returning.
nonisolated final class AppUpdateTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedSize: Int64
    private let progress: @Sendable (AppUpdateProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var session: URLSession?
    private var download: URLSessionDownloadTask?
    private var cancelled = false
    private var saved = false
    private var sizeRejected = false
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private var lastBytes: Int64 = 0

    init(destination: URL, expectedSize: Int64, progress: @escaping @Sendable (AppUpdateProgress) -> Void) {
        self.destination = destination; self.expectedSize = expectedSize; self.progress = progress
    }
    func receive(from url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
                config.httpAdditionalHeaders = ["User-Agent": "ChopChop"]
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url); download = task
                lock.unlock()
                lastTime = ProcessInfo.processInfo.systemUptime
                progress(.init(stage: .downloading, totalBytes: expectedSize))
                task.resume()
            }
        } onCancel: {
            let task = self.lock.withLock { self.cancelled = true; return self.download }
            task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= expectedSize,
              totalBytesExpectedToWrite <= 0 || totalBytesExpectedToWrite == expectedSize else {
            sizeRejected = true; downloadTask.cancel(); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastTime
        guard lastBytes == 0 || elapsed >= 0.15 || totalBytesWritten == expectedSize else { return }
        progress(.init(stage: .downloading, completedBytes: totalBytesWritten, totalBytes: expectedSize,
                       bytesPerSecond: Double(max(0, totalBytesWritten - lastBytes)) / max(elapsed, 0.001)))
        lastTime = now; lastBytes = totalBytesWritten
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,
              let size = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == expectedSize else { return }
        do { try FileManager.default.moveItem(at: location, to: destination); saved = true } catch { saved = false }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (pending, cancelled) = lock.withLock {
            let value = continuation; continuation = nil
            self.session = nil; download = nil
            return (value, self.cancelled)
        }
        session.finishTasksAndInvalidate()
        if cancelled { pending?.resume(throwing: CancellationError()) }
        else if sizeRejected { pending?.resume(throwing: AppUpdateError.invalidSignature) }
        else if error != nil || !saved { pending?.resume(throwing: AppUpdateError.downloadFailed) }
        else { pending?.resume() }
    }
}


nonisolated protocol AppUpdateArchiveDownloading: Sendable {
    func download(_ archive: AppUpdateArchive, progress: @escaping @Sendable (AppUpdateProgress) -> Void) async throws -> DownloadedAppUpdateArchive
}

/// Legacy packages download inside the app too; only the signed XPC path can replace the app.
nonisolated struct AppUpdateArchiveDownloader: AppUpdateArchiveDownloading {
    var directory: URL?
    var assetURL: @Sendable (AppVersion, String) -> URL = { AppUpdateManifest.assetURL(version: $0, name: $1) }

    @concurrent func download(_ archive: AppUpdateArchive, progress: @escaping @Sendable (AppUpdateProgress) -> Void) async throws -> DownloadedAppUpdateArchive {
        guard archive.size > 0, archive.size <= AppUpdateManifest.maximumSize else { throw AppUpdateError.noCompatibleRelease }
        progress(.init(stage: .connecting))
        let hash: String
        if let supplied = archive.sha256 {
            guard AppUpdateArchive.validDigest(supplied) else { throw AppUpdateError.invalidSignature }
            hash = supplied
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: assetURL(archive.version, archive.filename + ".sha256"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppUpdateError.downloadFailed }
            hash = try AppUpdateArchive.checksum(from: data, filename: archive.filename)
        }
        try Task.checkCancellation()
        let root = try directory ?? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ChopChop/App Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Retain completed installers briefly so Finder can open them; never remove a recent or foreign directory.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? [] {
            if url.lastPathComponent.hasPrefix("installer-"), UUID(uuidString: String(url.lastPathComponent.dropFirst(10))) != nil,
               let values = try? url.resourceValues(forKeys: keys), values.isDirectory == true, values.isSymbolicLink != true,
               let created = values.creationDate, created < Date().addingTimeInterval(-7 * 86_400) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let job = root.appendingPathComponent("installer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: job) } }
        let url = job.appendingPathComponent(archive.filename)
        try await AppUpdateTransfer(destination: url, expectedSize: archive.size, progress: progress)
            .receive(from: assetURL(archive.version, archive.filename))
        try Task.checkCancellation()
        progress(.init(stage: .verifying))
        let result = DownloadedAppUpdateArchive(url: url, size: archive.size, sha256: hash)
        try await result.verify()
        finished = true
        return result
    }
}
