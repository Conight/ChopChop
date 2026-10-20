import Foundation
import SwiftData
import XCTest
@testable import ChopChop

final class DownloadReliabilityTests: XCTestCase {
    func testCannotResumeProtectsAdoptedFilesEvenWithoutSuffixOptions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("existing.bin")
        let bytes = Data([9, 8, 7])
        try bytes.write(to: original)
        var value = try task(#"{"gid":"refused","status":"error","totalLength":"100","completedLength":"3","errorCode":"8","errorMessage":"The server ignores byte ranges"}"#)
        value.files = [DownloadFile(index: 1, path: original.path, length: 100, completedLength: 3, isSelected: true)]
        XCTAssertFalse(value.hasReportedTrashableFiles, "An old record without ownership data cannot authorize file deletion")
        XCTAssertTrue(DownloadTaskFileTrash.plan(for: value).primaryTargets.isEmpty)
        XCTAssertThrowsError(try DownloadTaskFileTrash.moveTaskFilesToTrash(value))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        for options in [[:], ["continue": "true"], ["continue": "true", "incomplete-suffix": ".part"]] {
            let failed = EngineDownloadFilePolicy.applying(options, to: value)
            XCTAssertFalse(failed.hasReportedTrashableFiles)
            XCTAssertTrue(DownloadTaskFileTrash.plan(for: failed).primaryTargets.isEmpty)
            try DownloadTaskFileTrash.moveTaskFilesToTrash(failed)
            XCTAssertEqual(try Data(contentsOf: original), bytes)
            var previous = value
            previous.files[0].storagePath = original.path + ".part"
            let refreshed = EngineDownloadFilePolicy.preservingOwnedPaths(failed, previous: previous)
            XCTAssertEqual(refreshed.files[0].storagePath, "")
            let restored = try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(refreshed))
            XCTAssertTrue(DownloadTaskFileTrash.plan(for: restored).primaryTargets.isEmpty)
        }
        XCTAssertTrue(try XCTUnwrap(value.failureExplanation).contains("Edit and Add Again"))
        XCTAssertEqual(value.errorMessage, "The server ignores byte ranges", "Keep the engine diagnosis for logs")
        XCTAssertEqual(DownloadRowPresentation(value).errorMessage, value.failureExplanation)
    }

    func testCannotResumeStillAllowsCleanupOfOurSeparatePartialFile() throws {
        var value = try task(#"{"gid":"owned","status":"error","totalLength":"100","completedLength":"40","errorCode":"8"}"#)
        value.files = [DownloadFile(index: 1, path: "/tmp/owned.bin", length: 100, completedLength: 40, isSelected: true)]
        let failed = EngineDownloadFilePolicy.applying(EngineDownloadFilePolicy.newTaskOptions, to: value)
        XCTAssertEqual(DownloadTaskFileTrash.plan(for: failed).primaryTargets.map(\.path), ["/tmp/owned.bin.part"])
        let plan = DownloadTaskFileTrash.plan(for: failed)
        XCTAssertFalse((plan.primaryTargets + plan.companionTargets).map(\.path).contains("/tmp/owned.bin"))
    }

    func testThunderBytePreservationAndNativeSubmission() throws {
        let bytes = Data("AAhttps://example.com/".utf8) + Data([0xd6, 0xd0]) + Data(".zipZZ".utf8)
        let link = "thunder://" + bytes.base64EncodedString()
        for raw in [link, link.replacingOccurrences(of: "=", with: ""), link.replacingOccurrences(of: "=", with: "%3D") + "/"] {
            let draft = AddDownloadDraft(rawInput: raw)
            XCTAssertEqual(try draft.normalizedResources(), ["https://example.com/%D6%D0.zip"])
            XCTAssertEqual(try draft.engineResources(), [raw])
            XCTAssertTrue(draft.containsHTTPSource)
            XCTAssertTrue(draft.supportsOutputOptions)
        }
        for uri in ["ftp://example.com/file", "file:///tmp/private", "thunder://nested"] {
            XCTAssertThrowsError(try AddDownloadDraft(rawInput: "thunder://" + Data("AA\(uri)ZZ".utf8).base64EncodedString()).normalizedResources())
        }
        let media = "thunder://" + Data("AAhttps://example.com/live.m3u8ZZ".utf8).base64EncodedString()
        XCTAssertTrue(AddDownloadDraft(rawInput: media).shouldInspectMedia)
        let torrent = "thunder://" + Data("AAhttps://example.com/file.torrentZZ".utf8).base64EncodedString()
        XCTAssertTrue(AddDownloadDraft(rawInput: torrent).shouldResolveBitTorrentFilesBeforeSubmit)
        XCTAssertEqual(TorrentFileTree.sourceName(torrent), "file.torrent")
        XCTAssertFalse(DownloadPrivacy.redact("Failed: \(link)").contains(bytes.base64EncodedString()))
        let ed2k = "ed2k://|file|file.bin|1|0123456789abcdef0123456789abcdef|/"
        let wrappedED2K = "thunder://" + Data("AA\(ed2k)ZZ".utf8).base64EncodedString()
        XCTAssertEqual(try AddDownloadDraft(rawInput: wrappedED2K).normalizedResources(), [ed2k])
        XCTAssertEqual(try AddDownloadDraft(rawInput: wrappedED2K).engineResources(), [wrappedED2K])
    }

    func testPartialFilesUseOwnedPathForRevealTrashAndHistoryUntilPublication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("file.zip")
        let partial = directory.appendingPathComponent("file.zip.part")
        try Data([9]).write(to: final) // An unrelated file must never become our Trash target.
        try Data([1, 2]).write(to: partial)
        var value = try task()
        value.destination = directory.path
        value.files = [DownloadFile(index: 1, path: final.path, length: 10, completedLength: 10, isSelected: true)]
        let mapped = EngineDownloadFilePolicy.applying(EngineDownloadFilePolicy.newTaskOptions, to: value)
        XCTAssertEqual(mapped.files[0].path, final.path)
        XCTAssertEqual(mapped.files[0].diskPath, partial.path)
        XCTAssertFalse(mapped.files[0].isCompleteOnDisk, "Full byte count does not mean the engine published its file")
        XCTAssertEqual(DownloadTaskFileTrash.plan(for: mapped).primaryTargets, [partial])
        XCTAssertEqual(DownloadFileLocation.revealURL(for: mapped), partial)
        XCTAssertEqual(try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(mapped)).files[0].diskPath, partial.path)
        value.status = .completed
        XCTAssertEqual(EngineDownloadFilePolicy.applying(EngineDownloadFilePolicy.newTaskOptions, to: value).files[0].diskPath, final.path)
        for protocolKind in [TaskProtocol.bitTorrent, .ed2k] {
            value.status = .paused; value.protocolKind = protocolKind
            XCTAssertNil(EngineDownloadFilePolicy.applying(EngineDownloadFilePolicy.newTaskOptions, to: value).files[0].storagePath)
        }
    }

    func testOutputPolicyDoesNotInventSuffixForExistingSessionsAndMedia() throws {
        var value = try task()
        value.files = [DownloadFile(path: "/tmp/old.bin", length: 10, completedLength: 2, isSelected: true)]
        XCTAssertNil(EngineDownloadFilePolicy.applying([:], to: value).files[0].storagePath)
        value.media = MediaTaskProgress(state: "downloading")
        XCTAssertNil(EngineDownloadFilePolicy.applying(EngineDownloadFilePolicy.newTaskOptions, to: value).files[0].storagePath)
        let oldJSON = #"{"id":"00000000-0000-0000-0000-000000000001","index":1,"path":"/tmp/file","length":10,"completedLength":2,"isSelected":true}"#
        XCTAssertEqual(try JSONDecoder().decode(DownloadFile.self, from: Data(oldJSON.utf8)).diskPath, "/tmp/file")
    }

    func testFailedPublicationKeepsThePreviouslyObservedPartialForCleanup() throws {
        var previous = try task()
        previous.files = [DownloadFile(index: 1, path: "/tmp/file.zip", length: 10, completedLength: 5,
                                       isSelected: true, storagePath: "/tmp/file.zip.part")]
        var failed = previous
        failed.status = .failed
        failed.errorCode = "14"
        failed.files[0].path = "/tmp/file (1).zip"
        failed.files[0].storagePath = "/tmp/file (1).zip.part"
        let safe = EngineDownloadFilePolicy.preservingOwnedPaths(failed, previous: previous)
        XCTAssertEqual(DownloadTaskFileTrash.plan(for: safe).primaryTargets.map(\.path), ["/tmp/file.zip.part"])
        let polled = EngineDownloadFilePolicy.applying(EngineDownloadFilePolicy.newTaskOptions, to: failed)
        let next = EngineDownloadFilePolicy.preservingOwnedPaths(polled, previous: safe)
        XCTAssertEqual(next.files[0].diskPath, "/tmp/file.zip.part", "Repeated polls must retain the original path")
        XCTAssertEqual(try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(next)).errorCode, "14")
    }

    func testUnobservedPublicationFailureDoesNotGuessATrashTarget() throws {
        var value = try task(#"{"gid":"rename-failed","status":"error","errorCode":"14","totalLength":"10","completedLength":"10"}"#)
        value.files = [DownloadFile(index: 1, path: "/tmp/file (1).zip", length: 10, completedLength: 10, isSelected: true)]
        let failed = EngineDownloadFilePolicy.applying(EngineDownloadFilePolicy.newTaskOptions, to: value)
        XCTAssertEqual(failed.errorCode, "14")
        XCTAssertTrue(DownloadTaskFileTrash.plan(for: failed).primaryTargets.isEmpty)
        XCTAssertThrowsError(try DownloadTaskFileTrash.moveTaskFilesToTrash(failed))
        XCTAssertFalse(try DownloadTaskFileTrash.allReportedFilesAreMissing(failed))
    }

    func testQueuedOutputHintDoesNotClaimAnExistingFileForDeletion() throws {
        var value = try task(#"{"gid":"not-started","status":"paused","totalLength":"0","completedLength":"0"}"#)
        value.files = [DownloadFile(index: 1, path: "/tmp/existing.zip", length: 0, completedLength: 0, isSelected: true)]
        let pending = EngineDownloadFilePolicy.applying(EngineDownloadFilePolicy.newTaskOptions, to: value)
        XCTAssertFalse(pending.hasReportedTrashableFiles)
        XCTAssertTrue(DownloadTaskFileTrash.plan(for: pending).primaryTargets.isEmpty)
        XCTAssertNoThrow(try DownloadTaskFileTrash.moveTaskFilesToTrash(pending))
    }

    @MainActor
    func testLegacyUnlimitedRetriesBecomeFiniteAcrossSettingsReload() throws {
        let store = try PersistentSettingsStore(inMemory: true)
        var settings = EngineSettings()
        XCTAssertEqual(settings.engineOptions(includeStartupOnly: true)["max-tries"], "3")
        settings.retryCount = 0
        try store.saveEngineSettings(settings)
        let loaded = try store.loadEngineSettings()
        XCTAssertEqual(loaded.retryCount, 3)
        XCTAssertEqual(loaded.hotReloadableEngineOptions()["max-tries"], "3")
        XCTAssertEqual(settings.engineOptions(includeStartupOnly: true)["max-tries"], "3")
        settings.retryCount = 7
        try store.saveEngineSettings(settings)
        XCTAssertEqual(try store.loadEngineSettings().retryCount, 7)
    }

    func testSavedUnlimitedTaskRetriesAreMigratedWithoutChangingPartialFilesOrCredentials() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let storage = EngineStorage(supportDirectory: support)
        let original = "https://example.com/file?max-tries=0\r\n gid=existing\r\n max-tries=0\r\n header=Authorization: Bearer fixture\r\nhttps://example.com/second\r\n max-tries=7\r\n"
        try original.write(to: storage.session, atomically: true, encoding: .utf8)
        let partial = support.appendingPathComponent("partial.bin")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: partial)
        let backup = try XCTUnwrap(EngineSessionMigration.boundRetryAttempts(supportDirectory: support, maximumAttempts: 3))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
        XCTAssertEqual(try String(contentsOf: storage.session, encoding: .utf8),
            original.replacingOccurrences(of: " max-tries=0\r\n", with: " max-tries=3\r\n"))
        XCTAssertEqual(try Data(contentsOf: partial), bytes)
        XCTAssertNil(try EngineSessionMigration.boundRetryAttempts(supportDirectory: support, maximumAttempts: 3))
    }

    func testTLSFailureReportsAResultWithTheEngineReason() throws {
        let value = try task(#"{"gid":"tls","status":"error","completedLength":"0","errorCode":"6","errorMessage":"TLS connect error: unexpected eof while reading"}"#)
        XCTAssertEqual(value.status, .failed)
        XCTAssertEqual(value.errorMessage, "TLS connect error: unexpected eof while reading")
        XCTAssertEqual(value.recentLogs, ["TLS connect error: unexpected eof while reading"])
        XCTAssertTrue(value.canEditAndAddAgain)
    }

    private func task(_ json: String = #"{"gid":"stable","status":"active","totalLength":"100","completedLength":"40"}"#) throws -> DownloadTask {
        try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(json.utf8)).toTask()
    }

    func testExplicitPausedAdditionAndProtocolSpecificControls() throws {
        var draft = AddDownloadDraft(rawInput: "https://example.com/file.zip")
        draft.startPaused = true
        XCTAssertEqual(try draft.engineOptions(fallbackDirectory: nil, autoOrganize: false)["pause"], "true")
        XCTAssertTrue(draft.containsHTTPSource); XCTAssertTrue(draft.supportsOutputOptions)
        draft.rawInput = "https://example.com/private.torrent"
        XCTAssertTrue(draft.containsHTTPSource, "Fetching remote torrent metadata can require HTTP authentication")
        draft.rawInput = "sftp://example.com/file.zip"
        XCTAssertFalse(draft.containsHTTPSource); XCTAssertTrue(draft.supportsOutputOptions)
        draft.rawInput = "magnet:?xt=urn:btih:BF650E61509ABA5376CB3946305B2B5270A68B17"
        XCTAssertFalse(draft.containsHTTPSource); XCTAssertFalse(draft.supportsOutputOptions)
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
        let checking = try task(#"{"gid":"native","status":"active","bittorrent":{"mode":"multi","state":"recovering"}}"#)
        XCTAssertEqual(checking.phaseLabel, "Checking files")
        let selection = try task(#"{"gid":"native","status":"paused","bittorrent":{"state":"paused","fileSelectionState":"awaiting"}}"#)
        XCTAssertTrue(selection.requiresFileSelection)
        XCTAssertEqual(selection.phaseLabel, "Choose torrent files")
    }

    func testV3NamedZeroBytePlaceholderIsNotAResolvedTorrentInAnyPhase() throws {
        for state in ["adding", "queued", "checking", "paused", "downloadingMetadata"] {
            let data = Data(#"{"gid":"native","status":"active","totalLength":"0","bittorrent":{"state":"\#(state)","fileSelectionState":"none","info":{"name":"Example"}},"files":[{"index":"1","path":"/tmp/Example","length":"0","selected":"true"}]}"#.utf8)
            let snapshot = try JSONDecoder().decode(Aria2TaskDTO.self, from: data).toSnapshot()
            XCTAssertTrue(snapshot.task.isFetchingMetadata, state)
            XCTAssertNil(snapshot.task.progressState.fraction, state)
            XCTAssertFalse(TorrentFileTree.isResolved(snapshot, source: "magnet:?xt=urn:btih:abc&dn=Example", followed: false), state)
        }
    }

    func testV3ResolvedEmptyFileRemainsSelectable() throws {
        for mode in ["single", "multi"] {
            let data = Data(#"{"gid":"native","status":"paused","totalLength":"0","bittorrent":{"mode":"\#(mode)","state":"paused","fileSelectionState":"none","info":{"name":"Empty"}},"files":[{"index":"1","path":"/tmp/empty.txt","length":"0","selected":"true"}]}"#.utf8)
            let snapshot = try JSONDecoder().decode(Aria2TaskDTO.self, from: data).toSnapshot()
            XCTAssertFalse(snapshot.task.isFetchingMetadata)
            XCTAssertTrue(TorrentFileTree.isResolved(snapshot, source: "magnet:?xt=urn:btih:abc", followed: false))
            XCTAssertEqual(TorrentFileTree.contentFiles(snapshot.task.files).count, 1)
        }
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

    func testCapabilitiesOnlyEnableAdvertisedFeatures() throws {
        let capabilities = try JSONDecoder().decode(EngineCapabilities.self, from: Data(#"{"product":"aria2-next","version":"3.8.6","rpcVersion":"1","enabledFeatures":["SFTP","BitTorrent"],"mediaFeatures":["structured-errors"]}"#.utf8))
        XCTAssertTrue(capabilities.supports(.sftp))
        XCTAssertTrue(capabilities.supports(.magnet))
        XCTAssertFalse(capabilities.supports(.ed2k))
        XCTAssertFalse(EngineCapabilities(version: "3.8.6").supports(.ed2k))
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
