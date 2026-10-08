import XCTest
@testable import ChopChop

final class MediaDownloadTests: XCTestCase {
    func testManifestDetectionIgnoresQueryAndRequiresOneHTTPSource() throws {
        XCTAssertTrue(AddDownloadDraft(rawInput: "https://example.com/master.M3U8?token=secret").shouldInspectMedia)
        XCTAssertTrue(AddDownloadDraft(rawInput: "https://example.com/clip.mpd").shouldInspectMedia)
        var draft = AddDownloadDraft(rawInput: "https://example.com/manifest?id=1")
        XCTAssertFalse(draft.shouldInspectMedia)
        draft.media.mode = .dash
        XCTAssertTrue(draft.shouldInspectMedia)
        draft.media.mode = .file
        XCTAssertFalse(draft.shouldInspectMedia)
        XCTAssertEqual(try draft.engineOptions(fallbackDirectory: nil, autoOrganize: false)["media"], "file")
        let batch = AddDownloadDraft(rawInput: "https://example.com/clip.m3u8\nhttps://example.com/file.zip")
        XCTAssertThrowsError(try batch.engineOptions(fallbackDirectory: nil, autoOrganize: false))
        XCTAssertFalse(AddDownloadDraft(rawInput: "sftp://example.com/clip.m3u8").shouldInspectMedia)
    }

    func testMediaOptionsRejectInvalidRangesAndTrackCombinations() throws {
        var options = MediaDownloadOptions()
        options.startSeconds = 20; options.endSeconds = 10
        XCTAssertThrowsError(try options.engineOptions())
        options.endSeconds = 30
        XCTAssertThrowsError(try options.engineOptions(live: true))
        XCTAssertEqual(try options.engineOptions(live: false)["media-end-time"], "30")
        options.startSeconds = 0; options.endSeconds = 0; options.recordSeconds = -1
        XCTAssertThrowsError(try options.engineOptions())
        options.recordSeconds = 60
        XCTAssertThrowsError(try options.engineOptions(live: false))
        XCTAssertEqual(try options.engineOptions(live: true)["media-record-time"], "60")
        options.video = "none"; options.audio = "none"
        XCTAssertThrowsError(try options.engineOptions())
        options.subtitles = "best"
        XCTAssertNoThrow(try options.engineOptions())
        options.video = "opaque-muxed"; options.audio = "external-audio"
        let tracks = [MediaTrack(id: "opaque-muxed", type: "muxed"), MediaTrack(id: "external-audio", type: "audio")]
        XCTAssertThrowsError(try options.engineOptions(tracks: tracks))
        options.audio = "opaque-muxed"
        XCTAssertNoThrow(try options.engineOptions(tracks: tracks))
        options.video = "missing-id"
        XCTAssertThrowsError(try options.engineOptions(tracks: tracks))
    }

    func testTrackIDsAreOpaqueAndUnknownPropertiesRemainCompatible() throws {
        let data = Data(#"{"state":"awaiting-selection","live":"false","protocol":"hls","tracks":[{"id":"track:stable/opaque?not-a-url","type":"muxed","height":"1080","frameRate":"59.940000","bandwidth":"4500000","codec":"avc1","selected":"true","futureField":true}]}"#.utf8)
        let media = try JSONDecoder().decode(MediaTaskProgress.self, from: data)
        var selection = MediaDownloadOptions()
        selection.useInspectedDefaults(media)
        XCTAssertEqual(selection.video, "track:stable/opaque?not-a-url")
        XCTAssertEqual(selection.audio, selection.video)
        XCTAssertEqual(try selection.engineOptions(tracks: media.tracks)["media-video"], selection.video)
        XCTAssertTrue(media.tracks?.first?.title.contains("1080p") == true)
        XCTAssertTrue(media.tracks?.first?.title.contains("59.94 fps") == true)
        let old = try JSONDecoder().decode(MediaTaskProgress.self, from: Data(#"{"state":"paused"}"#.utf8))
        XCTAssertNil(old.tracks)
    }

    func testMediaCapabilityRequiresExplicitEngineSupport() {
        XCTAssertFalse(EngineCapabilities(version: "2.8.6").supportsMedia)
        XCTAssertFalse(EngineCapabilities(version: "2.8.6", enabledFeatures: ["HLS/DASH"]).supportsMedia)
        XCTAssertTrue(EngineCapabilities(version: "2.8.6", enabledFeatures: ["HLS/DASH"], mediaFeatures: ["stable-track-ids"]).supportsMedia)
    }

    func testRecordingAndRetryActionsRespectLifecycle() throws {
        var task = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"live","status":"paused","media":{"state":"paused","live":"true","completedDuration":"2000"}}"#.utf8)).toTask()
        XCTAssertTrue(task.canFinishRecording)
        task.media?.state = "finalizing"
        XCTAssertFalse(task.canFinishRecording)
        XCTAssertNil(task.primaryControlAction)
        task.status = .failed
        XCTAssertTrue(task.canRetryMedia)
        task.isAvailableInEngine = false
        XCTAssertFalse(task.canRetryMedia)
    }

    func testImportedMediaSourcesGetIndividualConfirmation() async {
        let requests = await DownloadImportReader.prepare([.text("https://example.com/file.zip\nhttps://example.com/master.m3u8\nhttps://example.com/clip.mpd")], preferences: AppPreferences())
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.resources.count == 1 })
    }
}
