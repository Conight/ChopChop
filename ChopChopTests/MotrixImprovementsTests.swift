import Foundation
import XCTest
@testable import ChopChop

final class MotrixImprovementsTests: XCTestCase {
    private func task(_ status: String = "active", completed: Int = 0) throws -> DownloadTask {
        try JSONDecoder().decode(Aria2TaskDTO.self, from: Data("{\"gid\":\"abc\",\"status\":\"\(status)\",\"completedLength\":\"\(completed)\"}".utf8)).toTask()
    }

    func testPrivacyIsUnknownUntilExplicitlyReportedAndSurvivesHistory() throws {
        for (value, expected) in [("true", Optional(true)), ("false", Optional(false)), ("unrecognized", nil)] {
            let data = Data("{\"gid\":\"abc\",\"status\":\"active\",\"bittorrent\":{\"privateTorrent\":\"\(value)\"}}".utf8)
            let task = try JSONDecoder().decode(Aria2TaskDTO.self, from: data).toTask()
            XCTAssertEqual(task.privateTorrent, expected)
            XCTAssertEqual(try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(task)).privateTorrent, expected)
        }
        XCTAssertNil(try task().privateTorrent)
    }

    func testActivityUsesObservationGapsAndDoesNotRewritePausedHistory() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var old = try task(completed: 100)
        old.activity = DownloadActivity.observing(old, previous: nil, now: now)
        var next = try task(completed: 600)
        next.activity = DownloadActivity.observing(next, previous: old, now: now.addingTimeInterval(5))
        XCTAssertEqual(next.activity?.observedDownloadBytes, 500)
        XCTAssertEqual(next.activity?.averageDownload, 100)
        var offline = next.disconnectedSnapshot
        offline.activity = next.activity
        let recovered = DownloadActivity.observing(next, previous: offline, now: now.addingTimeInterval(500))
        XCTAssertTrue(recovered.hasGap)
        XCTAssertEqual(recovered.observedDownloadBytes, 500)
        XCTAssertTrue(recovered.events.last?.recovered == true)
        var paused = try task("paused", completed: 600)
        paused.activity = DownloadActivity.observing(paused, previous: next, now: now.addingTimeInterval(6))
        XCTAssertEqual(DownloadActivity.observing(paused, previous: paused, now: now.addingTimeInterval(60)), paused.activity)
    }

    func testActivityCompactionKeepsPeaksAndSummaryAndBoundsEvents() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var current = try task()
        for index in 0..<600 {
            var next = current
            next.status = index.isMultiple(of: 2) ? .active : .paused
            next.downloadSpeed = index == 100 ? 100_000 : Int64(index)
            next.uploadSpeed = index == 80 ? 200_000 : 1
            next.completedLength += 100
            next.errorMessage = "https://example.com/?token=private"
            next.activity = DownloadActivity.observing(next, previous: current, now: now.addingTimeInterval(Double(index)))
            current = next
        }
        let activity = try XCTUnwrap(current.activity)
        XCTAssertLessThanOrEqual(activity.samples.count, 96)
        XCTAssertEqual(activity.events.count, 256)
        XCTAssertEqual(activity.peakDownload, 100_000)
        XCTAssertEqual(activity.peakUpload, 200_000)
        XCTAssertTrue(activity.samples.contains { $0.down == 100_000 })
        XCTAssertTrue(activity.samples.contains { $0.up == 200_000 })
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(activity), as: UTF8.self).contains("token=private"))
    }

    @MainActor
    func testTrackerCurationRetainsSourceCacheManualEditsAndExclusions() {
        let diagnostics = TrackerDiagnostics()
        let source = "https://source.example/list"
        let first = TrackerSourceFetchResult(data: ["https://one.example/announce\nhttps://two.example/announce"], failures: [],
            successfulSources: [source: "https://one.example/announce\nhttps://two.example/announce"])
        let now = Date()
        let selected = diagnostics.curate(first, sourceURLs: [source], current: "https://manual.example/announce", proxy: "", now: now)
        XCTAssertTrue(selected.contains("manual.example"))
        XCTAssertEqual(diagnostics.managed.count, 2)
        let edited = selected.replacingOccurrences(of: "https://one.example/announce", with: "")
        let failed = TrackerSourceFetchResult(data: [], failures: [TrackerSourceFetchFailure(url: source, reason: "offline")])
        let retained = diagnostics.curate(failed, sourceURLs: [source], current: edited, proxy: "", now: now.addingTimeInterval(10))
        XCTAssertFalse(retained.contains("one.example"))
        XCTAssertTrue(retained.contains("two.example"))
        XCTAssertTrue(retained.contains("manual.example"))
        diagnostics.resetExclusions()
        let reset = diagnostics.curate(failed, sourceURLs: [source], current: retained, proxy: "", now: now.addingTimeInterval(20))
        XCTAssertTrue(reset.contains("one.example"))
        let expired = diagnostics.curate(failed, sourceURLs: [source], current: reset, proxy: "", now: now.addingTimeInterval(8 * 86400))
        XCTAssertEqual(expired, "https://manual.example/announce")
    }

    @MainActor
    func testManualTrackerOverlapDoesNotBecomeAutomaticallyOwned() {
        let diagnostics = TrackerDiagnostics()
        let source = "https://source.example/list"
        let manual = "https://manual.example/announce"
        let automatic = "https://automatic.example/announce"
        let first = diagnostics.curate(TrackerSourceFetchResult(data: [manual, automatic], failures: [], successfulSources: [source: manual + "\n" + automatic]), sourceURLs: [source], current: manual, proxy: "")
        XCTAssertFalse(diagnostics.managed.contains(manual))
        let second = diagnostics.curate(TrackerSourceFetchResult(data: [automatic], failures: [], successfulSources: [source: automatic]), sourceURLs: [source], current: first, proxy: "")
        XCTAssertTrue(second.contains(manual))
        XCTAssertTrue(second.contains(automatic))
    }

    @MainActor
    func testTrackerSelectionIsBoundedAndDiversifiesHosts() {
        let diagnostics = TrackerDiagnostics()
        let source = "https://source.example/list"
        let urls = (0..<300).map { "https://host\($0 % 100).example/announce/\($0)" }.joined(separator: "\n")
        _ = diagnostics.curate(TrackerSourceFetchResult(data: [urls], failures: [], successfulSources: [source: urls]),
            sourceURLs: [source], current: "", proxy: "")
        XCTAssertLessThanOrEqual(diagnostics.managed.count, 64)
        XCTAssertEqual(Set(diagnostics.managed.compactMap { URL(string: $0)?.host }).count, diagnostics.managed.count)
    }

    @MainActor
    func testTrackerCooldownExpiresWhenTheNetworkRouteChanges() async {
        let diagnostics = TrackerDiagnostics()
        let source = "https://source.example/list"
        let tracker = "https://tracker.example/announce"
        let result = TrackerSourceFetchResult(data: [tracker], failures: [], successfulSources: [source: tracker])
        let initial = diagnostics.curate(result, sourceURLs: [source], current: "", proxy: "")
        for _ in 0..<3 { await diagnostics.probe(urls: [tracker], proxy: "", measure: { _, _ in nil }) }
        let cooled = diagnostics.curate(TrackerSourceFetchResult(data: [], failures: []), sourceURLs: [source], current: initial, proxy: "")
        XCTAssertTrue(cooled.isEmpty)
        XCTAssertFalse(diagnostics.health[tracker]?.reachable ?? true)
        let changedRoute = diagnostics.curate(TrackerSourceFetchResult(data: [], failures: []), sourceURLs: [source], current: cooled, proxy: "http://proxy.example:8080")
        XCTAssertTrue(changedRoute.contains(tracker))
    }

    func testTrackerRetirementRequiresKnownOwnershipAndMatchingTorrentIdentity() throws {
        let original = BitTorrentTrackerStatus(url: "https://original.example/announce", tier: "7")
        let oldManaged = BitTorrentTrackerStatus(url: "https://old.example/announce", tier: "8")
        let ownership = PublicTrackerOwnership(infoHash: "hash-a", urlFingerprints: [PublicTrackerPolicy.fingerprint(oldManaged.url)])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(ownership), as: UTF8.self).contains("old.example"))
        let selected = ["https://new.example/announce"]
        let plan = PublicTrackerPolicy.replacement(current: [original, oldManaged], selected: selected, previous: ownership, infoHash: "hash-a")
        XCTAssertEqual(plan.trackers.map(\.url), [original.url] + selected)
        XCTAssertEqual(plan.trackers.first?.tier, 7)
        XCTAssertEqual(plan.ownership?.urlFingerprints, selected.map(PublicTrackerPolicy.fingerprint))
        let cleared = PublicTrackerPolicy.replacement(current: [original, oldManaged], selected: [], previous: ownership, infoHash: "hash-a")
        XCTAssertEqual(cleared.trackers.map(\.url), [original.url])
        for hash in [Optional("hash-b"), nil] {
            let unknown = PublicTrackerPolicy.replacement(current: [original, oldManaged], selected: [], previous: ownership, infoHash: hash)
            XCTAssertEqual(unknown.trackers.map(\.url), [original.url, oldManaged.url])
        }
    }

    func testForwardedCredentialsCannotFollowAnEditedOrigin() throws {
        var draft = AddDownloadDraft(rawInput: "https://example.com/file")
        draft.browserContextOrigin = "https://example.com"
        draft.cookie = "session=private"
        let options = try draft.engineOptions(fallbackDirectory: nil, autoOrganize: false)
        XCTAssertEqual(options["follow-metalink"], "false")
        XCTAssertEqual(options["follow-torrent"], "false")
        draft.rawInput = "https://other.example/file"
        XCTAssertThrowsError(try draft.engineOptions(fallbackDirectory: nil, autoOrganize: false))
        draft.cookie = ""
        XCTAssertNoThrow(try draft.engineOptions(fallbackDirectory: nil, autoOrganize: false))
    }

    @MainActor
    func testTemporaryLimitPersistsExpirationWithoutRaisingAnExistingLimit() throws {
        let persistence = try PersistentSettingsStore(inMemory: true)
        var preferences = AppPreferences()
        let now = Date()
        preferences.temporaryBandwidth = TemporaryBandwidthLimit(enabled: true, downloadKiB: 2048, uploadKiB: 128, expiresAt: now.addingTimeInterval(1800))
        try persistence.saveAppPreferences(preferences)
        let saved = try persistence.loadAppPreferences()
        XCTAssertEqual(saved.temporaryBandwidth, preferences.temporaryBandwidth)
        let result = EffectiveBandwidth.compute(baseDownload: 256, baseUpload: 0, schedule: BandwidthSchedule(), temporary: saved.temporaryBandwidth, now: now)
        XCTAssertEqual(result.downloadKiB, 256)
        XCTAssertEqual(result.uploadKiB, 128)
    }
}
