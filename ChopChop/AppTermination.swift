import AppKit

/// Enter AppKit's termination loop outside the main dispatch queue. Calling
/// terminate directly from a MainActor task keeps that queue occupied while
/// terminateLater waits, preventing asynchronous session cleanup from running.
@MainActor
final class AppTermination {
    static let shared = AppTermination()
    private var isPreparing = false
    private init() {}

    static func request() {
        guard !shared.isPreparing else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: NSApp as Any,
                                               selector: #selector(NSApplication.terminate(_:)), object: nil)
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil,
                      afterDelay: 0, inModes: [.common])
    }

    func shouldTerminate(_ application: NSApplication,
                         prepare: @escaping @MainActor () async -> Void) -> NSApplication.TerminateReply {
        guard !isPreparing else { return .terminateLater }
        isPreparing = true
        Task { @MainActor in
            await prepare()
            application.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
