import AppKit
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import ChopChop

final class DownloadImportTests: XCTestCase {
    func testMixedImportsKeepOrderAndSeparateTorrentReview() async throws {
        let directory = try temporaryDirectory()
        let torrent = directory.appendingPathComponent("a file.torrent")
        let metalink = directory.appendingPathComponent("download.meta4")
        try Data("torrent bytes".utf8).write(to: torrent)
        try Data("metalink bytes".utf8).write(to: metalink)
        let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        let requests = await DownloadImportReader.prepare([
            .text("https://example.com/one\nhttps://example.com/two\nhttps://example.com/one"),
            .url(torrent), .url(URL(string: magnet)!), .url(metalink), .text("sftp://example.com/three")
        ], preferences: AppPreferences())
        XCTAssertEqual(requests.map(\.resources), [["https://example.com/one", "https://example.com/two"],
                                                  [torrent.absoluteString], [magnet], [metalink.absoluteString], ["sftp://example.com/three"]])
        XCTAssertEqual(requests[1].documents[torrent.absoluteString]?.kind, .torrent)
        XCTAssertEqual(requests[3].documents[metalink.absoluteString]?.kind, .metalink)
        try FileManager.default.removeItem(at: torrent)
        XCTAssertEqual(requests[1].documents[torrent.absoluteString]?.data, Data("torrent bytes".utf8))
        XCTAssertTrue(requests.allSatisfy { $0.issues.isEmpty })
    }

