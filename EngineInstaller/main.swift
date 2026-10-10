import Darwin
import Foundation
import Security

/// Authenticated on-demand installer for the managed Engine and signed ChopChop updates.
/// The UI and Engine remain sandboxed; this service creates executables and stages updates
/// without administrator privileges or a user-selected executable location.
final class EngineInstallerService: NSObject, EngineInstallerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private weak var connection: NSXPCConnection?
    private var appTask: Task<Void, Never>?
    private var appJob: AppUpdateInstallation.Job?
    private var appToken: String?
    private var appWorker: Process?
    private var cancelled = false

    init(connection: NSXPCConnection) { self.connection = connection }

    private func report(_ update: EngineInstallationProgress) {
        guard let data = try? JSONEncoder().encode(update),
              let reporter = connection?.remoteObjectProxy as? EngineInstallerProgressReporting else { return }
        reporter.reportProgress(data)
    }

    func install(version: String, directoryBookmark: Data, reply: @escaping @Sendable (String?, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { reply(nil, "An installation is already in progress."); return }
        task = Task {
            do {
                guard let parsed = EngineVersion(version), parsed.description == version else { throw EngineInstallationError.invalidRelease }
                var stale = false
                let root = try URL(resolvingBookmarkData: directoryBookmark, options: [.withoutUI], bookmarkDataIsStale: &stale)
                // Resolving an implicit bookmark begins access; balance it once.
                defer { root.stopAccessingSecurityScopedResource() }
                let container = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Containers/\(ReleaseConfiguration.current.bundleIdentifier)/Data").resolvingSymlinksInPath()
                let resolved = root.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(container.path + "/"), resolved.lastPathComponent == EngineStorage.installationsDirectoryName,
                      resolved.deletingLastPathComponent().lastPathComponent == EngineStorage.supportDirectoryName else {
                    throw EngineInstallationError.installationFailed("Invalid engine installation directory.")
                }
                let identifier = UUID().uuidString
                let folder = resolved.appendingPathComponent(identifier, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                var finished = false
                defer { if !finished { try? FileManager.default.removeItem(at: folder) } }
                try await EngineDownload.downloadAndPrepare(version: parsed, destination: folder.appendingPathComponent(EngineStorage.executableName),
                                                           progress: { update in self.report(update) })
                try Task.checkCancellation()
                finished = true
                reply(identifier, nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    func cancel(preservePrepared: Bool = false) {
        lock.lock()
        task?.cancel()
        cancelled = true
        appTask?.cancel()
        if !preservePrepared, appWorker?.isRunning != true, let appJob,
           !AppUpdateInstallation.workerIsRunning(in: appJob.directory) { try? FileManager.default.removeItem(at: appJob.directory) }
        lock.unlock()
    }

    func discardUpdate(reply: @escaping @Sendable () -> Void) { cancel(); reply() }

    func resumeUpdate(version: String, reply: @escaping @Sendable (String?, String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard appTask == nil, !cancelled, let connection, let version = AppVersion(version) else {
            reply(nil, AppUpdateError.installerUnavailable.rawValue); return
        }
        let pid = connection.processIdentifier
        appTask = Task { [self] in
            do {
                guard let job = try AppUpdateInstallation.resume(version: version, target: AppUpdateInstallation.installedApp(), parentPID: pid) else { reply(nil, nil); return }
                let token = UUID().uuidString
                let accepted = lock.withLock {
                    guard !cancelled else { return false }
                    appJob = job; appToken = token; return true
                }
                guard accepted else { throw CancellationError() }
                reply(token, nil)
            } catch { reply(nil, (error as? AppUpdateError ?? .invalidApplication).rawValue) }
        }
    }

    func updateInstallationStatus(token: String, reply: @escaping @Sendable (String) -> Void) {
        let status: AppUpdateInstallationStatus = lock.withLock {
            guard token == appToken else { return .failed }
            if appWorker?.isRunning == true || appJob.map({ AppUpdateInstallation.workerIsRunning(in: $0.directory) }) == true { return .waitingForExit }
            if let job = appJob, let data = try? Data(contentsOf: job.directory.appendingPathComponent(AppUpdateStorage.workerErrorFile)),
               (try? JSONDecoder().decode(AppUpdateError.self, from: data)) == .terminationTimedOut { return .terminationTimedOut }
            return .failed
        }
        reply(status.rawValue)
    }

    func prepare(version: String, reply: @escaping @Sendable (String?, String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard appTask == nil, !cancelled, let connection else { reply(nil, AppUpdateError.installerUnavailable.rawValue); return }
        let pid = connection.processIdentifier
        appTask = Task { [self] in
            do {
                guard let version = AppVersion(version) else { throw AppUpdateError.invalidResponse }
                let job = try await AppUpdateInstallation.prepare(version: version, target: AppUpdateInstallation.installedApp(), parentPID: pid) { [weak self] update in
                    guard let data = try? JSONEncoder().encode(update),
                          let reporter = self?.connection?.remoteObjectProxy as? EngineInstallerProgressReporting else { return }
                    reporter.reportAppUpdateProgress(data)
                }
                let token = UUID().uuidString
                let accepted = self.lock.withLock {
                    guard !self.cancelled else { return false }
                    self.appJob = job; self.appToken = token
                    return true
                }
                guard accepted else { try? FileManager.default.removeItem(at: job.directory); throw CancellationError() }
                reply(token, nil)
            } catch { reply(nil, (error as? AppUpdateError ?? .downloadFailed).rawValue) }
        }
    }

    func install(token: String, reply: @escaping @Sendable (Bool, String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, token == appToken, let job = appJob else { reply(false, AppUpdateError.installerUnavailable.rawValue); return }
        // Installation handoff is idempotent when a client reconnects or retries a lost acknowledgement.
        if appWorker?.isRunning == true || AppUpdateInstallation.workerIsRunning(in: job.directory) { reply(true, nil); return }
        do {
            appWorker = try AppUpdateInstallation.launchWorker(job)
            reply(true, nil)
        } catch { reply(false, (error as? AppUpdateError ?? .installationFailed).rawValue) }
    }
}

final class InstallerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Accept only the containing app's designated code-signing requirement.
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var appCode: SecStaticCode?
        var requirement: SecRequirement?
        var caller: SecCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &appCode) == errSecSuccess,
              let appCode,
              SecCodeCopyDesignatedRequirement(appCode, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: connection.processIdentifier] as CFDictionary, [], &caller) == errSecSuccess,
              let caller, SecCodeCheckValidity(caller, [], requirement) == errSecSuccess else { return false }
        connection.remoteObjectInterface = NSXPCInterface(with: EngineInstallerProgressReporting.self)
        let service = EngineInstallerService(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: EngineInstallerProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { service.cancel(preservePrepared: true) }
        connection.resume()
        return true
    }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--apply-app-update" {
    // The worker must outlive both the app and the on-demand XPC service's process group.
    guard getpgrp() == getpid() || setpgid(0, 0) == 0 else { exit(1) }
    do { try AppUpdateInstallation.applyJob(at: URL(fileURLWithPath: CommandLine.arguments[2])) }
    catch { exit(1) }
} else {
    let delegate = InstallerDelegate()
    let listener = NSXPCListener.service()
    listener.delegate = delegate
    listener.resume()
}
