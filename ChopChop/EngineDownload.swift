import CryptoKit
import Foundation

nonisolated enum EngineDownload {
    private struct GitHubRelease: Decodable {
        var tag_name: String
        var draft: Bool
        var prerelease: Bool
        var assets: [Asset]
        struct Asset: Decodable { var name: String; var browser_download_url: URL }
    }

    static func parseRelease(_ data: Data) throws -> EngineRelease {
        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !payload.draft, !payload.prerelease, let version = EngineVersion(payload.tag_name),
              payload.tag_name == "v\(version)" else { throw EngineInstallationError.invalidRelease }
        let prefix = "https://github.com/AnInsomniacy/aria2-next/releases/download/v\(version)/"
        let binaryName = "aria2-next-\(version)-macos-arm64"
        let checksumName = "aria2-next-\(version)-checksums.sha256"
        guard let binary = payload.assets.first(where: { $0.name == binaryName }),
              let checksums = payload.assets.first(where: { $0.name == checksumName }),
              binary.browser_download_url.absoluteString == prefix + binaryName,
              checksums.browser_download_url.absoluteString == prefix + checksumName else {
            throw EngineInstallationError.invalidRelease
        }
        return EngineRelease(version: version, downloadURL: binary.browser_download_url, checksumURL: checksums.browser_download_url)
    }

    @concurrent static func latestRelease() async throws -> EngineRelease {
        let session = Self.session(timeout: 15)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/AnInsomniacy/aria2-next/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try Self.parseRelease(data)
    }

    static func verifyDownload(_ data: Data, checksums: Data, release: EngineRelease) throws {
        let filename = release.downloadURL.lastPathComponent
        let entries = String(decoding: checksums, as: UTF8.self).split(whereSeparator: \.isNewline)
        let hashes = entries.compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == filename else { return nil }
            return String(fields[0]).lowercased()
        }
        guard hashes.count == 1, hashes[0] == sha256(data) else { throw EngineInstallationError.invalidChecksum }
        // Thin arm64 Mach-O; do not run an unexpected architecture or an HTML error page.
        guard data.count > 32, Array(data.prefix(8)) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1] else {
            throw EngineInstallationError.invalidExecutable
        }
    }

    @concurrent static func downloadAndPrepare(version: EngineVersion, destination: URL,
                                              progress: @escaping @Sendable (EngineInstallationProgress) -> Void = { _ in }) async throws {
        let base = "https://github.com/AnInsomniacy/aria2-next/releases/download/v\(version)/aria2-next-\(version)"
        let release = EngineRelease(version: version, downloadURL: URL(string: base + "-macos-arm64")!, checksumURL: URL(string: base + "-checksums.sha256")!)
        progress(.init(stage: .connecting))
        let (data, response) = try await EngineBinaryDownload(progress: progress).download(from: release.downloadURL)
        try validate(response)
        progress(.init(stage: .downloading, completedBytes: Int64(data.count), totalBytes: Int64(data.count)))
        let session = session(timeout: 30)
        defer { session.invalidateAndCancel() }
        try Task.checkCancellation()
        progress(.init(stage: .verifying))
        let (checksums, checksumResponse) = try await session.data(from: release.checksumURL)
        try validate(checksumResponse)
        try verifyDownload(data, checksums: checksums, release: release)
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw EngineInstallationError.installationFailed(String(localized: "The destination already exists."))
        }
        try data.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        progress(.init(stage: .preparing))
        try await prepareExecutable(destination)
    }

    static func prepareExecutable(_ executable: URL) async throws {
        let entitlements = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: entitlements) }
        let data = try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.app-sandbox": true, "com.apple.security.inherit": true], format: .xml, options: 0)
        try data.write(to: entitlements)
        _ = try await runTool("/usr/bin/codesign", arguments: ["--force", "--sign", "-", "--timestamp=none", "--options", "runtime",
                                                           "--identifier", "com.conight.ChopChop.aria2-next", "--entitlements", entitlements.path, executable.path])
        _ = try await runTool("/usr/bin/codesign", arguments: ["--verify", "--strict", executable.path])
    }

    private static func session(timeout: TimeInterval) -> URLSession {
        URLSession(configuration: configuration(timeout: timeout))
    }

    static func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = min(timeout, 30)
        configuration.timeoutIntervalForResource = timeout
        configuration.httpAdditionalHeaders = ["User-Agent": "ChopChop"]
        return configuration
    }
    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw EngineInstallationError.unexpectedResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func runTool(_ path: String, arguments: [String], timeoutInterval: TimeInterval = 20) async throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try Task.checkCancellation()
        try process.run()
        return try await withTaskCancellationHandler {
            let result: (Int32, Data) = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutInterval, execute: timeout)
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timeout.cancel()
                    continuation.resume(returning: (process.terminationStatus, data))
                }
            }
            try Task.checkCancellation()
            let text = String(decoding: result.1, as: UTF8.self)
            guard result.0 == 0 else { throw EngineInstallationError.installationFailed(String(text.prefix(2_000))) }
            return text
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// URLSession calls its delegate on a serial queue; the lock also protects direct test callbacks.
nonisolated final class EngineDownloadProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (EngineInstallationProgress) -> Void
    private let lock = NSLock()
    private var lastReportTime = ProcessInfo.processInfo.systemUptime
    private var lastReportBytes: Int64 = 0
    private var hasReported = false

    init(progress: @escaping @Sendable (EngineInstallationProgress) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Reject an unexpectedly large response during transfer, too.
        guard totalBytesWritten <= 64 * 1_024 * 1_024,
              totalBytesExpectedToWrite <= 64 * 1_024 * 1_024 else { downloadTask.cancel(); return }
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastReportTime
        let finished = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard !hasReported || elapsed >= 0.2 || finished else { lock.unlock(); return }
        let speed = elapsed > 0 ? Double(max(0, totalBytesWritten - lastReportBytes)) / elapsed : 0
        lastReportTime = now
        lastReportBytes = totalBytesWritten
        hasReported = true
        lock.unlock()
        progress(.init(stage: .downloading, completedBytes: totalBytesWritten,
                       totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil,
                       bytesPerSecond: speed))
    }

    // The async download API owns completion and delivers the temporary URL to its caller.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

