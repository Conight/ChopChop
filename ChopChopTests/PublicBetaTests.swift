import Foundation
import SwiftData
import XCTest
@testable import ChopChop

final class PublicBetaTests: XCTestCase {
    func testAppVersionsRespectPrereleasePrecedenceAndRejectInvalidTags() throws {
        let versions = ["0.0.1-alpha", "0.0.1-alpha.1", "0.0.1-alpha.beta", "0.0.1-beta.1", "0.0.1-beta.2", "0.0.1-beta.10", "0.0.1-rc.1", "0.0.1", "0.0.2"]
        let parsed = try versions.map { try XCTUnwrap(AppVersion($0)) }
        XCTAssertEqual(parsed.sorted(), parsed)
        XCTAssertEqual(AppVersion("v0.0.1+build.123"), AppVersion("0.0.1"))
        for invalid in ["1.2", "01.2.3", "1.2.3-beta.01", "1.2.3-", "1.2.3+", "1.2.3/evil", "-1.2.3"] {
            XCTAssertNil(AppVersion(invalid), invalid)
        }
    }

    private func releases(_ definitions: [(String, Bool, Bool)]) throws -> Data {
        let items: [[String: Any]] = definitions.map { tag, draft, compatible in
            ["tag_name": "v" + tag, "draft": draft, "prerelease": tag.contains("-"), "body": "Release notes",
             "assets": compatible ? [["name": "ChopChop-v\(tag)-macos-arm64.dmg", "state": "uploaded", "size": 4096]] : []]
        }
        return try JSONSerialization.data(withJSONObject: items)
    }

    func testReleaseSelectionSeparatesChannelsAndRequiresReadyDMG() throws {
        let data = try releases([("0.0.2-beta.1", false, true), ("0.0.1-beta.2", false, true), ("0.0.1", false, true), ("9.0.0", true, true)])
        XCTAssertEqual(try GitHubAppReleaseClient.select(data: data, current: AppVersion("0.0.1-beta.1"))?.version, AppVersion("0.0.2-beta.1"))
        XCTAssertNil(try GitHubAppReleaseClient.select(data: data, current: AppVersion("0.0.1")))
        XCTAssertEqual(try GitHubAppReleaseClient.select(data: data, current: AppVersion("0.0.0"))?.version, AppVersion("0.0.1"))
        XCTAssertThrowsError(try GitHubAppReleaseClient.select(data: releases([("0.0.2", false, false)]), current: AppVersion("0.0.1"))) {
            XCTAssertEqual($0 as? AppUpdateError, .noCompatibleRelease)
        }
        XCTAssertThrowsError(try GitHubAppReleaseClient.select(data: Data("private server error".utf8), current: nil))
    }

