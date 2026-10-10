import AppKit

/// A windowless app using the production quit path, including asynchronous
/// cleanup. Controlled by files so the integration tests never simulate input.
@MainActor
final class TerminationFixtureDelegate: NSObject, NSApplicationDelegate {
    let termination = AppTermination.shared
    let root: URL
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    private var installerConnection: NSXPCConnection?

    init(root: URL) { self.root = root }

    func record(_ event: String) {
        try! Data().write(to: root.appendingPathComponent("\(version)-\(event)"))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        record("launched")
        Task { @MainActor in
            var startedInstaller = false
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("request-quit-\(version)").path) {
                if version == "1", !startedInstaller,
                   FileManager.default.fileExists(atPath: root.appendingPathComponent("request-xpc-install").path) {
                    startedInstaller = true
                    do {
                        try await handOffUpdate()
                        record("install-acknowledged")
                    } catch {
                        try? String(describing: error).write(to: root.appendingPathComponent("xpc-error"), atomically: true, encoding: .utf8)
                    }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            record("requested")
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("legacy-direct-quit").path) {
                NSApp.terminate(nil)
            } else {
                AppTermination.request()
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("repeat-quit").path) {
                    AppTermination.request()
                }
            }
        }
    }

    /// Exercise the production embedded service from the app which is quitting.
    /// A worker launched by the test driver does not inherit this XPC relationship.
    private func handOffUpdate() async throws {
        let identifier = Bundle.main.bundleIdentifier! + ".EngineInstaller"
        let connection = NSXPCConnection(serviceName: identifier)
        connection.remoteObjectInterface = NSXPCInterface(with: EngineInstallerProtocol.self)
        installerConnection = connection
        connection.resume()
        let token: String = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! EngineInstallerProtocol
            proxy.resumeUpdate(version: "1.0.0-beta.2") { token, error in
                if let token { continuation.resume(returning: token) }
                else { continuation.resume(throwing: NSError(domain: error ?? "Missing prepared update", code: 1)) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! EngineInstallerProtocol
            proxy.install(token: token) { accepted, error in
                if accepted { continuation.resume() }
                else { continuation.resume(throwing: NSError(domain: error ?? "Missing install acknowledgement", code: 1)) }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.shouldTerminate(sender) { [self] in
            record("preparing")
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("repeat-quit").path) {
                AppTermination.request()
            }
            // Both starting cleanup and resuming it after suspension need the
            // main actor to stay available inside AppKit's termination loop.
            try? await Task.sleep(for: .milliseconds(50))
            record("saved")
        }
    }

    func applicationWillTerminate(_ notification: Notification) { record("terminated") }
}

@main
struct AppTerminationFixture {
    @MainActor static func main() {
        let root = CommandLine.arguments.count > 1 && CommandLine.arguments[1].hasPrefix("/")
            ? URL(fileURLWithPath: CommandLine.arguments[1])
            : Bundle.main.bundleURL.deletingLastPathComponent()
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = TerminationFixtureDelegate(root: root)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
