import AppKit
import Observation
import Synchronization
import SwiftUI
import XCTest
@testable import ChopChop

final class MenuBarStatusTests: XCTestCase {
    @MainActor
    func testSystemInsertionWritebackDoesNotInvalidateAnUnchangedPreference() throws {
        let store = try makeStore()
        defer { store.shutdown() }
        let binding = ChopChopMenuBarScene(store: store).isInserted
        let changed = Mutex(false)
        withObservationTracking {
            _ = store.preferences.showMenuBar
        } onChange: {
            changed.withLock { $0 = true }
        }
        binding.wrappedValue = true
        XCTAssertFalse(changed.withLock { $0 }, "System writeback of the same value must not re-enter the scene update graph")
        binding.wrappedValue = false
        XCTAssertTrue(changed.withLock { $0 })
        XCTAssertFalse(store.preferences.showMenuBar)
        store.preferences.showMenuBar = true
        XCTAssertTrue(binding.wrappedValue, "Settings changes must flow back to the system scene")
    }

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
        XCTAssertEqual(sharing.rates?.upload, 64_000, "Uploading remains visible without an active download")
        XCTAssertTrue(try XCTUnwrap(sharing.accessibilityValue).contains(String(localized: "Upload speed: \(ByteFormat.speed(64_000))")))
        store.connectionIssue = "RPC unavailable"
        let unavailable = MenuBarStatusSnapshot(store: store)
        XCTAssertNil(unavailable.rates)
        XCTAssertEqual(unavailable.accessibilityValue, String(localized: "Transfer speeds unavailable"))
        XCTAssertFalse(unavailable.toolTip.contains(ByteFormat.speed(64_000)))
        store.connectionIssue = nil
        store.recordSpeed(download: -1, upload: -2)
        XCTAssertEqual(MenuBarStatusSnapshot(store: store).rates, MenuBarTransferRates(download: 0, upload: 0))
        store.runtime = EngineRuntimeSnapshot(phase: .stopped)
        XCTAssertNil(MenuBarStatusSnapshot(store: store).rates)
    }

    @MainActor
    func testOnlyVisibleSpeedModesReadTransferSamples() throws {
        let store = try makeStore()
        defer { store.shutdown() }
        store.runtime = EngineRuntimeSnapshot(phase: .running(pid: 123))
        store.recordSpeed(download: 5_000, upload: 7_000)
        for mode in MenuBarDisplayMode.allCases {
            store.preferences.menuBarDisplayMode = mode
            store.preferences.showMenuBar = true
            XCTAssertEqual(MenuBarStatusSnapshot(store: store).rates != nil, mode.showsSpeed)
            store.preferences.showMenuBar = false
            let hidden = MenuBarStatusSnapshot(store: store)
            XCTAssertFalse(hidden.isVisible)
            XCTAssertNil(hidden.rates)
        }
    }

    @MainActor
    func testMenuBarImagesStayCenteredAndFitTheSystemWorkingAreaAcrossModesAndRates() throws {
        let store = try makeStore()
        defer { store.shutdown() }
        store.runtime = EngineRuntimeSnapshot(phase: .running(pid: 123))
        for mode in [MenuBarDisplayMode.iconOnly, .speedOnly, .iconAndSpeed, .iconOnly] {
            store.preferences.menuBarDisplayMode = mode
            var initialImageWidth: CGFloat?
            for speed: Int64? in [nil, 0, 1, 999, 999_499, 999_500, 999_949, 1_000_000, 999_949_000, 1_000_000_000, Int64.max] {
                store.connectionIssue = speed == nil ? "offline" : nil
                store.recordSpeed(download: speed ?? 0, upload: (speed ?? 0) / 2)
                let snapshot = MenuBarStatusSnapshot(store: store)
                let image = try XCTUnwrap(MenuBarStatusAppearance.image(for: snapshot))
                XCTAssertTrue(image.isTemplate, "All content must follow the native light, dark and selected tint")
                XCTAssertLessThanOrEqual(image.size.height, 22, "Artwork must fit the system menu bar working area")
                if mode.showsSpeed {
                    for scale in [1, 2] {
                        let ink = try inkBounds(of: image, scale: scale)
                        let context = "\(mode.rawValue), \(speed.map { String($0) } ?? "offline"), \(scale)×"
                        XCTAssertEqual(ink.midY, image.size.height / 2, accuracy: 0.75,
                                       "Actual glyphs, not just their line boxes, must be vertically centered: \(context)")
                        XCTAssertGreaterThan(ink.minY, 0, context)
                        XCTAssertLessThan(ink.maxY, image.size.height, context)
                        XCTAssertGreaterThan(ink.minX, 0, context)
                        XCTAssertLessThan(ink.maxX, image.size.width, context)
                    }
                    if let initialImageWidth {
                        XCTAssertEqual(image.size.width, initialImageWidth, accuracy: 0.5,
                                       "Changing speed digits and units must not resize the label")
                    } else { initialImageWidth = image.size.width }
                }
            }
        }
        XCTAssertEqual(MenuBarStatusAppearance.speedText(999_500).unit, "\(ByteFormat.displayUnits[2])/s",
                       "Rounding at a unit boundary must promote the unit instead of overflowing the number column")
    }

    /// Inspect rendered alpha in memory. No screenshot files or app windows.
    @MainActor
    private func inkBounds(of image: NSImage, scale: Int) throws -> CGRect {
        let width = Int(image.size.width) * scale
        let height = Int(image.size.height) * scale
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * context.bytesPerRow + x * 4 + 3] > 16 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, minX, "The template must contain visible artwork")
        let factor = CGFloat(scale)
        return CGRect(x: CGFloat(minX) / factor, y: CGFloat(minY) / factor,
                      width: CGFloat(maxX - minX + 1) / factor, height: CGFloat(maxY - minY + 1) / factor)
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

}
