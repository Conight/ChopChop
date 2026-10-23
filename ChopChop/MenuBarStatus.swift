import AppKit
import Observation
import SwiftUI

nonisolated struct MenuBarTransferRates: Equatable, Sendable {
    let download: Int64
    let upload: Int64

    init(download: Int64, upload: Int64) {
        self.download = max(0, download)
        self.upload = max(0, upload)
    }
}

nonisolated struct MenuBarStatusSnapshot: Equatable, Sendable {
    let isVisible: Bool
    let mode: MenuBarDisplayMode
    let rates: MenuBarTransferRates?

    @MainActor
    init(store: DownloadStore) {
        isVisible = store.preferences.showMenuBar
        mode = store.preferences.menuBarDisplayMode
        // An icon-only or hidden item doesn't observe continuously changing rates.
        guard isVisible, mode.showsSpeed,
              case .running = store.runtime.phase, store.connectionIssue == nil else {
            rates = nil
            return
        }
        rates = MenuBarTransferRates(download: store.activeSpeed, upload: store.uploadSpeed)
    }

    var speedTitle: String {
        "↓\t\(rates.map { ByteFormat.speed($0.download) } ?? "—")\n↑\t\(rates.map { ByteFormat.speed($0.upload) } ?? "—")"
    }

    var accessibilityValue: String? {
        guard mode.showsSpeed else { return nil }
        guard let rates else { return String(localized: "Transfer speeds unavailable") }
        return String(localized: "Download speed: \(ByteFormat.speed(rates.download))") + ", " +
            String(localized: "Upload speed: \(ByteFormat.speed(rates.upload))")
    }

    var toolTip: String {
        [AppIdentity.displayName, accessibilityValue].compactMap { $0 }.joined(separator: "\n")
    }
}

/// Follow the same observable source as the in-app metrics. No independent timer
/// or RPC client is needed, and a failed connection immediately clears old rates.
@MainActor
final class MenuBarStatusObservation {
    private weak var store: DownloadStore?
    private var generation = 0
    private var lastSnapshot: MenuBarStatusSnapshot?
    private let onUpdate: (MenuBarStatusSnapshot) -> Void

    init(onUpdate: @escaping (MenuBarStatusSnapshot) -> Void) { self.onUpdate = onUpdate }

    func configure(store: DownloadStore) {
        guard self.store !== store else { return }
        stop()
        self.store = store
        observe(generation: generation)
    }

    func stop() {
        generation += 1
        store = nil
        lastSnapshot = nil
    }

    private func observe(generation: Int) {
        guard let store, self.generation == generation else { return }
        let snapshot = withObservationTracking {
            MenuBarStatusSnapshot(store: store)
        } onChange: { [weak self] in
            // Observation calls before mutation. Read the committed values on
            // the next main-actor turn, coalescing changes from one engine poll.
            Task { @MainActor [weak self] in self?.observe(generation: generation) }
        }
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onUpdate(snapshot)
    }
}

/// Preserve the system status button's highlighting, click and keyboard behavior.
/// Reserve one compact two-line width across digit and byte-unit transitions.
@MainActor
enum MenuBarStatusAppearance {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    static let lineHeight: CGFloat = 11
    static let textWidth: CGFloat = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        let count = formatter.string(from: 888.88) ?? "888.88"
        return ceil(ByteFormat.displayUnits.flatMap { unit in
            ["↓", "↑"].map { arrow in
                ("\(arrow) \(count) \(unit)/s" as NSString).size(withAttributes: [.font: font]).width
            }
        }.max() ?? 80)
    }()

    static func length(for mode: MenuBarDisplayMode) -> CGFloat {
        mode.showsSpeed ? textWidth + 12 + (mode.showsIcon ? 24 : 0) : NSStatusItem.squareLength
    }

    static func title(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: textWidth)]
        paragraph.lineBreakMode = .byClipping
        return NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
    }

    static func apply(_ snapshot: MenuBarStatusSnapshot, to button: NSButton) {
        if snapshot.mode.showsIcon {
            if button.image == nil { button.image = AppBrand.menuBarImage }
        } else {
            button.image = nil
        }
        button.imagePosition = snapshot.mode.showsSpeed ? (snapshot.mode.showsIcon ? .imageLeft : .noImage) : .imageOnly
        button.alignment = .left
        button.cell?.usesSingleLineMode = false
        button.cell?.wraps = false
        button.cell?.lineBreakMode = .byClipping
        button.attributedTitle = snapshot.mode.showsSpeed ? title(snapshot.speedTitle) : NSAttributedString(string: "")
        button.toolTip = snapshot.toolTip
        button.setAccessibilityLabel(AppIdentity.displayName)
        button.setAccessibilityValue(snapshot.accessibilityValue)
        button.setAccessibilityIdentifier("menu-bar-status")
    }
}

@MainActor
final class MenuBarStatusController: NSObject {
    private weak var store: DownloadStore?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private lazy var observation = MenuBarStatusObservation { [weak self] in self?.update($0) }

    func configure(store: DownloadStore) {
        guard !AppLaunchConfiguration.isTestAutomation else { remove(); return }
        if self.store !== store {
            popover?.performClose(nil)
            popover = nil
            self.store = store
        }
        observation.configure(store: store)
    }

    func remove() {
        observation.stop()
        removeStatusItem()
    }

    private func removeStatusItem() {
        popover?.performClose(nil)
        popover = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func update(_ snapshot: MenuBarStatusSnapshot) {
        guard snapshot.isVisible else { removeStatusItem(); return }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: MenuBarStatusAppearance.length(for: snapshot.mode))
            item.autosaveName = "ChopChopMenuBar"
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            statusItem = item
        }
        guard let statusItem, let button = statusItem.button else { return }
        let length = MenuBarStatusAppearance.length(for: snapshot.mode)
        if statusItem.length != length { statusItem.length = length }
        MenuBarStatusAppearance.apply(snapshot, to: button)
    }

    private func ensurePopover() -> NSPopover? {
        guard let store else { return nil }
        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.contentSize = NSSize(width: 376, height: 520)
            popover.contentViewController = NSHostingController(rootView: MenuBarPanel().environment(store))
            self.popover = popover
        }
        return popover
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover = ensurePopover() else { return }
        if popover.isShown { popover.performClose(sender) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
