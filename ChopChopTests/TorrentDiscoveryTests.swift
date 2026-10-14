import XCTest
@testable import ChopChop

final class TorrentDiscoveryTests: XCTestCase {
    func testPeerStagesUseHandshakeStateAndNeverAssumeUnknownMeansZero() {
        var session = BitTorrentFileSelectionSession(source: "magnet:?xt=urn:btih:test", taskName: "Example",
            files: [], selectedFileIndexes: [], phase: .loading)
        XCTAssertEqual(session.discoveryStage, .checking)
        session.discovery = TorrentDiscovery(peers: .init([PeerTransfer(state: "connecting")]))
        XCTAssertEqual(session.discoveryStage, .connecting)
        session.discovery?.peers = .init([PeerTransfer(state: "handshaking"), PeerTransfer(state: "connecting")])
        XCTAssertEqual(session.discoveryStage, .handshaking)
        XCTAssertEqual(session.discovery?.peers?.connected, 0)
        session.discovery?.peers = .init([PeerTransfer(state: "connected"), PeerTransfer(state: "handshaking")])
        XCTAssertEqual(session.discoveryStage, .metadata)
        XCTAssertEqual(session.discovery?.peers?.connected, 1)
        session.discovery?.peers = .init([PeerTransfer(state: "future-state")])
        XCTAssertEqual(session.discoveryStage, .checking)
        session.discovery?.peers = .init([])
        session.discovery?.trackers = .init([BitTorrentTrackerStatus(url: "udp://tracker.example:80", status: "error")])
        session.discovery?.dhtNodes = 0
        XCTAssertEqual(session.discoveryStage, .trackers)
        session.discovery?.dhtNodes = 20
        XCTAssertEqual(session.discoveryStage, .findingPeers)
        session.isPaused = true
        XCTAssertEqual(session.discoveryStage, .paused)
        session.isQueued = true
        XCTAssertEqual(session.discoveryStage, .queued)
    }

    func testSlowWarningStartsAtSixtySecondsAndResetsWithAttempt() {
        let start = Date(timeIntervalSince1970: 100)
        var session = BitTorrentFileSelectionSession(source: "magnet:test", taskName: "Example",
            files: [], selectedFileIndexes: [], phase: .loading, startedAt: start)
        XCTAssertFalse(session.isDiscoverySlow(at: start.addingTimeInterval(59)))
        XCTAssertTrue(session.isDiscoverySlow(at: start.addingTimeInterval(60)))
        session.startedAt = start.addingTimeInterval(60)
        XCTAssertFalse(session.isDiscoverySlow(at: start.addingTimeInterval(61)))
        session.phase = .ready
        XCTAssertFalse(session.isDiscoverySlow(at: start.addingTimeInterval(300)))
    }

    func testTrackerSummaryKeepsAllEntriesAndHidesURLCredentials() {
        let values = (0..<180).map { index in
            BitTorrentTrackerStatus(url: "https://user:secret@tracker.example:443/passkey/announce?token=secret",
                status: index < 30 ? "working" : index < 100 ? "error" : "updating", verified: index < 31 ? "true" : "false")
        }
        let summary = TorrentDiscovery.Trackers(values)
        XCTAssertEqual(summary.total, 180)
        XCTAssertEqual(summary.responded, 31)
        XCTAssertEqual(summary.failed, 70)
        XCTAssertEqual(summary.announcing, 80)
        XCTAssertEqual(summary.entries.count, 180)
        XCTAssertTrue(summary.entries.allSatisfy { $0.address == "https://tracker.example:443" })
        XCTAssertTrue(TorrentDiscovery(trackers: summary).hasUnavailableDetails)
        XCTAssertFalse(TorrentDiscovery(trackers: summary, peers: .init([]), dhtNodes: 0).hasUnavailableDetails)
    }
}