    func testUnsupportedAndDisabledInputsKeepValidLinksAndExplainInPlace() async throws {
        var preferences = AppPreferences()
        preferences.handleMagnetLinks = false
        preferences.handleED2KLinks = false
        preferences.handleTorrentFiles = false
        preferences.handleMetalinkFiles = false
        let requests = await DownloadImportReader.prepare([
            .text("https://example.com/valid\nmagnet:?xt=urn:btih:abcd\ned2k://|file|demo|1|abcd|/\nftp://example.com/file\nhttps://example.com/x.torrent\nhttps://example.com/x.meta4\nnot a URL")
        ], preferences: preferences)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.resources, ["https://example.com/valid"])
        XCTAssertTrue(requests[0].issues.contains { $0.contains("Settings → Protocols") })
        XCTAssertFalse(requests[0].issues.isEmpty)
    }

    func testBadFilesAndExcessiveInputAreBoundedWithoutDroppingFeedback() async throws {
        let directory = try temporaryDirectory()
        let empty = directory.appendingPathComponent("empty.torrent")
        let oversized = directory.appendingPathComponent("large.meta4")
        let unknown = directory.appendingPathComponent("file.app")
        try Data().write(to: empty)
        try Data(repeating: 0, count: DownloadImportReader.maximumDocumentBytes + 1).write(to: oversized)
        try Data([1]).write(to: unknown)
        let rejected = await DownloadImportReader.prepare([.url(empty), .url(oversized), .url(unknown)], preferences: AppPreferences())
        XCTAssertTrue(rejected[0].resources.isEmpty)
        XCTAssertTrue(rejected[0].issues.contains { $0.contains("16 MB") })
        let many = (0..<101).map { DownloadImportInput.text("https://example.com/\($0)") }
        let bounded = await DownloadImportReader.prepare(many, preferences: AppPreferences())
        XCTAssertEqual(bounded.flatMap(\.resources).count, 100)
        XCTAssertTrue(bounded[0].issues.contains { $0.contains("first 100") })
    }

    @MainActor
    func testItemProvidersFeedTheSameFileAndLinkParser() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("provider.torrent")
        try Data([1, 2, 3]).write(to: file)
        let providers = [NSItemProvider(object: file as NSURL), NSItemProvider(object: "https://example.com/file" as NSString)]
        let inputs = await DownloadInputCoordinator.droppedInputs(providers)
        let requests = await DownloadImportReader.prepare(inputs, preferences: AppPreferences())
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].documents[file.absoluteString]?.data, Data([1, 2, 3]))
        XCTAssertEqual(requests[1].resources, ["https://example.com/file"])
    }

    @MainActor
    func testSheetOwnershipPreservesDraftAndQueuesWhileEditing() throws {
        let coordinator = DownloadInputCoordinator()
        let firstWindow = UUID(), secondWindow = UUID()
        let request = DownloadImportRequest(resources: ["https://example.com/imported"])
        XCTAssertTrue(coordinator.claimManualSheet(owner: firstWindow))
        coordinator.enqueue([request, request])
        var original = AddDownloadDraft(rawInput: "https://example.com/manual")
        original.authorization = "Bearer not-persisted"
        XCTAssertNil(coordinator.claimImport(owner: secondWindow, preserving: original))
        XCTAssertNil(coordinator.finish(owner: secondWindow))
        XCTAssertEqual(coordinator.pending.count, 1)
        XCTAssertNil(coordinator.finish(owner: firstWindow))
        XCTAssertEqual(coordinator.claimImport(owner: secondWindow, preserving: original)?.resources, request.resources)
        coordinator.enqueue([request])
        XCTAssertTrue(coordinator.pending.isEmpty)
        XCTAssertFalse(coordinator.claimManualSheet(owner: firstWindow))
        XCTAssertEqual(coordinator.finish(owner: secondWindow), original)
        XCTAssertNil(coordinator.owner)
    }

    @MainActor
    func testManualRequestSurvivesNoWindowAndTakesPrecedenceOverImports() {
        let coordinator = DownloadInputCoordinator()
        coordinator.requestManualSheet()
        coordinator.enqueue([.init(resources: ["https://example.com/queued"])])
        let owner = UUID()
        XCTAssertNil(coordinator.claimImport(owner: owner, preserving: AddDownloadDraft()))
        XCTAssertTrue(coordinator.hasManualRequest)
        XCTAssertTrue(coordinator.claimManualSheet(owner: owner))
        XCTAssertFalse(coordinator.hasManualRequest)
        coordinator.requestManualSheet() // An already open sheet handles repeated requests.
        XCTAssertFalse(coordinator.hasManualRequest)
        _ = coordinator.finish(owner: owner)
        XCTAssertNotNil(coordinator.claimImport(owner: owner, preserving: AddDownloadDraft()))
    }

    @MainActor
    func testColdLaunchQueuesURLsWithoutSubmittingOrOverwritingTheDraft() async throws {
        let persistence = try PersistentSettingsStore(inMemory: true)
        let store = DownloadStore(settingsStore: persistence)
        defer { store.shutdown() }
        store.addDraft.rawInput = "https://example.com/manual"
        let delegate = ChopChopAppDelegate()
        delegate.application(NSApplication.shared, open: [URL(string: "magnet:?xt=urn:btih:abcd")!])
        delegate.configureMenuBar(store: store)
        for _ in 0..<100 where store.inputCoordinator.pending.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.inputCoordinator.pending.count, 1)
        XCTAssertFalse(store.beginImportedDownload(owner: UUID())) // Engine setup has not finished.
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(store.addDraft.rawInput, "https://example.com/manual")
        let owner = UUID()
        XCTAssertTrue(store.inputCoordinator.claimManualSheet(owner: owner))
        let failed = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"error","status":"error","uris":[{"uri":"https://example.com/retry"}]}"#.utf8)).toTask()
        store.editAndAddAgain(failed)
        XCTAssertEqual(store.addDraft.rawInput, "https://example.com/manual")
        store.finishDownloadPanel(owner: owner)
    }

    func testAppRegistersDownloadSchemesAndDocumentTypesWithoutClaimingHTTP() throws {
        let bundle = Bundle(for: DownloadStore.self)
        let info = try XCTUnwrap(bundle.infoDictionary)
        let urlTypes = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        XCTAssertEqual(urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.sorted(), ["ed2k", "magnet"])
        let documents = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertEqual(documents.count, 2)
        XCTAssertTrue(documents.allSatisfy { $0["LSHandlerRank"] as? String == "Alternate" })
        let declarations = try XCTUnwrap(info["UTImportedTypeDeclarations"] as? [[String: Any]])
        let extensions = declarations.flatMap { ($0["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String] ?? [] }
        XCTAssertEqual(Set(extensions), ["torrent", "metalink", "meta4"])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

@MainActor
final class DownloadNotificationTests: XCTestCase {
    private func task(_ id: String, status: String = "active") throws -> DownloadTask {
        try JSONDecoder().decode(Aria2TaskDTO.self, from: Data("{\"gid\":\"\(id)\",\"status\":\"\(status)\"}".utf8)).toTask()
    }

    func testNotificationPreferenceDefaultsOffAndPersists() throws {
        let persistence = try PersistentSettingsStore(inMemory: true)
        var preferences = try persistence.loadAppPreferences()
        XCTAssertFalse(preferences.notifyOnDownloadCompletion)
        preferences.notifyOnDownloadCompletion = true
        try persistence.saveAppPreferences(preferences)
        XCTAssertTrue(try persistence.loadAppPreferences().notifyOnDownloadCompletion)
    }

    func testCompletionConsumptionAndPreferenceSurviveDiskReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.store")
        func saveBeforeExit() throws {
            let persistence = try PersistentSettingsStore(storeURL: url)
            var preferences = try persistence.loadAppPreferences()
            preferences.notifyOnDownloadCompletion = true
            try persistence.saveAppPreferences(preferences)
            let history = try persistence.makeHistoryStore()
            try history.save([task("persisted", status: "complete")])
            try history.markCompletionsObserved(["persisted"])
        }
        try saveBeforeExit()
        let reopened = try PersistentSettingsStore(storeURL: url)
        XCTAssertTrue(try reopened.loadAppPreferences().notifyOnDownloadCompletion)
        XCTAssertTrue(try reopened.makeHistoryStore().hasObservedCompletion("persisted"))
    }

    func testPermissionsAreOnlyRequestedByAnExplicitEnable() async throws {
        let delivery = TestNotificationDelivery()
        let coordinator = DownloadNotificationCoordinator(delivery: delivery, isForeground: { false })
        coordinator.setEnabled(false)
        XCTAssertEqual(delivery.permissionRequests, 0)
        delivery.authorization = .notDetermined
        delivery.grant = true
        let allowed = await coordinator.requestEnable()
        XCTAssertTrue(allowed)
        XCTAssertEqual(delivery.permissionRequests, 1)
        delivery.authorization = .denied
        let denied = await coordinator.requestEnable()
        XCTAssertFalse(denied)
        XCTAssertEqual(delivery.permissionRequests, 1)
        XCTAssertTrue(coordinator.status?.contains("System Settings") == true)
    }

    func testFirstSnapshotIsQuietAndTransitionsNotifyOnceAcrossRestart() async throws {
        let persistence = try PersistentSettingsStore(inMemory: true)
        let history = try persistence.makeHistoryStore()
        let old = try task("old", status: "complete"), active = try task("new")
        let completed = try task("new", status: "complete")
        let delivery = TestNotificationDelivery()
        let coordinator = DownloadNotificationCoordinator(delivery: delivery, isForeground: { false })
        coordinator.setEnabled(true)
        try history.save([old, active])
        await coordinator.observe([old, active], previous: [], history: history)
        XCTAssertTrue(delivery.deliveries.isEmpty)
        XCTAssertTrue(history.hasObservedCompletion("old"))
        try history.save([old, completed])
        await coordinator.observe([old, completed], previous: [old, active], history: history)
        await coordinator.observe([old, completed], previous: [old, active], history: history)
        XCTAssertEqual(delivery.deliveries, [[CompletedDownload(id: "new", name: completed.name)]])
        let reopened = try persistence.makeHistoryStore()
        let restarted = DownloadNotificationCoordinator(delivery: delivery, isForeground: { false })
        restarted.setEnabled(true)
        restarted.noteAdded(["new"])
        await restarted.observe([completed], previous: [active], history: reopened)
        XCTAssertEqual(delivery.deliveries.count, 1)
    }

    func testQuickNewDownloadsAreBatchedEvenBeforeTheFirstPoll() async throws {
        let history = try PersistentSettingsStore(inMemory: true).makeHistoryStore()
        let tasks = try [task("one", status: "complete"), task("two", status: "complete")]
        try history.save(tasks)
        let delivery = TestNotificationDelivery()
        let coordinator = DownloadNotificationCoordinator(delivery: delivery, isForeground: { false })
        coordinator.setEnabled(true)
        coordinator.noteAdded(tasks.map(\.id))
        await coordinator.observe(tasks, previous: [], history: history)
        XCTAssertEqual(delivery.deliveries.count, 1)
        XCTAssertEqual(delivery.deliveries[0].map(\.id), ["one", "two"])
    }

    func testDisabledForegroundAndDeniedCompletionsNeverBecomeDelayedAlerts() async throws {
        for mode in ["disabled", "foreground", "denied"] {
            let history = try PersistentSettingsStore(inMemory: true).makeHistoryStore()
            let value = try task(mode, status: "complete")
            try history.save([value])
            let delivery = TestNotificationDelivery()
            if mode == "denied" { delivery.authorization = .denied }
            var foreground = mode == "foreground"
            let coordinator = DownloadNotificationCoordinator(delivery: delivery, isForeground: { foreground })
            coordinator.setEnabled(mode != "disabled")
            coordinator.noteAdded([value.id])
            await coordinator.observe([value], previous: [], history: history)
            XCTAssertTrue(delivery.deliveries.isEmpty, mode)
            XCTAssertEqual(delivery.permissionRequests, 0)
            XCTAssertTrue(history.hasObservedCompletion(value.id))
            foreground = false
            delivery.authorization = .allowed
            coordinator.setEnabled(true)
            await coordinator.observe([value], previous: [], history: history)
            XCTAssertTrue(delivery.deliveries.isEmpty, mode)
        }
    }

    func testClickingNotificationSelectsTheTaskWithoutStartingIt() throws {
        let persistence = try PersistentSettingsStore(inMemory: true)
        let completed = try task("selected", status: "complete")
        try persistence.makeHistoryStore().save([completed])
        let delivery = TestNotificationDelivery()
        let coordinator = DownloadNotificationCoordinator(delivery: delivery)
        let store = DownloadStore(settingsStore: persistence, notificationCoordinator: coordinator)
        defer { store.shutdown() }
        store.selectedDestination = .failed
        store.searchQuery = "hidden"
        delivery.onOpenDownloads?(["deleted", "selected"])
        XCTAssertEqual(store.selectedTaskID, "selected")
        XCTAssertEqual(store.selectedDestination, .all)
        XCTAssertTrue(store.searchQuery.isEmpty)
        XCTAssertEqual(store.notificationNavigationRevision, 1)
        XCTAssertEqual(store.tasks.first?.status, .completed)
    }

    func testTorrentCompletionIncludesSeedingButMediaWaitsForFinalization() throws {
        let seeding = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"seed","status":"active","seeder":"true","bittorrent":{"state":"seeding"}}"#.utf8)).toTask()
        XCTAssertTrue(seeding.hasCompletedPayload)
        let metadata = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"metadata","status":"complete","followedBy":["content"]}"#.utf8)).toTask()
        XCTAssertFalse(metadata.hasCompletedPayload)
        let awaiting = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"awaiting","status":"paused","bittorrent":{"fileSelectionState":"awaiting"},"files":[{"length":"100","completedLength":"100","selected":"true"}]}"#.utf8)).toTask()
        XCTAssertFalse(awaiting.hasCompletedPayload)
        var video = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"video","status":"active","media":{"state":"finalizing","duration":"10000","completedDuration":"10000"}}"#.utf8)).toTask()
        XCTAssertFalse(video.hasCompletedPayload)
        video.status = .completed
        XCTAssertTrue(video.hasCompletedPayload)
    }
}

@MainActor
private final class TestNotificationDelivery: CompletionNotificationDelivering {
    var onOpenDownloads: (([String]) -> Void)?
    var authorization: CompletionNotificationPermission = .allowed
    var grant = false
    var permissionRequests = 0
    var deliveries: [[CompletedDownload]] = []
    func permission() async -> CompletionNotificationPermission { authorization }
    func requestPermission() async throws -> Bool { permissionRequests += 1; return grant }
    func deliver(_ downloads: [CompletedDownload]) async throws { deliveries.append(downloads) }
    func cancelPending() {}
}
