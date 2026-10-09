import AppKit
import Combine
import SwiftUI

/// Search display text while retaining stable action identifiers for dispatch.
enum CommandSearchIndex {
    static func matches(_ query: String, title: (DownloadAction) -> String = { $0.title }) -> [DownloadAction] {
        let words = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        return DownloadAction.allCases.filter { action in
            let text = (title(action) + " " + action.titleKey).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return words.allSatisfy { text.contains($0) }
        }
    }

    static func nextSelection(_ selected: DownloadAction?, direction: Int, in actions: [DownloadAction]) -> DownloadAction? {
        guard !actions.isEmpty else { return nil }
        guard let selected, let index = actions.firstIndex(of: selected) else { return actions.first }
        return actions[min(actions.count - 1, max(0, index + direction))]
    }
}

@MainActor
final class CommandSearchPresentation: NSObject, ObservableObject, NSWindowDelegate {
    private(set) var panel: NSPanel?
    private weak var owner: NSWindow?
    private weak var returnResponder: NSResponder?
    private var closeObserver: NSObjectProtocol?

    func present(owner: NSWindow?, store: DownloadStore, context: @escaping @MainActor () -> DownloadActionContext) {
        guard let owner, owner.attachedSheet == nil else { return }
        dismiss(returnFocus: false)
        self.owner = owner
        returnResponder = owner.firstResponder
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = String(localized: "Search Commands…")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = true
        panel.alphaValue = owner.alphaValue
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier("ChopChop.CommandSearch")
        let root = CommandSearchView(store: store, context: context,
            execute: { [weak self] action in
                let latest = context()
                self?.dismiss()
                // Restore the owning window before opening a sheet or another panel.
                DispatchQueue.main.async { action.perform(in: latest) }
            }, dismiss: { [weak self] in self?.dismiss() })
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        let screen = owner.screen?.visibleFrame ?? owner.frame
        panel.setFrame(TaskDetailsPresentation.fittedFrame(
            NSRect(x: owner.frame.midX - 270, y: owner.frame.midY - 120, width: 540, height: 400),
            screens: NSScreen.screens.map(\.visibleFrame), fallback: screen), display: false)
        self.panel = panel
        owner.addChildWindow(panel, ordered: .above)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(returnFocus: false) }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss(returnFocus: Bool = true) {
        guard let panel else { return }
        self.panel = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        panel.delegate = nil
        owner?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentViewController = nil
        if returnFocus, let owner, owner.isVisible {
            owner.makeKey()
            if let returnResponder { owner.makeFirstResponder(returnResponder) }
        }
        returnResponder = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
    func windowDidResignKey(_ notification: Notification) { dismiss(returnFocus: false) }
}

private struct CommandSearchView: View {
    @ObservedObject var store: DownloadStore
    let context: @MainActor () -> DownloadActionContext
    let execute: (DownloadAction) -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var selected: DownloadAction?
    private var results: [DownloadAction] {
        let matches = CommandSearchIndex.matches(query)
        let current = context()
        return matches.filter { $0.isEnabled(in: current) } + matches.filter { !$0.isEnabled(in: current) }
    }
    private var available: [DownloadAction] { results.filter { $0.isEnabled(in: context()) } }

    var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(text: $query, move: { direction in
                selected = CommandSearchIndex.nextSelection(selected, direction: direction, in: available)
            }, submit: {
                if let selected, available.contains(selected) { execute(selected) }
            }, dismiss: dismiss)
                .frame(height: 28).padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
            Divider()
            ScrollViewReader { proxy in
                List(selection: $selected) {
                    ForEach(results) { action in
                        let enabled = action.isEnabled(in: context())
                        Button { execute(action) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: action.symbol).frame(width: 20).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(action.title(in: context()))
                                    Text(enabled ? action.group : String(localized: "Currently unavailable"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 12)
                                if let shortcut = action.shortcutLabel { Text(shortcut).font(.callout).foregroundStyle(.secondary) }
                            }.padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!enabled).tag(action).id(action)
                    }
                }.listStyle(.inset)
                    .onChange(of: selected) { _, id in if let id { proxy.scrollTo(id) } }
                    .overlay { if results.isEmpty { Text(String(localized: "No Matching Commands")).foregroundStyle(.secondary) } }
            }
            Divider()
            Text(String(localized: "↑ ↓ to select · Return to run · Esc to close"))
                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 9)
        }
        .onChange(of: available, initial: true) { _, actions in
            if selected == nil || !actions.contains(selected!) { selected = actions.first }
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .desktopControls()
        .accessibilityIdentifier("command-search")
    }
}

/// NSSearchField supplies the system search bezel, clear control and text editing behavior.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var move: (Int) -> Void
    var submit: () -> Void
    var dismiss: () -> Void
    var prompt = String(localized: "Search commands")
    var focusOnAppear = true
    var size: NSControl.ControlSize = .large
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        field.controlSize = size
        field.delegate = context.coordinator
        if focusOnAppear {
            DispatchQueue.main.async { [weak field] in
                if let field { field.window?.makeFirstResponder(field) }
            }
        }
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        init(_ parent: NativeSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Candidate navigation and confirmation belong to the input method while composing.
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.dismiss()
            default: return false
            }
            return true
        }
    }
}
