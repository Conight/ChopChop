import AppKit
import SwiftUI
import XCTest
@testable import ChopChop

final class WindowLayoutTests: XCTestCase {
    @MainActor
    func testFeedbackButtonsKeepTheirGeometryThroughBusySuccessAndReset() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingController(rootView: Button {} label: {
                ActionFeedbackLabel(title: String(localized: "Copy Pairing Code"), systemImage: "doc.on.doc", successTitle: String(localized: "Copied"))
            }.buttonStyle(.bordered).environment(\.colorScheme, scheme))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentViewController = host
            defer { window.close() }
            let proposal = NSSize(width: 320, height: 100)
            let initial = host.sizeThatFits(in: proposal)
            for feedback in [ActionFeedback.working, .succeeded, .idle] {
                host.rootView = Button {} label: {
                    ActionFeedbackLabel(title: String(localized: "Copy Pairing Code"), systemImage: "doc.on.doc", feedback: feedback, successTitle: String(localized: "Copied"))
                }.buttonStyle(.bordered).environment(\.colorScheme, scheme)
                await NativeLayout.flush(host.view)
                let size = host.sizeThatFits(in: proposal)
                XCTAssertEqual(size.width, initial.width, accuracy: 0.5)
                XCTAssertEqual(size.height, initial.height, accuracy: 0.5)
            }
        }
    }

    @MainActor
    func testEngineInstallationStageChangesKeepTheProgressContainerStable() async throws {
        let host = NSHostingController(rootView: EngineInstallationProgressView(progress: .init(stage: .connecting), onCancel: {}))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = host
        defer { window.close() }
        let proposal = NSSize(width: 360, height: 200)
        let initial = host.sizeThatFits(in: proposal)
        for stage in [EngineInstallationProgress.Stage.downloading, .verifying, .preparing, .savingDownloads, .restarting, .activating, .restoring] {
            host.rootView = EngineInstallationProgressView(progress: .init(stage: stage, completedBytes: 250, totalBytes: 1000), onCancel: {})
            await NativeLayout.flush(host.view)
            let size = host.sizeThatFits(in: proposal)
            XCTAssertEqual(size.width, initial.width, accuracy: 0.5, "\(stage)")
            XCTAssertEqual(size.height, initial.height, accuracy: 0.5, "\(stage)")
        }
    }

    @MainActor
    func testSidebarUpdateCheckingKeepsFooterSizeStable() async throws {
        let suite = "ChopChop-sidebar-update-layout-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = UpdateCheckProbe(holdApp: true, holdEngine: true)
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true), engineInstallationManager: probe)
        defer { store.shutdown(); Task { await probe.finishApp(); await probe.finishEngine() } }
        store.runtime = EngineRuntimeSnapshot(phase: .running(pid: 1234))
        let updates = AppUpdateCoordinator(build: AppBuild(version: "0.0.1-beta.1"), client: probe, defaults: defaults)
        let host = NSHostingController(rootView: UpdateActivityFooter(updates: updates).environment(store).desktopControls().frame(width: 188))
        host.sizingOptions = []
        let window = LayoutPreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 188, height: 180),
                                         styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        defer { window.close() }
        await NativeLayout.flush(host.view)
        let proposal = NSSize(width: 188, height: 180)
        let before = host.sizeThatFits(in: proposal)
        let check = Task { await updates.checkAll(using: store) }
        try await NativeLayout.wait(until: "update check starts") { updates.isChecking(using: store) }
        await NativeLayout.flush(host.view)
        let during = host.sizeThatFits(in: proposal)
        XCTAssertEqual(during.height, before.height, accuracy: 0.5)
        XCTAssertEqual(during.width, before.width, accuracy: 0.5)
        await probe.finishEngine()
        try await NativeLayout.wait(until: "update check starts") { updates.isChecking(using: store) }
        await NativeLayout.flush(host.view)
        XCTAssertEqual(host.sizeThatFits(in: proposal).height, before.height, accuracy: 0.5)
        await probe.finishApp()
        await check.value
        await NativeLayout.flush(host.view)
        XCTAssertFalse(updates.isChecking(using: store))
        XCTAssertEqual(host.sizeThatFits(in: proposal).height, before.height, accuracy: 0.5)
    }

    @MainActor
    func testAddDownloadSheetKeepsFieldBordersInsideDisclosure() async throws {
        try await verifyAddDownloadSheet(width: 740, height: nil, appearance: .aqua)
    }

    @MainActor
    func testCompactAddDownloadSheetKeepsActionsVisible() async throws {
        try await verifyAddDownloadSheet(width: 660, height: AppLayout.sheetMinimumHeight, appearance: .darkAqua)
    }

    @MainActor
    func testMediaSelectionSheetKeepsControlsInsideCompactWindow() async throws {
        try await verifyAddDownloadSheet(width: 660, height: AppLayout.sheetMinimumHeight, appearance: .darkAqua, mediaSelection: true)
    }

    @MainActor
    func testAddDownloadSheetUsesTallerDefaultAndEnforcesMinimumHeight() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        store.addDraft.rawInput = "https://example.com/download.zip"
        let host = NSHostingController(rootView: Color.clear.sheet(isPresented: .constant(true)) {
            AddDownloadPanel(onDismiss: {}).environment(store).background(InvisibleSheetWindow())
        })
        host.sizingOptions = []
        let owner = LayoutPreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; owner.alphaValue = 0; owner.contentViewController = host
        owner.orderBack(nil)
        defer {
            for sheet in owner.sheets { owner.endSheet(sheet) }
            owner.close()
        }
        try await NativeLayout.wait(until: "sheet presentation") { owner.attachedSheet != nil }
        let sheet = try XCTUnwrap(owner.attachedSheet)
        await NativeLayout.flush(try XCTUnwrap(sheet.contentView))
        let content = try XCTUnwrap(sheet.contentView)
        // The native presenter must enforce this limit during interactive resizing;
        // merely rendering a fixed-size root would not catch the original 178-point minimum.
        XCTAssertEqual(content.bounds.height, AppLayout.sheetHeight, accuracy: 1)
        XCTAssertEqual(sheet.contentMinSize.height, AppLayout.sheetMinimumHeight, accuracy: 1)
        content.layoutSubtreeIfNeeded()

    }

    @MainActor
    func testExpandedTaskControlsFitANarrowInspector() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        let task = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"layout","status":"paused","files":[{"index":"1","path":"/tmp/file","length":"10","completedLength":"0"}],"uris":[{"uri":"https://example.com/file"}]}"#.utf8)).toTask()
        let root = ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DownloadRepairView(task: task, initiallyExpanded: true)
                TaskScheduleView(task: task, initiallyExpanded: true)
                FileVerificationView(file: task.files[0], initiallyExpanded: true)
            }.padding(16)
        }.environment(store)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0
        window.contentViewController = host
        window.orderBack(nil)
        defer { window.close() }
        await NativeLayout.flush(host.view)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let fields = descendants(content).compactMap { $0 as? NSTextField }
        XCTAssertGreaterThanOrEqual(fields.count, 4)
        for field in fields where field.isEditable {
            let rect = field.convert(field.bounds, to: content)
            XCTAssertGreaterThanOrEqual(rect.minX, 3)
            XCTAssertLessThanOrEqual(rect.maxX, content.bounds.maxX - 3)
        }
        let scroll = try XCTUnwrap(descendants(content).compactMap { $0 as? NSScrollView }.first)
        XCTAssertLessThanOrEqual(scroll.documentView?.bounds.width ?? 0, scroll.contentView.bounds.width + 1)
    }

    @MainActor
    func testTorrentSelectionFitsCompactSheetAndKeepsActionsOutsideList() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        store.bitTorrentSelectionSession = BitTorrentFileSelectionSession(source: "magnet:?xt=urn:btih:test",
            taskName: String(repeating: "Long torrent title ", count: 12), files: (1...200).map {
                DownloadFile(index: $0, path: "/tmp/Example/Folder/File \($0).bin", length: 100, completedLength: 0, isSelected: true)
            }, selectedFileIndexes: [1], phase: .ready, destination: "/tmp")
        let host = NSHostingController(rootView: AddDownloadPanel(onDismiss: {}).environment(store))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0
        window.contentViewController = host; window.orderBack(nil)
        defer { window.close() }
        await NativeLayout.flush(host.view)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.bounds.width, 660, accuracy: 1)
        XCTAssertLessThanOrEqual(content.bounds.height, 480)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let scrolls = descendants(content).compactMap { $0 as? NSScrollView }
        XCTAssertEqual(scrolls.count, 1, "Torrent files get a single scrolling surface")
        let list = try XCTUnwrap(scrolls.first)
        let bounds = list.convert(list.bounds, to: content)
        XCTAssertTrue(content.bounds.contains(bounds))
        XCTAssertGreaterThan(content.bounds.height - bounds.height, 120, "Reserve space for the header and persistent actions")
    }

    @MainActor
    func testResizedTorrentSheetFillsWindowAcrossSourceChanges() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        store.addDraft.rawInput = "file:///tmp/Example.torrent"
        let controller = NSHostingController(rootView: Color.clear.sheet(isPresented: .constant(true)) {
            AddDownloadPanel(onDismiss: {}).environment(store).background(InvisibleSheetWindow())
        })
        controller.sizingOptions = []
        let owner = LayoutPreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; owner.alphaValue = 0; owner.contentViewController = controller
        owner.orderBack(nil)
        defer {
            for sheet in owner.sheets { owner.endSheet(sheet) }
            owner.close()
        }
        try await NativeLayout.wait(until: "sheet presentation") { owner.attachedSheet != nil }
        let sheet = try XCTUnwrap(owner.attachedSheet)
        await NativeLayout.flush(try XCTUnwrap(sheet.contentView))
        let content = try XCTUnwrap(sheet.contentView)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let paths = ["\(String(repeating: "Long video name — 影片 ", count: 8)).mkv",
                     "Pictures/cover.png", "Subtitles/movie.srt", "Readme.txt"]
        let files = paths.enumerated().map { DownloadFile(index: $0.offset + 1,
            path: "/tmp/Example/" + $0.element, length: Int64(($0.offset + 1) * 100), completedLength: 0, isSelected: true) }

        // Reproduce an actual sheet being resized and reused; recreating a root view
        // at each size would miss AppKit retaining the user's larger sheet frame.
        // The native sheet still obeys its screen bounds, even though the invisible
        // owner allows an oversized frame. CI's display can be only 1024 points wide.
        let screen = try XCTUnwrap(sheet.screen ?? owner.screen)
        let availableSize = sheet.contentRect(forFrameRect: screen.visibleFrame.insetBy(dx: 20, dy: 20)).size
        let largeSize = NSSize(width: min(1040, availableSize.width), height: min(720, availableSize.height))
        XCTAssertGreaterThan(largeSize.width, AppLayout.sheetWidth)
        XCTAssertGreaterThan(largeSize.height, AppLayout.sheetHeight)
        for (size, appearance) in [
            (largeSize, NSAppearance.Name.aqua),
            (NSSize(width: 660, height: AppLayout.sheetMinimumHeight), NSAppearance.Name.darkAqua)
        ] {
            sheet.appearance = NSAppearance(named: appearance)
            sheet.setContentSize(size)
            await NativeLayout.flush(content)
            for stage in ["source", "loading", "ready", "failed", "returned"] {
                if stage == "source" || stage == "returned" {
                    await store.cancelBitTorrentFileSelection()
                } else {
                    store.bitTorrentSelectionSession = BitTorrentFileSelectionSession(
                        source: store.addDraft.rawInput, taskName: String(repeating: "Example collection 示例合集 ", count: 6),
                        files: stage == "ready" ? files : [], selectedFileIndexes: stage == "ready" ? [1, 2, 3, 4] : [],
                        phase: stage == "ready" ? .ready : stage == "failed" ? .failed : .loading,
                        destination: "/tmp/Example", issue: stage == "failed" ? "Temporary fixture error" : nil)
                }
                await NativeLayout.flush(content)
                content.layoutSubtreeIfNeeded()
                XCTAssertEqual(content.bounds.width, size.width, accuracy: 1, stage)
                XCTAssertEqual(content.bounds.height, size.height, accuracy: 1, stage)
                XCTAssertGreaterThanOrEqual(sheet.contentMinSize.height, AppLayout.sheetMinimumHeight, stage)
                let artwork = try XCTUnwrap(descendants(content).first { $0.identifier?.rawValue == "download-artwork-anchor" })
                let artworkFrame = artwork.convert(artwork.bounds, to: content)
                XCTAssertEqual(artworkFrame.minX, 0, accuracy: 1, stage)
                XCTAssertEqual(artworkFrame.minY, 0, accuracy: 1, stage)
                XCTAssertEqual(artworkFrame.width, 180, accuracy: 1, stage)
                XCTAssertEqual(artworkFrame.height, content.bounds.height, accuracy: 1,
                               "Artwork must fill the resized sheet, including after Change Source: \(stage)")
                let scrolls = descendants(content).compactMap { $0 as? NSScrollView }
                let mainScroll = try XCTUnwrap(scrolls.max { $0.bounds.height < $1.bounds.height })
                let scrollFrame = mainScroll.convert(mainScroll.bounds, to: content)
                XCTAssertGreaterThanOrEqual(scrollFrame.minX, 200, stage)
                XCTAssertTrue(content.bounds.contains(scrollFrame), stage)
                // Preserve a scrollable list/body plus fixed header and footer even
                // with long names and the compact frame.
                XCTAssertGreaterThan(mainScroll.bounds.height, stage == "ready" ? 40 : 100, stage)
            }
        }
    }

    /// Exercise the real SwiftUI sheet presenter, including its native clipping containers.
    /// Both windows are invisible; no input events or production app state are used.
    @MainActor
    private func verifyAddDownloadSheet(width: CGFloat, height: CGFloat?, appearance: NSAppearance.Name, mediaSelection: Bool = false) async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        store.addDraft.rawInput = "https://example.com/download.zip"
        if mediaSelection {
            let task = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"selection","status":"paused","media":{"state":"awaiting-selection","live":"false","duration":"120000","tracks":[{"id":"video","type":"video","height":"2160","frameRate":"59.940000","codec":"avc1.640028","bandwidth":"25000000","selected":"true"},{"id":"audio","type":"audio","language":"zh-Hant","codec":"mp4a.40.2","selected":"true"}]}}"#.utf8)).toTask()
            store.mediaDownloads.restore(task, options: [:])
        }
        store.addDraft.userAgent = String(repeating: "Long user agent; ", count: 20)
        store.addDraft.customHeaders = "X-Example: " + String(repeating: "long-value", count: 30)
        let controller = NSHostingController(rootView: Color.clear
            .sheet(isPresented: .constant(true)) {
                AddDownloadPanel(initiallyShowsAdvanced: true, mediaCoordinator: store.mediaDownloads, onDismiss: {}).environment(store)
                    .frame(width: width, height: height)
                    .background(InvisibleSheetWindow())
            })
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
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
        try await NativeLayout.wait(until: "sheet presentation") { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        await NativeLayout.flush(try XCTUnwrap(sheet.contentView))
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
        if mediaSelection { XCTAssertGreaterThanOrEqual(fields.count, 7) }
        else { XCTAssertEqual(fields.count, 7, "Every advanced field, including secure and multiline fields, must be laid out") }
        for field in fields {
            XCTAssertGreaterThanOrEqual(field.convert(field.bounds, to: content).minX, 200,
                                       "Form fields must retain their own gutter beside the 180-point artwork")
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
        await NativeLayout.flush(content)
        let lastField = try XCTUnwrap(fields.last)
        let lastBezel = lastField.convert(lastField.bounds, to: scroll.contentView).insetBy(dx: -3, dy: -3)
        XCTAssertTrue(scroll.contentView.bounds.contains(lastBezel), "The final field must be fully visible at the end of the scroll")

    }

    @MainActor
    func testTransferPanelsFitNarrowInspector() async throws {
        let map = try XCTUnwrap(PieceMap(count: 3500, pieceLength: 2_097_152,
            bitfield: String(repeating: "bce08012ff", count: 88), totalSpan: 7_340_031_003))
        let peers = try JSONDecoder().decode([PeerTransfer].self, from: Data(#"[{"ip":"2001:db8:1234:1234:abcd:0123:ef12:1234","port":"6881","state":"connected","peerClientName":"A long peer client identification string","transport":"utp","downloadSpeed":"1048576","uploadSpeed":"32768","progress":"0.73","incoming":"true","encryption":"rc4","sources":["dht","pex"]}]"#.utf8))
        var task = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"preview","status":"active","totalLength":"7340031003","completedLength":"1234567","bittorrent":{}}"#.utf8)).toTask()
        task.protocolKind = .bitTorrent; task.status = .active
        task.downloadSpeed = 12_000_000; task.uploadSpeed = 1_240_000; task.connections = 8
        let servers = [ServerTransfer(id: "1:0", fileIndex: 1, address: "downloads.long-example-hostname.example.org:443", transport: "HTTPS", downloadSpeed: 1234567)]
        for appearance: NSAppearance.Name in [.aqua, .darkAqua, .accessibilityHighContrastAqua] {
            let root = ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TransferRateSummary(task: task, uploaded: 4_123_456)
                    PieceMapView(map: map)
                    PeerTransfersView(peers: peers)
                    ServerTransfersView(servers: servers)
                }.padding(12)
            }
            try await verifyLayout(root, contract: .transfer, size: NSSize(width: 300, height: 850), appearance: appearance)
            try await verifyLayout(root, contract: .transfer, size: NSSize(width: 300, height: 650), appearance: appearance, scrollToBottom: true)
        }
    }

    @MainActor
    func testCompactStatusBarAndFlatListLayout() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        store.selectedDestination = .all
        store.tasks = [
            task("chrome-paused", "Example disk image.iso", .paused, .http, 0.45),
            task("chrome-active", "Download archive.zip", .active, .http, 0.2),
            task("chrome-complete", "Finished download.dmg", .completed, .http, 1),
            task("chrome-waiting", "等待开始 — Video lecture recording.mov", .waiting, .http, 0),
            task("chrome-metadata", "获取种子文件列表 — Example collection", .active, .magnet, 0),
            task("chrome-unknown", "Unknown-size server response.bin", .active, .http, 0.2),
            task("chrome-failed", "这是用于检查窄窗口的很长的文件名称 — Research archive.tar.gz", .failed, .http, 0.1)
        ]
        store.tasks[4].isFetchingMetadata = true
        store.tasks[4].totalLength = 0
        store.tasks[5].totalLength = 0
        store.tasks[6].errorMessage = "The connection was interrupted. 可以检查网络后继续此任务。"
        let bar = NSHostingController(rootView: DownloadStatusBar().environment(store))
        for width: CGFloat in [280, 900] {
            let size = bar.sizeThatFits(in: NSSize(width: width, height: 100))
            XCTAssertGreaterThanOrEqual(size.height, 28)
            XCTAssertLessThanOrEqual(size.height, 32, "Window status must remain a single compact row")
            XCTAssertLessThanOrEqual(size.width, width, "Use the compact summary when details narrow the list")
        }
        for appearance: NSAppearance.Name in [.aqua, .darkAqua, .accessibilityHighContrastAqua] {
            store.selectedTaskID = nil
            try await verifyLayout(DownloadConsoleView(inputCoordinator: store.inputCoordinator).environment(store),
                             contract: .mainWindow, size: NSSize(width: 1100, height: 600),
                             appearance: appearance)
            store.selectedTaskID = store.tasks[0].id
            try await verifyLayout(DownloadConsoleView(inputCoordinator: store.inputCoordinator).environment(store),
                             contract: .mainWindow, size: NSSize(width: 900, height: 600),
                             appearance: appearance)
        }
        store.runtime.phase = .running(pid: 1)
        let presentation = TaskDetailsPresentation()
        for (appearance, width) in [
            (NSAppearance.Name.aqua, CGFloat(840)),
            (.darkAqua, CGFloat(840)),
            (.aqua, CGFloat(579)),
            (.accessibilityHighContrastAqua, CGFloat(579))
        ] {
            store.selectedTaskID = store.tasks[0].id
            try await verifyLayout(VStack(spacing: 0) {
                DownloadCanvas(destination: .all, onPaste: {}, onOpenFile: {}, showDetails: {}, toggleDetails: {})
                DownloadStatusBar()
            }.environment(store).environmentObject(presentation),
                contract: .downloadList, size: NSSize(width: width, height: 520),
                appearance: appearance)
        }
        store.tasks = [
            task("seeding", "Linux distribution", .active, .bitTorrent, 1),
            task("torrent", "Sample footage collection", .active, .bitTorrent, 0.55),
            task("checking", "Archive integrity check.zip", .active, .http, 0.55),
            task("media", "Example lecture recording.mp4", .active, .http, 0),
            task("finalizing", "Another video recording.mp4", .active, .http, 0),
            task("offline", "Saved download.zip", .paused, .http, 0.35),
            task("scheduled", "Scheduled archive.zip", .paused, .http, 0)
        ]
        store.tasks[0].isSharing = true
        store.tasks[0].downloadSpeed = 0
        store.tasks[0].uploadSpeed = 1_600_000
        store.tasks[1].uploadSpeed = 560_000
        store.tasks[2].isChecking = true
        store.tasks[2].downloadSpeed = 0
        store.tasks[3].media = MediaTaskProgress(state: "downloading", duration: "120000", completedDuration: "30000", downloadedLength: "100000000")
        store.tasks[4].media = MediaTaskProgress(state: "finalizing", completedDuration: "120000", downloadedLength: "400000000")
        store.tasks[4].downloadSpeed = 0
        store.tasks[5].isAvailableInEngine = false
        store.tasks[6].scheduledStart = Date().addingTimeInterval(3600)
        store.selectedTaskID = nil
        try await verifyLayout(VStack(spacing: 0) {
            DownloadCanvas(destination: .all, onPaste: {}, onOpenFile: {}, showDetails: {}, toggleDetails: {})
            DownloadStatusBar()
        }.environment(store).environmentObject(presentation),
            contract: .downloadList, size: NSSize(width: 579, height: 520),
            appearance: .aqua)

    }

    @MainActor
    func testTaskDetailsLayoutKeepsHeaderAndActionsVisible() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        var file = task("details-layout", "macOS_27_Developer_Beta.dmg", .active, .http, 0.42)
        file.sourceURL = "https://developer.apple.com/downloads/example.dmg?token=private"
        file.addedAtIsFirstSeen = false
        for appearance: NSAppearance.Name in [.aqua, .darkAqua, .accessibilityHighContrastAqua] {
            try await verifyLayout(TaskInspectorView(task: file).environment(store),
                             contract: .details, size: NSSize(width: 600, height: 680),
                             appearance: appearance)
            var long = file
            long.name = String(repeating: "很长的任务名称 — Long download name ", count: 8)
            long.destination = "/tmp/" + String(repeating: "Long folder name/", count: 20)
            long.status = .failed
            long.errorMessage = String(repeating: "The server disconnected. 请检查网络后重试。 ", count: 20)
            try await verifyLayout(TaskInspectorView(task: long).environment(store),
                             contract: .details, size: NSSize(width: 520, height: 480),
                             appearance: appearance)
        }
        file.status = .paused
        file.protocolKind = .bitTorrent
        file.sourceURL = nil
        file.files = [DownloadFile(index: 1, path: "/tmp/Example/Archive.zip", length: 100, completedLength: 42, isSelected: true)]
        file.recentLogs = [String(repeating: "An example task event. ", count: 20)]
        for tab in InspectorTab.allCases {
            try await verifyLayout(TaskInspectorView(task: file, initialTab: tab).environment(store),
                             contract: .details, size: NSSize(width: 520, height: 480),
                             appearance: .aqua)
        }
        file.status = .active
        file.isFetchingMetadata = true
        try await verifyLayout(TaskInspectorView(task: file).environment(store),
                         contract: .details, size: NSSize(width: 520, height: 480),
                         appearance: .aqua)

    }

    @MainActor
    func testSidebarAndWindowStayStableWithSelectionAndDetailsPanelAtScreenEdges() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        store.selectedDestination = .all
        store.tasks = [task("edge-layout", "Example archive.zip", .paused, .http, 0.45)]
        let presentation = TaskDetailsPresentation()
        let host = NSHostingController(rootView: DownloadConsoleView(inputCoordinator: store.inputCoordinator, presentation: presentation)
            .environment(store))
        host.sizingOptions = [.minSize]
        host.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentViewController = host
        window.orderBack(nil)
        defer { window.close() }
        await NativeLayout.flush(host.view)
        XCTAssertEqual(host.sizeThatFits(in: .zero).width, 900, accuracy: 1,
                       "The window must enforce its full minimum width before any task is selected")
        let (navigation, sidebarItem) = try splitItem(.sidebar, in: host.view)
        let sidebar = sidebarItem.viewController.view
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame
        for width: CGFloat in [900, 1100, 1280] {
            for atRightEdge in [false, true] {
                for sidebarWidth: CGFloat in [240, 320] {
                    store.selectedTaskID = nil
                    await NativeLayout.flush(host.view)
                    window.setContentSize(NSSize(width: width, height: 600))
                    window.setFrameOrigin(NSPoint(x: atRightEdge ? screen.maxX - window.frame.width : screen.minX,
                                                  y: screen.maxY - window.frame.height))
                    navigation.splitView.setPosition(sidebarWidth, ofDividerAt: 0)
                    await NativeLayout.flush(host.view)
                    XCTAssertEqual(host.view.safeAreaRect.height, 600, accuracy: 1)
                    let frameBeforeDetails = window.frame
                    let frameEvents = WindowFrameObservation(window)
                    let sidebarBeforeDetails = sidebar.convert(sidebar.bounds, to: host.view)
                    store.selectedTaskID = store.tasks[0].id
                    await NativeLayout.flush(host.view)
                    XCTAssertFalse(presentation.isPresented, "Selecting a row must keep details closed")
                    presentation.present(store: store, moveSelection: { _ in })
                    XCTAssertEqual(presentation.panel?.alphaValue, 0, "Test panels remain invisible")
                    XCTAssertNil(window.attachedSheet, "Task details must not block the main window")
                    await NativeLayout.flush(host.view)
                    verifySidebarGeometry(sidebar, in: host.view, expected: sidebarBeforeDetails)
                    XCTAssertEqual(window.frame, frameBeforeDetails, "Opening Details must preserve the owner frame")
                    let panel = try XCTUnwrap(presentation.panel)
                    XCTAssertGreaterThanOrEqual(panel.contentView?.bounds.width ?? 0, 520)
                    XCTAssertGreaterThanOrEqual(panel.contentView?.bounds.height ?? 0, 480)
                    XCTAssertTrue(screen.insetBy(dx: -1, dy: -1).contains(panel.frame), "Panel \(panel.frame) must fit screen \(screen)")
                    presentation.dismiss(returnFocus: false)
                    XCTAssertNil(panel.contentViewController)
                    store.selectedTaskID = nil
                    await NativeLayout.flush(host.view)
                    XCTAssertEqual(window.frame, frameBeforeDetails, "Closing Details must preserve the owner frame")
                    verifySidebarGeometry(sidebar, in: host.view, expected: sidebarBeforeDetails)
                    XCTAssertTrue(frameEvents.changes.allSatisfy { $0 == frameBeforeDetails },
                                  "Details must never transiently move or resize its owner: \(frameEvents.changes)")
                    XCTAssertEqual(host.sizeThatFits(in: .zero).width, 900, accuracy: 1,
                                   "Closing Details must not lower the minimum width")
                }
            }
        }
    }

    @MainActor
    func testEngineVersionRefreshKeepsPickerSizeStable() async throws {
        let manager = LayoutEngineManager()
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true),
                                  engineInstallationManager: manager)
        defer { store.shutdown(); Task { await manager.resumeChecks() } }
        await store.prepareEngineOnLaunch()
        store.startEngineUpdateCheck()
        try await NativeLayout.wait(until: "engine check completes") { !store.isCheckingEngineUpdate }
        XCTAssertFalse(store.isCheckingEngineUpdate)
        let host = NSHostingController(rootView: EngineVersionPicker().environment(store).desktopControls().fixedSize())
        host.sizingOptions = []
        let window = LayoutPreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
                                         styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        defer { window.close() }
        for selection in [EngineVersion?.none, EngineVersion("3.8.2")] {
            store.selectedEngineVersion = selection
            await NativeLayout.flush(host.view)
            let proposal = NSSize(width: 500, height: 100)
            let before = host.sizeThatFits(in: proposal)
            let status = store.engineUpdateStatus
            await manager.suspendChecks()
            store.startEngineUpdateCheck()
            try await NativeLayout.wait(until: "engine check starts") { store.isCheckingEngineUpdate }
            await NativeLayout.flush(host.view)
            let during = host.sizeThatFits(in: proposal)
            XCTAssertEqual(during.width, before.width, accuracy: 0.5, "The loading indicator must keep the button's width")
            XCTAssertEqual(during.height, before.height, accuracy: 0.5, "Refreshing must not shrink the row")
            XCTAssertEqual(store.engineUpdateStatus, status)
            await manager.resumeChecks()
            try await NativeLayout.wait(until: "engine check completes") { !store.isCheckingEngineUpdate }
            XCTAssertFalse(store.isCheckingEngineUpdate)
            await NativeLayout.flush(host.view)
            let after = host.sizeThatFits(in: proposal)
            XCTAssertEqual(after.width, before.width, accuracy: 0.5)
            XCTAssertEqual(after.height, before.height, accuracy: 0.5)
        }
    }

    @MainActor
    func testSettingsPanesKeepNavigationAndScrollableContentInsideMinimumWindow() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        store.engineSettings.btTracker = (1...40).map { "https://tracker\($0).example.org/announce" }.joined(separator: "\n")
        store.runtime.lastLaunchArguments = ["--pause=true", "--example=" + String(repeating: "long-value-", count: 40)]
        store.runtime.lastError = String(repeating: "The engine could not connect. Check the network and retry. 连接失败，请检查网络后重试。", count: 5)
        let suite = "ChopChop-flat-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = AppUpdateCoordinator(build: AppBuild(version: "0.0.1-beta.1"), client: LayoutReleaseClient(), defaults: defaults)
        for appearance: NSAppearance.Name in [.aqua, .darkAqua, .accessibilityHighContrastAqua] {
            for pane in SettingsPane.allCases {
                let view = SettingsView(initialPane: pane).environment(store).environment(updates)
                try await verifyLayout(view, contract: .settings, size: NSSize(width: 860, height: 560),
                                       appearance: appearance, scrollToBottom: true)
            }
        }
    }

    private enum LayoutContract {
        case mainWindow, downloadList, details, transfer, settings
        var windowChrome: Bool { self == .mainWindow || self == .settings }
    }

    @MainActor
    private func verifyLayout<V: View>(_ view: V, contract: LayoutContract, size: NSSize, appearance: NSAppearance.Name,
                                      scrollToBottom: Bool = false) async throws {
        let fixture = NativeLayoutFixture(view.background(Color(nsColor: .windowBackgroundColor)), size: size,
                                          appearance: appearance, windowChrome: contract.windowChrome,
                                          settingsToolbar: contract == .settings)
        defer { fixture.close() }
        let controller = fixture.controller
        let window = fixture.window
        await NativeLayout.flush(controller.view)
        for atBottom in scrollToBottom ? [false, true] : [false] {
            if contract == .mainWindow {
                XCTAssertEqual(controller.view.bounds.width, size.width, accuracy: 1)
                XCTAssertEqual(controller.view.safeAreaRect.height, size.height, accuracy: 1)
                func verifySplitColumns(_ view: NSView) {
                    if view is NSSplitView {
                        // Inspect actual native column geometry with and without a selected task.
                        // Ignore narrow divider/hit targets that may extend for pointer interaction.
                        for column in view.subviews where column.frame.width > 40 {
                            XCTAssertGreaterThanOrEqual(column.frame.minX, view.bounds.minX - 1)
                            XCTAssertLessThanOrEqual(column.frame.maxX, view.bounds.maxX + 1,
                                                     "Every visible column must fit inside the native split view")
                        }
                    }
                    view.subviews.forEach(verifySplitColumns)
                }
                verifySplitColumns(controller.view)
                func toolbarItems(_ items: [NSToolbarItem]) -> [NSToolbarItem] {
                    items.flatMap { [$0] + toolbarItems(($0 as? NSToolbarItemGroup)?.subitems ?? []) }
                }
                let toolbar = try XCTUnwrap(window.toolbar)
                let items = toolbarItems(toolbar.items)
                XCTAssertFalse(items.contains { $0.itemIdentifier.rawValue.lowercased().contains("togglesidebar") },
                               "The navigation sidebar must have no collapse toolbar item: \(items.map { $0.itemIdentifier.rawValue })")
                let (_, sidebarItem) = try splitItem(.sidebar, in: controller.view)
                let sidebar = sidebarItem.viewController.view
                XCTAssertGreaterThanOrEqual(sidebar.bounds.width, 239)
                XCTAssertLessThanOrEqual(sidebar.bounds.width, 321)
                XCTAssertEqual(sidebar.bounds.height, controller.view.bounds.height, accuracy: 1, "The sidebar keeps its full height, including the toolbar safe area")
                let (navigation, _) = try splitItem(.sidebar, in: controller.view)
                XCTAssertEqual(navigation.splitViewItems.count, 2, "Selection must not add a third window column")
                let detail = try XCTUnwrap(navigation.splitViewItems.last?.viewController.view)
                func scrollViews(_ view: NSView) -> [NSScrollView] {
                    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                }
                let list = try XCTUnwrap(scrollViews(detail).first)
                let frame = list.convert(list.safeAreaRect, to: controller.view)
                XCTAssertEqual(frame.minX, sidebar.bounds.width + 1, accuracy: 1)
                XCTAssertEqual(frame.maxX, controller.view.bounds.maxX, accuracy: 1)
                XCTAssertEqual(size.height - frame.height, 29, accuracy: 1,
                               "The footer stays below the full list when selection changes")
                if contract == .mainWindow {
                    let table = try XCTUnwrap(list.documentView as? NSTableView)
                    XCTAssertEqual(table.numberOfRows, 7)
                    for index in 0..<table.numberOfRows {
                        let row = table.rect(ofRow: index)
                        XCTAssertGreaterThanOrEqual(row.height, 56, "Rows need breathing room around their two text lines")
                        XCTAssertLessThanOrEqual(row.height, 70,
                                                 "A normal task should remain a compact desktop row")
                        if index < 6 { XCTAssertLessThanOrEqual(row.maxY, list.contentView.bounds.height) }
                    }
                }
            }
            if contract == .downloadList {
                func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
                let table = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
                let scroll = try XCTUnwrap(table.enclosingScrollView)
                XCTAssertLessThanOrEqual(table.bounds.width, scroll.contentView.bounds.width + 1,
                                         "The list must fit the minimum content width without horizontal scrolling")
                let rows = (0..<table.numberOfRows).map { table.rect(ofRow: $0) }
                XCTAssertTrue(rows.allSatisfy { abs($0.height - rows[0].height) < 1 },
                              "Selection, long errors and unknown sizes must not change row height")
                let bars = descendants(table).compactMap { $0 as? NSProgressIndicator }
                XCTAssertEqual(bars.count, table.numberOfRows,
                               "Every task, including completed downloads and seeds, keeps its progress bar")
                let frames = bars.map { $0.convert($0.bounds, to: table) }
                let reference = try XCTUnwrap(frames.first)
                XCTAssertGreaterThan(reference.width, 100)
                for frame in frames {
                    XCTAssertEqual(frame.minX, reference.minX, accuracy: 1,
                                   "Task names and phases must not move the progress column")
                    XCTAssertEqual(frame.width, reference.width, accuracy: 1,
                                   "All progress tracks must have the same width")
                }
                XCTAssertNotNil(table.doubleAction)
            }
            if !contract.windowChrome {
                func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
                for field in descendants(controller.view).compactMap({ $0 as? NSTextField })
                    where field.isEditable && !field.isHiddenOrHasHiddenAncestor && field.bounds.width > 1 {
                    let rect = field.convert(field.bounds, to: controller.view)
                    XCTAssertGreaterThanOrEqual(rect.minX, 3, "Editable controls need focus-ring clearance in \(contract)")
                    XCTAssertLessThanOrEqual(rect.maxX, controller.view.bounds.maxX - 3,
                                            "Long fields must stay inside the content gutter in \(contract)")
                }
            }
            if contract == .details {
                XCTAssertEqual(controller.view.bounds.width, size.width, accuracy: 1)
                XCTAssertEqual(controller.view.bounds.height, size.height, accuracy: 1)
                func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
                let views = descendants(controller.view)
                let tabs = try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }.first)
                let tabFrame = tabs.convert(tabs.bounds, to: controller.view)
                XCTAssertEqual(tabFrame.minX, 24, accuracy: 1)
                XCTAssertEqual(tabFrame.maxX, size.width - 24, accuracy: 1)
                XCTAssertEqual(tabs.segmentCount, InspectorTab.allCases.count)
                let scroll = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first)
                XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.height, 160,
                                            "The pinned summary must leave usable space for tab content at minimum size")
                XCTAssertLessThanOrEqual(scroll.documentView?.bounds.width ?? 0, scroll.contentView.bounds.width + 1,
                                         "Long names, locations and errors must not cause horizontal overflow")
                for button in views.compactMap({ $0 as? NSButton }) where !button.isHiddenOrHasHiddenAncestor {
                    let bounds = button.convert(button.bounds, to: controller.view)
                    XCTAssertGreaterThanOrEqual(bounds.minX, 20, "Detail controls need a consistent outer gutter")
                    XCTAssertLessThanOrEqual(bounds.maxX, size.width - 20)
                }
            }
            if atBottom {
                func firstScrollView(in view: NSView) -> NSScrollView? {
                    if let scroll = view as? NSScrollView { return scroll }
                    return view.subviews.lazy.compactMap { firstScrollView(in: $0) }.first
                }
                func settingsScrollView(in view: NSView) -> NSScrollView? {
                    if let scroll = view as? NSScrollView,
                       scroll.convert(scroll.bounds, to: controller.view).minX >= 190,
                       scroll.bounds.width > 400 { return scroll }
                    return view.subviews.lazy.compactMap { settingsScrollView(in: $0) }.first
                }
                let scroll = try XCTUnwrap(contract == .settings
                                          ? settingsScrollView(in: controller.view) : firstScrollView(in: controller.view))
                let document = try XCTUnwrap(scroll.documentView)
                // Ask the native clip view for its actual end, including Form's safe-area insets.
                let end = scroll.contentView.constrainBoundsRect(NSRect(
                    origin: NSPoint(x: 0, y: document.bounds.maxY), size: scroll.contentView.bounds.size))
                scroll.contentView.scroll(to: end.origin)
                scroll.reflectScrolledClipView(scroll.contentView)
                await NativeLayout.flush(controller.view)
                XCTAssertEqual(scroll.contentView.bounds.origin.x, end.origin.x, accuracy: 1)
                XCTAssertEqual(scroll.contentView.bounds.origin.y, end.origin.y, accuracy: 1,
                               "The existing pane must actually scroll to its native lower bound")
            }
            if contract == .transfer {
                func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
                let scroll = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSScrollView }.first)
                XCTAssertLessThanOrEqual(scroll.documentView?.bounds.width ?? 0, scroll.contentView.bounds.width + 1,
                                         "Transfer content must wrap inside a narrow inspector")
                for field in descendants(controller.view).compactMap({ $0 as? NSTextField }) where field.isEditable {
                    let rect = field.convert(field.bounds, to: controller.view)
                    XCTAssertGreaterThanOrEqual(rect.minX, 3)
                    XCTAssertLessThanOrEqual(rect.maxX, size.width - 3)
                }
            }
            if contract == .settings {
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let (_, sidebar) = try splitItem(.sidebar, in: controller.view)
                let frame = try XCTUnwrap(window.contentView?.superview)
                let sidebarFrame = sidebar.viewController.view.convert(sidebar.viewController.view.bounds, to: frame)
                XCTAssertEqual(sidebarFrame.maxY, frame.bounds.maxY, accuracy: 1, "Every settings pane must keep a full-height native sidebar")
                XCTAssertEqual(sidebarFrame.width, 210, accuracy: 1)
                let fields = descendants(controller.view).compactMap { $0 as? NSSearchField }
                XCTAssertEqual(fields.count, 1, "Every category shares the single sidebar search field")
                let search = try XCTUnwrap(fields.first)
                XCTAssertLessThanOrEqual(search.convert(search.bounds, to: controller.view).maxX, 211)
                if contract == .settings {
                    XCTAssertEqual(controller.view.bounds.width, size.width, accuracy: 1)
                    XCTAssertEqual(controller.view.safeAreaRect.height, size.height, accuracy: 1)
                    let scrolls = descendants(controller.view).compactMap { $0 as? NSScrollView }
                    XCTAssertFalse(scrolls.isEmpty, "Flattened settings must remain vertically scrollable")
                    for scroll in scrolls {
                        XCTAssertLessThanOrEqual(scroll.documentView?.bounds.width ?? 0, scroll.contentView.bounds.width + 1,
                                                 "Long settings content must not require horizontal scrolling")
                    }
                }
            }
        }
    }

    @MainActor
    private func splitItem(_ behavior: NSSplitViewItem.Behavior, in view: NSView) throws -> (NSSplitViewController, NSSplitViewItem) {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for split in descendants(view).compactMap({ $0 as? NSSplitView }) {
            guard let controller = split.delegate as? NSSplitViewController else { continue }
            if let item = controller.splitViewItems.first(where: { $0.behavior == behavior }) {
                return (controller, item)
            }
        }
        XCTFail("The native split item is missing: \(behavior)")
        throw NSError(domain: "WindowLayoutTests", code: 1)
    }

    @MainActor
    private func verifySidebarGeometry(_ sidebar: NSView, in root: NSView, expected: NSRect,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let frame = sidebar.convert(sidebar.bounds, to: root)
        XCTAssertTrue(sidebar.window === root.window,
                      "The observed sidebar must remain attached, not be replaced during presentation", file: file, line: line)
        XCTAssertEqual(frame.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.minY, expected.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.width, expected.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.height, expected.height, accuracy: 1, file: file, line: line)
        XCTAssertFalse(sidebar.isHiddenOrHasHiddenAncestor, file: file, line: line)
        XCTAssertEqual(sidebar.visibleRect.intersection(sidebar.bounds).width, sidebar.bounds.width, accuracy: 1,
                       "The sidebar must not slide behind an ancestor's clipping bounds", file: file, line: line)
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

private struct LayoutReleaseClient: AppReleaseFetching {
    func latest(for current: AppVersion?, channel: AppUpdateChannel) async throws -> AppRelease? {
        AppRelease(version: AppVersion("0.0.2-beta.1")!, notes: "Improved downloads and recovery. 下载与恢复改进。")
    }
}

private actor LayoutEngineManager: EngineInstallationManaging {
    private var checksSuspended = false
    private var checks: [CheckedContinuation<Void, Never>] = []
    func suspendChecks() { checksSuspended = true }
    func resumeChecks() {
        checksSuspended = false
        checks.forEach { $0.resume() }
        checks.removeAll()
    }
    func localInstallation() async -> EngineInstallation? { nil }
    func latestRelease() async throws -> EngineRelease {
        if checksSuspended { await withCheckedContinuation { checks.append($0) } }
        return EngineDistribution.release(version: EngineVersion("3.8.6")!)
    }
    func recentReleases() async throws -> [EngineRelease] {
        (2...6).reversed().map { EngineDistribution.release(version: EngineVersion("3.8.\($0)")!) }
    }
    func activate(_ installation: EngineInstallation) async throws { throw CancellationError() }
    func backupRuntimeState() async throws -> EngineRuntimeBackup? { nil }
    func install(_ release: EngineRelease, progress: @escaping @Sendable (EngineInstallationProgress) async -> Void) async throws -> EngineInstallation {
        throw CancellationError()
    }
}
