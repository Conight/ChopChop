import Foundation
import XCTest
@testable import ChopChop

final class ManagedEngineTests: XCTestCase {
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
        XCTAssertLessThan(try XCTUnwrap(EngineVersion("v2.9.9")), try XCTUnwrap(EngineVersion("2.10.0")))
        XCTAssertEqual(EngineVersion("v2.8.6"), EngineVersion("2.8.6"))
        for invalid in ["2.8", "2.8.6-beta", "../../2.8.6", "2.-8.6", "2.8.6.1", "2.８.6"] {
            XCTAssertNil(EngineVersion(invalid))
        }
    }

    func testReleaseParserSelectsOfficialStableArm64Asset() throws {
        let release = try EngineDownload.parseRelease(releaseJSON())
        XCTAssertEqual(release.version, EngineVersion("2.8.6"))
        XCTAssertTrue(release.downloadURL.absoluteString.hasSuffix("/aria2-next-2.8.6-macos-arm64"))
        for invalid in [releaseJSON(prerelease: true), releaseJSON(host: "evil.example"), releaseJSON(architecture: "x86_64")] {
            XCTAssertThrowsError(try EngineDownload.parseRelease(invalid))
        }
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
            _ = try await EngineInstallerRequest().install(version: "../../2.8.6", directoryBookmark: bookmark)
            XCTFail("Invalid versions must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("supported Apple Silicon engine")) }
        do {
            _ = try await EngineInstallerRequest().install(version: "2.8.6", directoryBookmark: bookmark)
            XCTFail("Installer must only write into the app's Engines directory")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Invalid engine installation directory")) }
    }

    func testCancelledInstallerRequestCompletesWithoutWaitingForNetwork() async {
        let request = EngineInstallerRequest()
        let task = Task { try await request.install(version: "2.8.6", directoryBookmark: Data()) }
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
        let controller = Aria2NextEngineController()
        controller.selectInstallation(installation)
        var settings = EngineSettings()
        settings.rpcToken = UUID().uuidString
        settings.btTrackerAutoSync = false
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
        _ = try await controller.stop()
    }

    @MainActor
    func testManualUpgradeFrom285ThroughSandboxedStore() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHOPCHOP_TEST_ENGINE_DOWNLOAD"] == "1", "Live engine download is opt-in")
        let support = try Aria2NextPaths.supportDirectory()
        let manager = EngineInstallationManager(supportDirectory: support)
        let oldVersion = "2.8.5"
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
        for _ in 0..<300 {
            if store.canUpdateEngine { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let target = try XCTUnwrap(store.availableEngineUpdate?.version)
        XCTAssertTrue(store.canUpdateEngine)
        XCTAssertEqual(store.engineSidebarVersionDescription, "\(oldVersion) → \(target)")
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

    private func releaseJSON(prerelease: Bool = false, host: String = "github.com", architecture: String = "arm64") -> Data {
        Data("""
        {"tag_name":"v2.8.6","draft":false,"prerelease":\(prerelease),"assets":[
        {"name":"aria2-next-2.8.6-macos-\(architecture)","browser_download_url":"https://\(host)/AnInsomniacy/aria2-next/releases/download/v2.8.6/aria2-next-2.8.6-macos-\(architecture)"},
        {"name":"aria2-next-2.8.6-checksums.sha256","browser_download_url":"https://\(host)/AnInsomniacy/aria2-next/releases/download/v2.8.6/aria2-next-2.8.6-checksums.sha256"}]}
        """.utf8)
    }

    private func configureIsolatedPorts(_ settings: inout EngineSettings) {
        settings.rpcPort = (40_000...49_000).first { !LocalHostPortProbe.isTCPPortInUse(port: $0) } ?? 49_001
        settings.listenPort = 49_100
        settings.dhtListenPort = 49_110
        settings.ed2kListenPort = 0
        settings.ed2kUDPListenPort = 0
    }
}

private actor InstallationProgressRecorder {
    var events: [EngineInstallationProgress] = []
    func append(_ progress: EngineInstallationProgress) { events.append(progress) }
}
