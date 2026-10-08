import CryptoKit
import XCTest
@testable import ChopChop

final class TorrentStorageTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private let info = Data("d6:lengthi4e4:name8:file.bin12:piece lengthi16384e6:pieces20:abcdefghijklmnopqrste".utf8)
    private var infoHash: String { Insecure.SHA1.hash(data: info).map { String(format: "%02x", $0) }.joined() }

    func testDirectoriesAreReservedWithoutReusingOrEscapingExistingFolders() throws {
        let root = try temporaryDirectory()
        let first = try TorrentStorage.createDirectory(in: root, name: "../Example/Folder")
        let second = try TorrentStorage.createDirectory(in: root, name: "../Example/Folder")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent().path, root.path)
        XCTAssertFalse(first.lastPathComponent.hasPrefix("."))
        XCTAssertLessThanOrEqual(TorrentStorage.safeName(String(repeating: "文件", count: 200)).utf8.count, 160)
        TorrentStorage.removeEmptyDirectory(first.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        try Data("keep".utf8).write(to: second.appendingPathComponent("existing.bin"))
        TorrentStorage.removeEmptyDirectory(second.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testMetadataExportPreservesInfoHashAndExcludesPrivateResumeState() throws {
        var resume = Data("d4:info".utf8); resume.append(info)
        resume.append(Data("5:peers6:secret9:save_path12:/private/tmp8:trackersll20:https://example.com/eee".utf8))
        let exported = try TorrentStorage.metainfo(from: resume, infoHash: infoHash, resume: true)
        var expected = Data("d13:announce-listll20:https://example.com/ee4:info".utf8)
        expected.append(info); expected.append(Data("e".utf8))
        XCTAssertEqual(exported, expected)
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("secret"))
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("save_path"))
        XCTAssertEqual(try TorrentStorage.metainfo(from: exported, infoHash: infoHash, resume: false), exported)
        XCTAssertThrowsError(try TorrentStorage.metainfo(from: resume, infoHash: String(repeating: "0", count: 40), resume: true))
    }

    func testMetadataScannerRejectsTruncatedOversizedAndDeepDocuments() throws {
        for invalid in [Data(), Data("d4:info9999999999999999999999:x".utf8), Data("d4:infod4:name20:shorte".utf8),
                        Data(("d4:info" + String(repeating: "l", count: 65) + String(repeating: "e", count: 66)).utf8),
                        Data(repeating: 0, count: TorrentStorage.maximumMetadataSize + 1)] {
            XCTAssertThrowsError(try TorrentStorage.metainfo(from: invalid, infoHash: infoHash, resume: true))
        }
    }

    func testCopiesNeverOverwriteUserFilesAndRetryReusesIdenticalCopy() async throws {
        let root = try temporaryDirectory()
        let existing = root.appendingPathComponent("Example.torrent")
        try Data("user file".utf8).write(to: existing)
        var torrent = Data("d4:info".utf8); torrent.append(info); torrent.append(Data("e".utf8))
        try await TorrentStorage.saveEngineCopy(infoHash: infoHash, name: "Example", directory: root,
            original: torrent, metadataURL: nil, stateDirectory: root)
        try await TorrentStorage.saveEngineCopy(infoHash: infoHash, name: "Example", directory: root,
            original: torrent, metadataURL: nil, stateDirectory: root)
        XCTAssertEqual(try Data(contentsOf: existing), Data("user file".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Example (2).torrent")), torrent)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    func testMagnetCopyReadsSavedResumeAndLeavesStateUntouched() async throws {
        let root = try temporaryDirectory()
        let state = root.appendingPathComponent("bittorrent/torrents")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        var resume = Data("d4:info".utf8); resume.append(info); resume.append(Data("e".utf8))
        let resumeURL = state.appendingPathComponent(infoHash + ".fastresume")
        try resume.write(to: resumeURL)
        try await TorrentStorage.saveEngineCopy(infoHash: infoHash, name: "Magnet", directory: root,
            original: nil, metadataURL: nil, stateDirectory: root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Magnet.torrent")), resume)
        XCTAssertEqual(try Data(contentsOf: resumeURL), resume)
    }

    func testSkippedSharedPiecesAreNotPresentedAsACompletedFile() throws {
        let root = try temporaryDirectory()
        let path = root.appendingPathComponent("skipped.bin")
        var file = DownloadFile(index: 1, path: path.path, length: 2001, completedLength: 2001, isSelected: false)
        XCTAssertNil(file.displayedProgress)
        XCTAssertFalse(file.isCompleteOnDisk)
        XCTAssertNil(DownloadFileLocation.existingFile(path.path))
        try Data(repeating: 0, count: 2001).write(to: path)
        XCTAssertFalse(file.isCompleteOnDisk, "An old skipped file is retained, not a selected completion")
        file.isSelected = true
        XCTAssertTrue(file.isCompleteOnDisk)
        XCTAssertEqual(file.displayedProgress, 1)
    }

    func testV2MagnetKeepsUsableFinderShortcutInsteadOfAnIncompleteTorrent() async throws {
        let root = try temporaryDirectory()
        let state = root.appendingPathComponent("bittorrent/torrents")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let v2Info = Data("d12:meta versioni2e4:name7:Examplee".utf8)
        let hash = SHA256.hash(data: v2Info).map { String(format: "%02x", $0) }.joined()
        var resume = Data("d4:info".utf8); resume.append(v2Info)
        resume.append(Data("8:trackersll20:https://example.com/eee".utf8))
        try resume.write(to: state.appendingPathComponent(hash + ".fastresume"))
        try await TorrentStorage.saveEngineCopy(infoHash: hash, name: "Example", directory: root,
            original: nil, metadataURL: nil, stateDirectory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Example.torrent").path))
        let bookmark = try XCTUnwrap(PropertyListSerialization.propertyList(from:
            Data(contentsOf: root.appendingPathComponent("Example.magnet.webloc")), format: nil) as? [String: String])
        let components = try XCTUnwrap(URLComponents(string: try XCTUnwrap(bookmark["URL"])))
        XCTAssertEqual(components.scheme, "magnet")
        XCTAssertEqual(components.queryItems?.first?.value, "urn:btmh:1220" + hash)
        XCTAssertEqual(components.queryItems?.last?.value, "https://example.com/")
    }

    @MainActor
    func testDisplayLocationResolvesSandboxLinkWithoutChangingTaskPaths() throws {
        let home = try temporaryDirectory().resolvingSymlinksInPath()
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let container = home.appendingPathComponent("Library/Containers/Test/Data", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let link = container.appendingPathComponent("Downloads")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: downloads)
        var task = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"path","status":"paused"}"#.utf8)).toTask()
        task.protocolKind = .bitTorrent
        task.destination = link.path
        task.files = [DownloadFile(index: 1, path: link.appendingPathComponent("Example/file.bin").path,
                                   length: 100, completedLength: 0, isSelected: true)]
        let original = try JSONEncoder().encode(task)
        let location = try XCTUnwrap(DownloadLocationDisplay.taskURL(task))
        XCTAssertEqual(location.path, downloads.appendingPathComponent("Example").path)
        XCTAssertEqual(DownloadLocationDisplay.path(location.path, home: home), "~/Downloads/Example")
        XCTAssertEqual(DownloadLocationDisplay.path(task.files[0].path, home: home), "~/Downloads/Example/file.bin")
        XCTAssertEqual(task.destination, link.path)
        XCTAssertEqual(task.files[0].path, try JSONDecoder().decode(DownloadTask.self, from: original).files[0].path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path), "Formatting must not create or move content")
        // RPC file paths may already be canonical while its directory retains the sandbox alias.
        task.files[0].path = downloads.appendingPathComponent("Example/file.bin").path
        XCTAssertEqual(DownloadLocationDisplay.taskURL(task), location)
    }

    @MainActor
    func testDisplayLocationDistinguishesDedicatedTorrentFolderAndSingleFile() throws {
        let root = try temporaryDirectory().resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("Torrent")
        let content = folder.appendingPathComponent("Nested/file.bin")
        var task = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"path","status":"paused"}"#.utf8)).toTask()
        task.destination = folder.path
        task.files = [DownloadFile(index: 1, path: content.path, length: 100, completedLength: 0, isSelected: true)]
        XCTAssertEqual(DownloadLocationDisplay.taskURL(task), content)
        task.protocolKind = .bitTorrent
        task.torrentDirectory = folder.path
        XCTAssertEqual(DownloadLocationDisplay.taskURL(task), folder)
        task.files = []
        XCTAssertEqual(DownloadLocationDisplay.taskURL(task), folder, "Metadata discovery and offline history retain their folder")
        task.torrentDirectory = nil
        task.files = [DownloadFile(index: 1, path: root.appendingPathComponent("Other/file.bin").path,
                                  length: 100, completedLength: 0, isSelected: true)]
        XCTAssertEqual(DownloadLocationDisplay.taskURL(task), folder, "Do not infer a torrent folder outside its destination")
    }

    func testDisplayPathAbbreviationUsesHomeBoundaryAndPreservesExternalPaths() throws {
        let home = try temporaryDirectory().resolvingSymlinksInPath()
        XCTAssertEqual(DownloadLocationDisplay.path(home.path, home: home), "~")
        XCTAssertEqual(DownloadLocationDisplay.path("~/Downloads/文件 name ", home: home), "~/Downloads/文件 name ")
        XCTAssertEqual(DownloadLocationDisplay.path(home.path + "-other/file", home: home), home.path + "-other/file")
        XCTAssertEqual(DownloadLocationDisplay.path("/Volumes/Offline Drive/file.zip", home: home), "/Volumes/Offline Drive/file.zip")
        XCTAssertEqual(DownloadLocationDisplay.path(""), "")
        XCTAssertNil(DownloadLocationDisplay.resolvedURL("[METADATA]example"))
        let downloads = try XCTUnwrap(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        XCTAssertTrue(DownloadLocationDisplay.path(downloads.path).hasPrefix("~/"), "Use the real user home even inside the sandbox")
    }

    @MainActor
    func testFinderTargetsAndTorrentDirectorySurviveHistoryRoundTrip() throws {
        let root = try temporaryDirectory()
        let folder = try TorrentStorage.createDirectory(in: root, name: "Example")
        let content = folder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        let file = content.appendingPathComponent("file.bin")
        try Data([0]).write(to: file)
        var task = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"a","status":"paused"}"#.utf8)).toTask()
        task.destination = root.path
        task.files = [DownloadFile(index: 1, path: file.path, length: 1, completedLength: 1, isSelected: true)]
        XCTAssertEqual(DownloadFileLocation.revealURL(for: task), file)
        task.protocolKind = .bitTorrent
        XCTAssertEqual(DownloadFileLocation.revealURL(for: task), content)
        task.destination = folder.path; task.torrentDirectory = folder.path
        XCTAssertEqual(DownloadFileLocation.revealURL(for: task), folder)
        let saved = try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(saved.torrentDirectory, folder.path)
        var incoming = task; incoming.torrentDirectory = nil
        let merged = try XCTUnwrap(DownloadHistoryStore.merge([incoming], existing: [saved], hidden: []).first)
        XCTAssertEqual(merged.torrentDirectory, folder.path)
        XCTAssertEqual(DownloadTaskFileTrash.plan(for: merged).primaryTargets, [folder])
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        old.removeValue(forKey: "torrentDirectory")
        XCTAssertNil(try JSONDecoder().decode(DownloadTask.self, from: JSONSerialization.data(withJSONObject: old)).torrentDirectory)
        try FileManager.default.removeItem(at: file)
        incoming.protocolKind = .http; incoming.torrentDirectory = nil
        XCTAssertEqual(DownloadFileLocation.revealURL(for: incoming), folder)
    }
}
