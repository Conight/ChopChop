import Foundation

/// A single cancellable request. Replies, disconnection and cancellation share one completion gate.
nonisolated final class EngineInstallerRequest: NSObject, EngineInstallerProgressReporting, @unchecked Sendable {
    private let connection = NSXPCConnection(serviceName: ReleaseConfiguration.current.installerIdentifier)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var result: Result<String, any Error>?
    private let updates = AsyncStream<EngineInstallationProgress>.makeStream(bufferingPolicy: .unbounded)

    func install(version: String, directoryBookmark: Data,
                 progress: @escaping @Sendable (EngineInstallationProgress) async -> Void = { _ in }) async throws -> String {
        let reporting = Task {
            for await update in updates.stream { await progress(update) }
        }
        do {
            let directory = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    start(version: version, bookmark: directoryBookmark, continuation: continuation)
                }
            } onCancel: { finish(.failure(CancellationError())) }
            await reporting.value
            return directory
        } catch {
            await reporting.value
            throw error
        }
    }

    func reportProgress(_ data: Data) {
        guard let update = try? JSONDecoder().decode(EngineInstallationProgress.self, from: data) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        updates.continuation.yield(update)
    }

    func reportAppUpdateProgress(_ data: Data) {}

    private func start(version: String, bookmark: Data, continuation: CheckedContinuation<String, any Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
        connection.remoteObjectInterface = NSXPCInterface(with: EngineInstallerProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: EngineInstallerProgressReporting.self)
        connection.exportedObject = self
        connection.interruptionHandler = { [weak self] in
            self?.finish(.failure(EngineInstallationError.installationFailed(String(localized: "The installer connection was interrupted. Please retry."))))
        }
        connection.invalidationHandler = { [weak self] in
            self?.finish(.failure(EngineInstallationError.installationFailed(String(localized: "The installer is unavailable. Please retry or reinstall ChopChop."))))
        }
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in self?.finish(.failure(error)) }
        guard let installer = proxy as? EngineInstallerProtocol else {
            finish(.failure(EngineInstallationError.installationFailed(String(localized: "The installer could not be reached."))))
            return
        }
        installer.install(version: version, directoryBookmark: bookmark) { [weak self] directory, error in
            if let directory { self?.finish(.success(directory)) }
            else { self?.finish(.failure(EngineInstallationError.installationFailed(error ?? String(localized: "Please retry.")))) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.finish(.failure(URLError(.timedOut)))
        }
    }

    private func finish(_ result: Result<String, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        updates.continuation.finish()
        connection.invalidate()
        connection.exportedObject = nil
        continuation?.resume(with: result)
    }
}
