import AppKit
import XCTest
@testable import ChopChop

final class MenuBarStatusTests: XCTestCase {
    @MainActor
    func testDisplayModeSurvivesDiskReopenAndHidingTheItem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preferences.store")
        XCTAssertEqual(AppPreferences().menuBarDisplayMode, .iconOnly)
        for mode in MenuBarDisplayMode.allCases {
            try autoreleasepool {
                let persistence = try PersistentSettingsStore(storeURL: url)
                var preferences = try persistence.loadAppPreferences()
                preferences.menuBarDisplayMode = mode
                preferences.showMenuBar = false
                try persistence.saveAppPreferences(preferences)
            }
            try autoreleasepool {
                let loaded = try PersistentSettingsStore(storeURL: url).loadAppPreferences()
                XCTAssertEqual(loaded.menuBarDisplayMode, mode)
                XCTAssertFalse(loaded.showMenuBar)
            }
        }
        let record = PersistentAppConfiguration()
        for raw in [nil, "unknown-future-mode"] as [String?] {
            record.menuBarDisplayModeRawValue = raw
            XCTAssertEqual(record.appPreferences().menuBarDisplayMode, .iconOnly)
        }
    }

    @MainActor
    func testSnapshotUsesGlobalRatesAndRejectsDisconnectedSamples() throws {
        let store = try makeStore()
        defer { store.shutdown() }
        store.preferences.menuBarDisplayMode = .speedOnly
        store.recordSpeed(download: 1_250_000, upload: 320_000)
        XCTAssertNil(MenuBarStatusSnapshot(store: store).rates, "A stored sample isn't evidence of a live engine")
        store.runtime = EngineRuntimeSnapshot(phase: .running(pid: 123))
        XCTAssertEqual(MenuBarStatusSnapshot(store: store).rates, MenuBarTransferRates(download: 1_250_000, upload: 320_000))
        store.recordSpeed(download: 0, upload: 64_000)
        let sharing = MenuBarStatusSnapshot(store: store)
        XCTAssertTrue(sharing.speedTitle.contains(ByteFormat.speed(64_000)), "Uploading remains visible without an active download")
        XCTAssertTrue(try XCTUnwrap(sharing.accessibilityValue).contains(String(localized: "Upload speed: \(ByteFormat.speed(64_000))")))
        store.connectionIssue = "RPC unavailable"
        let unavailable = MenuBarStatusSnapshot(store: store)
        XCTAssertNil(unavailable.rates)
        XCTAssertEqual(unavailable.speedTitle, "↓\t—\n↑\t—")
        XCTAssertFalse(unavailable.toolTip.contains(ByteFormat.speed(64_000)))
        store.connectionIssue = nil
        store.recordSpeed(download: -1, upload: -2)
        XCTAssertEqual(MenuBarStatusSnapshot(store: store).rates, MenuBarTransferRates(download: 0, upload: 0))
        store.runtime = EngineRuntimeSnapshot(phase: .stopped)
        XCTAssertNil(MenuBarStatusSnapshot(store: store).rates)
    }

    @MainActor
    func testObservationFollowsCommittedRatesPreferencesAndConnectionRecovery() async throws {
        let store = try makeStore()
        defer { store.shutdown() }
        var snapshots: [MenuBarStatusSnapshot] = []
        let observation = MenuBarStatusObservation { snapshots.append($0) }
        observation.configure(store: store)
        XCTAssertEqual(snapshots.count, 1)
        store.preferences.menuBarDisplayMode = .iconAndSpeed
        store.runtime = EngineRuntimeSnapshot(phase: .running(pid: 123))
        store.recordSpeed(download: 5_000, upload: 7_000)
        try await NativeLayout.wait(until: "menu bar receives committed rates") {
            snapshots.last?.rates == MenuBarTransferRates(download: 5_000, upload: 7_000)
        }
        store.recordSpeed(download: 9_000, upload: 11_000)
        try await NativeLayout.wait(until: "menu bar receives a subsequent sample") {
            snapshots.last?.rates?.upload == 11_000
        }
        store.connectionIssue = "offline"
        try await NativeLayout.wait(until: "menu bar clears disconnected rates") { snapshots.last?.rates == nil }
        store.recordSpeed(download: 15_000, upload: 17_000)
        store.connectionIssue = nil
        try await NativeLayout.wait(until: "menu bar follows reconnection") { snapshots.last?.rates?.upload == 17_000 }
        store.preferences.showMenuBar = false
        try await NativeLayout.wait(until: "menu bar follows hide preference") { snapshots.last?.isVisible == false }
        store.preferences.showMenuBar = true
        try await NativeLayout.wait(until: "menu bar restores the selected mode") {
            snapshots.last?.isVisible == true && snapshots.last?.mode == .iconAndSpeed && snapshots.last?.rates?.upload == 17_000
        }
        observation.stop()
        let count = snapshots.count
        store.recordSpeed(download: 19_000, upload: 23_000)
        await drainMainQueue()
        XCTAssertEqual(snapshots.count, count, "Removed observations must not keep updating the menu bar")
    }

    @MainActor
    func testSwitchingStoresDiscardsQueuedChangesFromThePreviousStore() async throws {
        let first = try makeStore(), second = try makeStore()
        defer { first.shutdown(); second.shutdown() }
        var snapshots: [MenuBarStatusSnapshot] = []
        let observation = MenuBarStatusObservation { snapshots.append($0) }
        defer { observation.stop() }
        observation.configure(store: first)
        first.preferences.menuBarDisplayMode = .speedOnly
        second.preferences.showMenuBar = false
        observation.configure(store: second)
        await drainMainQueue()
        XCTAssertFalse(try XCTUnwrap(snapshots.last).isVisible)
        XCTAssertEqual(snapshots.last?.mode, .iconOnly)
        XCTAssertEqual(snapshots.count, 2, "An old queued callback must not resurrect the previous item")
    }

    @MainActor
    func testNativeStatusButtonSwitchesAllModesWithoutClippingOrLosingAccessibility() async throws {
        let store = try makeStore()
        defer { store.shutdown() }
        store.runtime = EngineRuntimeSnapshot(phase: .running(pid: 123))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        for mode in [MenuBarDisplayMode.iconOnly, .speedOnly, .iconAndSpeed, .iconOnly] {
            store.preferences.menuBarDisplayMode = mode
            item.length = MenuBarStatusAppearance.length(for: mode)
            var initialButtonWidth: CGFloat?
            for speed: Int64 in [0, 1, 999, 999_949, 1_000_000, 999_949_000, 1_000_000_000, Int64.max] {
                store.recordSpeed(download: speed, upload: speed / 2)
                let snapshot = MenuBarStatusSnapshot(store: store)
                MenuBarStatusAppearance.apply(snapshot, to: button)
                await NativeLayout.flush(button)
                XCTAssertEqual(button.image != nil, mode.showsIcon)
                if let image = button.image { XCTAssertTrue(image.isTemplate) }
                XCTAssertEqual(button.attributedTitle.string, mode.showsSpeed ? snapshot.speedTitle : "")
                XCTAssertEqual(button.accessibilityLabel(), AppIdentity.displayName)
                XCTAssertEqual(button.accessibilityValue() as? String, snapshot.accessibilityValue)
                XCTAssertEqual(button.toolTip, snapshot.toolTip)
                if mode.showsSpeed {
                    let textBounds = button.attributedTitle.boundingRect(
                        with: NSSize(width: 10_000, height: 1000),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
                    XCTAssertLessThanOrEqual(textBounds.width, MenuBarStatusAppearance.textWidth + 0.5)
                    let titleRect = try XCTUnwrap(button.cell).titleRect(forBounds: button.bounds)
                    XCTAssertLessThanOrEqual(textBounds.height, titleRect.height + 0.5,
                                             "Both speed rows must fit the actual system status button")
                    XCTAssertLessThanOrEqual(textBounds.width, titleRect.width + 0.5,
                                             "Full byte units and counts must fit without truncation")
                    if let initialButtonWidth {
                        XCTAssertEqual(button.bounds.width, initialButtonWidth, accuracy: 0.5,
                                       "Changing speed digits and units must not resize the native button")
                    } else { initialButtonWidth = button.bounds.width }
                }
            }
        }
    }

    func testSpeedDisplayKeepsBackgroundTransfersCurrentWithoutChangingIdleOrFailureBackoff() {
        XCTAssertEqual(DownloadRefreshPolicy.interval(foreground: false, hasTransfers: true, failures: 0, showsMenuBarSpeeds: true), .seconds(1))
        XCTAssertEqual(DownloadRefreshPolicy.interval(foreground: false, hasTransfers: true, failures: 0), .seconds(5))
        XCTAssertEqual(DownloadRefreshPolicy.interval(foreground: false, hasTransfers: false, failures: 0, showsMenuBarSpeeds: true), .seconds(30))
        XCTAssertEqual(DownloadRefreshPolicy.interval(foreground: false, hasTransfers: false, failures: 0, receivesEvents: true, showsMenuBarSpeeds: true), .seconds(60))
        XCTAssertEqual(DownloadRefreshPolicy.interval(foreground: false, hasTransfers: true, failures: 100, showsMenuBarSpeeds: true), .seconds(60))
    }

    @MainActor
    private func makeStore() throws -> DownloadStore {
        DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
    }

    @MainActor
    private func drainMainQueue() async {
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
