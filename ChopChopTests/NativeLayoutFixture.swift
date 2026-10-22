import AppKit
import SwiftUI
import XCTest

/// Layout assertions don't need PNG encoding, a compositor frame rate or a guessed delay.
/// Drain queued observation work, then ask AppKit for the current layout explicitly.
@MainActor
enum NativeLayout {
    static func flush(_ view: NSView) async {
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            view.window?.layoutIfNeeded()
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
    }

    static func wait(until description: String, timeout: Duration = .seconds(3),
                     file: StaticString = #filePath, line: UInt = #line,
                     condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                throw ReadinessTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct ReadinessTimeout: Error {}
}

@MainActor
final class NativeLayoutFixture<V: View> {
    let controller: NSHostingController<V>
    let window: NSWindow
    private let previousAppearance: NSAppearance?

    init(_ view: V, size: NSSize, appearance: NSAppearance.Name, windowChrome: Bool, settingsToolbar: Bool = false) {
        previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        controller = NSHostingController(rootView: view)
        controller.sizingOptions = windowChrome ? [.minSize] : []
        controller.view.frame = NSRect(origin: .zero, size: size)
        window = LayoutPreviewWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: windowChrome ? [.titled, .closable, .resizable, .fullSizeContentView] : [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        if settingsToolbar { window.toolbarStyle = .unified }
        window.contentViewController = controller
        window.setContentSize(size)
        window.alphaValue = 0
        window.animationBehavior = .none
        if windowChrome { window.orderBack(nil) }
    }

    func close() {
        window.close()
        NSApp.appearance = previousAppearance
    }
}

// Layout canvases must not shrink to the runner's display resolution.
// Screen-edge behavior is tested separately with an ordinary NSWindow.
final class LayoutPreviewWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Observe every frame change, including transients between display frames.
/// Keep this alive across presentation, layout and dismissal of a child panel.
@MainActor
final class WindowFrameObservation {
    private var tokens: [NSObjectProtocol] = []
    private(set) var changes: [NSRect] = []

    init(_ window: NSWindow) {
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if let window { self?.changes.append(window.frame) }
                }
            })
        }
    }

    isolated deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
