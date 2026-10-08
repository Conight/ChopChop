import XCTest
@testable import ChopChop

final class DownloadPlanningTests: XCTestCase {
    func testQueuePositionsAccountForRemovalBeforeInsertion() {
        let queue = ["a", "b", "c", "d"]
        XCTAssertEqual(DownloadQueueOrder.position(moving: "a", before: "c", in: queue), 1)
        XCTAssertEqual(DownloadQueueOrder.position(moving: "d", before: "b", in: queue), 1)
        XCTAssertEqual(DownloadQueueOrder.position(moving: "d", before: nil, in: queue), 0)
        XCTAssertNil(DownloadQueueOrder.position(moving: "a", before: "a", in: queue))
        XCTAssertNil(DownloadQueueOrder.position(moving: "missing", before: "a", in: queue))
    }

    func testDailyWindowCrossesMidnightAndUsesExclusiveEnd() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8)))
        var plan = BandwidthSchedule(enabled: true)
        XCTAssertTrue(plan.contains(date, calendar: calendar))
        XCTAssertFalse(plan.contains(date.addingTimeInterval(8 * 3600), calendar: calendar))
        XCTAssertTrue(plan.contains(date.addingTimeInterval(22 * 3600), calendar: calendar))
        plan.startMinute = 9 * 60; plan.endMinute = 17 * 60
        XCTAssertFalse(plan.contains(date, calendar: calendar))
        XCTAssertTrue(plan.contains(date.addingTimeInterval(9 * 3600), calendar: calendar))
        plan.startMinute = plan.endMinute
        XCTAssertTrue(plan.contains(date, calendar: calendar))
        plan.enabled = false
        XCTAssertFalse(plan.contains(date, calendar: calendar))
    }

    @MainActor
    func testBandwidthPersistsAndRestoresBaseLimits() throws {
        let store = try PersistentSettingsStore(inMemory: true)
        var preferences = AppPreferences()
        preferences.bandwidthSchedule = BandwidthSchedule(enabled: true, startMinute: 0, endMinute: 0, downloadKB: 256, uploadKB: 0)
        try store.saveAppPreferences(preferences)
        XCTAssertEqual(try store.loadAppPreferences().bandwidthSchedule, preferences.bandwidthSchedule)
        var settings = EngineSettings(); settings.maxOverallDownloadLimitKB = 500
        XCTAssertEqual(preferences.bandwidthSchedule.options(at: Date(), base: settings)["max-overall-download-limit"], "256K")
        preferences.bandwidthSchedule.enabled = false
        XCTAssertEqual(preferences.bandwidthSchedule.options(at: Date(), base: settings)["max-overall-download-limit"], "500K")
    }
}
