import AppKit
import SwiftUI
import XCTest
@testable import ChopChop

final class TaskDetailsPresentationTests: XCTestCase {
    @MainActor
    func testSelectionOnlyExpandsOneSummaryAndNeverOpensAPanel() {
        let presentation = TaskDetailsPresentation()
        presentation.selectionChanged(to: "first")
        XCTAssertEqual(presentation.expandedTaskID, "first")
        XCTAssertFalse(presentation.isPresented)
        presentation.selectionChanged(to: "second")
        XCTAssertEqual(presentation.expandedTaskID, "second")
        presentation.selectionChanged(to: nil)
        XCTAssertNil(presentation.expandedTaskID)
        XCTAssertNil(presentation.panel)
    }

    @MainActor
    func testPreviewShortcutRespectsTextControlsSheetsAndVisibleOrder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0
        defer { window.close() }
        window.makeFirstResponder(nil)
        XCTAssertTrue(TaskDetailsKeyboard.permitsPreviewShortcut(in: window))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        window.contentView?.addSubview(text)
        XCTAssertTrue(window.makeFirstResponder(text))
        XCTAssertFalse(TaskDetailsKeyboard.permitsPreviewShortcut(in: window), "Spaces and arrows belong to text editing")
        let list = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        window.contentView?.addSubview(list)
        XCTAssertTrue(window.makeFirstResponder(list))
        XCTAssertTrue(TaskDetailsKeyboard.permitsPreviewShortcut(in: window), "The native task list may use Space to preview")
        XCTAssertFalse(TaskDetailsKeyboard.permitsPreviewShortcut(in: nil))
        XCTAssertEqual(TaskDetailsKeyboard.nextSelection("b", direction: 1, ids: ["c", "b", "a"]), "a")
        XCTAssertEqual(TaskDetailsKeyboard.nextSelection("b", direction: -1, ids: ["c", "b", "a"]), "c")
        XCTAssertNil(TaskDetailsKeyboard.nextSelection("a", direction: 1, ids: ["c", "b", "a"]))
        XCTAssertNil(TaskDetailsKeyboard.nextSelection("removed", direction: 1, ids: ["a"]))
    }

    @MainActor
    func testPanelReusesItsWindowAndClosesWithSelectionOrOwner() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        let dto = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"details","status":"paused","files":[{"index":"1","path":"/tmp/Example.zip","length":"100","completedLength":"45"}]}"#.utf8))
        store.tasks = [dto.toTask()]; store.selectedTaskID = "details"
        let presentation = TaskDetailsPresentation()
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; owner.alphaValue = 0; owner.orderBack(nil)
        presentation.attach(to: owner)
        defer { presentation.dismiss(returnFocus: false); owner.close() }
        let frame = owner.frame
        presentation.present(store: store, moveSelection: { _ in })
        let panel = try XCTUnwrap(presentation.panel)
        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertTrue(panel.parent === owner)
        XCTAssertNil(owner.attachedSheet)
        try await Task.sleep(for: .milliseconds(150))
        let panelFrame = panel.frame
        presentation.present(store: store, moveSelection: { _ in })
        XCTAssertTrue(presentation.panel === panel)
        XCTAssertEqual(panel.frame, panelFrame)
        XCTAssertEqual(owner.frame, frame)
        store.selectedTaskID = nil
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(presentation.isPresented, "Removing/filtering the selected task closes its panel")
        XCTAssertNil(panel.contentViewController)
        XCTAssertEqual(presentation.scenePhase, .inactive)
        store.selectedTaskID = "details"
        presentation.present(store: store, moveSelection: { _ in })
        owner.close()
        XCTAssertFalse(presentation.isPresented)
        XCTAssertNil(panel.contentViewController)
    }

    @MainActor
    func testUnifiedPanelKeepsNativeWindowControlsClearOfContent() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        let dto = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"unified","status":"paused","files":[{"index":"1","path":"/tmp/Example.zip","length":"100","completedLength":"45"}]}"#.utf8))
        var task = dto.toTask()
        task.name = String(repeating: "Long file name 很长的文件名 ", count: 8)
        store.tasks = [task]; store.selectedTaskID = task.id
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; owner.alphaValue = 0; owner.orderBack(nil)
        let presentation = TaskDetailsPresentation()
        presentation.attach(to: owner)
        defer { presentation.dismiss(returnFocus: false); owner.close() }
        presentation.present(store: store, moveSelection: { _ in })
        let panel = try XCTUnwrap(presentation.panel)
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(panel.titleVisibility, .hidden)
        XCTAssertTrue(panel.titlebarAppearsTransparent)
        XCTAssertEqual(panel.titlebarSeparatorStyle, .none)
        XCTAssertTrue(panel.isMovableByWindowBackground)
        let output = try Aria2NextPaths.supportDirectory().appendingPathComponent("Design Previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for size in [NSSize(width: 600, height: 680), panel.contentMinSize] {
            panel.setContentSize(size)
            try await Task.sleep(for: .milliseconds(300))
            let content = try XCTUnwrap(panel.contentView)
            content.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
            let tabs = try XCTUnwrap(descendants(content).compactMap { $0 as? NSSegmentedControl }.first)
            let rect = tabs.convert(tabs.bounds, to: content)
            XCTAssertEqual(rect.minX, 24, accuracy: 1)
            XCTAssertEqual(rect.maxX, content.bounds.width - 24, accuracy: 1)
            let close = try XCTUnwrap(panel.standardWindowButton(.closeButton))
            XCTAssertFalse(close.isHidden)
            let closeRect = close.convert(close.bounds, to: nil)
            XCTAssertLessThanOrEqual(panel.contentLayoutRect.maxY, closeRect.minY,
                                     "The titlebar safe area must reserve the native window buttons")
            let scroll = try XCTUnwrap(descendants(content).compactMap { $0 as? NSScrollView }.first)
            XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.height, 140,
                                        "The full-size titlebar must leave usable content at the minimum size")
            let frame = try XCTUnwrap(content.superview)
            let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("unified-details-\(Int(size.width)).png"))
        }
        print("UNIFIED_DETAILS_PREVIEW_OUTPUT=\(output.path)")
    }

    @MainActor
    func testNativeTabsUpdateBoundSelectionAndIgnoreMissingSelection() {
        var selected = InspectorTab.overview
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let coordinator = TaskInspectorTabs(selection: binding).makeCoordinator()
        let control = NSSegmentedControl(labels: InspectorTab.allCases.map(\.localizedTitle),
                                         trackingMode: .selectOne, target: nil, action: nil)
        control.selectedSegment = 2
        coordinator.selectTab(control)
        XCTAssertEqual(selected, .network)
        control.selectedSegment = -1
        coordinator.selectTab(control)
        XCTAssertEqual(selected, .network)
    }

    func testInspectorSourceAndTimeEstimateRespectPrivacyAndTransferPhase() throws {
        let dto = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"display","status":"active","totalLength":"1000","completedLength":"250","downloadSpeed":"100","files":[]}"#.utf8))
        var task = dto.toTask()
        task.sourceURL = "https://user:password@example.com/file.zip?token=secret#private"
        XCTAssertEqual(TaskInspectorDisplay(task: task).sourceHost, "example.com")
        XCTAssertEqual(TaskInspectorDisplay(task: task).sourceAddress, "https://example.com/file.zip")
        XCTAssertEqual(TaskInspectorDisplay(task: task).remainingTime, ByteFormat.duration(8))
        task.status = .paused
        XCTAssertNil(TaskInspectorDisplay(task: task).remainingTime)
        task.status = .active
        task.isChecking = true
        XCTAssertNil(TaskInspectorDisplay(task: task).remainingTime)
        task.isChecking = false
        task.isSharing = true
        XCTAssertNil(TaskInspectorDisplay(task: task).remainingTime)
        task.sourceURL = "magnet:?xt=urn:btih:example&dn=private"
        XCTAssertNil(TaskInspectorDisplay(task: task).sourceAddress)
        task.isSharing = false
        task.totalLength = .max; task.completedLength = 0; task.downloadSpeed = 1
        XCTAssertNil(TaskInspectorDisplay(task: task).remainingTime, "Unrepresentable estimates must not trap")
    }

    func testBandwidthParsingKeepsProtocolOptionsSeparateAndValidatesInput() throws {
        var http = try TaskBandwidthLimits(options: ["max-download-limit": "2M"], isTorrent: false)
        XCTAssertEqual(try http.engineOptions(), ["max-download-limit": "2048K"])
        http.downloadKiB = 0
        XCTAssertEqual(try http.engineOptions(), ["max-download-limit": "0K"])
        http.downloadKiB = -1
        XCTAssertThrowsError(try http.engineOptions())
        http.downloadKiB = .max
        XCTAssertThrowsError(try http.engineOptions())
        let torrent = try TaskBandwidthLimits(options: ["max-download-limit": "1025", "max-upload-limit": "32K"], isTorrent: true)
        XCTAssertEqual(try torrent.engineOptions(), ["max-download-limit": "2K", "max-upload-limit": "32K"])
        XCTAssertThrowsError(try TaskBandwidthLimits(options: [:], isTorrent: false))
        XCTAssertThrowsError(try TaskBandwidthLimits(options: ["max-download-limit": "0"], isTorrent: true))
    }
}
