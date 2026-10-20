import XCTest
@testable import ChopChop

final class EngineSettingsApplicationTests: XCTestCase {
    func testClearingConnectionDefaultsSendsEmptyValuesAndDoesNotTouchScheduledCaps() {
        var settings = EngineSettings()
        settings.proxyURL = "http://127.0.0.1:7890"
        settings.proxyBypass = "localhost"
        var applied = EngineSettingsApplication()
        applied.didLaunch(settings)
        settings.proxyURL = ""
        settings.proxyBypass = ""
        settings.userAgent = ""
        settings.maxOverallUploadLimitKB = 1024
        let pending = applied.pendingOptions(for: settings)
        XCTAssertEqual(pending, ["all-proxy": "", "no-proxy": "", "user-agent": ""])
        applied.didApply(pending)
        XCTAssertTrue(applied.pendingOptions(for: settings).isEmpty)
    }

    func testRestartRequirementTracksTheRunningConfigurationAndClearsOnRevertOrLaunch() {
        var settings = EngineSettings()
        settings.rpcToken = "managed-token"
        settings.ed2kServer = "server.example:4661"
        var applied = EngineSettingsApplication()
        applied.didLaunch(settings)
        settings.rpcPort += 1
        settings.ed2kServer = ""
        XCTAssertEqual(applied.restartReasons(for: settings), ["Engine connection", "ED2K"])
        applied.didApply(applied.pendingOptions(for: settings))
        XCTAssertEqual(applied.restartReasons(for: settings).count, 2, "Saving live defaults is not a restart")
        settings.rpcPort -= 1
        XCTAssertEqual(applied.restartReasons(for: settings), ["ED2K"])
        applied.didLaunch(settings)
        XCTAssertTrue(applied.restartReasons(for: settings).isEmpty)
        settings.lastED2KBootstrapSyncAt = Date()
        XCTAssertTrue(applied.restartReasons(for: settings).isEmpty, "Checking unchanged bootstrap files is not a configuration change")
        XCTAssertEqual(applied.restartReasons(for: settings, bootstrap: .init(serverMetSize: 12)), ["ED2K"])
    }

    func testLivePeerSettingsDoNotRequireRestartOrContainRPCSecrets() {
        var settings = EngineSettings()
        var applied = EngineSettingsApplication()
        applied.didLaunch(settings)
        settings.btDHTEnabled = false
        settings.btPeerExchangeEnabled = false
        settings.btLocalPeerDiscoveryEnabled = false
        settings.btForceEncryption = true
        settings.btMaxPeers = 96
        settings.ed2kUploadSlots = 5
        settings.rpcToken = "new-token"
        let pending = applied.pendingOptions(for: settings)
        XCTAssertEqual(pending, ["enable-dht": "false", "enable-peer-exchange": "false",
                                 "bt-enable-lpd": "false", "bt-encryption": "required",
                                 "bt-max-peers": "96", "ed2k-upload-slots": "5"])
        XCTAssertEqual(applied.restartReasons(for: settings), ["Engine connection"])
    }

    func testOldRepliesNeverMarkNewEditsAsApplied() {
        var settings = EngineSettings()
        var applied = EngineSettingsApplication()
        applied.didLaunch(settings)
        settings.splitCount = 16
        let sent = applied.pendingOptions(for: settings)
        settings.splitCount = 32
        applied.didApply(sent)
        XCTAssertEqual(applied.pendingOptions(for: settings), ["split": "32"])
    }

    @MainActor func testEngineCommandsDoNotExposeManualServiceControls() {
        XCTAssertEqual(DownloadAction.allCases.filter { $0.group == "Engine" }, [.engineSettings])
        XCTAssertTrue(CommandSearchIndex.matches("Start Engine").isEmpty)
        XCTAssertTrue(CommandSearchIndex.matches("Stop Engine").isEmpty)
    }
}
