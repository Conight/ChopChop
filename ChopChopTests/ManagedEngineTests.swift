import Foundation
import CryptoKit
import Network
import XCTest
@testable import ChopChop

final class ManagedEngineTests: XCTestCase {
    func testEngineVersionRequiresV3BannerAndAnExactVersion() throws {
        let current = try XCTUnwrap(EngineVersion("3.8.6"))
        XCTAssertTrue(current.matchesVersionOutput("aria2-next version 3.8.6\nCopyright"))
        XCTAssertTrue(current.matchesVersionOutput("aria2-next version 3.8.6\r\nCopyright"))
        for output in ["", "aria2 version 3.8.6", "aria2-next version 3.8.60", "aria2-next version 3.8.6-beta",
                       "aria2-next version 2.8.6", "Aria2 Next version 3.8.6", "Error: aria2-next version 3.8.6", "Error\naria2-next version 3.8.6"] {
            XCTAssertFalse(current.matchesVersionOutput(output), output)
        }
    }

    func testAppDoesNotShipAnEngineOrDeclareAnInstalledVersion() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "Aria2NextVersion"))
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/aria2-next")
        XCTAssertFalse(FileManager.default.fileExists(atPath: executable.path))
    }

    @MainActor
    func testFreshAppRequiresDownloadBeforeAnyEngineCanStart() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true),
                                  engineInstallationManager: EngineInstallationManager(supportDirectory: support))
        defer { store.shutdown() }
        XCTAssertEqual(store.engineVersionDescription, "Unavailable")
        await store.prepareEngineOnLaunch()
        XCTAssertEqual(store.engineSetupState, .required)
        XCTAssertNil(store.installedEngine)
        XCTAssertEqual(store.runtime.phase, .stopped)
        XCTAssertFalse(store.isCheckingEngineUpdate)
    }

    @MainActor
    func testControllerRequiresAnExplicitlySelectedInstallation() async {
        let controller = Aria2NextEngineController()
        var settings = EngineSettings()
        settings.rpcToken = "test-token"
        do {
            _ = try await controller.start(settings: settings)
            XCTFail("Must not implicitly launch an embedded engine")
        } catch {
            guard case EngineError.installationRequired = error else {
                return XCTFail("Expected installationRequired, got \(error)")
            }
        }
        XCTAssertFalse(controller.hasLaunchedProcess)
    }

    func testProgressUsesMeasuredBytesAndDoesNotInventInstallationPercentages() throws {
        let unknown = EngineInstallationProgress(stage: .downloading, completedBytes: 512, totalBytes: -1)
        XCTAssertNil(unknown.fractionCompleted)
        XCTAssertNil(unknown.percentDescription)
        XCTAssertTrue(unknown.transferDescription.contains("downloaded"))
        let download = EngineInstallationProgress(stage: .downloading, completedBytes: 256, totalBytes: 1_024)
        XCTAssertEqual(download.fractionCompleted, 0.25)
        XCTAssertEqual(try JSONDecoder().decode(EngineInstallationProgress.self, from: JSONEncoder().encode(download)), download)
        XCTAssertEqual(EngineInstallationProgress(stage: .downloading, completedBytes: 2_000, totalBytes: 1_024).fractionCompleted, 1)
        XCTAssertNil(EngineInstallationProgress(stage: .verifying, completedBytes: 1_024, totalBytes: 1_024).fractionCompleted)
        XCTAssertFalse(EngineInstallationProgress(stage: .restarting).canCancel)
        XCTAssertTrue(download.canCancel)
    }

    func testLiveInstallationInApplicationSupportWithSpaces() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHOPCHOP_TEST_ENGINE_DOWNLOAD"] == "1", "Live engine download is opt-in")
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appendingPathComponent("ChopChop/Installation Tests/\(UUID().uuidString)")
        let support = try Aria2NextPaths.supportDirectory(applicationSupportBase: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = EngineInstallationManager(supportDirectory: support)
        let release = try await manager.latestRelease()
        let recorder = InstallationProgressRecorder()
        do {
            let installation = try await manager.install(release) { await recorder.append($0) }
            let events = await recorder.events
            XCTAssertTrue(events.contains { $0.stage == .downloading && $0.completedBytes > 0 && ($0.fractionCompleted ?? 1) < 1 },
                          "XPC must deliver real progress before the download finishes")
            XCTAssertTrue(events.contains { $0.stage == .verifying })
            XCTAssertTrue(events.contains { $0.stage == .preparing })
            XCTAssertEqual(events.last?.stage, .testing)
            try await manager.activate(installation)
            let restored = await manager.localInstallation()
            XCTAssertEqual(restored, installation)
        } catch {
            let error = error as NSError
            XCTFail("Installation failed: \(error.domain) \(error.code) \(error.userInfo)")
        }
    }

    func testVersionsCompareNumericallyAndRejectPrereleasesAndPaths() throws {
        XCTAssertLessThan(try XCTUnwrap(EngineVersion("v3.9.9")), try XCTUnwrap(EngineVersion("3.10.0")))
        XCTAssertEqual(EngineVersion("v3.8.6"), EngineVersion("3.8.6"))
        for invalid in ["3.0.0", "3.0.1", "3.0.2", "3.0.3", "3.0.4", "3.0.5", "3.0.6", "3.0.7", "2.8.6", "1.37.0", "0.0.0", "3.8", "3.8.6-beta", "../../3.8.6", "2.-8.6", "3.8.6.1", "2.８.6"] {
            XCTAssertNil(EngineVersion(invalid))
        }
    }

    func testPersistedVersionsCannotBypassTheMinimumVersion() throws {
        for json in [#"{"major":3,"minor":0,"patch":7}"#, #"{"major":3,"minor":0,"patch":0}"#,
                     #"{"major":2,"minor":8,"patch":6}"#, #"{"major":3,"minor":-1,"patch":0}"#,
                     #"{"major":3,"minor":0,"patch":-1}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(EngineVersion.self, from: Data(json.utf8)))
        }
        for version in ["3.0.8", "3.0.9", "4.0.0", "10.0.0"] {
            let parsed = try XCTUnwrap(EngineVersion(version))
            XCTAssertEqual(try JSONDecoder().decode(EngineVersion.self, from: JSONEncoder().encode(parsed)), parsed)
        }
    }

    func testRecentReleasesNeverOfferV2EvenWhenMixedWithV3AndFutureMajors() throws {
        let payloads = ["2.99.99", "3.0.0", "3.0.1", "3.0.2", "3.0.3", "3.0.4", "3.0.5", "3.0.6", "3.0.7", "3.0.8", "2.8.6", "4.0.0", "3.0.9"].map { releaseJSON(version: $0) }
        let data = Data(("[" + payloads.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]").utf8)
        XCTAssertEqual(try EngineDownload.parseRecentReleases(data).map(\.version.description), ["4.0.0", "3.0.9", "3.0.8"])
        let unsupported = Data(("[" + String(decoding: releaseJSON(version: "2.8.6"), as: UTF8.self) + "]").utf8)
        XCTAssertTrue(try EngineDownload.parseRecentReleases(unsupported).isEmpty)
    }

    func testReleaseParserSelectsOfficialStableArm64Asset() throws {
        let release = try EngineDownload.parseRelease(releaseJSON())
        XCTAssertEqual(release.version, EngineVersion("3.8.6"))
        XCTAssertTrue(release.downloadURL.absoluteString.hasSuffix("/aria2-next-3.8.6-macos-arm64"))
        for invalid in [releaseJSON(version: "3.0.7"), releaseJSON(version: "2.8.6"), releaseJSON(prerelease: true), releaseJSON(host: "evil.example"), releaseJSON(architecture: "x86_64")] {
            XCTAssertThrowsError(try EngineDownload.parseRelease(invalid))
        }
    }

    func testRecentReleasesKeepOnlyFiveNewestUniqueSupportedStableVersions() throws {
        let valid = ["3.8.1", "3.9.0", "3.8.4", "3.8.6", "3.8.5", "3.10.0", "3.8.6"]
            .map { releaseJSON(version: $0) }
        let invalid = [releaseJSON(version: "2.99.99"), releaseJSON(version: "3.8.5", prerelease: true),
                       releaseJSON(version: "4.0.0", host: "evil.example"),
                       releaseJSON(version: "5.0.0", architecture: "x86_64"),
                       releaseJSON(version: "6.0.0", draft: true),
                       releaseJSON(version: "02.8.6"), releaseJSON(version: "7.0.0-beta.1")]
        let json = Data(("[" + (invalid + valid).map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]").utf8)
        let releases = try EngineDownload.parseRecentReleases(json)
        XCTAssertEqual(releases.map(\.version.description), ["3.10.0", "3.9.0", "3.8.6", "3.8.5", "3.8.4"])
        XCTAssertEqual(try EngineDownload.parseRecentReleases(Data("[]".utf8)), [])
        XCTAssertThrowsError(try EngineDownload.parseRecentReleases(Data("{}".utf8)))
        XCTAssertEqual(try EngineDownload.parseRecentReleases(Data(("[" + String(decoding: releaseJSON(), as: UTF8.self) + "]").utf8)).count, 1)
    }

    func testDownloadVerificationRejectsTamperingWrongFilenameAndWrongArchitecture() throws {
        let release = try EngineDownload.parseRelease(releaseJSON())
        let data = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1] + Array(repeating: UInt8(0), count: 40))
        let checksum = Data("\(EngineDownload.sha256(data))  \(release.downloadURL.lastPathComponent)\n".utf8)
        XCTAssertNoThrow(try EngineDownload.verifyDownload(data, checksums: checksum, release: release))
        XCTAssertThrowsError(try EngineDownload.verifyDownload(data + Data([1]), checksums: checksum, release: release))
        XCTAssertThrowsError(try EngineDownload.verifyDownload(data, checksums: Data("\(EngineDownload.sha256(data))  other-file".utf8), release: release))
        let html = Data("<html>This is not an executable.</html>".utf8)
        let htmlChecksum = Data("\(EngineDownload.sha256(html))  \(release.downloadURL.lastPathComponent)".utf8)
        XCTAssertThrowsError(try EngineDownload.verifyDownload(html, checksums: htmlChecksum, release: release))
    }

    func testMissingAndCorruptManagedInstallationsRequireDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = EngineInstallationManager(supportDirectory: directory)
        let first = await manager.localInstallation()
        XCTAssertNil(first)
        try Data("broken manifest".utf8).write(to: directory.appendingPathComponent("installed-engine.json"))
        let second = await manager.localInstallation()
        XCTAssertNil(second)
    }

    func testInstallerRejectsInvalidVersionsAndForeignDirectoriesWithoutDownloading() async throws {
        let directory = FileManager.default.temporaryDirectory
        let bookmark = try directory.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        do {
            _ = try await EngineInstallerRequest().install(version: "../../3.8.6", directoryBookmark: bookmark)
            XCTFail("Invalid versions must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("supported Apple Silicon engine")) }
        do {
            _ = try await EngineInstallerRequest().install(version: "3.8.6", directoryBookmark: bookmark)
            XCTFail("Installer must only write into the app's Engines directory")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Invalid engine installation directory")) }
    }

    func testCancelledInstallerRequestCompletesWithoutWaitingForNetwork() async {
        let request = EngineInstallerRequest()
        let task = Task { try await request.install(version: "3.8.6", directoryBookmark: Data()) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must fail the request") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    /// Runs without any UI interaction. The helper is downloaded by the embedded installer
    /// and then executed and queried from the sandboxed test host.
    @MainActor
    func testAutomaticInstallAndRPCStartupInsideSandbox() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHOPCHOP_TEST_ENGINE_DOWNLOAD"] == "1", "Live engine download is opt-in")
        let support = try Aria2NextPaths.supportDirectory()
        let manager = EngineInstallationManager(supportDirectory: support)
        let release = try await manager.latestRelease()
        let installation = try await manager.install(release) { _ in }
        defer { try? FileManager.default.removeItem(at: installation.executableURL.deletingLastPathComponent()) }
        XCTAssertTrue(installation.executableURL.path.hasPrefix(support.appendingPathComponent("Engines").path + "/"))
        let staged = await manager.localInstallation()
        XCTAssertNotEqual(staged, installation, "Downloading must not activate a replacement")
        try await manager.activate(installation)
        let restored = await manager.localInstallation()
        XCTAssertEqual(restored, installation)
        let notificationSockets = LiveNotificationSockets()
        let controller = Aria2NextEngineController { port, token in
            let stream = Aria2WebSocketTransport(endpoint: URL(string: "ws://127.0.0.1:\(port)/jsonrpc")!, token: token,
                reconnectDelay: .milliseconds(50), makeSocket: { notificationSockets.make($0) })
            return Aria2RPCClient(endpoint: URL(string: "http://127.0.0.1:\(port)/jsonrpc")!, token: token, eventStream: stream)
        }
        controller.selectInstallation(installation)
        var settings = EngineSettings()
        settings.rpcToken = UUID().uuidString
        settings.btTrackerAutoSync = false
        // Larger than macOS argv: startup must load the complete list from our config.
        let startupTrackers = (0..<6_000).map { "http://127.0.0.1:9/\(String(repeating: "long-path-", count: 8))\($0)/announce" }
        settings.btTracker = startupTrackers.joined(separator: "\n")
        configureIsolatedPorts(&settings)
        defer { controller.terminateForAppExit() }
        let snapshot = try await controller.start(settings: settings)
        if case .running = snapshot.phase {} else { XCTFail("Downloaded engine did not start") }
        var connected = false
        for _ in 0..<50 {
            if (try? await controller.client().globalStat()) != nil { connected = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(connected, "Downloaded engine must answer authenticated RPC")
        let client = try controller.client()
        XCTAssertFalse(snapshot.lastLaunchArguments.contains { $0.hasPrefix("--bt-tracker=") })
        XCTAssertTrue(snapshot.lastLaunchArguments.contains { $0.hasPrefix("--conf-path=") })
        let globalOptions = try await client.getGlobalOption()
        XCTAssertEqual(globalOptions["bt-tracker"], startupTrackers.joined(separator: ","))
        try await client.changeGlobalOption(["bt-tracker": ""])
        let events = try XCTUnwrap(client.events, "Managed engines must receive WebSocket notifications")
        let ready = expectation(description: "WebSocket authenticated")
        let disconnected = expectation(description: "Notification connection lost")
        let reconnected = expectation(description: "Notification connection recovered")
        let recoveredNotification = expectation(description: "Native notifications work after reconnect")
        let started = expectation(description: "Native onDownloadStart push")
        started.expectedFulfillmentCount = 2
        let failed = expectation(description: "Native onDownloadError push")
        let completed = expectation(description: "Native onDownloadComplete push")
        let observation = LiveNotificationObservation()
        let eventTask = Task {
            for await event in events {
                observation.eventStore?.handleEngineEvent(event)
                switch event {
                case .connected:
                    observation.connectionCount += 1
                    if observation.connectionCount == 1 { ready.fulfill() }
                    if observation.connectionCount == 2 { reconnected.fulfill() }
                case .disconnected:
                    if !observation.sawDisconnect { observation.sawDisconnect = true; disconnected.fulfill() }
                case .download("aria2.onDownloadStart", let gid):
                    if observation.observeInitialTransfers { started.fulfill() }
                    if gid == observation.recoveryGID { recoveredNotification.fulfill() }
                case .download("aria2.onDownloadError", _) where observation.observeInitialTransfers: failed.fulfill()
                case .download("aria2.onDownloadComplete", _) where observation.observeInitialTransfers: completed.fulfill()
                default: break
                }
            }
        }
        defer { eventTask.cancel() }
        await client.startEvents()
        await fulfillment(of: [ready], timeout: 5)
        let unusedPort = try XCTUnwrap((49_200...49_300).first { !LocalHostPortProbe.isTCPPortInUse(port: $0) })
        var draft = AddDownloadDraft(rawInput: "http://127.0.0.1:\(unusedPort)/ws-event-fixture.bin")
        draft.startPaused = true
        let gid = try await client.addDownload(draft, fallbackDirectory: support.path)
        try await client.changeOption(gid: gid, options: ["max-tries": "1", "connect-timeout": "1", "timeout": "2"])
        try await client.resume(gid)
        await fulfillment(of: [failed], timeout: 10)
        let tasks = try await client.pollTasks()
        XCTAssertEqual(tasks.first { $0.id == gid }?.status, .failed)
        try await client.removeDownloadResult(gid)

        let bytes = Data(repeating: 0x5a, count: 64 * 1024)
        let listening = expectation(description: "Loopback HTTP fixture")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        listener.stateUpdateHandler = { state in if case .ready = state { listening.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .utility))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { request, _, _, _ in
                guard let request else { connection.cancel(); return }
                var response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8)
                if !request.starts(with: Data("HEAD ".utf8)) { response.append(bytes) }
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global(qos: .utility))
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(listener.port?.rawValue)
        var successful = AddDownloadDraft(rawInput: "http://127.0.0.1:\(port)/ws-success.bin")
        successful.startPaused = true
        let successGID = try await client.addDownload(successful, fallbackDirectory: support.path)
        try await client.resume(successGID)
        await fulfillment(of: [started, completed], timeout: 10)
        let finished = try await client.pollTasks().first { $0.id == successGID }
        XCTAssertEqual(finished?.status, .completed)
        XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent("ws-success.bin")), bytes)
        try await client.removeDownloadResult(successGID)
        observation.observeInitialTransfers = false

        // Break only the actual WS connection. HTTP commands, progress and file
        // downloads must remain available while notification reconnects fail.
        notificationSockets.disconnect()
        await fulfillment(of: [disconnected], timeout: 5)
        var duringOutage = AddDownloadDraft(rawInput: "http://127.0.0.1:\(port)/http-during-ws-outage.bin")
        duringOutage.startPaused = false
        let outageGID = try await client.addDownload(duringOutage, fallbackDirectory: support.path)
        var outageDownload: DownloadTask?
        for _ in 0..<100 {
            outageDownload = try await client.tellStatus(outageGID).task
            if outageDownload?.status == .completed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(outageDownload?.status, .completed)
        XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent("http-during-ws-outage.bin")), bytes)
        XCTAssertEqual(observation.connectionCount, 1, "The download must finish while WS is still disconnected")

        let originalTracker = "http://127.0.0.1:\(port)/original/announce"
        let extraTrackers = (0..<200).map { "http://127.0.0.1:\(port)/\(String(repeating: "tracker-path-", count: 6))\($0)/announce" }
        let trackerStore = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true), engineController: controller,
            trackerFetcher: LiveTrackerFixture(text: (extraTrackers + [originalTracker]).joined(separator: "\n")))
        trackerStore.engineSettings.btTrackerAutoSync = false
        observation.eventStore = trackerStore
        defer { trackerStore.shutdown() }
        var magnet = URLComponents(string: "magnet:")!
        magnet.queryItems = [URLQueryItem(name: "xt", value: "urn:btih:0123456789012345678901234567890123456789"),
                             URLQueryItem(name: "tr", value: originalTracker)]
        let torrentGID = try await client.addDownload(AddDownloadDraft(rawInput: magnet.string!), fallbackDirectory: support.path)
        for _ in 0..<100 {
            if (try? await client.torrentTrackerStatus(torrentGID).contains { $0.url == originalTracker }) == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        await trackerStore.syncBitTorrentTrackersManually()
        XCTAssertNil(trackerStore.trackerSyncIssue)
        XCTAssertEqual(trackerStore.trackerSyncFeedback, .succeeded)
        let applied = try await client.torrentTrackerStatus(torrentGID)
        XCTAssertEqual(Set(applied.map(\.url)), Set([originalTracker] + extraTrackers))
        XCTAssertEqual(applied.count, 201)
        XCTAssertEqual(applied.first { $0.url == originalTracker }?.tier, "0")
        let progressSamples = try await client.activeTransferProgress()
        let torrentSample = try XCTUnwrap(progressSamples.first { $0.gid == torrentGID })
        XCTAssertEqual(torrentSample.status, "active")
        XCTAssertNotNil(Int64(torrentSample.downloadSpeed))
        XCTAssertNotNil(Int64(torrentSample.completedLength))
        XCTAssertNotNil(Int(torrentSample.connections))
        try await client.forcePause(torrentGID)
        for _ in 0..<100 {
            if try await client.tellStatus(torrentGID).task.status == .paused { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await client.resume(torrentGID)
        var restoredTrackers: [BitTorrentTrackerStatus] = []
        for _ in 0..<100 {
            restoredTrackers = (try? await client.torrentTrackerStatus(torrentGID)) ?? []
            if restoredTrackers.count == 201 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(Set(restoredTrackers.map(\.url)), Set([originalTracker] + extraTrackers))
        XCTAssertEqual(observation.connectionCount, 1, "Tracker updates and pause/resume must work without WS")
        notificationSockets.allowConnections()
        await fulfillment(of: [reconnected], timeout: 5)
        await trackerStore.engineEventRefreshTask?.value
        XCTAssertTrue(trackerStore.engineEventsConnected)
        XCTAssertEqual(trackerStore.tasks.first { $0.id == outageGID }?.status, .completed,
            "Reconnect must reconcile downloads completed without a notification")
        try await client.forcePause(torrentGID)
        for _ in 0..<100 {
            if try await client.tellStatus(torrentGID).task.status == .paused { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        observation.recoveryGID = torrentGID
        try await client.resume(torrentGID)
        await fulfillment(of: [recoveredNotification], timeout: 5)
        XCTAssertTrue(notificationSockets.methods.allSatisfy { $0 == "aria2.getVersion" },
            "The WS connection must never carry application commands or queries")
        observation.eventStore = nil
        _ = try await controller.stop()
        await client.close()
    }

    /// Real BEP 9 metadata exchange and file selection, entirely over loopback.
    @MainActor
    func testV3MagnetConfirmationExportsGIDResumeAndDownloadsSelectedFile() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHOPCHOP_TEST_ENGINE_DOWNLOAD"] == "1", "Live engine download is opt-in")
        let support = try Aria2NextPaths.supportDirectory()
        let manager = EngineInstallationManager(supportDirectory: support)
        let version = "3.0.8"
        let release = EngineRelease(version: try XCTUnwrap(EngineVersion(version)),
            downloadURL: URL(string: "https://github.com/AnInsomniacy/aria2-next/releases/download/v\(version)/aria2-next-\(version)-macos-arm64")!,
            checksumURL: URL(string: "https://github.com/AnInsomniacy/aria2-next/releases/download/v\(version)/aria2-next-\(version)-checksums.sha256")!)
        let installation = try await manager.install(release) { _ in }
        defer { try? FileManager.default.removeItem(at: installation.executableURL.deletingLastPathComponent()) }
        let fixture = support.appendingPathComponent("MagnetConfirmation")
        let seedDirectory = fixture.appendingPathComponent("Seed")
        let seedContent = seedDirectory.appendingPathComponent("Fixture")
        try FileManager.default.createDirectory(at: seedContent, withIntermediateDirectories: true)
        let wanted = Data(repeating: 0x5a, count: 32_768)
        let skipped = Data(repeating: 0x78, count: 32_768)
        try wanted.write(to: seedContent.appendingPathComponent("wanted.bin"))
        try skipped.write(to: seedContent.appendingPathComponent("skipped.bin"))
        let payload = wanted + skipped
        var pieces = Data()
        for offset in stride(from: 0, to: payload.count, by: 16_384) {
            pieces.append(contentsOf: Insecure.SHA1.hash(data: payload[offset..<min(offset + 16_384, payload.count)]))
        }
        var info = Data("d5:filesld6:lengthi32768e4:pathl10:wanted.bineed6:lengthi32768e4:pathl11:skipped.bineee4:name7:Fixture12:piece lengthi16384e6:pieces\(pieces.count):".utf8)
        info.append(pieces); info.append(Data("e".utf8))
        let hash = Insecure.SHA1.hash(data: info).map { String(format: "%02x", $0) }.joined()
        var torrent = Data("d4:info".utf8); torrent.append(info); torrent.append(Data("e".utf8))
        let torrentURL = fixture.appendingPathComponent("Fixture.torrent")
        try torrent.write(to: torrentURL)

        let seedRPCPort = try XCTUnwrap((49_200...49_300).first { !LocalHostPortProbe.isTCPPortInUse(port: $0) })
        let seedPeerPort = try XCTUnwrap((49_301...49_400).first { !LocalHostPortProbe.isTCPPortInUse(port: $0) })
        let token = UUID().uuidString
        let seeder = Process()
        seeder.executableURL = installation.executableURL
        seeder.arguments = ["--no-conf=true", "--enable-rpc=true", "--rpc-listen-all=false",
            "--rpc-listen-port=\(seedRPCPort)", "--rpc-secret=\(token)", "--listen-port=\(seedPeerPort)",
            "--dir=\(seedDirectory.path)", "--state-dir=\(seedDirectory.appendingPathComponent("State").path)",
            "--enable-dht=false", "--bt-enable-lpd=false", "--enable-peer-exchange=false", "--bt-tracker=",
            "--ed2k-listen-port=0", "--ed2k-udp-listen-port=0", "--quiet=true", "--seed-ratio=0"]
        seeder.standardOutput = FileHandle.nullDevice; seeder.standardError = FileHandle.nullDevice
        try seeder.run()
        defer { if seeder.isRunning { seeder.terminate(); seeder.waitUntilExit() } }
        let seedClient = Aria2RPCClient(endpoint: URL(string: "http://127.0.0.1:\(seedRPCPort)/jsonrpc")!, token: token)
        var seedReady = false
        for _ in 0..<100 {
            if (try? await seedClient.getVersion()) != nil { seedReady = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(seedReady)
        let seedGID = try await seedClient.addDownload(AddDownloadDraft(rawInput: torrentURL.absoluteString), fallbackDirectory: seedDirectory.path)
        for _ in 0..<200 {
            if try await seedClient.tellStatus(seedGID).task.isSharing { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let seedStatus = try await seedClient.tellStatus(seedGID)
        XCTAssertTrue(seedStatus.task.isSharing, "Loopback seeder must be ready before metadata discovery")

        let controller = Aria2NextEngineController()
        controller.selectInstallation(installation)
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true), engineController: controller)
        defer { store.shutdown() }
        store.engineSettings.rpcToken = UUID().uuidString
        store.engineSettings.btTrackerAutoSync = false
        store.engineSettings.btTracker = ""
        configureIsolatedPorts(&store.engineSettings)
        _ = try await controller.start(settings: store.engineSettings)
        let client = try controller.client()
        for _ in 0..<100 {
            if (try? await client.getVersion()) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Start without peers so the named zero-byte placeholder survives several
        // store polls. A fast loopback metadata exchange can hide the readiness race.
        store.addDraft.rawInput = "magnet:?xt=urn:btih:\(hash)&dn=Fixture"
        store.addDraft.savePath = fixture.appendingPathComponent("Receive").path
        let discovery = Task { await store.prepareBitTorrentFileSelection() }
        defer { discovery.cancel() }
        for _ in 0..<100 where store.bitTorrentSelectionSession?.metadataTaskID == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let metadataGID = try XCTUnwrap(store.bitTorrentSelectionSession?.metadataTaskID)
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(100))
            let unresolved = try await client.tellStatus(metadataGID).task
            XCTAssertEqual(store.bitTorrentSelectionSession?.phase, .loading)
            XCTAssertTrue(store.bitTorrentSelectionSession?.files.isEmpty == true)
            XCTAssertEqual(unresolved.status, .active, "The app must not pause the metadata placeholder")
            XCTAssertTrue(unresolved.isFetchingMetadata)
            XCTAssertEqual(unresolved.totalLength, 0)
        }
        for _ in 0..<60 where store.bitTorrentSelectionSession?.discovery == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(store.bitTorrentSelectionSession?.discovery?.peers?.connected, 0)
        XCTAssertEqual(store.bitTorrentSelectionSession?.discovery?.trackers?.total, 0)
        store.bitTorrentSelectionSession?.startedAt = Date().addingTimeInterval(-90)
        store.retryBitTorrentDiscovery()
        XCTAssertTrue(store.isRetryingBitTorrentDiscovery)
        for _ in 0..<200 where store.isRetryingBitTorrentDiscovery {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(store.isRetryingBitTorrentDiscovery)
        XCTAssertEqual(store.bitTorrentSelectionSession?.phase, .loading)
        XCTAssertEqual(store.bitTorrentSelectionSession?.metadataTaskID, metadataGID)
        XCTAssertFalse(store.bitTorrentSelectionSession?.isDiscoverySlow(at: Date()) ?? true)
        let retriedTask = try await client.tellStatus(metadataGID).task
        XCTAssertTrue(retriedTask.isFetchingMetadata)
        XCTAssertEqual(retriedTask.completedLength, 0)
        let retryOptions = try await client.getOption(metadataGID)
        XCTAssertEqual(retryOptions["pause-metadata"], "true")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let peerSession = URLSession(configuration: configuration)
        defer { peerSession.invalidateAndCancel() }
        let request = try client.makeRequest(method: "aria2.addBtPeers", params: [metadataGID, ["127.0.0.1:\(seedPeerPort)"]])
        let (peerData, _) = try await peerSession.data(for: request)
        let peerResponse = try XCTUnwrap(JSONSerialization.jsonObject(with: peerData) as? [String: Any])
        XCTAssertEqual((peerResponse["result"] as? [String: Int])?["added"], 1)
        for _ in 0..<600 {
            if store.bitTorrentSelectionSession?.phase == .ready || store.bitTorrentSelectionSession?.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let selection = store.bitTorrentSelectionSession, selection.phase == .ready else {
            let issue = store.bitTorrentSelectionSession?.issue ?? "Metadata discovery timed out"
            await store.cancelBitTorrentFileSelection()
            await discovery.value
            XCTFail(issue)
            return
        }
        await discovery.value
        let gid = try XCTUnwrap(selection.downloadTaskID)
        XCTAssertEqual(gid, selection.metadataTaskID, "v3 magnets retain the same GID")
        XCTAssertEqual(selection.files.count, 2)
        XCTAssertEqual(selection.files.map(\.length), [Int64(wanted.count), Int64(skipped.count)])
        XCTAssertTrue(selection.files.allSatisfy { $0.completedLength == 0 })
        store.setBitTorrentFileIndexes([2], selected: false)
        let confirmed = await store.confirmBitTorrentFileSelection()
        XCTAssertTrue(confirmed, "Saving the GID-named metadata must not block starting the download")
        XCTAssertNil(store.bitTorrentSelectionSession)
        let directory = URL(fileURLWithPath: try XCTUnwrap(selection.torrentDirectory))
        let exported = try Data(contentsOf: directory.appendingPathComponent("Fixture.torrent"))
        XCTAssertEqual(try TorrentStorage.metainfo(from: exported, infoHash: hash, resume: false), exported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: EngineStorage(supportDirectory: support).state
            .appendingPathComponent("bittorrent/torrents/\(gid).fastresume").path))
        var downloaded: DownloadTask?
        for _ in 0..<600 {
            downloaded = try await client.tellStatus(gid).task
            if downloaded?.files.first?.completedLength == Int64(wanted.count) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let files = try XCTUnwrap(downloaded).files
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: files[0].path)), wanted)
        XCTAssertFalse(files[1].isSelected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[1].path), "Unselected payload must not be created")
        _ = try await controller.stop()
        await client.close(); await seedClient.close()
    }

    @MainActor
    func testManualUpgradeFrom308ThroughSandboxedStore() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHOPCHOP_TEST_ENGINE_DOWNLOAD"] == "1", "Live engine download is opt-in")
        let support = try Aria2NextPaths.supportDirectory()
        let manager = EngineInstallationManager(supportDirectory: support)
        let oldVersion = "3.0.8"
        let oldRelease = EngineRelease(version: try XCTUnwrap(EngineVersion(oldVersion)),
            downloadURL: URL(string: "https://github.com/AnInsomniacy/aria2-next/releases/download/v\(oldVersion)/aria2-next-\(oldVersion)-macos-arm64")!,
            checksumURL: URL(string: "https://github.com/AnInsomniacy/aria2-next/releases/download/v\(oldVersion)/aria2-next-\(oldVersion)-checksums.sha256")!)
        let old = try await manager.install(oldRelease) { _ in }
        try await manager.activate(old)
        let controller = Aria2NextEngineController()
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true),
                                  engineController: controller, engineInstallationManager: manager)
        store.engineSettings.btTrackerAutoSync = false
        configureIsolatedPorts(&store.engineSettings)
        defer { store.shutdown() }
        await store.prepareEngineOnLaunch()
        XCTAssertEqual(store.engineVersionDescription, oldVersion)
        guard case .running = store.runtime.phase else {
            XCTFail("Original engine must be running before update: \(store.runtime.lastError ?? "unknown error")")
            return
        }
        // Launch update checks are coordinated by the app, not by prepareEngineOnLaunch.
        store.startEngineUpdateCheck()
        await store.waitForEngineUpdateCheck()
        try XCTSkipIf(store.availableEngineUpdate == nil, "No stable release newer than the minimum supported engine is available yet")
        let target = try XCTUnwrap(store.availableEngineUpdate?.version, store.engineUpdateStatus)
        XCTAssertTrue(store.canUpdateEngine)
        XCTAssertEqual(store.engineSidebarVersionDescription, oldVersion)
        store.updateEngine()
        for _ in 0..<2400 {
            if !store.isUpdatingEngine { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(store.isUpdatingEngine)
        XCTAssertNil(store.engineUpgradeError)
        XCTAssertEqual(store.installedEngine?.version, target)
        XCTAssertNil(store.availableEngineUpdate)
        let restored = await manager.localInstallation()
        XCTAssertEqual(restored, store.installedEngine)
        if case .running = store.runtime.phase {} else { XCTFail("Updated engine did not start") }
        _ = try await controller.client().globalStat()
        await store.prepareForAppTermination()
    }

    func testRuntimeBackupRestoresSessionAndRecoveryWithoutChangingPreferences() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let support = try Aria2NextPaths.supportDirectory(applicationSupportBase: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let recovery = base.appendingPathComponent("aria2-next")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let session = support.appendingPathComponent("aria2.session")
        let marker = support.appendingPathComponent("engine-version")
        let preferences = support.appendingPathComponent("preferences.json")
        let database = recovery.appendingPathComponent("recovery.db")
        for url in [session, marker, database] { try Data("old".utf8).write(to: url) }
        let backup = try await EngineRuntimeBackup.create(supportDirectory: support)
        for url in [session, marker, database, preferences] { try Data("new".utf8).write(to: url) }
        try await backup.restore()
        for url in [session, marker, database] { XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8)) }
        XCTAssertEqual(try Data(contentsOf: preferences), Data("new".utf8))
        await backup.discard()
    }

    private func releaseJSON(version: String = "3.8.6", prerelease: Bool = false, host: String = "github.com", architecture: String = "arm64", draft: Bool = false) -> Data {
        Data("""
        {"tag_name":"v\(version)","draft":\(draft),"prerelease":\(prerelease),"assets":[
        {"name":"aria2-next-\(version)-macos-\(architecture)","browser_download_url":"https://\(host)/AnInsomniacy/aria2-next/releases/download/v\(version)/aria2-next-\(version)-macos-\(architecture)"},
        {"name":"aria2-next-\(version)-checksums.sha256","browser_download_url":"https://\(host)/AnInsomniacy/aria2-next/releases/download/v\(version)/aria2-next-\(version)-checksums.sha256"}]}
        """.utf8)
    }

    private func configureIsolatedPorts(_ settings: inout EngineSettings) {
        settings.rpcPort = (40_000...49_000).first { !LocalHostPortProbe.isTCPPortInUse(port: $0) } ?? 49_001
        settings.listenPort = 49_100
        settings.btDHTEnabled = false
        settings.btLocalPeerDiscoveryEnabled = false
        settings.btPeerExchangeEnabled = false
        settings.ed2kListenPort = 0
        settings.ed2kUDPListenPort = 0
    }
}

