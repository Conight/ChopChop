import AppKit
import SwiftUI
import XCTest
@testable import ChopChop

final class SettingsAndTablesTests: XCTestCase {
    @MainActor func testSearchFindsControlsAcrossEnglishAndChineseAndKeepsStableRoutes() {
        let entries = SettingsSearchIndex.entries
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        XCTAssertEqual(Set(entries.map(\.pane)), Set(SettingsPane.allCases))
        XCTAssertEqual(SettingsSearchIndex.results(for: "Global upload limit").map(\.id), ["network.global-upload-limit"])
        XCTAssertTrue(SettingsSearchIndex.results(for: "上传 限速").contains { $0.id == "network.global-upload-limit" })
        XCTAssertEqual(SettingsSearchIndex.results(for: "RPC token").map(\.id), ["engine.rpc-token"])
        XCTAssertTrue(SettingsSearchIndex.results(for: "nothing matches this").isEmpty)
        let model = SettingsSearchModel()
        model.query = "Global upload limit"
        model.isPresented = true
        model.select(model.results[0])
        let request = model.navigationRequest!
        XCTAssertEqual(request.entry.id, "network.global-upload-limit")
        XCTAssertTrue(model.query.isEmpty)
        XCTAssertFalse(model.isPresented)
        model.select(request.entry)
        XCTAssertNotEqual(model.navigationRequest?.id, request.id, "Repeated results must scroll again")
        model.finishNavigation(request)
        XCTAssertNotNil(model.navigationRequest, "An older navigation must not consume a newer request")
        model.cancel()
        XCTAssertNil(model.navigationRequest)
    }

