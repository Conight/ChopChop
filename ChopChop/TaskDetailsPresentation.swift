import AppKit
import Combine
import SwiftUI

enum TaskDetailSection: Hashable { case speedLimits, schedule }
struct TaskDetailRequest: Equatable {
    let id = UUID()
    var section: TaskDetailSection
}

/// Window-local presentation state. Download selection and engine state stay in the store.
@MainActor
final class TaskDetailsPresentation: NSObject, ObservableObject, NSWindowDelegate {
    @Published var sectionRequest: TaskDetailRequest?
    @Published var selectedTab: InspectorTab = .overview
    private var rememberedFrame: NSRect?
    private var observedTaskID: String?
    @Published private(set) var isPresented = false
    @Published private(set) var scenePhase: ScenePhase = .inactive
    private(set) weak var owner: NSWindow?
    private(set) var panel: TaskDetailsPanel?
    private weak var returnResponder: NSResponder?
    private var ownerCloseObserver: NSObjectProtocol?
    private var activityObservers: [NSObjectProtocol] = []
    private var moveSelection: ((Int) -> Void)?

    func attach(to window: NSWindow?) {
        guard owner !== window else { return }
        dismiss(returnFocus: false)
        if let ownerCloseObserver { NotificationCenter.default.removeObserver(ownerCloseObserver) }
        owner = window
        guard let window else { return }
        ownerCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(returnFocus: false) }
            }
        if activityObservers.isEmpty {
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                activityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateActivity() }
                })
            }
        }
    }

    func selectionChanged(to id: String?) {
        if observedTaskID != id { sectionRequest = nil }
        observedTaskID = id
        if id == nil { dismiss(returnFocus: false) }
    }

    func present(store: DownloadStore, moveSelection: @escaping (Int) -> Void) {
        guard store.selectedTask != nil, let owner, owner.attachedSheet == nil else { return }
        self.moveSelection = moveSelection
        if isPresented { panel?.makeKeyAndOrderFront(nil); return }
        returnResponder = owner.firstResponder
        if panel == nil {
            let panel = TaskDetailsPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = String(localized: "Download Details")
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.titlebarSeparatorStyle = .none
            panel.isMovableByWindowBackground = true
            panel.identifier = NSUserInterfaceItemIdentifier("ChopChop.TaskDetails")
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.isFloatingPanel = true
            panel.contentMinSize = NSSize(width: 520, height: 480)
            panel.delegate = self
            panel.onDismiss = { [weak self] in self?.dismiss() }
            panel.onMoveSelection = { [weak self] direction in self?.moveSelection?(direction) }
            self.panel = panel
        }
        guard let panel else { return }
        // A normal hosting controller in a separate native window keeps the main
        // window's navigation, safe areas, toolbar and dimensions untouched.
        let content = NSHostingController(rootView: TaskDetailsPanelContent(store: store, presentation: self))
        content.sizingOptions = []
        content.view.frame = NSRect(origin: .zero, size: panel.contentView?.bounds.size ?? panel.frame.size)
        panel.contentViewController = content
        panel.alphaValue = owner.alphaValue
        let screen = owner.screen?.visibleFrame ?? owner.frame
        let proposed = rememberedFrame ?? NSRect(
            x: owner.frame.midX - panel.frame.width / 2, y: owner.frame.midY - panel.frame.height / 2,
            width: panel.frame.width, height: panel.frame.height)
        panel.setFrame(Self.fittedFrame(proposed, screens: NSScreen.screens.map(\.visibleFrame), fallback: screen), display: false)
        owner.addChildWindow(panel, ordered: .above)
        isPresented = true
        updateActivity()
        // Explicitly opening details transfers keyboard focus and lets AppKit
        // render the panel as active; dismiss() restores the list responder.
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss(returnFocus: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        scenePhase = .inactive
        if let panel {
            rememberedFrame = panel.frame
            owner?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentViewController = nil // Cancels task-scoped RPC observation.
        }
        moveSelection = nil
        if returnFocus, let owner, owner.isVisible {
            owner.makeKey()
            if let returnResponder { owner.makeFirstResponder(returnResponder) }
        }
        returnResponder = nil
    }

    /// Use the display containing the saved panel; recover onto the owner display when it disappears.
    static func fittedFrame(_ proposed: NSRect, screens: [NSRect], fallback: NSRect) -> NSRect {
        let display = screens.max { a, b in
            let x = a.intersection(proposed), y = b.intersection(proposed)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        }.flatMap { $0.intersects(proposed) ? $0 : nil } ?? fallback
        var frame = proposed
        frame.size.width = min(frame.width, display.width)
        frame.size.height = min(frame.height, display.height)
        frame.origin.x = min(max(frame.minX, display.minX), display.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, display.minY), display.maxY - frame.height)
        return frame
    }

    func windowDidMove(_ notification: Notification) { rememberVisibleFrame() }
    func windowDidResize(_ notification: Notification) { rememberVisibleFrame() }
    private func rememberVisibleFrame() {
        guard isPresented, let panel else { return }
        rememberedFrame = panel.frame
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    private func updateActivity() {
        scenePhase = isPresented && NSApp.isActive ? .active : .inactive
    }

    isolated deinit {
        if let ownerCloseObserver { NotificationCenter.default.removeObserver(ownerCloseObserver) }
        for observer in activityObservers { NotificationCenter.default.removeObserver(observer) }
    }
}

/// Let native text editing and controls consume their keys. No app-wide keyboard monitor.
@MainActor
enum TaskDetailsKeyboard {
    static func permitsPreviewShortcut(in window: NSWindow?) -> Bool {
        guard let window, window.attachedSheet == nil else { return false }
        if window.firstResponder is NSTableView { return true }
        return !(window.firstResponder is NSTextView) && !(window.firstResponder is NSControl)
    }

    static func nextSelection(_ selected: String?, direction: Int, ids: [String]) -> String? {
        guard let selected, let index = ids.firstIndex(of: selected) else { return nil }
        let next = index + direction
        return ids.indices.contains(next) ? ids[next] : nil
    }
}

final class TaskDetailsPanel: NSPanel {
    var onDismiss: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?

    override func cancelOperation(_ sender: Any?) { onDismiss?() }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              TaskDetailsKeyboard.permitsPreviewShortcut(in: self) else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 49 where !event.isARepeat, 53: onDismiss?()
        case 125: onMoveSelection?(1)
        case 126: onMoveSelection?(-1)
        default: super.keyDown(with: event)
        }
    }
}

private struct TaskDetailsPanelContent: View {
    @ObservedObject var store: DownloadStore
    @ObservedObject var presentation: TaskDetailsPresentation

    var body: some View {
        Group {
            if let task = store.selectedTask {
                TaskInspectorView(task: task, selection: $presentation.selectedTab, sectionRequest: presentation.sectionRequest)
            }
        }
        .environmentObject(store)
        .environment(\.scenePhase, presentation.scenePhase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.selectedTask?.id) { _, id in
            if id == nil { presentation.dismiss(returnFocus: false) }
        }
    }
}

struct TaskDetailsWindowAnchor: NSViewRepresentable {
    let presentation: TaskDetailsPresentation
    final class Anchor: NSView {
        weak var presentation: TaskDetailsPresentation?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Resolve after SwiftUI has attached the window; no controller introspection.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                presentation?.attach(to: window)
            }
        }
    }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor(); view.presentation = presentation; return view
    }
    func updateNSView(_ view: Anchor, context: Context) {}
}
