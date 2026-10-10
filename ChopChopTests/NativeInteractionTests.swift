import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ChopChop

final class NativeInteractionTests: XCTestCase {
    @MainActor
    func testNativeListPrimaryActionOnlyTogglesOneResumableTask() throws {
        var task = try fixture("double-click")
        for (status, expected) in [(DownloadStatus.paused, DownloadAction.resume), (.active, .pause), (.waiting, .pause)] {
            task.status = status
            XCTAssertEqual(DownloadListPresentation.primaryAction(for: [task.id], tasks: [task]), expected)
        }
        for status in [DownloadStatus.completed, .failed, .removed] {
            task.status = status
            XCTAssertNil(DownloadListPresentation.primaryAction(for: [task.id], tasks: [task]))
        }
        task.status = .paused
        XCTAssertNil(DownloadListPresentation.primaryAction(for: [], tasks: [task]))
        XCTAssertNil(DownloadListPresentation.primaryAction(for: ["missing"], tasks: [task]))
        XCTAssertNil(DownloadListPresentation.primaryAction(for: [task.id, "second"], tasks: [task, try fixture("second")]))
        task.isAvailableInEngine = false
        XCTAssertNil(DownloadListPresentation.primaryAction(for: [task.id], tasks: [task]))
        task.isAvailableInEngine = true
        task.media = MediaTaskProgress(state: "finalizing")
        XCTAssertNil(DownloadListPresentation.primaryAction(for: [task.id], tasks: [task]))
    }

    func testListProgressDistinguishesUnknownSizeAndFinishedTransfers() throws {
        var task = try fixture("progress")
        task.totalLength = 0
        XCTAssertEqual(task.progressState, .indeterminate)
        XCTAssertEqual(task.progressLabel, "—")
        XCTAssertTrue(DownloadListTaskDisplay(task: task).showsProgress)
        XCTAssertTrue(DownloadListTaskDisplay(task: task).sizeLabel.contains(ByteFormat.size(task.completedLength)))
        task.totalLength = 1000
        task.completedLength = 1000
        task.status = .completed
        XCTAssertFalse(DownloadListTaskDisplay(task: task).showsProgress)
        XCTAssertEqual(DownloadListTaskDisplay(task: task).sizeLabel, ByteFormat.size(1000))
        task.status = .active
        task.isSharing = true
        XCTAssertFalse(DownloadListTaskDisplay(task: task).showsProgress)
        XCTAssertEqual(DownloadListTaskDisplay(task: task).statusSymbol, "arrow.up.circle")
        XCTAssertTrue(DownloadListTaskDisplay(task: task).showsTransferRates)
        task.isSharing = false
        task.isChecking = true
        XCTAssertFalse(DownloadListTaskDisplay(task: task).showsTransferRates)
        task.isChecking = false
        task.media = MediaTaskProgress(state: "finalizing")
        XCTAssertFalse(DownloadListTaskDisplay(task: task).showsTransferRates)
    }

    @MainActor
    func testCommandSearchUsesLocalizedTitlesAndStableIdentifiers() {
        XCTAssertEqual(CommandSearchIndex.matches("resume download"), [.resume])
        XCTAssertEqual(CommandSearchIndex.matches(" finder "), [.reveal])
        XCTAssertEqual(CommandSearchIndex.matches("限速", title: { $0 == .speedLimits ? "设置任务限速" : $0.titleKey }), [.speedLimits])
        XCTAssertTrue(CommandSearchIndex.matches("no-such-command").isEmpty)
        XCTAssertEqual(CommandSearchIndex.nextSelection(.resume, direction: 1, in: [.pause, .resume]), .resume)
        XCTAssertEqual(CommandSearchIndex.nextSelection(nil, direction: -1, in: [.pause, .resume]), .pause)
        XCTAssertNil(CommandSearchIndex.nextSelection(.resume, direction: 1, in: []))
        XCTAssertEqual(Set(DownloadAction.allCases.map(\.id)).count, DownloadAction.allCases.count)
    }

