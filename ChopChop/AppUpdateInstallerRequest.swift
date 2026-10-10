import Foundation

nonisolated protocol AppUpdateInstalling: Sendable {
    func prepare(version: String, progress: @escaping @Sendable (AppUpdateProgress) -> Void) async throws -> String
    func install(token: String) async throws
    func resume(version: String) async throws -> String?
    func status(token: String) async throws -> AppUpdateInstallationStatus
    func disconnect()
    func cancel()
}

nonisolated final class AppUpdateInstallerRequest: NSObject, EngineInstallerProgressReporting, AppUpdateInstalling, @unchecked Sendable {
    private let connection = NSXPCConnection(serviceName: ReleaseConfiguration.current.installerIdentifier)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var progress: (@Sendable (AppUpdateProgress) -> Void)?
    private var cancelled = false
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        connection.remoteObjectInterface = NSXPCInterface(with: EngineInstallerProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: EngineInstallerProgressReporting.self)
        connection.exportedObject = self
        connection.interruptionHandler = { [weak self] in self?.finish(.failure(AppUpdateError.installerUnavailable)) }
        connection.invalidationHandler = { [weak self] in self?.finish(.failure(AppUpdateError.installerUnavailable)) }
        connection.resume()
    }

    func prepare(version: String, progress: @escaping @Sendable (AppUpdateProgress) -> Void) async throws -> String {
        lock.withLock { self.progress = progress }
        return try await request(timeout: .seconds(900)) { proxy, done in
            proxy.prepare(version: version) { token, error in
                done(token.map(Result.success) ?? .failure(AppUpdateError(rawValue: error ?? "") ?? .installationFailed))
            }
        }
    }

    func install(token: String) async throws {
        _ = try await request(timeout: .seconds(20)) { proxy, done in
            proxy.install(token: token) { success, error in
                done(success ? .success(token) : .failure(AppUpdateError(rawValue: error ?? "") ?? .installationFailed))
            }
        }
    }

    func resume(version: String) async throws -> String? {
        let value = try await request(timeout: .seconds(30)) { proxy, done in
            proxy.resumeUpdate(version: version) { token, error in
                if let error { done(.failure(AppUpdateError(rawValue: error) ?? .invalidApplication)) }
                else { done(.success(token ?? "")) }
            }
        }
        return value.isEmpty ? nil : value
    }

    func status(token: String) async throws -> AppUpdateInstallationStatus {
        let value = try await request(timeout: .seconds(10)) { proxy, done in
            proxy.updateInstallationStatus(token: token) { done(.success($0)) }
        }
        guard let status = AppUpdateInstallationStatus(rawValue: value) else { throw AppUpdateError.installerUnavailable }
        return status
    }

    private func request(timeout: Duration, _ send: (any EngineInstallerProtocol, @escaping @Sendable (Result<String, any Error>) -> Void) -> Void) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let accepted = lock.withLock {
                    guard !cancelled, self.continuation == nil else { return false }
                    self.continuation = continuation
                    timeoutTask = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        self?.finish(.failure(AppUpdateError.installerUnavailable))
                    }
                    return true
                }
                guard accepted else { continuation.resume(throwing: CancellationError()); return }
                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in self?.finish(.failure(AppUpdateError.installerUnavailable)) }
                guard let proxy = proxy as? EngineInstallerProtocol else { finish(.failure(AppUpdateError.installerUnavailable)); return }
                send(proxy) { [weak self] result in self?.finish(result) }
            }
        } onCancel: { self.cancel() }
    }

    func reportProgress(_ data: Data) {}
    func reportAppUpdateProgress(_ data: Data) {
        guard let update = try? JSONDecoder().decode(AppUpdateProgress.self, from: data) else { return }
        let callback = lock.withLock { cancelled ? nil : progress }
        callback?(update)
    }
    private func finish(_ result: Result<String, any Error>) {
        let pending = lock.withLock { let pending = continuation; continuation = nil; timeoutTask?.cancel(); timeoutTask = nil; return pending }
        pending?.resume(with: result)
    }
    func disconnect() {
        lock.withLock { cancelled = true; progress = nil }
        finish(.failure(CancellationError()))
        connection.invalidate(); connection.exportedObject = nil
    }
    func cancel() {
        lock.withLock { cancelled = true; progress = nil }
        finish(.failure(CancellationError()))
        let close: @Sendable () -> Void = { [self] in connection.invalidate(); connection.exportedObject = nil }
        if let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in close() }) as? EngineInstallerProtocol {
            proxy.discardUpdate(reply: close)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: close)
        } else { close() }
    }
}