private nonisolated struct LiveTrackerFixture: BitTorrentTrackerSourceFetching {
    var text: String
    func fetchTrackerSources(_ urls: [String]) async -> TrackerSourceFetchResult {
        .init(data: [text], failures: [])
    }
}

private actor InstallationProgressRecorder {
    var events: [EngineInstallationProgress] = []
    func append(_ progress: EngineInstallationProgress) { events.append(progress) }
}

/// Fault injection wraps real URLSession sockets; HTTP and the engine stay alive.
private final class LiveNotificationSockets: @unchecked Sendable {
    private let lock = NSLock()
    private let session: URLSession
    private var blocked = false
    private var tasks: [URLSessionWebSocketTask] = []
    private var sentMethods: [String] = []
    var methods: [String] { lock.withLock { sentMethods } }
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }
    func make(_ request: URLRequest) -> any RPCWebSocketConnection {
        let task = session.webSocketTask(with: request)
        lock.withLock { tasks.append(task) }
        return LiveNotificationSocket(task: task, owner: self)
    }
    func disconnect() {
        let current = lock.withLock { blocked = true; return tasks }
        for task in current { task.cancel(with: .goingAway, reason: nil) }
    }
    func allowConnections() { lock.withLock { blocked = false } }
    func willSend(_ message: URLSessionWebSocketTask.Message) throws {
        guard case .string(let text) = message,
              let body = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let method = body["method"] as? String else { throw URLError(.cannotParseResponse) }
        let shouldFail = lock.withLock { sentMethods.append(method); return blocked }
        if shouldFail { throw URLError(.networkConnectionLost) }
    }
}

private struct LiveNotificationSocket: RPCWebSocketConnection {
    let task: URLSessionWebSocketTask
    let owner: LiveNotificationSockets
    func resume() { task.resume() }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try owner.willSend(message)
        try await task.send(message)
    }
}

@MainActor
private final class LiveNotificationObservation {
    var connectionCount = 0
    var sawDisconnect = false
    var observeInitialTransfers = true
    var recoveryGID: String?
    var eventStore: DownloadStore?
}
