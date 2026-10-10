import XCTest
@testable import ChopChop

final class BitTorrentManagementTests: XCTestCase {
    func testFileKindsUseLeafExtensionsWithoutRequiringDownloadedFiles() {
        let cases: [(String, TorrentFileKind?)] = [
            ("/missing/影片.MKV", .videos), ("/missing/clip.mp4", .videos),
            ("/missing/camera.m2ts", .videos), ("/missing/photo.HEIC", .images),
            ("/missing/photo.avif", .images), ("/missing/cover.png", .images),
            ("/missing/track.FLAC", .audio), ("/missing/audio.m4a", .audio),
            ("/missing/字幕.ass", .subtitles), ("/missing/字幕.SRT", .subtitles),
            ("/missing/archive.7z", .archives), ("/missing/archive.zip", .archives),
            ("/missing/folder.mp4/readme.txt", nil), ("/missing/clip.mp4.url", nil),
            ("/missing/README", nil)
        ]
        for (path, expected) in cases {
            XCTAssertEqual(TorrentFileKind.allCases.filter { $0.matches(path) }, expected.map { [$0] } ?? [], path)
        }
    }

    @MainActor
    func testFileTypeSelectionReplacesTheWholeSelectionAndCanBeAdjusted() throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        let paths = ["/tmp/Bundle/video.MKV", "/tmp/Bundle/extras/cover.png", "/tmp/Bundle/subs/video.srt", "/tmp/Bundle/clip.mp4"]
        let files = paths.enumerated().map { DownloadFile(index: $0.offset + 1, path: $0.element,
            length: Int64(($0.offset + 1) * 100), completedLength: 0, isSelected: true) }
        store.bitTorrentSelectionSession = BitTorrentFileSelectionSession(source: "magnet:?xt=urn:btih:test",
            taskName: "Bundle", files: files, selectedFileIndexes: [1, 2, 3, 4], phase: .ready)
        store.selectBitTorrentFiles(ofKind: .videos)
        XCTAssertEqual(store.bitTorrentSelectionSession?.selectedFileIndexes, [1, 4])
        XCTAssertEqual(store.bitTorrentSelectionSession?.selectedTotalLength, 500)
        XCTAssertEqual(store.bitTorrentSelectionSession?.selectFileOption, "1,4")
        store.setBitTorrentFileIndexes([3], selected: true)
        XCTAssertEqual(store.bitTorrentSelectionSession?.selectedFileIndexes, [1, 3, 4])
        store.selectBitTorrentFiles(ofKind: .images)
        XCTAssertEqual(store.bitTorrentSelectionSession?.selectedFileIndexes, [2])
        store.setAllBitTorrentFilesSelected(true)
        XCTAssertEqual(store.bitTorrentSelectionSession?.selectedFileIndexes, [1, 2, 3, 4])
        store.setAllBitTorrentFilesSelected(false)
        XCTAssertEqual(store.bitTorrentSelectionSession?.hasSelection, false)
        store.selectBitTorrentFiles(ofKind: .audio)
        XCTAssertEqual(store.bitTorrentSelectionSession?.hasSelection, false)
        store.bitTorrentSelectionSession?.phase = .loading
        store.setAllBitTorrentFilesSelected(true)
        store.selectBitTorrentFiles(ofKind: .videos)
        XCTAssertEqual(store.bitTorrentSelectionSession?.hasSelection, false)
        XCTAssertTrue(store.tasks.isEmpty, "Selection changes only the draft until confirmation")
    }

    func testBitTorrentIdentityUsesAppReleaseAndLeavesRandomPeerIDSuffix() {
        XCTAssertEqual(BitTorrentClientIdentity(releaseVersion: "v0.0.1-beta.7", appVersion: "0.0.1").userAgent,
                       "ChopChop/0.0.1-beta.7")
        XCTAssertEqual(BitTorrentClientIdentity(releaseVersion: "v1.2.3", appVersion: "0.0.1").userAgent,
                       "ChopChop/1.2.3")
        XCTAssertEqual(BitTorrentClientIdentity(releaseVersion: "development", appVersion: "0.0.1").userAgent,
                       "ChopChop/0.0.1-dev")
        XCTAssertEqual(BitTorrentClientIdentity(releaseVersion: "invalid\r\nvalue", appVersion: nil).userAgent,
                       "ChopChop/0.0.0-dev")
        let identity = BitTorrentClientIdentity.current
        XCTAssertEqual(identity.peerIDPrefix, "ChopChop-")
        XCTAssertEqual(20 - identity.peerIDPrefix.utf8.count, 11)
        for startup in [true, false] {
            let options = EngineSettings().engineOptions(includeStartupOnly: startup)
            XCTAssertEqual(options["bt-user-agent"], identity.userAgent)
            XCTAssertEqual(options["bt-peer-id-prefix"], identity.peerIDPrefix)
            XCTAssertEqual(options["user-agent"], EngineSettings.defaultUserAgent)
        }
    }

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
