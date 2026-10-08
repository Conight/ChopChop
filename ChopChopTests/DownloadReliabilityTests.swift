import Foundation
import SwiftData
import XCTest
@testable import ChopChop

final class DownloadReliabilityTests: XCTestCase {
    private func task(_ json: String = #"{"gid":"stable","status":"active","totalLength":"100","completedLength":"40"}"#) throws -> DownloadTask {
        try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(json.utf8)).toTask()
    }

    func testMediaProgressAndPhasesUseDurationRatherThanOutputBytes() throws {
        var value = try task(#"{"gid":"video","status":"active","totalLength":"0","completedLength":"0","media":{"state":"downloading","live":"false","duration":"60000","completedDuration":"20000","downloadedLength":"4194304"}}"#)
        XCTAssertEqual(try XCTUnwrap(value.progressState.fraction), 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(value.progressLabel, "33%")
        XCTAssertTrue(value.transferSizeLabel.contains("downloaded"))
        value.media?.state = "finalizing"
        XCTAssertNil(value.progressState.fraction)
        XCTAssertEqual(value.phaseLabel, "Finalizing file")
        value.status = .completed
        XCTAssertEqual(value.progressState.fraction, 1)
    }

    func testLiveUnknownSizeMetadataAndVerificationNeverInventAPercentage() throws {
        let unknown = try task(#"{"gid":"unknown","status":"active","completedLength":"4096"}"#)
        XCTAssertEqual(unknown.progressLabel, "—")
        XCTAssertTrue(unknown.transferSizeLabel.contains("size unknown"))
        let live = try task(#"{"gid":"live","status":"active","media":{"state":"recording","live":"true","duration":"60000","completedDuration":"20000","progress":"0.3"}}"#)
        XCTAssertNil(live.progressState.fraction)
        XCTAssertEqual(live.phaseLabel, "Recording")
        let metadata = try task(#"{"gid":"magnet","status":"active","files":[{"path":"[METADATA]example","length":"100"}]}"#)
        XCTAssertNil(metadata.progressState.fraction)
        XCTAssertEqual(metadata.phaseLabel, "Getting metadata")
        let checking = try task(#"{"gid":"check","status":"active","totalLength":"100","completedLength":"100","verifyIntegrityPending":"true"}"#)
        XCTAssertEqual(checking.phaseLabel, "Checking files")
        XCTAssertNil(checking.progressState.fraction)
    }

    func testNativeBitTorrentLifecycleMapsMetadataCheckingAndSelection() throws {
        let metadata = try task(#"{"gid":"native","status":"active","bittorrent":{"state":"downloadingMetadata"}}"#)
        XCTAssertEqual(metadata.phaseLabel, "Getting metadata")
        let checking = try task(#"{"gid":"native","status":"active","bittorrent":{"state":"recovering"}}"#)
        XCTAssertEqual(checking.phaseLabel, "Checking files")
        let selection = try task(#"{"gid":"native","status":"paused","bittorrent":{"state":"paused","fileSelectionState":"awaiting"}}"#)
        XCTAssertTrue(selection.requiresFileSelection)
        XCTAssertEqual(selection.phaseLabel, "Choose torrent files")
    }

    func testMediaErrorsAndNonFiniteProgressAreSafe() throws {
        let value = try task(#"{"gid":"media","status":"error","media":{"state":"error","error":"Failed https://example.com/video?token=private","errorCode":"authentication_required"}}"#)
        XCTAssertTrue(value.canEditAndAddAgain)
        XCTAssertFalse(value.errorMessage?.contains("private") ?? true)
        let invalid = MediaTaskProgress(state: "downloading", live: "false", progress: "NaN")
        XCTAssertNil(invalid.fraction)
    }

    func testFTPRejectedIncludingTorrentAndEncodedThunderWhileSFTPAccepted() throws {
        for url in ["ftp://example.com/file.zip", "ftp://example.com/file.torrent", "ftp://example.com/file.meta4"] {
            XCTAssertFalse(AddDownloadDraft(rawInput: url).isSubmittable)
            XCTAssertThrowsError(try AddDownloadDraft(rawInput: url).normalizedResources())
        }
        let encoded = Data("AAftp://example.com/file.zipZZ".utf8).base64EncodedString()
        XCTAssertThrowsError(try AddDownloadDraft(rawInput: "thunder://" + encoded).normalizedResources())
        let sftp = try task(#"{"gid":"sftp","uris":[{"uri":"sftp://example.com/file"}]}"#)
        XCTAssertEqual(sftp.protocolKind, .sftp)
        XCTAssertEqual(try AddDownloadDraft(rawInput: "sftp://example.com/file").engineOptions(fallbackDirectory: nil, autoOrganize: false)["pause"], "false")
    }

    func testCapabilitiesDistinguishUnknownFromUnsupported() throws {
        let capabilities = try JSONDecoder().decode(EngineCapabilities.self, from: Data(#"{"product":"aria2-next","version":"2.8.6","rpcVersion":"1","enabledFeatures":["SFTP","BitTorrent"],"mediaFeatures":["structured-errors"]}"#.utf8))
        XCTAssertTrue(capabilities.supports(.sftp))
        XCTAssertTrue(capabilities.supports(.magnet))
        XCTAssertFalse(capabilities.supports(.ed2k))
        XCTAssertTrue(EngineCapabilities(version: "older").supports(.ed2k))
    }

    @MainActor
    func testHistoryPersistsCompletedAndFailedTasksAndStableDates() throws {
        let settings = try PersistentSettingsStore(inMemory: true)
        let history = try settings.makeHistoryStore()
        var original = try task()
        original.addedAt = Date(timeIntervalSince1970: 1_000)
        original.addedAtIsFirstSeen = false
        original.status = .failed
        try history.save([original])
        let reopened = try settings.makeHistoryStore()
        let loaded = try reopened.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.addedAt, original.addedAt)
        XCTAssertEqual(loaded.first?.addedAtIsFirstSeen, false)
        XCTAssertEqual(loaded.first?.status, .failed)
        XCTAssertNil(loaded.first?.primaryControlAction)
        var completed = original
        completed.status = .completed
        completed.addedAt = Date()
        let merged = DownloadHistoryStore.merge([completed, completed], existing: loaded, hidden: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.addedAt, original.addedAt)
        try reopened.save(merged)
        XCTAssertEqual(try settings.makeHistoryStore().load().first?.status, .completed)
        XCTAssertEqual(DownloadHistoryStore.merge([], existing: merged, hidden: []).first?.status, .completed)
    }

    @MainActor
    func testOfflineClearingPersistsTombstoneWithoutTouchingFiles() throws {
        let settings = try PersistentSettingsStore(inMemory: true)
        let history = try settings.makeHistoryStore()
        let value = try task()
        try history.save([value])
        try history.hide([value.id])
        let reopened = try settings.makeHistoryStore()
        XCTAssertTrue(try reopened.load().isEmpty)
        XCTAssertEqual(reopened.deletedIDs, [value.id])
        XCTAssertTrue(DownloadHistoryStore.merge([value], existing: [], hidden: reopened.deletedIDs).isEmpty)
        try reopened.save([value])
        XCTAssertTrue(try reopened.load().isEmpty)
    }

    @MainActor
    func testHistoryStoresNoCredentialsOrSignedSources() throws {
        let schema = Schema([PersistentDownloadRecord.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let history = try DownloadHistoryStore(context: context)
        var value = try task()
        value.sourceURL = "https://user:password@example.com/file?signature=private"
        value.errorMessage = "HTTP failure https://example.com/file?token=secret\nAuthorization: Bearer sensitive\nCookie: session=hidden"
        value.recentLogs = ["Cookie: private"]
        value.trackers = [TrackerEntry(url: "https://tracker/announce?passkey=private", status: "", lastAnnounce: nil)]
        try history.save([value])
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<PersistentDownloadRecord>()).first)
        let json = try XCTUnwrap(String(data: XCTUnwrap(record.snapshot), encoding: .utf8))
        for secret in ["password", "signature", "private", "secret", "sensitive", "hidden", "passkey"] {
            XCTAssertFalse(json.contains(secret), secret)
        }
        XCTAssertNil(try history.load().first?.sourceURL)
        XCTAssertEqual(DownloadPrivacy.reusableSource("https://example.com/file.zip"), "https://example.com/file.zip")
    }

    @MainActor
    func testAddingHistorySchemaMigratesExistingSettingsOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.store")
        func createOldStore() throws {
            let schema = Schema([PersistentEngineConfiguration.self, PersistentAppConfiguration.self])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = ModelContext(container)
            let record = PersistentEngineConfiguration()
            var settings = EngineSettings()
            settings.rpcPort = 29099
            record.update(from: settings)
            context.insert(record)
            try context.save()
        }
        try createOldStore()
        let migrated = try PersistentSettingsStore(storeURL: url)
        XCTAssertEqual(try migrated.loadEngineSettings().rpcPort, 29099)
        let history = try migrated.makeHistoryStore()
        XCTAssertTrue(try history.load().isEmpty)
        try history.save([task()])
        XCTAssertEqual(try migrated.makeHistoryStore().load().count, 1)
    }
}