    @MainActor
    func testCommandDispatchRevalidatesTaskAndRoutesToRequestedSettings() throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        let task = try fixture("command")
        store.tasks = [task]; store.runtime.phase = .running(pid: 1)
        var section: TaskDetailSection?
        var opened = false
        var window = DownloadWindowActions(newDownload: { opened = true }, pasteDownload: {}, openDownloadFile: {},
            toggleDetails: {}, detailsPresented: false, hasSelection: true, canPresentDownload: true,
            showDetails: { section = $0 })
        var context = DownloadActionContext(store: store, taskID: task.id, window: window)
        XCTAssertTrue(DownloadAction.newDownload.perform(in: context)); XCTAssertTrue(opened)
        XCTAssertTrue(DownloadAction.speedLimits.perform(in: context)); XCTAssertEqual(section, .speedLimits)
        XCTAssertTrue(DownloadAction.schedule.perform(in: context)); XCTAssertEqual(section, .schedule)
        XCTAssertTrue(DownloadAction.resume.isEnabled(in: context))
        store.tasks[0].status = .active
        XCTAssertFalse(DownloadAction.resume.perform(in: context), "Never dispatch a stale menu action")
        store.tasks = []
        XCTAssertFalse(DownloadAction.remove.perform(in: context))
        XCTAssertNil(store.removalRequest)
        window.canPresentDownload = false; context.window = window
        XCTAssertFalse(DownloadAction.newDownload.perform(in: context))
    }

    @MainActor
    func testRowActionsTargetClickedTaskAndRetainRemovalConfirmation() throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        let first = try fixture("first"), second = try fixture("second")
        store.tasks = [first, second]
        store.selectedTaskIDs = [first.id, second.id]
        store.preferences.suppressRemoveConfirmation = false
        let presentation = TaskDetailsPresentation()
        presentation.selectionChanged(to: first.id)
        presentation.sectionRequest = TaskDetailRequest(section: .schedule)
        var openedTask: String?
        let context = DownloadActionContext.listTask(store: store, taskID: second.id,
            detailsPresentation: presentation, showDetails: { openedTask = store.selectedTaskID })

        // A row's trash button never inherits an existing multiple selection.
        XCTAssertTrue(DownloadAction.remove.perform(in: context))
        XCTAssertEqual(store.removalRequest?.tasks.map(\.id), [second.id])
        XCTAssertEqual(store.tasks.map(\.id), [first.id, second.id], "Wait for the existing confirmation flow")
        XCTAssertEqual(store.selectedTaskIDs, [first.id, second.id])
        store.removalRequest = nil

        // Details remain available offline and select the task before opening the panel.
        XCTAssertFalse(DownloadAction.engineReady(in: store))
        XCTAssertTrue(DownloadAction.details.perform(in: context))
        XCTAssertEqual(openedTask, second.id)
        XCTAssertEqual(store.selectedTaskIDs, [second.id])
        XCTAssertNil(presentation.sectionRequest)
        store.isPerformingBatchOperation = true
        XCTAssertFalse(DownloadAction.remove.perform(in: context))
        XCTAssertNil(store.removalRequest)
        XCTAssertTrue(DownloadAction.details.isEnabled(in: context))
        store.isPerformingBatchOperation = false

        // Polling may remove the row between rendering and dispatch.
        store.tasks = [first]
        openedTask = nil
        XCTAssertFalse(DownloadAction.details.perform(in: context))
        XCTAssertNil(openedTask)
        XCTAssertFalse(DownloadAction.remove.perform(in: context))
        XCTAssertNil(store.removalRequest)
    }

    @MainActor
    func testNativeCommandPanelFitsAndClosesWithOwner() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        let owner = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 900, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; owner.alphaValue = 0; owner.orderBack(nil)
        let presentation = CommandSearchPresentation()
        defer { presentation.dismiss(returnFocus: false); owner.close() }
        let originalFrame = owner.frame
        presentation.present(owner: owner, store: store) { DownloadActionContext(store: store) }
        try await Task.sleep(for: .milliseconds(200))
        let panel = try XCTUnwrap(presentation.panel)
        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertTrue(panel.parent === owner)
        XCTAssertEqual(owner.frame, originalFrame)
        let content = try XCTUnwrap(panel.contentView)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let field = try XCTUnwrap(descendants(content).compactMap { $0 as? NSSearchField }.first)
        let rect = field.convert(field.bounds, to: content)
        XCTAssertGreaterThanOrEqual(rect.minX, 16)
        XCTAssertLessThanOrEqual(rect.maxX, content.bounds.maxX - 16)
        XCTAssertGreaterThan(field.bounds.width, 400)
        let composition = NSTextView()
        composition.setMarkedText("中文", selectedRange: NSRange(location: 0, length: 2),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(composition.hasMarkedText())
        XCTAssertEqual(field.delegate?.control?(field, textView: composition, doCommandBy: #selector(NSResponder.insertNewline(_:))), false,
                       "Return must confirm the input method candidate before executing a command")
        XCTAssertEqual(field.delegate?.control?(field, textView: composition, doCommandBy: #selector(NSResponder.moveDown(_:))), false)
        let output = try Aria2NextPaths.supportDirectory().appendingPathComponent("Design Previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("command-search.png"))
        print("COMMAND_SEARCH_PREVIEW_OUTPUT=\(output.path)")
        owner.close()
        XCTAssertNil(presentation.panel)
    }

    @MainActor
    func testThousandTaskProjectionOnlyPublishesChangedRowsAndReusesIdentity() throws {
        let presentation = DownloadListPresentation()
        var tasks = try (0..<1000).map { try fixture("row-\($0)") }
        presentation.update(tasks)
        let unchanged = presentation.row(for: tasks[0]), changed = presentation.row(for: tasks[500])
        var unchangedEvents = 0, changedEvents = 0
        let first = unchanged.objectWillChange.sink { unchangedEvents += 1 }
        let second = changed.objectWillChange.sink { changedEvents += 1 }
        defer { first.cancel(); second.cancel() }
        let start = ContinuousClock.now
        for _ in 0..<20 { presentation.update(tasks) }
        XCTAssertEqual(unchangedEvents, 0); XCTAssertEqual(changedEvents, 0)
        tasks[500].completedLength += 1
        presentation.update(tasks)
        XCTAssertEqual(unchangedEvents, 0); XCTAssertEqual(changedEvents, 1)
        XCTAssertTrue(presentation.row(for: tasks[500]) === changed)
        presentation.update(tasks.reversed())
        XCTAssertTrue(presentation.row(for: tasks[0]) === unchanged)
        XCTAssertEqual(changedEvents, 1)
        print("ROW_PROJECTION_1000_TASKS_22_UPDATES=\(start.duration(to: .now))")
        weak let removed = presentation.row(for: tasks[700])
        tasks.remove(at: 700); presentation.update(tasks)
        XCTAssertNil(removed, "Removed rows must release their task snapshots")
    }

    @MainActor
    func testThousandTaskWindowKeepsScrollSelectionAndDraftDuringPolling() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        store.tasks = try (0..<1000).map { try fixture("list-\($0)") }
        store.addDraft.rawInput = "https://example.com/unfinished-draft"
        store.selectedTaskID = "list-500"
        let details = TaskDetailsPresentation()
        let host = NSHostingController(rootView: DownloadConsoleView(inputCoordinator: store.inputCoordinator, presentation: details).environmentObject(store))
        host.sizingOptions = [.minSize]
        host.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.view.frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0
        window.contentViewController = host; window.orderBack(nil)
        defer { details.dismiss(returnFocus: false); window.close() }
        try await Task.sleep(for: .milliseconds(400))
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let table = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTableView }.first { $0.numberOfRows >= 1000 })
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        let offset = scroll.contentView.bounds.origin
        let frame = window.frame
        for _ in 0..<5 {
            var refreshed = store.tasks
            refreshed[0].completedLength += 1
            store.tasks = refreshed
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(store.selectedTaskID, "list-500")
        XCTAssertEqual(store.addDraft.rawInput, "https://example.com/unfinished-draft")
        XCTAssertEqual(scroll.contentView.bounds.minY, offset.y, accuracy: 1)
        XCTAssertEqual(window.frame, frame)
        XCTAssertFalse(details.isPresented)
        XCTAssertNotNil(table.doubleAction, "The native list must handle its primary double-click action")
    }

    @MainActor
    func testDetailsRememberFrameAndTabAcrossSelectionAndReopening() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        store.tasks = [try fixture("first"), try fixture("second")]; store.selectedTaskID = "first"
        let owner = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 900, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; owner.alphaValue = 0; owner.orderBack(nil)
        let presentation = TaskDetailsPresentation(); presentation.attach(to: owner)
        defer { presentation.dismiss(returnFocus: false); owner.close() }
        presentation.present(store: store, moveSelection: { _ in })
        let panel = try XCTUnwrap(presentation.panel)
        panel.setContentSize(NSSize(width: 550, height: 510))
        presentation.selectedTab = .files
        let frame = panel.frame
        store.selectedTaskID = "second"
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(panel.frame, frame)
        XCTAssertEqual(presentation.selectedTab, .files)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let tabs = try XCTUnwrap(descendants(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(tabs.selectedSegment, 1, "The actual native control must retain its selection")
        presentation.dismiss(returnFocus: false)
        owner.setFrameOrigin(NSPoint(x: 200, y: 100))
        presentation.present(store: store, moveSelection: { _ in })
        XCTAssertEqual(panel.frame, frame, "Reopening must not recenter or reset the panel size")
        XCTAssertEqual(presentation.selectedTab, .files)
        presentation.selectedTab = .overview
        presentation.sectionRequest = TaskDetailRequest(section: .schedule)
        try await Task.sleep(for: .milliseconds(300))
        let content = try XCTUnwrap(panel.contentView)
        let datePicker = try XCTUnwrap(descendants(content).compactMap { $0 as? NSDatePicker }.first)
        let scroll = try XCTUnwrap(datePicker.enclosingScrollView)
        XCTAssertTrue(scroll.contentView.bounds.contains(datePicker.convert(datePicker.bounds, to: scroll.contentView)),
            "A schedule command must reveal the actual editor inside the scrolling content")
        store.tasks[1].completedLength += 1
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(descendants(content).contains { $0 === datePicker }, "Polling must not recreate task editors")
    }

    @MainActor
    func testSavedPanelFrameRecoversWhenDisplayDisappears() {
        let main = NSRect(x: 0, y: 24, width: 1440, height: 876)
        let other = NSRect(x: -1920, y: 24, width: 1920, height: 1056)
        let saved = NSRect(x: -1000, y: 200, width: 600, height: 680)
        XCTAssertEqual(TaskDetailsPresentation.fittedFrame(saved, screens: [main, other], fallback: main), saved)
        let recovered = TaskDetailsPresentation.fittedFrame(saved, screens: [main], fallback: main)
        XCTAssertTrue(main.contains(recovered))
        let oversized = TaskDetailsPresentation.fittedFrame(NSRect(x: 100, y: -50, width: 2000, height: 1500), screens: [main], fallback: main)
        XCTAssertEqual(oversized, main)
    }

    private func fixture(_ gid: String) throws -> DownloadTask {
        try JSONDecoder().decode(Aria2TaskDTO.self, from: Data("""
        {"gid":"\(gid)","status":"paused","totalLength":"1000","completedLength":"200","files":[{"index":"1","path":"/tmp/Example.zip","length":"1000","completedLength":"200"}]}
        """.utf8)).toTask()
    }
}