    @MainActor func testSearchNavigatesToAnotherPaneAndScrollsToTheExactControl() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        let suite = "settings-search-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = AppUpdateCoordinator(build: AppBuild(version: "0.0.1-beta.1"), client: SearchReleaseClient(), defaults: defaults)
        let search = SettingsSearchModel()
        let host = NSHostingController(rootView: SettingsView(initialPane: .general, search: search).environmentObject(store).environmentObject(updates))
        host.sizingOptions = [.minSize]
        host.view.frame = NSRect(x: 0, y: 0, width: 860, height: 560)
        let window = NSWindow(contentRect: host.view.frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0
        window.toolbarStyle = .unified
        window.contentViewController = host; window.setContentSize(NSSize(width: 860, height: 560)); window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(650))
        func renderLayout() throws {
            host.view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        }
        try renderLayout()
        try await Task.sleep(for: .milliseconds(100))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func searchFields() -> [NSSearchField] {
            descendants(window.contentView!.superview!).compactMap { $0 as? NSSearchField }
        }
        let initialField = try XCTUnwrap(searchFields().first)
        XCTAssertEqual(searchFields().count, 1, "Settings has one global native search field")
        let sidebar = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSSplitView }
            .compactMap { $0.delegate as? NSSplitViewController }
            .flatMap(\.splitViewItems).first { $0.behavior == .sidebar })
        XCTAssertTrue(sidebar.allowsFullHeightLayout, "The system sidebar must extend through the titlebar")
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let sidebarFrame = sidebar.viewController.view.convert(sidebar.viewController.view.bounds, to: frameView)
        XCTAssertEqual(sidebarFrame.maxY, frameView.bounds.maxY, accuracy: 1, "The sidebar must reach the top of the window")
        XCTAssertEqual(sidebarFrame.width, 210, accuracy: 1)
        XCTAssertFalse(window.toolbar?.items.contains { $0.itemIdentifier.rawValue.contains("toggleSidebar") } ?? false)
        let fieldFrame = initialField.convert(initialField.bounds, to: nil)
        XCTAssertLessThan(fieldFrame.maxX, 240, "Search belongs above the sidebar, outside every settings Form")
        if let close = window.standardWindowButton(.closeButton) {
            let controls = close.convert(close.bounds, to: nil)
            XCTAssertLessThan(fieldFrame.maxY, controls.minY, "Search must respect the native window-control safe area")
        }
        let originalWindowFrame = window.frame
        search.select(try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == "network.transfer-timeout" }))
        try await Task.sleep(for: .milliseconds(450))
        try renderLayout()
        try await Task.sleep(for: .milliseconds(100))
        try renderLayout()
        let scrolls = descendants(host.view).compactMap { $0 as? NSScrollView }
        XCTAssertEqual(sidebar.viewController.view.convert(sidebar.viewController.view.bounds, to: frameView), sidebarFrame,
                       "Long settings and search navigation must not stretch or displace the sidebar")
        XCTAssertTrue(scrolls.contains { $0.contentView.bounds.origin.y > 10 }, "Jump to a lower setting must scroll its actual Form")
        XCTAssertNil(search.navigationRequest, "Navigation is consumed, with no lingering highlight state")
        XCTAssertEqual(searchFields().count, 1)
        XCTAssertTrue(searchFields().first === initialField, "Changing panes must retain the same search control")
        XCTAssertEqual(window.frame, originalWindowFrame)
        let output = try Aria2NextPaths.supportDirectory().appendingPathComponent("Design Previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("settings-search-target.png"))
        search.select(try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == "engine.rpc-port" }))
        try await Task.sleep(for: .milliseconds(350))
        search.query = "upload"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(searchFields().count, 1)
        XCTAssertTrue(searchFields().first === initialField)
        XCTAssertEqual(initialField.stringValue, "upload")
        XCTAssertEqual(window.frame, originalWindowFrame, "Search results must not expand the window")
        for size in [NSSize(width: 940, height: 640), NSSize(width: 860, height: 560)] {
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(100))
            try renderLayout()
            let currentSidebar = sidebar.viewController.view.convert(sidebar.viewController.view.bounds, to: frameView)
            XCTAssertEqual(currentSidebar.maxY, frameView.bounds.maxY, accuracy: 1)
            XCTAssertEqual(currentSidebar.width, 210, accuracy: 1)
            XCTAssertFalse(sidebar.isCollapsed)
            XCTAssertTrue(searchFields().first === initialField)
        }
        print("SETTINGS_SEARCH_PREVIEW=\(output.path)")
    }

    @MainActor func testSearchResultsLeaveThePopoverBackgroundVisible() async throws {
        let output = try Aria2NextPaths.supportDirectory().appendingPathComponent("Design Previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let model = SettingsSearchModel()
            model.query = "update"
            model.selection = model.results.first?.id
            let coordinator = SettingsSearchField.Coordinator(model: model)
            defer { coordinator.close() }
            let host = try XCTUnwrap(coordinator.popover.contentViewController)
            let size = NSSize(width: 360, height: CGFloat(model.results.count) * 44 + 16)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host
            window.setContentSize(size)
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let table = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTableView }.first)
            XCTAssertEqual(table.effectiveStyle, .inset, "Native inset selection must not form a square band against the rounded popover")
            XCTAssertEqual(table.numberOfRows, model.results.count)
            let scroll = try XCTUnwrap(table.enclosingScrollView)
            XCTAssertEqual(table.backgroundColor.alphaComponent, 0, "The system popover must own the background")
            XCTAssertFalse(scroll.drawsBackground)
            XCTAssertFalse(scroll.contentView.drawsBackground)
            XCTAssertEqual(table.selectedRow, 0)
            XCTAssertEqual(host.view.bounds.size, size)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("settings-results-\(appearance.rawValue).png"))
        }
        print("SETTINGS_RESULTS_PREVIEW=\(output.path)")
    }

    @MainActor func testSettingsSearchKeyboardNavigationPreservesIMEComposition() {
        let model = SettingsSearchModel()
        let coordinator = SettingsSearchField.Coordinator(model: model)
        defer { coordinator.close() }
        let field = NSSearchField()
        coordinator.field = field
        field.stringValue = "limit"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(model.query, "limit")
        let first = model.selection
        let composition = NSTextView()
        composition.setMarkedText("限速", selectedRange: NSRange(location: 0, length: 2),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        for selector in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            XCTAssertFalse(coordinator.control(field, textView: composition, doCommandBy: selector))
        }
        XCTAssertEqual(model.selection, first)
        XCTAssertNil(model.navigationRequest)
        let editor = NSTextView()
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        let selected = model.selection
        XCTAssertNotEqual(selected, first)
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(model.navigationRequest?.entry.id, selected)
        XCTAssertFalse(model.isPresented)
        XCTAssertTrue(model.query.isEmpty)
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertNil(model.navigationRequest)
    }

    func testLiveOrderPreservesRowsDuringSpeedChangesAndDropsDisconnectedPeers() {
        XCTAssertEqual(LiveTableOrder.reconcile(["a", "b", "c"], incoming: ["d", "c", "a"]), ["a", "c", "d"])
        XCTAssertEqual(LiveTableOrder.reconcile([], incoming: ["b", "a"]), ["b", "a"])
    }

    func testFileIdentityAndRelativeDirectorySurviveRPCDecodedUUIDChanges() {
        let file = DownloadFile(index: 2, path: "/Downloads/Torrent/Season 1/Episode.mkv", length: 100, completedLength: 40, isSelected: true)
        var fresh = file; fresh.id = UUID(); fresh.completedLength = 50
        let first = DownloadFileTableRow.rows([file], directory: "/Downloads/Torrent")[0]
        let next = DownloadFileTableRow.rows([fresh], directory: "/Downloads/Torrent")[0]
        XCTAssertEqual(first.id, next.id)
        XCTAssertEqual(first.name, "Season 1/Episode.mkv")
        XCTAssertEqual(next.progress, 0.5)
    }

    func testRefreshBackoffDoesNotChangeScheduleDeadline() {
        XCTAssertEqual(DownloadRefreshPolicy.interval(foreground: true, hasTransfers: true, failures: 0), .seconds(2))
        XCTAssertEqual(DownloadRefreshPolicy.interval(foreground: false, hasTransfers: true, failures: 0), .seconds(5))
        XCTAssertEqual(DownloadRefreshPolicy.interval(foreground: false, hasTransfers: false, failures: 0), .seconds(30))
        XCTAssertEqual(DownloadRefreshPolicy.interval(foreground: true, hasTransfers: true, failures: 100), .seconds(60))
        let now = Date(timeIntervalSince1970: 61)
        XCTAssertEqual(DownloadRefreshPolicy.planDelay(now: now, deadlines: [now.addingTimeInterval(3)], bandwidthEnabled: false), .seconds(3))
        XCTAssertEqual(DownloadRefreshPolicy.planDelay(now: now, deadlines: [], bandwidthEnabled: true), .seconds(59))
        XCTAssertEqual(DownloadRefreshPolicy.planDelay(now: now, deadlines: [now.addingTimeInterval(-1)], bandwidthEnabled: true), .milliseconds(100))
    }

    @MainActor func testNativeTablesFitCompactDetailsAndLongFilePaths() async throws {
        let files = (1...120).map { DownloadFile(index: $0, path: "/tmp/Download/Folder/Long 文件名 \($0).bin", length: 100, completedLength: 40, isSelected: $0 != 1) }
        let host = NSHostingController(rootView: ScrollView { VStack(spacing: 20) {
            DownloadFilesTable(files: files, directory: "/tmp/Download")
            PeerTransfersView(peers: (1...40).map { PeerTransfer(ip: "2001:db8::\($0)", port: "6881", peerClientName: "Example", state: "connected", downloadSpeed: "1024", uploadSpeed: "512") })
            ServerTransfersView(servers: [ServerTransfer(id: "1", fileIndex: 1, address: "example.com", transport: "HTTPS", downloadSpeed: 1024)])
        }.padding(16) })
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0
        window.contentViewController = host; window.setContentSize(NSSize(width: 440, height: 560)); window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(450))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let tables = descendants(content).compactMap { $0 as? NSTableView }
        XCTAssertEqual(tables.count, 3)
        let fileTable = try XCTUnwrap(tables.first { $0.numberOfRows == 120 })
        XCTAssertTrue(fileTable.allowsMultipleSelection)
        XCTAssertGreaterThan(fileTable.tableColumns.count, 2)
        for table in tables {
            let clip = try XCTUnwrap(table.enclosingScrollView?.contentView)
            XCTAssertLessThanOrEqual(table.rect(ofColumn: table.tableColumns.count - 1).maxX, clip.bounds.width + 1,
                                     "The final speed/progress column must fit without horizontal scrolling")
        }
        let scroll = try XCTUnwrap(descendants(content).compactMap { $0 as? NSScrollView }.first)
        XCTAssertLessThanOrEqual(scroll.documentView?.bounds.width ?? 0, scroll.contentView.bounds.width + 1)
        XCTAssertEqual(content.bounds.width, 440, accuracy: 1)
    }
}

private struct SearchReleaseClient: AppReleaseFetching {
    func latest(for current: AppVersion?, channel: AppUpdateChannel) async throws -> AppRelease? { nil }
}
