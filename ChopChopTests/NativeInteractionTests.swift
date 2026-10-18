import AppKit
import Combine
import Observation
import Synchronization
import SwiftUI
import XCTest
@testable import ChopChop

final class NativeInteractionTests: XCTestCase {
    @MainActor
    func testTransferUpdatesAreIsolatedFromEditingNavigationAndOtherTaskDetails() throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        store.tasks = [try fixture("selected"), try fixture("transferring")]
        store.tasks[1].status = .active
        store.selectedTaskID = "selected"
        let editing = Mutex(0), navigation = Mutex(0), details = Mutex(0), live = Mutex(0)
        withObservationTracking {
            _ = store.engineSettings; _ = store.preferences; _ = store.addDraft
        } onChange: { editing.withLock { $0 += 1 } }
        withObservationTracking {
            _ = store.selectedTaskRow?.id
            _ = store.listPresentation.visibleRows(for: .all, query: store.searchQuery).map(\.id)
            _ = store.count(for: .active)
        } onChange: { navigation.withLock { $0 += 1 } }
        withObservationTracking { _ = store.selectedTask } onChange: { details.withLock { $0 += 1 } }
        withObservationTracking { _ = store.activeSpeed } onChange: { live.withLock { $0 += 1 } }
        for tick in 1...20 {
            store.tasks[1].downloadSpeed = Int64(tick * 1024)
            store.tasks[1].completedLength += 1
            store.recordSpeed(download: Int64(tick * 1024), upload: 0)
            store.updateRuntime(lastError: nil)
        }
        XCTAssertEqual(editing.withLock { $0 }, 0, "Background transfers must not invalidate settings or unfinished input")
        XCTAssertEqual(navigation.withLock { $0 }, 0, "Transfer values do not change list membership, count or selection")
        XCTAssertEqual(details.withLock { $0 }, 0, "Another task's progress does not invalidate the inspected task")
        XCTAssertEqual(live.withLock { $0 }, 1, "The visible speed must still receive its new sample")
        XCTAssertEqual(store.activeSpeed, 20 * 1024)
        store.addDraft.rawInput = "https://example.com/draft"
        XCTAssertEqual(editing.withLock { $0 }, 1)
        store.tasks[0].completedLength += 1
        XCTAssertEqual(details.withLock { $0 }, 1)
        store.tasks[1].status = .completed
        XCTAssertEqual(navigation.withLock { $0 }, 1, "A real status change must update counts and filtered lists")
    }

    @MainActor
    func testAppKitEventStreamsObserveCommittedStateAfterObservationMigration() throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        var snapshots = 0, preferences = 0, navigation = 0
        let taskEvents = store.taskSnapshots.dropFirst().sink { tasks in
            snapshots += 1
            XCTAssertEqual(tasks.map(\.id), store.listPresentation.orderedRows.map(\.id))
        }
        let preferenceEvents = store.preferenceChanges.sink { value in
            preferences += 1
            XCTAssertEqual(store.preferences, value)
        }
        let navigationEvents = store.notificationNavigationRequests.sink { navigation += 1 }
        defer { taskEvents.cancel(); preferenceEvents.cancel(); navigationEvents.cancel() }
        store.tasks = [try fixture("event")]
        store.preferences.showMenuBar.toggle()
        store.notifications.onOpenDownloads?(["event"])
        XCTAssertEqual(snapshots, 1)
        XCTAssertEqual(preferences, 1)
        XCTAssertEqual(navigation, 1)
    }

    @MainActor
    func testNativeListPrimaryActionInspectsEveryTaskWithoutChangingTransferState() throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        var inspected = 0
        for status in DownloadStatus.allCases {
            var task = try fixture("double-click")
            task.status = status
            task.isAvailableInEngine = false
            store.tasks = [task]
            let action = try XCTUnwrap(DownloadListPresentation.primaryAction(for: [task.id], tasks: store.tasks))
            action.perform(in: DownloadActionContext(store: store, taskID: task.id,
                window: DownloadWindowActions(showDetails: { _ in inspected += 1 })))
            XCTAssertEqual(store.tasks.first?.status, status)
        }
        XCTAssertEqual(inspected, DownloadStatus.allCases.count)
        XCTAssertNil(DownloadListPresentation.primaryAction(for: [], tasks: store.tasks))
        XCTAssertNil(DownloadListPresentation.primaryAction(for: ["missing"], tasks: store.tasks))
        XCTAssertNil(DownloadListPresentation.primaryAction(for: ["double-click", "second"], tasks: store.tasks))
    }

    @MainActor
    func testClipboardImportKeepsFinderFileURLsAndMultilineLinks() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let file = URL(fileURLWithPath: "/tmp/Example Download.torrent")
        pasteboard.writeObjects([file as NSURL])
        let fileInputs = DownloadInputPresentation.clipboardInputs(from: pasteboard)
        XCTAssertEqual(fileInputs.count, 1)
        guard case .url(let imported) = try XCTUnwrap(fileInputs.first) else { return XCTFail("Keep Finder's file URL instead of its display name") }
        XCTAssertEqual(imported, file)
        pasteboard.clearContents()
        let links = "https://example.com/one.zip\nhttps://example.com/two.zip"
        pasteboard.setString(links, forType: .string)
        let textInputs = DownloadInputPresentation.clipboardInputs(from: pasteboard)
        XCTAssertEqual(textInputs.count, 1)
        guard case .text(let text) = try XCTUnwrap(textInputs.first) else { return XCTFail("Keep all pasted links") }
        XCTAssertEqual(text, links)
        pasteboard.clearContents()
        pasteboard.setString("  \n", forType: .string)
        XCTAssertTrue(DownloadInputPresentation.clipboardInputs(from: pasteboard).isEmpty)
    }

    func testListProgressDistinguishesUnknownSizeAndFinishedTransfers() throws {
        var task = try fixture("progress")
        task.totalLength = 0
        XCTAssertEqual(task.progressState, .indeterminate)
        XCTAssertEqual(task.progressLabel, "—")
        XCTAssertTrue(DownloadListTaskDisplay(task: task).sizeLabel.contains(ByteFormat.size(task.completedLength)))
        task.totalLength = 1000
        task.completedLength = 1000
        task.status = .completed
        XCTAssertEqual(task.progressState, .determinate(1))
        XCTAssertEqual(DownloadListTaskDisplay(task: task).sizeLabel, ByteFormat.size(1000))
        task.status = .active
        task.isSharing = true
        // Selected torrent files can be complete even if the reported total
        // includes skipped files. Seeding represents a finished download.
        task.completedLength = 700
        XCTAssertEqual(task.progressState, .determinate(1))
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
        var searched = false
        var window = DownloadWindowActions(newDownload: { opened = true }, pasteDownload: {}, openDownloadFile: {},
            toggleDetails: {}, detailsPresented: false, hasSelection: true, canPresentDownload: true,
            showDetails: { section = $0 }, searchDownloads: { searched = true })
        var context = DownloadActionContext(store: store, taskID: task.id, window: window)
        XCTAssertTrue(DownloadAction.newDownload.perform(in: context)); XCTAssertTrue(opened)
        XCTAssertTrue(DownloadAction.searchDownloads.perform(in: context)); XCTAssertTrue(searched)
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
        window.searchDownloads = nil; context.window = window; searched = false
        XCTAssertFalse(DownloadAction.searchDownloads.perform(in: context))
        XCTAssertFalse(searched)
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
    func testRowDetailsToggleClosesSameTaskAndSwitchesOtherTasks() throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        let first = try fixture("toggle-first"), second = try fixture("toggle-second")
        store.tasks = [first, second]
        let presentation = TaskDetailsPresentation()
        let owner = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 900, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; owner.alphaValue = 0; owner.orderBack(nil)
        presentation.attach(to: owner)
        defer { presentation.dismiss(returnFocus: false); owner.close() }
        let ownerFrame = owner.frame
        func context(_ id: String) -> DownloadActionContext {
            .listTask(store: store, taskID: id, detailsPresentation: presentation,
                      showDetails: { presentation.present(store: store, moveSelection: { _ in }) })
        }
        let firstContext = context(first.id), secondContext = context(second.id)
        XCTAssertFalse(DownloadAction.engineReady(in: store), "Details toggling also works offline")
        firstContext.window?.toggleDetails()
        XCTAssertTrue(presentation.isPresented)
        XCTAssertEqual(store.selectedTaskID, first.id)
        XCTAssertEqual(context(first.id).window?.detailsPresented, true)
        XCTAssertEqual(context(second.id).window?.detailsPresented, false)
        let panel = try XCTUnwrap(presentation.panel)

        // Reusing an earlier context must consult live presentation state.
        firstContext.window?.toggleDetails()
        XCTAssertFalse(presentation.isPresented)
        XCTAssertNil(panel.contentViewController)
        XCTAssertNil(panel.parent)
        XCTAssertEqual(context(first.id).window?.detailsPresented, false)

        firstContext.window?.toggleDetails()
        secondContext.window?.toggleDetails()
        XCTAssertTrue(presentation.isPresented, "Another task switches the existing details panel")
        XCTAssertTrue(presentation.panel === panel)
        XCTAssertEqual(store.selectedTaskID, second.id)
        XCTAssertEqual(context(first.id).window?.detailsPresented, false)
        XCTAssertEqual(context(second.id).window?.detailsPresented, true)

        // Explicit Show Details and configuration commands must keep the panel open.
        XCTAssertTrue(DownloadAction.details.perform(in: secondContext))
        XCTAssertTrue(presentation.isPresented)
        store.runtime.phase = .running(pid: 1)
        XCTAssertTrue(DownloadAction.speedLimits.perform(in: secondContext))
        XCTAssertTrue(presentation.isPresented)
        XCTAssertEqual(presentation.sectionRequest?.section, .speedLimits)

        // A stale button for a removed task must not dismiss another task's panel.
        store.tasks = [second]
        firstContext.window?.toggleDetails()
        XCTAssertTrue(presentation.isPresented)
        secondContext.window?.toggleDetails()
        XCTAssertFalse(presentation.isPresented)

        // Opening through the shared presenter (as Space does) is also toggled off.
        presentation.present(store: store, moveSelection: { _ in })
        secondContext.window?.toggleDetails()
        XCTAssertFalse(presentation.isPresented)
        XCTAssertEqual(owner.frame, ownerFrame)
    }

    @MainActor
    func testAnimatedSettingsSearchKeepsTypingFocusAndSurvivesQuickReopen() async throws {
        let model = SettingsSearchModel()
        let host = NSHostingController(rootView: SettingsSearchField(model: model).frame(width: 240, height: 28).padding(20))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 150),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentViewController = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSSearchField }.first)
        let coordinator = try XCTUnwrap(field.delegate as? SettingsSearchField.Coordinator)
        defer { coordinator.close() }
        window.makeFirstResponder(field)
        model.query = "engine"; field.stringValue = "engine"; model.isPresented = true
        coordinator.schedulePresentation()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(coordinator.popover.isShown)
        XCTAssertNotNil(field.currentEditor(), "Popover presentation must leave typing in the search field")
        model.cancel(); coordinator.schedulePresentation()
        try await Task.sleep(for: .milliseconds(20))
        model.query = "update"; field.stringValue = "update"; model.isPresented = true
        coordinator.schedulePresentation()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.query, "update")
        XCTAssertTrue(model.isPresented)
        XCTAssertTrue(coordinator.popover.isShown, "A pending close must not discard a new search")
        XCTAssertNotNil(field.currentEditor())
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
        let unchangedEvents = Mutex(0), changedEvents = Mutex(0)
        let presentationEvents = Mutex(0)
        withObservationTracking { _ = unchanged.task } onChange: { unchangedEvents.withLock { $0 += 1 } }
        withObservationTracking { _ = changed.task } onChange: { changedEvents.withLock { $0 += 1 } }
        withObservationTracking { _ = changed.presentation } onChange: { presentationEvents.withLock { $0 += 1 } }
        let start = ContinuousClock.now
        for _ in 0..<20 { presentation.update(tasks) }
        XCTAssertEqual(unchangedEvents.withLock { $0 }, 0); XCTAssertEqual(changedEvents.withLock { $0 }, 0)
        tasks[500].completedLength += 1
        presentation.update(tasks)
        XCTAssertEqual(unchangedEvents.withLock { $0 }, 0); XCTAssertEqual(changedEvents.withLock { $0 }, 1)
        XCTAssertEqual(presentationEvents.withLock { $0 }, 0,
                       "A progress tick must not invalidate filename, status, tooltip or row controls")
        XCTAssertTrue(presentation.row(for: tasks[500]) === changed)
        withObservationTracking { _ = changed.task } onChange: { changedEvents.withLock { $0 += 1 } }
        presentation.update(tasks.reversed())
        XCTAssertTrue(presentation.row(for: tasks[0]) === unchanged)
        XCTAssertEqual(changedEvents.withLock { $0 }, 1)
        tasks[500].status = .active
        presentation.update(tasks)
        XCTAssertEqual(presentationEvents.withLock { $0 }, 1, "A real phase change must update row controls")
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
        let host = NSHostingController(rootView: DownloadConsoleView(inputCoordinator: store.inputCoordinator, presentation: details).environment(store))
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