/// A session-level download delegate is required for byte callbacks. Own the temporary
/// file's contents before returning from didFinishDownloadingTo, as Foundation requires.
nonisolated final class EngineBinaryDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let reporter: EngineDownloadProgressReporter
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
    private var task: URLSessionDownloadTask?
    private var result: Result<(Data, URLResponse), any Error>?
    private var downloadedData: Data?

    init(progress: @escaping @Sendable (EngineInstallationProgress) -> Void) {
        reporter = EngineDownloadProgressReporter(progress: progress)
    }

    func download(from url: URL) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: EngineDownload.configuration(timeout: 180), delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                let task = session.downloadTask(with: url)
                self.task = task
                task.resume()
                lock.unlock()
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard max(totalBytesWritten, totalBytesExpectedToWrite) <= 64 * 1_024 * 1_024 else {
            finish(.failure(EngineInstallationError.invalidExecutable))
            return
        }
        reporter.urlSession(session, downloadTask: downloadTask, didWriteData: bytesWritten,
                            totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 64 * 1_024 * 1_024 else { throw EngineInstallationError.invalidExecutable }
            let data = try Data(contentsOf: location)
            lock.lock()
            downloadedData = data
            lock.unlock()
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let data = downloadedData
        lock.unlock()
        if let error { finish(.failure(error)) }
        else if let data, let response = task.response { finish(.success((data, response))) }
        else { finish(.failure(EngineInstallationError.invalidExecutable)) }
    }

    private func finish(_ result: Result<(Data, URLResponse), any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        let task = task
        self.task = nil
        lock.unlock()
        if case .failure = result { task?.cancel() }
        continuation?.resume(with: result)
    }
}
