import AppKit
import SwiftUI
import XCTest
@testable import ChopChop

final class DesignPreviewTests: XCTestCase {
    @MainActor
    func testAddDownloadSheetKeepsFieldBordersInsideDisclosure() async throws {
        try await verifyAddDownloadSheet(width: 560, height: nil, appearance: .aqua)
    }

    @MainActor
    func testCompactAddDownloadSheetKeepsActionsVisible() async throws {
        try await verifyAddDownloadSheet(width: 480, height: 420, appearance: .darkAqua)
    }

    /// Exercise the real SwiftUI sheet presenter, including its native clipping containers.
    /// Both windows are invisible; no input events or production app state are used.
    @MainActor
    private func verifyAddDownloadSheet(width: CGFloat, height: CGFloat?, appearance: NSAppearance.Name) async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        store.addDraft.rawInput = "https://example.com/download.zip"
        store.addDraft.userAgent = String(repeating: "Long user agent; ", count: 20)
        store.addDraft.customHeaders = "X-Example: " + String(repeating: "long-value", count: 30)
        let controller = NSHostingController(rootView: Color.clear
            .sheet(isPresented: .constant(true)) {
                AddDownloadPanel(initiallyShowsAdvanced: true, onDismiss: {}).environmentObject(store)
                    .frame(width: width, height: height)
                    .background(InvisibleSheetWindow())
            })
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = controller
        window.alphaValue = 0
        // SwiftUI starts a sheet's presentation lifecycle only for ordered windows.
        window.orderBack(nil)
        defer {
            for sheet in window.sheets { window.endSheet(sheet) }
            window.close()
        }
        try await Task.sleep(for: .milliseconds(600))
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(sheet.alphaValue, 0)
        XCTAssertEqual(content.bounds.width, width, accuracy: 1)
        XCTAssertLessThanOrEqual(content.bounds.height, height ?? 600)

        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let views = descendants(of: content)
        let fields = views.compactMap { $0 as? NSTextField }
        XCTAssertEqual(fields.count, 7, "Every advanced field, including secure and multiline fields, must be laid out")
        for field in fields {
            var ancestor = field.superview
            while let container = ancestor, !(container is NSClipView) {
                if container.clipsToBounds {
                    let bezel = field.convert(field.bounds, to: container).insetBy(dx: -3, dy: -3)
                    XCTAssertTrue(container.bounds.contains(bezel),
                                  "Native field bezels and focus rings must fit inside their clipping container: \(bezel), \(container.bounds)")
                }
                ancestor = container.superview
            }
        }
        // Buttons have native focus/key views at the sheet root, outside its scroll view.
        // Check every root child so a fixed-size body cannot push those actions offscreen.
        for child in content.subviews where !child.frame.isEmpty {
            XCTAssertTrue(content.bounds.contains(child.frame), "Sheet content extends beyond the window: \(child.frame)")
        }
        let scroll = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.height, 150)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(150))
        let lastField = try XCTUnwrap(fields.last)
        let lastBezel = lastField.convert(lastField.bounds, to: scroll.contentView).insetBy(dx: -3, dy: -3)
        XCTAssertTrue(scroll.contentView.bounds.contains(lastBezel), "The final field must be fully visible at the end of the scroll")

    }

    @MainActor
    func testLastWindowCloseRespectsBackgroundDownloadPreference() throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        let delegate = ChopChopAppDelegate()
        delegate.configureMenuBar(store: store)
        store.preferences.keepRunningAfterClose = true
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        store.preferences.keepRunningAfterClose = false
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }

    /// Renders real SwiftUI views into offscreen AppKit windows. No clicks, key events,
    /// production preferences, or engine processes are involved. Native vibrancy and
    /// toolbar compositing require WindowServer, so these images verify content layout only.
    @MainActor
    func testExportDesignPreviews() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHOPCHOP_DESIGN_RENDER"] == "1",
                          "Offscreen design previews are opt-in")
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        store.preferences.preventSleepDuringActiveDownloads = false
        store.selectedDestination = .all
        store.tasks = [
            task("1", "Ubuntu 26.04 Desktop.iso", .active, .bitTorrent, 0.42),
            task("2", "Design assets.zip", .paused, .http, 0.67),
            task("3", "Conference recording.mov", .waiting, .http, 0),
            task("4", "ChopChop.dmg", .completed, .http, 1),
            task("5", "Project archive.tar.gz", .failed, .http, 0.23)
        ]
        store.runtime = EngineRuntimeSnapshot(phase: .running(pid: 1234))
        defer { store.shutdown() }
        let output = try Aria2NextPaths.supportDirectory().appendingPathComponent("Design Previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua),
                                   ("contrast", .accessibilityHighContrastAqua)] {
            let progressExamples = VStack(alignment: .leading, spacing: 28) {
                Text("Engine Update").font(.headline)
                EngineInstallationProgressView(progress: .init(stage: .downloading, completedBytes: 6_370_000,
                                                               totalBytes: 15_930_784, bytesPerSecond: 1_650_000), onCancel: {})
                Divider()
                EngineInstallationProgressView(progress: .init(stage: .verifying), onCancel: {})
                Divider()
                EngineInstallationProgressView(progress: .init(stage: .restarting), onCancel: {})
            }.padding(24)
            try await render(progressExamples, name: "engine-progress-\(name)",
                             size: NSSize(width: 510, height: 370), appearance: appearance, output: output)
            try await render(DownloadConsoleView().environmentObject(store), name: "main-\(name)",
                             size: NSSize(width: 1100, height: 740), appearance: appearance, output: output)
            try await render(DownloadConsoleView().environmentObject(store), name: "compact-\(name)",
                             size: NSSize(width: 900, height: 600), appearance: appearance, output: output)
            try await render(SettingsView().environmentObject(store), name: "settings-\(name)",
                             size: NSSize(width: 860, height: 640), appearance: appearance, output: output)
            try await render(TaskInspectorView(task: store.tasks[0]).environmentObject(store), name: "details-\(name)",
                             size: NSSize(width: 340, height: 640), appearance: appearance, output: output)
            store.addDraft.rawInput = "https://example.com/download.zip"
            try await render(AddDownloadPanel(onDismiss: {}).environmentObject(store), name: "add-\(name)",
                             size: NSSize(width: 560, height: 400), appearance: appearance, output: output, fitContent: true)
            try await render(AddDownloadPanel(initiallyShowsAdvanced: true, onDismiss: {}).environmentObject(store), name: "add-options-\(name)",
                             size: NSSize(width: 560, height: 600), appearance: appearance, output: output, fitContent: true)
            try await render(AddDownloadPanel(initiallyShowsAdvanced: true, onDismiss: {}).environmentObject(store), name: "add-options-bottom-\(name)",
                             size: NSSize(width: 560, height: 600), appearance: appearance, output: output,
                             fitContent: true, scrollToBottom: true)
        }
        store.addDraft.rawInput = ""
        try await render(AddDownloadPanel(onDismiss: {}).environmentObject(store), name: "add-empty",
                         size: NSSize(width: 560, height: 400), appearance: .aqua, output: output, fitContent: true)
        store.addDraft.rawInput = "https://example.com/file1.zip\nhttps://example.com/file2.zip\nhttps://example.com/file3.zip"
        try await render(AddDownloadPanel(onDismiss: {}).environmentObject(store), name: "add-batch",
                         size: NSSize(width: 560, height: 400), appearance: .aqua, output: output, fitContent: true)
        store.addDraft.rawInput = "magnet:?xt=urn:btih:BF650E61509ABA5376CB3946305B2B5270A68B17"
        store.bitTorrentSelectionSession = BitTorrentFileSelectionSession(
            source: store.addDraft.rawInput, taskName: "Design Resources", files: [
                DownloadFile(index: 1, path: "Design Resources/Illustrations.zip", length: 120_000_000, completedLength: 0, isSelected: true),
                DownloadFile(index: 2, path: "Design Resources/Read Me.pdf", length: 4_000_000, completedLength: 0, isSelected: true)
            ], selectedFileIndexes: [1, 2], phase: .ready)
        try await render(AddDownloadPanel(onDismiss: {}).environmentObject(store), name: "add-torrent",
                         size: NSSize(width: 560, height: 600), appearance: .aqua, output: output, fitContent: true)
        store.bitTorrentSelectionSession = nil
        store.selectedTaskID = store.tasks.first?.id
        try await render(DownloadConsoleView().environmentObject(store), name: "selected-details",
                         size: NSSize(width: 1100, height: 740), appearance: .aqua, output: output)
        store.selectedTaskID = nil
        store.searchQuery = "nothing matches this search"
        try await render(DownloadConsoleView().environmentObject(store), name: "search-empty",
                         size: NSSize(width: 900, height: 600), appearance: .aqua, output: output)
        print("DESIGN_PREVIEWS: \(output.path)")
    }

    @MainActor
    private func render<V: View>(_ view: V, name: String, size: NSSize, appearance: NSAppearance.Name, output: URL,
                                 fitContent: Bool = false, scrollToBottom: Bool = false) async throws {
        let oldAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        defer { NSApp.appearance = oldAppearance }
        let controller = NSHostingController(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        controller.sizingOptions = []
        controller.view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = controller
        window.setContentSize(size)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        if fitContent {
            window.setContentSize(controller.sizeThatFits(in: NSSize(width: size.width, height: 620)))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertLessThanOrEqual(controller.view.frame.height, 620, "The sheet must leave its actions visible on small windows")
        }
        controller.view.layoutSubtreeIfNeeded()
        if scrollToBottom {
            func firstScrollView(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { firstScrollView(in: $0) }.first
            }
            let scroll = try XCTUnwrap(firstScrollView(in: controller.view))
            let document = try XCTUnwrap(scroll.documentView)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
        }
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        window.appearance?.performAsCurrentDrawingAppearance {
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent("\(name).png"))
    }

    private func task(_ id: String, _ name: String, _ status: DownloadStatus, _ kind: TaskProtocol, _ progress: Double) -> DownloadTask {
        DownloadTask(id: id, name: name, protocolKind: kind, status: status,
                     totalLength: 2_000_000_000, completedLength: Int64(2_000_000_000 * progress),
                     downloadSpeed: status == .active ? 4_800_000 : 0, uploadSpeed: 0,
                     connections: status == .active ? 8 : 0, destination: "~/Downloads",
                     addedAt: Date(), errorMessage: nil, files: [], peers: [], trackers: [], recentLogs: [])
    }
}

/// Keep the sheet invisible before AppKit orders it, while retaining its real layout lifecycle.
private struct InvisibleSheetWindow: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.alphaValue = 0
            window?.animationBehavior = .none
        }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {}
}
