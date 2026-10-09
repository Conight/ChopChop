import AppKit
import SwiftUI

/// Observe the owning NSWindow, so a different active window doesn't keep hidden details polling.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool
    func makeNSView(context: Context) -> ObserverView { ObserverView { visible = $0 } }
    func updateNSView(_ view: ObserverView, context: Context) { view.changed = { visible = $0 } }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stop() }

    final class ObserverView: NSView {
        var changed: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var lastValue: Bool?
        private var revision = 0
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { update(); return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    let closing = notification.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.update(closing: closing) }
                })
            }
            update()
        }
        func stop() {
            revision += 1
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }
        private func update(closing: Bool = false) {
            let value = !closing && window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
            guard lastValue != value else { return }
            lastValue = value; revision += 1
            let request = revision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == request else { return }
                self.changed(value)
            }
        }
    }
}