    func testGitHubTransportClassifiesRateLimitsOfflineAndInvalidResponses() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReleaseURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = GitHubAppReleaseClient(session: session)
        for (status, expected) in [(403, AppUpdateError.rateLimited), (429, .rateLimited), (503, .serviceUnavailable), (200, .invalidResponse), (0, .offline)] {
            ReleaseURLProtocol.responseStatus = status
            do { _ = try await client.latest(for: AppVersion("0.0.1"), channel: .stable); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? AppUpdateError, expected) }
        }
    }

    @MainActor
    func testDailyUpdateChecksPersistAttemptsIncludingFailuresAndCanBeDisabled() async throws {
        let suite = "ChopChop-public-beta-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ReleaseStub(error: .offline)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = AppUpdateCoordinator(build: AppBuild(version: "0.0.1-beta.1"), client: client, defaults: defaults, now: { start })
        await first.check(automatically: true)
        XCTAssertEqual(first.state, .failed(.offline))
        let reopened = AppUpdateCoordinator(build: first.build, client: client, defaults: defaults, now: { start.addingTimeInterval(60) })
        await reopened.check(automatically: true)
        XCTAssertEqual(reopened.state, .idle)
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
        await reopened.check()
        XCTAssertEqual(reopened.state, .failed(.offline))
        let later = AppUpdateCoordinator(build: first.build, client: client, defaults: defaults, now: { start.addingTimeInterval(86_461) })
        later.automaticallyChecks = false
        await later.check(automatically: true)
        XCTAssertEqual(later.state, .idle)
        later.automaticallyChecks = true
        await later.check(automatically: true)
        let finalCalls = await client.calls
        XCTAssertEqual(finalCalls, 3)
    }

    @MainActor
    func testDiagnosticsCannotIncludeFreeformEngineOrTaskData() throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        let secret = "PRIVATE_DIAGNOSTIC_SENTINEL"
        store.engineSettings.rpcToken = secret
        store.engineSettings.proxyURL = "https://user:\(secret)@example.com"
        store.engineSettings.downloadDirectoryPath = "/Users/\(secret)"
        let task = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data("""
        {"gid":"\(secret)","status":"error","errorMessage":"Cookie: \(secret)","files":[{"index":"1","path":"/Users/\(secret)","length":"100","completedLength":"1"}],"uris":[{"uri":"https://example.com/?token=\(secret)"}]}
        """.utf8)).toTask()
        store.tasks = [task]
        let report = try DiagnosticReport(store: store, build: AppBuild(version: secret)).json()
        XCTAssertFalse(report.contains(secret))
        XCTAssertFalse(report.contains("example.com"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "appVersion", "macOSVersion", "architecture", "capabilitiesKnown", "capabilities", "taskCounts", "issues"])
        XCTAssertEqual((object["taskCounts"] as? [String: Int])?["failed"], 1)
    }

    @MainActor
    func testOldDiskStoreMigratesSettingsHistoryAndTombstonesWithoutChangingIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.store")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let task = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"original-gid","status":"paused","totalLength":"100","completedLength":"40"}"#.utf8)).toTask()
        var snapshot = task; snapshot.addedAt = date
        var oldSnapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        for key in ["scheduledStart", "media", "addedAtIsFirstSeen", "requiresFileSelection"] { oldSnapshot.removeValue(forKey: key) }
        let payload = try JSONSerialization.data(withJSONObject: oldSnapshot)
        try autoreleasepool {
            let schema = Schema([LegacyBetaSchema.PersistentEngineConfiguration.self, LegacyBetaSchema.PersistentAppConfiguration.self, LegacyBetaSchema.PersistentDownloadRecord.self])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = ModelContext(container)
            let engine = LegacyBetaSchema.PersistentEngineConfiguration()
            engine.rpcPort = 29099; engine.downloadDirectoryPath = "/tmp/existing-downloads"; engine.rpcToken = "saved-token"
            let app = LegacyBetaSchema.PersistentAppConfiguration()
            app.keepRunningAfterClose = false
            context.insert(engine); context.insert(app)
            context.insert(LegacyBetaSchema.PersistentDownloadRecord(gid: "original-gid", snapshot: payload))
            context.insert(LegacyBetaSchema.PersistentDownloadRecord(gid: "removed-gid", snapshot: nil, isDeleted: true))
            try context.save()
        }
        try autoreleasepool {
            let migrated = try PersistentSettingsStore(storeURL: url)
            let settings = try migrated.loadEngineSettings()
            XCTAssertEqual(settings.rpcPort, 29099)
            XCTAssertEqual(settings.downloadDirectoryPath, "/tmp/existing-downloads")
            XCTAssertEqual(settings.rpcToken, "saved-token")
            XCTAssertFalse(try migrated.loadAppPreferences().keepRunningAfterClose)
            let history = try migrated.makeHistoryStore()
            let tasks = try history.load()
            XCTAssertEqual(tasks.count, 1)
            XCTAssertEqual(tasks[0].id, "original-gid")
            XCTAssertEqual(tasks[0].addedAt, date)
            XCTAssertEqual(tasks[0].completedLength, 40)
            XCTAssertEqual(tasks[0].status, .paused)
            XCTAssertEqual(history.deletedIDs, ["removed-gid"])
            try history.save(tasks)
        }
        let reopened = try PersistentSettingsStore(storeURL: url)
        XCTAssertEqual(try reopened.makeHistoryStore().load().first?.addedAt, date)
        XCTAssertEqual(try reopened.makeHistoryStore().deletedIDs, ["removed-gid"])
    }

    func testChineseCatalogAndPersistedStatusesRemainIndependent() throws {
        let bundle = Bundle(for: DownloadStore.self)
        let path = try XCTUnwrap(bundle.path(forResource: "zh-Hans", ofType: "lproj"))
        let chinese = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(L10n.key("Downloads", bundle: chinese), "下载")
        XCTAssertEqual(L10n.key("Paused", bundle: chinese), "已暂停")
        XCTAssertEqual(String(localized: "Verifying \(50)%", bundle: chinese, locale: Locale(identifier: "zh-Hans")), "正在校验 50%")
        XCTAssertEqual(String(localized: "\(2) items", bundle: chinese, locale: Locale(identifier: "zh-Hans")), "2 项")
        let english = try XCTUnwrap(Bundle(path: XCTUnwrap(bundle.path(forResource: "en", ofType: "lproj"))))
        XCTAssertEqual(String(localized: "\(1) items", bundle: english, locale: Locale(identifier: "en")), "1 item")
        XCTAssertEqual(String(localized: "\(2) items", bundle: english, locale: Locale(identifier: "en")), "2 items")
        XCTAssertEqual(DownloadStatus.paused.rawValue, "Paused")
        XCTAssertEqual(try JSONDecoder().decode(DownloadStatus.self, from: Data(#""Paused""#.utf8)), .paused)
    }
}

private actor ReleaseStub: AppReleaseFetching {
    var calls = 0
    let error: AppUpdateError
    init(error: AppUpdateError) { self.error = error }
    func latest(for current: AppVersion?, channel: AppUpdateChannel) async throws -> AppRelease? { calls += 1; throw error }
}

private final class ReleaseURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseStatus = 200 // This XCTest suite runs serially.
    override class func canInit(with request: URLRequest) -> Bool { request.url == GitHubAppReleaseClient.endpoint }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.responseStatus
        if status == 0 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("Not a release list".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
