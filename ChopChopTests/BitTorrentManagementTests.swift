import XCTest
@testable import ChopChop

final class BitTorrentManagementTests: XCTestCase {
    func testPriorityOverridesSelectionAndEmitsNativeOptions() throws {
        let files = [DownloadFile(index: 1, path: "/one", length: 10, completedLength: 2, isSelected: true),
                     DownloadFile(index: 2, path: "/two", length: 20, completedLength: 0, isSelected: false)]
        var options = BitTorrentTaskOptions(files: files, options: ["bt-file-priority": "1=off,2=top", "seed-ratio": "2", "force-sequential": "true"])
        XCTAssertEqual(options.priorities[1], .off)
        XCTAssertEqual(try options.engineOptions()["select-file"], "2")
        XCTAssertEqual(try options.engineOptions()["bt-file-priority"], "1=off,2=top")
        XCTAssertEqual(try options.engineOptions()["force-sequential"], "true")
        XCTAssertNil(try options.engineOptions()["seed-time"])
        options.seedMinutes = "0"
        XCTAssertEqual(try options.engineOptions()["seed-time"], "0")
        options.priorities[2] = .off
        XCTAssertThrowsError(try options.engineOptions())
        options.priorities[1] = .high; options.seedRatio = "nan"
        XCTAssertThrowsError(try options.engineOptions())
    }

    func testNativeDiagnosticsAreMappedWithoutInventingTrackerSuccess() throws {
        let task = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"torrent","status":"active","bittorrent":{"state":"downloading","numPeers":"4","numSeeds":"2","availability":"0.75","handshakingPeers":"1","seedingTime":"60","announceList":[["https://tracker.example.com/announce"]]}}"#.utf8)).toTask()
        XCTAssertEqual(task.torrentDiagnostics?.peers, 4)
        XCTAssertEqual(task.torrentDiagnostics?.availability, 0.75)
        XCTAssertEqual(task.torrentDiagnostics?.seedingSeconds, 60)
        XCTAssertEqual(task.trackers.first?.status, "Configured")
    }
}
