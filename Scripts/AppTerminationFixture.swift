import AppKit

/// A windowless app using the production quit path, including asynchronous
/// cleanup. Controlled by files so the integration tests never simulate input.
@MainActor
final class TerminationFixtureDelegate: NSObject, NSApplicationDelegate {
    let termination = AppTermination.shared
    let root: URL
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    init(root: URL) { self.root = root }

    func record(_ event: String) {
        try! Data().write(to: root.appendingPathComponent("\(version)-\(event)"))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        record("launched")
        Task { @MainActor in
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("request-quit-\(version)").path) {
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
