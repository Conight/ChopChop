import Foundation
import Security

/// Private, on-demand installer. It only accepts a release version and the app's Engines folder.
/// The UI and engine remain sandboxed; this service owns executable creation so installation
/// does not require a user-selected executable location or any administrator privileges.
final class EngineInstallerService: NSObject, EngineInstallerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private weak var connection: NSXPCConnection?

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
                    .appendingPathComponent("Library/Containers/com.conight.ChopChop/Data").resolvingSymlinksInPath()
                let resolved = root.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(container.path + "/"), resolved.lastPathComponent == "Engines",
                      resolved.deletingLastPathComponent().lastPathComponent == "ChopChop" else {
                    throw EngineInstallationError.installationFailed("Invalid engine installation directory.")
                }
                let identifier = UUID().uuidString
                let folder = resolved.appendingPathComponent(identifier, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                var finished = false
                defer { if !finished { try? FileManager.default.removeItem(at: folder) } }
                try await EngineDownload.downloadAndPrepare(version: parsed, destination: folder.appendingPathComponent("aria2-next"),
                                                           progress: { update in self.report(update) })
                try Task.checkCancellation()
                finished = true
                reply(identifier, nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    func cancel() {
        lock.lock()
        task?.cancel()
        lock.unlock()
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
        connection.invalidationHandler = { service.cancel() }
        connection.resume()
        return true
    }
}

let delegate = InstallerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
