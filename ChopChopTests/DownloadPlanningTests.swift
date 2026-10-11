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

    func testNativeQueueMovePreservesGroupOrderAndRejectsStaleIDs() throws {
        let queue = ["a", "b", "c", "d", "e"]
        func result(_ ids: [String], before: String? = nil, toEnd: Bool = false) throws -> [String] {
            var changed = queue
            for move in try XCTUnwrap(DownloadQueueOrder.moves(ids, before: before, toEnd: toEnd, in: queue)) {
                changed.removeAll { $0 == move.id }
                changed.insert(move.id, at: move.position)
            }
            return changed
        }
        XCTAssertEqual(try result(["c", "a"], before: "e"), ["b", "d", "a", "c", "e"])
        XCTAssertEqual(try result(["c", "e"], before: "a"), ["c", "e", "a", "b", "d"])
        XCTAssertEqual(try result(["a", "b"], toEnd: true), ["c", "d", "e", "a", "b"])
        XCTAssertEqual(try result(["a", "b"], before: "c"), queue)
        for ids in [["missing"], ["a", "a"], []] {
            XCTAssertNil(DownloadQueueOrder.moves(ids, before: "c", toEnd: false, in: queue))
        }
        XCTAssertNil(DownloadQueueOrder.moves(["a"], before: "a", toEnd: false, in: queue))
        XCTAssertNil(DownloadQueueOrder.moves(["a"], before: "missing", toEnd: false, in: queue))
        XCTAssertNil(DownloadQueueOrder.moves(["a"], before: nil, toEnd: false, in: queue))
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
