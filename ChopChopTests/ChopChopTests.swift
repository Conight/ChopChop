//
//  ChopChopTests.swift
//  ChopChopTests
//
//  Created by Conight on 3/6/26.
//

import Foundation
import Darwin
import Combine
import SystemConfiguration
import AppKit
import SwiftUI
import XCTest
@testable import ChopChop

final class ChopChopTests: XCTestCase {

    func testDetectsSupportedProtocols() {
        XCTAssertEqual(AddDownloadDraft(rawInput: "https://example.com/file.iso").detectedProtocol, .http)
        XCTAssertNil(AddDownloadDraft(rawInput: "ftp://example.com/file.zip").detectedProtocol)
        XCTAssertEqual(AddDownloadDraft(rawInput: "sftp://example.com/file.zip").detectedProtocol, .sftp)
        XCTAssertEqual(AddDownloadDraft(rawInput: "magnet:?xt=urn:btih:abc").detectedProtocol, .magnet)
        XCTAssertEqual(AddDownloadDraft(rawInput: "ed2k://|file|demo|1|hash|/").detectedProtocol, .ed2k)
        XCTAssertEqual(AddDownloadDraft(rawInput: "https://example.com/file.meta4").detectedProtocol, .metalink)
        XCTAssertEqual(AddDownloadDraft(rawInput: "https://example.com/linux.torrent?token=abc").detectedProtocol, .bitTorrent)
        XCTAssertEqual(AddDownloadDraft(rawInput: "0123456789abcdef0123456789abcdef01234567").detectedProtocol, .magnet)
        XCTAssertEqual(AddDownloadDraft(rawInput: "thunder://QUFodHRwczovL2V4YW1wbGUuY29tL2ZpbGUuaXNvWlo=").detectedProtocol, .thunder)
        XCTAssertNil(AddDownloadDraft(rawInput: "not a url").detectedProtocol)
    }

    func testProtocolSymbolsUseAvailableSystemSymbolNames() {
        XCTAssertEqual(TaskProtocol.magnet.symbolName, "link.circle")
        XCTAssertNotEqual(TaskProtocol.magnet.symbolName, "magnet")
    }

    func testNormalizesBareInfoHashAndThunderLinks() throws {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        XCTAssertEqual(
            try AddDownloadDraft.normalizedResource(hash),
            "magnet:?xt=urn:btih:\(hash)"
        )
        XCTAssertEqual(
            try AddDownloadDraft.normalizedResource("thunder://QUFodHRwczovL2V4YW1wbGUuY29tL2ZpbGUuaXNvWlo="),
            "https://example.com/file.iso"
        )
    }

    func testAddDownloadDraftRequiresPositiveSpeedLimitWhenEnabled() {
        var draft = AddDownloadDraft(rawInput: "https://example.com/file.iso")
        XCTAssertTrue(draft.isSubmittable)

        draft.limitSpeed = true
        draft.speedLimitKB = 0
        XCTAssertFalse(draft.isSubmittable)

        draft.speedLimitKB = 128
        XCTAssertTrue(draft.isSubmittable)
    }

    func testByteFormatUsesNumericZeroLabels() {
        XCTAssertEqual(ByteFormat.size(0), "0 KB")
        XCTAssertEqual(ByteFormat.size(-128), "0 KB")
        XCTAssertEqual(ByteFormat.speed(0), "0 KB/s")
        XCTAssertEqual(ByteFormat.speed(-128), "0 KB/s")
    }

    func testByteFormatDurationUsesCompactLabels() {
        XCTAssertEqual(ByteFormat.duration(18), "18s")
        XCTAssertEqual(ByteFormat.duration(138), "2m 18s")
        XCTAssertEqual(ByteFormat.duration(7_380), "2h 3m")
    }

    func testSpeedSamplesKeepTenMinuteRollingWindow() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let stale = SpeedSample(
            timestamp: now.addingTimeInterval(-(SpeedSample.rollingWindowDuration + 1)),
            downloadBytesPerSecond: 1,
            uploadBytesPerSecond: 0
        )
        let boundary = SpeedSample(
            timestamp: now.addingTimeInterval(-SpeedSample.rollingWindowDuration),
            downloadBytesPerSecond: 2,
            uploadBytesPerSecond: 0
        )
        let recent = SpeedSample(
            timestamp: now.addingTimeInterval(-30),
            downloadBytesPerSecond: 3,
            uploadBytesPerSecond: 0
        )

        let samples = SpeedSample.rollingWindowSamples([stale, boundary, recent], now: now)

        XCTAssertEqual(samples.map(\.downloadBytesPerSecond), [2, 3])
    }

    func testEngineSettingsRequireExplicitRuntimeInputs() {
        var settings = EngineSettings()
        XCTAssertEqual(settings.downloadDirectoryPath, EngineSettings.defaultDownloadDirectoryPath)
        XCTAssertNil(settings.downloadDirectoryBookmark)
        XCTAssertFalse(settings.canLaunch)
        XCTAssertEqual(
            settings.missingLaunchRequirements,
            ["Generate an RPC token"]
        )

        settings.rpcToken = "token"
        XCTAssertTrue(settings.canLaunch)

        settings.downloadDirectoryPath = "/tmp/downloads"
        settings.downloadDirectoryBookmark = nil
        XCTAssertFalse(settings.canLaunch)
        XCTAssertEqual(settings.missingLaunchRequirements, ["Choose a default download folder"])

        settings.downloadDirectoryBookmark = Data([1])
        XCTAssertTrue(settings.canLaunch)
        XCTAssertTrue(settings.missingLaunchRequirements.isEmpty)

        settings.rpcPort = 0
        XCTAssertFalse(settings.canLaunch)
        XCTAssertEqual(settings.missingLaunchRequirements, ["Set RPC port between 1 and 65535"])

        settings.rpcPort = 65_536
        XCTAssertFalse(settings.canLaunch)
        XCTAssertEqual(settings.missingLaunchRequirements, ["Set RPC port between 1 and 65535"])

        settings.rpcPort = EngineSettings.defaultRPCPort
        XCTAssertTrue(settings.canLaunch)
        XCTAssertNoThrow(try settings.validateLaunchRequirements())
    }

    func testDefaultDownloadDirectoryCanonicalizesSandboxAlias() throws {
        let searchPathURL = try XCTUnwrap(
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        )
        let canonicalPath = searchPathURL.resolvingSymlinksInPath().standardizedFileURL.path

        XCTAssertEqual(EngineSettings.defaultDownloadDirectoryPath, canonicalPath)
        XCTAssertTrue(EngineSettings.isDefaultDownloadDirectoryPath(searchPathURL.path))
        XCTAssertTrue(EngineSettings.isDefaultDownloadDirectoryPath(canonicalPath))
    }

    func testSystemProxyDetectorPrefersHTTPProxyAndBuildsBypassList() {
        let info = SystemProxyDetector.proxyInfo(from: [
            kSCPropNetProxiesHTTPEnable as String: 1,
            kSCPropNetProxiesHTTPProxy as String: " 127.0.0.1 ",
            kSCPropNetProxiesHTTPPort as String: 7_890,
            kSCPropNetProxiesHTTPSEnable as String: 1,
            kSCPropNetProxiesHTTPSProxy as String: "https-proxy.local",
            kSCPropNetProxiesHTTPSPort as String: 8_443,
            kSCPropNetProxiesExceptionsList as String: ["localhost", "*.local", "localhost"],
            kSCPropNetProxiesExcludeSimpleHostnames as String: 1
        ])

        XCTAssertEqual(info?.server, "http://127.0.0.1:7890")
        XCTAssertEqual(info?.bypass, "localhost,*.local,<local>")
        XCTAssertFalse(info?.isSocks ?? true)
    }

    func testSystemProxyDetectorFlagsSOCKSProxyWhenOnlySOCKSIsAvailable() {
        let info = SystemProxyDetector.proxyInfo(from: [
            kSCPropNetProxiesSOCKSEnable as String: NSNumber(value: 1),
            kSCPropNetProxiesSOCKSProxy as String: "127.0.0.1",
            kSCPropNetProxiesSOCKSPort as String: NSNumber(value: 10_890)
        ])

        XCTAssertEqual(info?.server, "socks5://127.0.0.1:10890")
        XCTAssertTrue(info?.isSocks ?? false)
    }

    @MainActor
    func testPersistentSettingsDefaultDownloadDirectoryIsDownloads() throws {
        let persistence = try PersistentSettingsStore(inMemory: true)

        let settings = try persistence.loadEngineSettings()

        XCTAssertEqual(settings.downloadDirectoryPath, EngineSettings.defaultDownloadDirectoryPath)
        XCTAssertNil(settings.downloadDirectoryBookmark)
        XCTAssertFalse(settings.missingLaunchRequirements.contains("Choose a default download folder"))
    }

    @MainActor
    func testPersistentSettingsStoreSavesRPCTokenWithEngineSettings() throws {
        let persistence = try PersistentSettingsStore(inMemory: true)
        var settings = EngineSettings()
        settings.rpcToken = "token-from-ui"
        settings.splitCount = 32
        try persistence.saveEngineSettings(settings)

        let loaded = try persistence.loadEngineSettings()

        XCTAssertEqual(loaded.rpcToken, "token-from-ui")
        XCTAssertEqual(loaded.splitCount, 32)
    }

    @MainActor
    func testPersistentSettingsStoreSavesBitTorrentSettings() throws {
        let persistence = try PersistentSettingsStore(inMemory: true)
        var settings = EngineSettings()
        settings.pauseMetadata = false
        settings.btTracker = "udp://tracker-a:6969/announce\nudp://tracker-b:6969/announce"
        settings.btTrackerAutoSync = false
        settings.btTrackerSyncIntervalHours = TrackerSyncInterval.weekly.rawValue
        settings.trackerSourceURLs = ["https://example.com/trackers.txt"]
        settings.customTrackerSourceURLs = ["https://custom.example.com/trackers.txt"]
        settings.lastTrackerSyncAt = Date(timeIntervalSince1970: 1_800)
        settings.proxyURL = "http://127.0.0.1:7890"
        settings.proxyBypass = "localhost,<local>"

        try persistence.saveEngineSettings(settings)

        let loaded = try persistence.loadEngineSettings()
        XCTAssertFalse(loaded.pauseMetadata)
        XCTAssertEqual(loaded.btTracker, settings.btTracker)
        XCTAssertFalse(loaded.btTrackerAutoSync)
        XCTAssertEqual(loaded.btTrackerSyncIntervalHours, TrackerSyncInterval.weekly.rawValue)
        XCTAssertEqual(loaded.trackerSourceURLs, ["https://example.com/trackers.txt"])
        XCTAssertEqual(loaded.customTrackerSourceURLs, ["https://custom.example.com/trackers.txt"])
        XCTAssertEqual(loaded.lastTrackerSyncAt, Date(timeIntervalSince1970: 1_800))
        XCTAssertEqual(loaded.proxyURL, "http://127.0.0.1:7890")
        XCTAssertEqual(loaded.proxyBypass, "localhost,<local>")
    }

    @MainActor
    func testPersistentSettingsStoreSavesED2KSettings() throws {
        let persistence = try PersistentSettingsStore(inMemory: true)
        var settings = EngineSettings()
        settings.ed2kListenPort = 29_140
        settings.ed2kUDPListenPort = 29_150
        settings.ed2kServer = "server.example:4661\nserver-two.example:4661"
        settings.ed2kServerMetURL = "https://example.com/server.met"
        settings.ed2kNodesDatURL = "https://example.com/nodes.dat"
        settings.ed2kBootstrapAutoSync = true
        settings.ed2kBootstrapSyncIntervalHours = TrackerSyncInterval.weekly.rawValue
        settings.lastED2KBootstrapSyncAt = Date(timeIntervalSince1970: 2_400)
        settings.ed2kUploadSlots = 7
        settings.ed2kSearchTimeoutSeconds = 60

        try persistence.saveEngineSettings(settings)

        let loaded = try persistence.loadEngineSettings()
        XCTAssertEqual(loaded.ed2kListenPort, 29_140)
        XCTAssertEqual(loaded.ed2kUDPListenPort, 29_150)
        XCTAssertEqual(loaded.ed2kServer, settings.ed2kServer)
        XCTAssertEqual(loaded.ed2kServerMetURL, "https://example.com/server.met")
        XCTAssertEqual(loaded.ed2kNodesDatURL, "https://example.com/nodes.dat")
        XCTAssertTrue(loaded.ed2kBootstrapAutoSync)
        XCTAssertEqual(loaded.ed2kBootstrapSyncIntervalHours, TrackerSyncInterval.weekly.rawValue)
        XCTAssertEqual(loaded.lastED2KBootstrapSyncAt, Date(timeIntervalSince1970: 2_400))
        XCTAssertEqual(loaded.ed2kUploadSlots, 7)
        XCTAssertEqual(loaded.ed2kSearchTimeoutSeconds, 60)
    }

    @MainActor
    func testPersistentSettingsStorePreservesDisabledED2KPorts() throws {
        let persistence = try PersistentSettingsStore(inMemory: true)
        var settings = EngineSettings()
        settings.ed2kListenPort = 0
        settings.ed2kUDPListenPort = 0

        try persistence.saveEngineSettings(settings)

        let loaded = try persistence.loadEngineSettings()
        XCTAssertEqual(loaded.ed2kListenPort, 0)
        XCTAssertEqual(loaded.ed2kUDPListenPort, 0)
    }

    @MainActor
    func testPersistentEngineConfigurationTreatsMissingRPCTokenAsUnset() {
        let record = PersistentEngineConfiguration()
        record.rpcToken = nil

        let settings = record.engineSettings()

        XCTAssertEqual(settings.rpcToken, "")
        XCTAssertFalse(settings.canLaunch)
        XCTAssertEqual(settings.missingLaunchRequirements, ["Generate an RPC token"])
    }

    @MainActor
    func testPersistentSettingsStoreSavesAppPreferences() throws {
        let persistence = try PersistentSettingsStore(inMemory: true)
        var preferences = AppPreferences()
        preferences.showMenuBar = false
        preferences.autoOrganizeFiles = true
        preferences.preventSleepDuringActiveDownloads = true
        preferences.captureMinimumSizeMB = 128
        preferences.suppressRemoveConfirmation = true
        preferences.deleteFilesWhenSkippingRemoveConfirmation = true

        try persistence.saveAppPreferences(preferences)
        let loaded = try persistence.loadAppPreferences()

        XCTAssertFalse(loaded.showMenuBar)
        XCTAssertTrue(loaded.autoOrganizeFiles)
        XCTAssertTrue(loaded.preventSleepDuringActiveDownloads)
        XCTAssertEqual(loaded.captureMinimumSizeMB, 128)
        XCTAssertTrue(loaded.suppressRemoveConfirmation)
        XCTAssertTrue(loaded.deleteFilesWhenSkippingRemoveConfirmation)
    }

    @MainActor
    func testManagedEngineRejectsInvalidRPCPortBeforeLaunch() async {
        let controller = Aria2NextEngineController()
        var settings = EngineSettings()
        settings.rpcToken = "token"
        settings.rpcPort = 65_536

        do {
            _ = try await controller.start(settings: settings)
            XCTFail("Expected invalidRPCPort")
        } catch {
            guard case EngineError.invalidRPCPort(65_536) = error else {
                XCTFail("Expected invalidRPCPort, got \(error)")
                return
            }
        }
    }

    func testProgressIsClampedAndSafeForZeroLength() {
        let emptyFile = DownloadFile(path: "empty", length: 0, completedLength: 100, isSelected: true)
        XCTAssertEqual(emptyFile.progress, 0)

        let overCompleteFile = DownloadFile(path: "done", length: 100, completedLength: 150, isSelected: true)
        XCTAssertEqual(overCompleteFile.progress, 1)

        let task = makeTask(status: .active, totalLength: 100, completedLength: 150)
        XCTAssertEqual(task.progress, 1)
    }

    func testRPCClientBuildsTokenPrefixedPayload() throws {
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:6800/jsonrpc"))
        let client = Aria2RPCClient(endpoint: endpoint, token: "secret")
        let request = try client.makeRequest(
            method: "aria2.addUri",
            params: [["https://example.com/file.iso"], ["dir": "/tmp/downloads"]]
        )

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(payload["method"] as? String, "aria2.addUri")

        let params = try XCTUnwrap(payload["params"] as? [Any])
        XCTAssertEqual(params.count, 3)
        XCTAssertEqual(params[0] as? String, "token:secret")
        XCTAssertEqual(params[1] as? [String], ["https://example.com/file.iso"])
        XCTAssertEqual(params[2] as? [String: String], ["dir": "/tmp/downloads"])
    }

    func testRPCClientRequiresExplicitTokenBeforeRequest() throws {
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:6800/jsonrpc"))
        let client = Aria2RPCClient(endpoint: endpoint, token: "   ")

        XCTAssertThrowsError(try client.makeRequest(method: "aria2.getGlobalStat", params: [])) { error in
            guard case RPCError.tokenMissing = error else {
                XCTFail("Expected tokenMissing, got \(error)")
                return
            }
        }
    }

    func testRPCClientRejectsInvalidPort() {
        XCTAssertThrowsError(try Aria2RPCClient(port: 65_536, token: "secret")) { error in
            guard case RPCError.invalidPort(65_536) = error else {
                XCTFail("Expected invalidPort, got \(error)")
                return
            }
        }
    }

    func testRPCClientPauseSendsTokenAndGID() async throws {
        let capturedPayload = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            capturedPayload.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"pause","result":"gid-active"}"#
            )
        }

        try await client.pause("gid-active")

        let payload = try XCTUnwrap(capturedPayload.value())
        XCTAssertEqual(payload["method"] as? String, "aria2.pause")
        let params = try XCTUnwrap(payload["params"] as? [Any])
        XCTAssertEqual(params.count, 2)
        XCTAssertEqual(params[0] as? String, "token:secret")
        XCTAssertEqual(params[1] as? String, "gid-active")
    }

    func testRPCClientForcePauseSendsForcePauseMethod() async throws {
        let capturedPayload = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            capturedPayload.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"force-pause","result":"gid-active"}"#
            )
        }

        try await client.forcePause("gid-active")

        let payload = try XCTUnwrap(capturedPayload.value())
        XCTAssertEqual(payload["method"] as? String, "aria2.forcePause")
        let params = try XCTUnwrap(payload["params"] as? [Any])
        XCTAssertEqual(params[0] as? String, "token:secret")
        XCTAssertEqual(params[1] as? String, "gid-active")
    }

    func testRPCClientResumeSendsUnpauseMethod() async throws {
        let capturedPayload = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            capturedPayload.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"resume","result":"gid-paused"}"#
            )
        }

        try await client.resume("gid-paused")

        let payload = try XCTUnwrap(capturedPayload.value())
        XCTAssertEqual(payload["method"] as? String, "aria2.unpause")
        let params = try XCTUnwrap(payload["params"] as? [Any])
        XCTAssertEqual(params[1] as? String, "gid-paused")
    }

    func testRPCClientRemoveSendsRemoveMethod() async throws {
        let capturedPayload = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            capturedPayload.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"remove","result":"gid-done"}"#
            )
        }

        try await client.remove("gid-done")

        let payload = try XCTUnwrap(capturedPayload.value())
        XCTAssertEqual(payload["method"] as? String, "aria2.remove")
    }

    func testRPCClientForceRemoveSendsForceRemoveMethod() async throws {
        let capturedPayload = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            capturedPayload.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"force-remove","result":"gid-active"}"#
            )
        }

        try await client.forceRemove("gid-active")

        let payload = try XCTUnwrap(capturedPayload.value())
        XCTAssertEqual(payload["method"] as? String, "aria2.forceRemove")
        let params = try XCTUnwrap(payload["params"] as? [Any])
        XCTAssertEqual(params[0] as? String, "token:secret")
        XCTAssertEqual(params[1] as? String, "gid-active")
    }

    func testRPCClientRemoveDownloadResultSendsResultRemovalMethod() async throws {
        let capturedPayload = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            capturedPayload.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"remove-result","result":"OK"}"#
            )
        }

        try await client.removeDownloadResult("gid-completed")

        let payload = try XCTUnwrap(capturedPayload.value())
        XCTAssertEqual(payload["method"] as? String, "aria2.removeDownloadResult")
        let params = try XCTUnwrap(payload["params"] as? [Any])
        XCTAssertEqual(params[0] as? String, "token:secret")
        XCTAssertEqual(params[1] as? String, "gid-completed")
    }

    func testRPCClientSaveSessionSendsSaveSessionMethod() async throws {
        let capturedPayload = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            capturedPayload.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"save","result":"OK"}"#
            )
        }

        try await client.saveSession()

        let payload = try XCTUnwrap(capturedPayload.value())
        XCTAssertEqual(payload["method"] as? String, "aria2.saveSession")
        let params = try XCTUnwrap(payload["params"] as? [Any])
        XCTAssertEqual(params.count, 1)
        XCTAssertEqual(params[0] as? String, "token:secret")
    }

    func testRPCClientReportsAria2ServerErrorEnvelope() async throws {
        let client = try makeRPCClient { request in
            try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"pause","error":{"code":1,"message":"Unauthorized"}}"#
            )
        }

        do {
            try await client.pause("gid")
            XCTFail("Expected serverError")
        } catch RPCError.serverError(let code, let message) {
            XCTAssertEqual(code, 1)
            XCTAssertEqual(message, "Unauthorized")
        } catch {
            XCTFail("Expected serverError, got \(error)")
        }
    }

    func testRPCClientReportsAria2ServerErrorEnvelopeFromHTTP400() async throws {
        let client = try makeRPCClient { request in
            try Self.rpcHTTPResponse(
                for: request,
                statusCode: 400,
                body: #"{"id":"A24D0B14-14C0-4D5A-829E-979F51AB5FC9","jsonrpc":"2.0","error":{"code":1,"message":"Active Download not found for GID#33d1d88241432bad"}}"#
            )
        }

        do {
            try await client.remove("33d1d88241432bad")
            XCTFail("Expected serverError")
        } catch RPCError.serverError(let code, let message) {
            XCTAssertEqual(code, 1)
            XCTAssertEqual(message, "Active Download not found for GID#33d1d88241432bad")
        } catch {
            XCTFail("Expected serverError, got \(error)")
        }
    }

    func testRPCClientReportsHTTPStatusAndBody() async throws {
        let client = try makeRPCClient { request in
            try Self.rpcHTTPResponse(for: request, statusCode: 401, body: "Unauthorized")
        }

        do {
            try await client.pause("gid")
            XCTFail("Expected unexpectedHTTPStatus")
        } catch RPCError.unexpectedHTTPStatus(let code, let body) {
            XCTAssertEqual(code, 401)
            XCTAssertEqual(body, "Unauthorized")
            XCTAssertEqual(errorDescription(RPCError.unexpectedHTTPStatus(code: code, body: body)), "Aria2 RPC returned HTTP 401.\nUnauthorized")
        } catch {
            XCTFail("Expected unexpectedHTTPStatus, got \(error)")
        }
    }

    func testRPCClientReportsMalformedJSONWithMethodName() async throws {
        let client = try makeRPCClient { request in
            try Self.rpcHTTPResponse(for: request, body: "not-json")
        }

        do {
            try await client.pause("gid")
            XCTFail("Expected invalidResponseBody")
        } catch RPCError.invalidResponseBody(let method, let body, let reason) {
            XCTAssertEqual(method, "aria2.pause")
            XCTAssertEqual(body, "not-json")
            XCTAssertFalse(reason.isEmpty)
        } catch {
            XCTFail("Expected invalidResponseBody, got \(error)")
        }
    }

    func testRPCClientReportsMissingResultOrError() async throws {
        let client = try makeRPCClient { request in
            try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"empty"}"#)
        }

        do {
            try await client.pause("gid")
            XCTFail("Expected missingResult")
        } catch RPCError.missingResult(let method, let body) {
            XCTAssertEqual(method, "aria2.pause")
            XCTAssertEqual(body, #"{"jsonrpc":"2.0","id":"empty"}"#)
        } catch {
            XCTFail("Expected missingResult, got \(error)")
        }
    }

    func testRPCClientGlobalStatDecodesNumericStrings() async throws {
        let client = try makeRPCClient { request in
            try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"stat","result":{"downloadSpeed":"2048","uploadSpeed":"64","numActive":"1","numWaiting":"2","numStopped":"3"}}"#
            )
        }

        let stat = try await client.globalStat()

        XCTAssertEqual(stat.downloadBytesPerSecond, 2048)
        XCTAssertEqual(stat.uploadBytesPerSecond, 64)
    }

    func testRPCClientPollTasksCombinesActiveWaitingAndStopped() async throws {
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            switch payload["method"] as? String {
            case "aria2.tellActive":
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"active","result":[{"gid":"active","status":"active","totalLength":"100","completedLength":"20","downloadSpeed":"5","uploadSpeed":"0","connections":"2","dir":"/tmp","files":[{"path":"/tmp/active.iso","length":"100","completedLength":"20","selected":"true"}]}]}"#
                )
            case "aria2.tellWaiting":
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"waiting","result":[{"gid":"waiting","status":"waiting","totalLength":"200","completedLength":"0","downloadSpeed":"0","uploadSpeed":"0","connections":"0","dir":"/tmp","files":[{"path":"/tmp/waiting.iso","length":"200","completedLength":"0","selected":"true"}]}]}"#
                )
            case "aria2.tellStopped":
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"stopped","result":[{"gid":"done","status":"complete","totalLength":"300","completedLength":"300","downloadSpeed":"0","uploadSpeed":"0","connections":"0","dir":"/tmp","files":[{"path":"/tmp/done.iso","length":"300","completedLength":"300","selected":"true"}]}]}"#
                )
            default:
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"unknown","result":[]}"#)
            }
        }

        let tasks = try await client.pollTasks()

        XCTAssertEqual(tasks.map(\.id), ["active", "waiting", "done"])
        XCTAssertEqual(tasks.map(\.status), [.active, .waiting, .completed])
        XCTAssertEqual(tasks.first?.name, "active.iso")
    }

    func testRPCClientPollTasksFiltersBitTorrentMetadataPlaceholders() async throws {
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            switch payload["method"] as? String {
            case "aria2.tellActive":
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"active","result":[{"gid":"metadata-gid","status":"active","totalLength":"40582","completedLength":"0","downloadSpeed":"0","uploadSpeed":"0","connections":"0","dir":"/tmp","followedBy":["download-gid"],"files":[{"index":"1","path":"[METADATA]Example","length":"40582","completedLength":"0","selected":"true"}]},{"gid":"download-gid","status":"paused","totalLength":"100","completedLength":"0","downloadSpeed":"0","uploadSpeed":"0","connections":"0","dir":"/tmp","bittorrent":{"info":{"name":"Example"},"announceList":[["udp://tracker.example.com:1337/announce"]]},"files":[{"index":"1","path":"/tmp/Example.mp4","length":"100","completedLength":"0","selected":"true"}]}]}"#
                )
            default:
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"empty","result":[]}"#)
            }
        }

        let tasks = try await client.pollTasks()

        XCTAssertEqual(tasks.map(\.id), ["download-gid"])
        XCTAssertEqual(tasks.first?.name, "Example")
        XCTAssertEqual(tasks.first?.trackers.map(\.url), ["udp://tracker.example.com:1337/announce"])
    }

    func testRPCClientPollTasksFiltersED2KSearchPlaceholdersAndMapsED2KInfo() async throws {
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            switch payload["method"] as? String {
            case "aria2.tellActive":
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"active","result":[{"gid":"search-gid","status":"active","totalLength":"0","completedLength":"0","downloadSpeed":"0","uploadSpeed":"0","connections":"0","dir":"/tmp","ed2k":{"searchActive":true,"searchMoreResults":false,"searchResultCount":"4"},"files":[{"path":"/tmp/chopchop-ed2k-search-abc/aria2-next-ed2k-search-search-gid","length":"0","completedLength":"0","selected":"true"}]},{"gid":"ed2k-gid","status":"active","totalLength":"1024","completedLength":"128","downloadSpeed":"64","uploadSpeed":"0","connections":"3","dir":"/Downloads","ed2k":{"hash":"abcdef","name":"Demo.bin","serverCount":"10","connectedServerCount":"2","peerCount":"5","kadNodeCount":"50","kadFirewalled":false},"files":[{"path":"/Downloads/Demo.bin","length":"1024","completedLength":"128","selected":"true","uris":[{"uri":"ed2k://|file|Demo.bin|1024|abcdef|/"}]}]}]}"#
                )
            default:
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"empty","result":[]}"#)
            }
        }

        let tasks = try await client.pollTasks()

        XCTAssertEqual(tasks.map(\.id), ["ed2k-gid"])
        XCTAssertEqual(tasks.first?.protocolKind, .ed2k)
        XCTAssertEqual(tasks.first?.name, "Demo.bin")
        XCTAssertEqual(tasks.first?.infoHash, "abcdef")
        XCTAssertTrue(tasks.first?.recentLogs.contains("Sources: 5") == true)
        XCTAssertTrue(tasks.first?.recentLogs.contains("Kad firewalled: No") == true)
    }

    func testRPCClientGetPeersDecodesPeerDetails() async throws {
        let capturedGID = LockedBox<String?>(nil)
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            XCTAssertEqual(payload["method"] as? String, "aria2.getPeers")
            let params = try XCTUnwrap(payload["params"] as? [Any])
            capturedGID.set(params[1] as? String)
            return try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"peers","result":[{"ip":"203.0.113.10","port":"51413","seeder":"true","downloadSpeed":"2048"},{"ip":"198.51.100.7","port":"6881","seeder":"false","downloadSpeed":"512"}]}"#
            )
        }

        let peers = try await client.getPeers("download-gid")

        XCTAssertEqual(capturedGID.value(), "download-gid")
        XCTAssertEqual(peers.map(\.address), ["203.0.113.10:51413", "198.51.100.7:6881"])
        XCTAssertEqual(peers.map(\.client), ["Seeder", "Peer"])
        XCTAssertEqual(peers.map(\.downloadSpeed), [2048, 512])
    }

    func testRPCClientPollTasksUsesMotrixSizedWaitingAndStoppedLimits() async throws {
        let capturedParams = LockedBox<[String: [Any]]>([:])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            let method = try XCTUnwrap(payload["method"] as? String)
            if let params = payload["params"] as? [Any] {
                var stored = capturedParams.value()
                stored[method] = params
                capturedParams.set(stored)
            }
            switch method {
            case "aria2.getGlobalStat":
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"stat","result":{"downloadSpeed":"0","uploadSpeed":"0","numActive":"0","numWaiting":"0","numStopped":"0"}}"#
                )
            default:
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"empty","result":[]}"#)
            }
        }

        _ = try await client.pollTasks()

        let waiting = try XCTUnwrap(capturedParams.value()["aria2.tellWaiting"])
        let stopped = try XCTUnwrap(capturedParams.value()["aria2.tellStopped"])
        XCTAssertEqual(waiting[2] as? Int, 1000)
        XCTAssertEqual(stopped[2] as? Int, 1000)
    }

    func testRPCClientPollTasksFallsBackToURINameWhenAria2PathIsRoot() async throws {
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            switch payload["method"] as? String {
            case "aria2.tellActive":
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"active","result":[{"gid":"hetzner","status":"active","totalLength":"0","completedLength":"0","downloadSpeed":"0","uploadSpeed":"0","connections":"0","dir":"/Users/conight/Downloads","files":[{"path":"/","length":"0","completedLength":"0","selected":"true","uris":[{"uri":"https://ash-speed.hetzner.com/10GB.bin"}]}]}]}"#
                )
            default:
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"empty","result":[]}"#)
            }
        }

        let tasks = try await client.pollTasks()

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.name, "10GB.bin")
        XCTAssertEqual(tasks.first?.protocolKind, .http)
        XCTAssertEqual(tasks.first?.destination, "/Users/conight/Downloads")
    }

    func testRPCClientPollTasksMapsActiveSeederAsSharing() async throws {
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            switch payload["method"] as? String {
            case "aria2.tellActive":
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"active","result":[{"gid":"seed","status":"active","seeder":"true","totalLength":"100","completedLength":"100","downloadSpeed":"0","uploadSpeed":"10","connections":"1","dir":"/tmp","bittorrent":{"info":{"name":"Linux.iso"}},"files":[{"path":"/tmp/Linux.iso","length":"100","completedLength":"100","selected":"true"}]}]}"#
                )
            default:
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"empty","result":[]}"#)
            }
        }

        let tasks = try await client.pollTasks()

        XCTAssertEqual(tasks.count, 1)
        XCTAssertTrue(tasks[0].isSharing)
        XCTAssertEqual(tasks[0].protocolKind, .bitTorrent)
    }

    func testRPCClientAddDownloadUsesFallbackDirectory() async throws {
        let capturedPayload = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            capturedPayload.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"add","result":"gid-new"}"#)
        }
        let draft = AddDownloadDraft(rawInput: "https://example.com/file.iso")

        let gid = try await client.addDownload(draft, fallbackDirectory: "/Users/conight/Downloads")

        XCTAssertEqual(gid, "gid-new")
        let payload = try XCTUnwrap(capturedPayload.value())
        let params = try XCTUnwrap(payload["params"] as? [Any])
        XCTAssertEqual(params[0] as? String, "token:secret")
        XCTAssertEqual(params[1] as? [String], ["https://example.com/file.iso"])
        let options = try XCTUnwrap(params[2] as? [String: String])
        XCTAssertEqual(options["dir"], "/Users/conight/Downloads")
        XCTAssertEqual(options["pause"], "false")
        XCTAssertEqual(options["split"], "\(EngineSettings.defaultSplitCount)")
        XCTAssertEqual(options["user-agent"], EngineSettings.defaultUserAgent)
    }

    func testRPCClientAddDownloadPrefersExplicitDraftDirectoryAndOptions() async throws {
        let capturedPayload = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            capturedPayload.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"add","result":"gid-new"}"#)
        }
        let draft = AddDownloadDraft(
            rawInput: "https://example.com/file.iso",
            savePath: "/tmp/custom",
            limitSpeed: true,
            speedLimitKB: 512
        )

        _ = try await client.addDownload(draft, fallbackDirectory: "/Users/conight/Downloads")

        let payload = try XCTUnwrap(capturedPayload.value())
        let params = try XCTUnwrap(payload["params"] as? [Any])
        let options = try XCTUnwrap(params[2] as? [String: String])
        XCTAssertEqual(options["dir"], "/tmp/custom")
        XCTAssertEqual(options["pause"], "false")
        XCTAssertEqual(options["max-download-limit"], "512K")
        XCTAssertEqual(options["split"], "\(EngineSettings.defaultSplitCount)")
        XCTAssertEqual(options["user-agent"], EngineSettings.defaultUserAgent)
    }

    func testRPCClientAddsMagnetMetadataWithPauseMetadataAndNoInitialPause() async throws {
        let capturedPayload = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            capturedPayload.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"add","result":"metadata-gid"}"#)
        }
        let draft = AddDownloadDraft(
            rawInput: "magnet:?xt=urn:btih:BF650E61509ABA5376CB3946305B2B5270A68B17",
            savePath: "/tmp/downloads"
        )

        let gid = try await client.addBitTorrentMetadataDownload(
            draft,
            fallbackDirectory: "/Users/conight/Downloads",
            autoOrganize: false
        )

        XCTAssertEqual(gid, "metadata-gid")
        let payload = try XCTUnwrap(capturedPayload.value())
        XCTAssertEqual(payload["method"] as? String, "aria2.addUri")
        let params = try XCTUnwrap(payload["params"] as? [Any])
        XCTAssertEqual(params[1] as? [String], ["magnet:?xt=urn:btih:BF650E61509ABA5376CB3946305B2B5270A68B17"])
        let options = try XCTUnwrap(params[2] as? [String: String])
        XCTAssertEqual(options["pause-metadata"], "true")
        XCTAssertEqual(options["follow-torrent"], "true")
        XCTAssertEqual(options["dir"], "/tmp/downloads")
        XCTAssertEqual(options["pause"], "false")
    }

    func testRPCClientAddsLocalTorrentFileThroughAddTorrentPausedForSelection() async throws {
        let torrentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("torrent")
        try Data("fake torrent data".utf8).write(to: torrentURL)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: torrentURL)
        }

        let capturedPayload = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            capturedPayload.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"add","result":"torrent-gid"}"#)
        }
        let draft = AddDownloadDraft(rawInput: torrentURL.path)

        let gid = try await client.addBitTorrentMetadataDownload(
            draft,
            fallbackDirectory: "/Users/conight/Downloads",
            autoOrganize: false
        )

        XCTAssertEqual(gid, "torrent-gid")
        let payload = try XCTUnwrap(capturedPayload.value())
        XCTAssertEqual(payload["method"] as? String, "aria2.addTorrent")
        let params = try XCTUnwrap(payload["params"] as? [Any])
        XCTAssertEqual(params[1] as? String, Data("fake torrent data".utf8).base64EncodedString())
        XCTAssertEqual((params[2] as? [Any])?.count, 0)
        let options = try XCTUnwrap(params[3] as? [String: String])
        XCTAssertEqual(options["pause"], "true")
        XCTAssertEqual(options["pause-metadata"], "true")
    }

    func testRPCClientTellStatusAndGetFilesDecodeTorrentSelectionFields() async throws {
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request)
            switch method {
            case "aria2.tellStatus":
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"status","result":{"gid":"metadata","status":"active","followedBy":["download"],"dir":"/tmp","bittorrent":{"info":{"name":"Ubuntu"}},"files":[]}}"#
                )
            case "aria2.getFiles":
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"files","result":[{"index":"1","path":"/tmp/Ubuntu.iso","length":"100","completedLength":"0","selected":"true"}]}"#
                )
            default:
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"ok","result":"OK"}"#)
            }
        }

        let status = try await client.tellStatus("metadata")
        let files = try await client.getFiles("download")

        XCTAssertEqual(status.firstFollowedDownloadID, "download")
        XCTAssertEqual(status.task.name, "Ubuntu")
        XCTAssertEqual(files.first?.index, 1)
        XCTAssertEqual(files.first?.path, "/tmp/Ubuntu.iso")
    }

    @MainActor
    func testMediaInspectionThenConfirmationUsesSameGIDAndOpaqueTracks() async throws {
        try await verifyMediaConfirmation(startPaused: false)
    }

    @MainActor
    func testMediaInspectionResolvesButKeepsConfirmedPayloadPaused() async throws {
        try await verifyMediaConfirmation(startPaused: true)
    }

    @MainActor
    private func verifyMediaConfirmation(startPaused: Bool) async throws {
        let calls = LockedBox<[[String: Any]]>([])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            calls.set(calls.value() + [payload])
            let method = payload["method"] as? String ?? ""
            let body: String
            if method == "aria2.tellStatus" {
                body = #"{"result":{"gid":"media-gid","status":"paused","media":{"state":"awaiting-selection","live":"false","tracks":[{"id":"stable-video","type":"video","selected":"true"},{"id":"stable-audio","type":"audio","selected":"true"}]}}}"#
            } else { body = #"{"result":"media-gid"}"# }
            return try Self.rpcHTTPResponse(for: request, body: body)
        }
        let coordinator = MediaDownloadCoordinator()
        var added: String?
        coordinator.onAdded = { gid, _ in added = gid }
        await coordinator.inspect(AddDownloadDraft(rawInput: "https://example.com/master.m3u8", startPaused: startPaused), using: client, fallbackDirectory: "/tmp/downloads")
        XCTAssertEqual(added, "media-gid")
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(coordinator.selection.video, "stable-video")
        XCTAssertEqual(coordinator.selection.audio, "stable-audio")
        XCTAssertFalse(calls.value().contains { $0["method"] as? String == "aria2.unpause" })
        let add = try XCTUnwrap(calls.value().first)
        let params = try XCTUnwrap(add["params"] as? [Any])
        XCTAssertEqual((params[2] as? [String: String])?["media-pause-after-probe"], "true")
        XCTAssertEqual((params[2] as? [String: String])?["pause"], "false")
        coordinator.selection.format = "mkv"
        let confirmed = await coordinator.confirm(using: client, startPaused: startPaused)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(coordinator.phase, .idle)
        let mutations = calls.value().filter { ["aria2.changeOption", "aria2.unpause"].contains($0["method"] as? String ?? "") }
        XCTAssertEqual(mutations.compactMap { $0["method"] as? String }, startPaused ? ["aria2.changeOption"] : ["aria2.changeOption", "aria2.unpause"])
        let changed = try XCTUnwrap(mutations[0]["params"] as? [Any])
        XCTAssertEqual(changed[1] as? String, "media-gid")
        XCTAssertEqual((changed[2] as? [String: String])?["media-video"], "stable-video")
        XCTAssertEqual((changed[2] as? [String: String])?["media-format"], "mkv")
        XCTAssertEqual((changed[2] as? [String: String])?["media-pause-after-probe"], "false")
    }

    @MainActor
    func testCancellingMediaInspectionRemovesProvisionalTaskButKeepsRestoredTask() async throws {
        let methods = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: methods)
            let body = method == "aria2.tellStatus" ? #"{"result":{"gid":"media","status":"paused","media":{"state":"awaiting-selection","live":"true","tracks":[{"id":"track","type":"muxed","selected":"true"}]}}}"# : #"{"result":"media"}"#
            return try Self.rpcHTTPResponse(for: request, body: body)
        }
        let coordinator = MediaDownloadCoordinator()
        var discarded: String?
        coordinator.onDiscarded = { discarded = $0 }
        await coordinator.inspect(AddDownloadDraft(rawInput: "https://example.com/live.m3u8"), using: client, fallbackDirectory: nil)
        await coordinator.cancel(using: client)
        XCTAssertEqual(discarded, "media")
        XCTAssertTrue(methods.value().contains("aria2.forceRemove"))
        XCTAssertTrue(methods.value().contains("aria2.removeDownloadResult"))
        let task = try await client.tellStatus("media").task
        coordinator.restore(task, options: ["media-pause-after-probe": "true"])
        methods.set([])
        await coordinator.cancel(using: client)
        XCTAssertTrue(methods.value().isEmpty)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    @MainActor
    func testMediaInspectionTimeoutRemovesProvisionalTaskAndKeepsErrorInline() async throws {
        let methods = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: methods)
            let body = method == "aria2.tellStatus" ? #"{"result":{"gid":"pending","status":"active","media":{"state":"probing"}}}"# : #"{"result":"pending"}"#
            return try Self.rpcHTTPResponse(for: request, body: body)
        }
        let coordinator = MediaDownloadCoordinator()
        await coordinator.inspect(AddDownloadDraft(rawInput: "https://example.com/stuck.m3u8"), using: client, fallbackDirectory: nil, timeout: .zero)
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertTrue(coordinator.error?.contains("timed out") == true)
        XCTAssertTrue(methods.value().contains("aria2.forceRemove"))
        XCTAssertFalse(methods.value().contains("aria2.unpause"))
    }

    func testMediaRetryAndFinishNeverRemoveOrReAddTask() async throws {
        let methods = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            _ = try Self.captureRPCMethod(from: request, into: methods)
            return try Self.rpcHTTPResponse(for: request, body: #"{"result":"same-gid"}"#)
        }
        try await client.retryMedia("same-gid")
        try await client.finishMedia("same-gid")
        XCTAssertEqual(methods.value(), ["aria2.retryMedia", "aria2.finishMedia"])
    }

    func testRPCImportsCapturedMetalinkBytesAfterTheOriginalFileIsGone() async throws {
        let captured = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            captured.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(for: request, body: #"{"result":["file-one","file-two"]}"#)
        }
        let resource = "file:///no-longer-present/list.meta4"
        let data = Data("<metalink/>".utf8)
        var draft = AddDownloadDraft(rawInput: resource)
        draft.importedDocuments[resource] = .init(kind: .metalink, data: data)
        let gids = try await client.addDownloads(draft, fallbackDirectory: "/tmp/downloads", autoOrganize: false)
        XCTAssertEqual(gids, ["file-one", "file-two"])
        let payload = try XCTUnwrap(captured.value())
        XCTAssertEqual(payload["method"] as? String, "aria2.addMetalink")
        let params = try XCTUnwrap(payload["params"] as? [Any])
        XCTAssertEqual(params[1] as? String, data.base64EncodedString())
        XCTAssertEqual((params[2] as? [String: String])?["pause"], "false")
    }

    func testRPCImportsCapturedTorrentBytesPausedForFileSelection() async throws {
        let captured = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            captured.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(for: request, body: #"{"result":"torrent-gid"}"#)
        }
        let resource = "file:///no-longer-present/file.torrent"
        let data = Data([1, 2, 3])
        var draft = AddDownloadDraft(rawInput: resource)
        draft.importedDocuments[resource] = .init(kind: .torrent, data: data)
        let gid = try await client.addBitTorrentMetadataDownload(draft, fallbackDirectory: "/tmp/downloads", autoOrganize: false)
        XCTAssertEqual(gid, "torrent-gid")
        let payload = try XCTUnwrap(captured.value())
        XCTAssertEqual(payload["method"] as? String, "aria2.addTorrent")
        let params = try XCTUnwrap(payload["params"] as? [Any])
        XCTAssertEqual(params[1] as? String, data.base64EncodedString())
        let options = try XCTUnwrap(params[3] as? [String: String])
        XCTAssertEqual(options["pause"], "true")
        XCTAssertEqual(options["force-save"], "true")
    }

    func testRPCRejectsManuallyMixedLocalDocumentsBeforeAddingAnyTasks() async throws {
        let client = try makeRPCClient { request in
            XCTFail("Mixed local documents must enter separate confirmation sheets")
            return try Self.rpcHTTPResponse(for: request, body: #"{"result":"unexpected"}"#)
        }
        let draft = AddDownloadDraft(rawInput: "https://example.com/file\nfile:///tmp/list.meta4")
        do {
            _ = try await client.addDownloads(draft, fallbackDirectory: nil, autoOrganize: false)
            XCTFail("Expected a review error")
        } catch DownloadDraftError.documentRequiresSingleResource {}
    }

    func testRPCClientAddDownloadsSubmitsIndependentTasksForMultipleLines() async throws {
        let capturedPayloads = LockedBox<[[String: Any]]>([])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            var payloads = capturedPayloads.value()
            payloads.append(payload)
            capturedPayloads.set(payloads)
            let count = payloads.count
            return try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"add","result":"gid-\#(count)"}"#
            )
        }
        let draft = AddDownloadDraft(rawInput: "https://example.com/one.iso\nhttps://example.com/two.zip")

        let gids = try await client.addDownloads(draft, fallbackDirectory: "/Users/conight/Downloads", autoOrganize: false)

        XCTAssertEqual(gids, ["gid-1", "gid-2"])
        let payloads = capturedPayloads.value()
        XCTAssertEqual(payloads.count, 2)
        let firstParams = try XCTUnwrap(payloads[0]["params"] as? [Any])
        let secondParams = try XCTUnwrap(payloads[1]["params"] as? [Any])
        XCTAssertEqual(firstParams[1] as? [String], ["https://example.com/one.iso"])
        XCTAssertEqual(secondParams[1] as? [String], ["https://example.com/two.zip"])
    }

    func testRPCClientAddDownloadsCanSubmitMirrorGroup() async throws {
        let capturedPayload = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            capturedPayload.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"add","result":"gid-mirror"}"#)
        }
        let draft = AddDownloadDraft(
            rawInput: "https://mirror1.example.com/file.iso\nhttps://mirror2.example.com/file.iso",
            outputName: "file.iso",
            treatLinesAsMirrors: true
        )

        let gids = try await client.addDownloads(draft, fallbackDirectory: "/Users/conight/Downloads", autoOrganize: false)

        XCTAssertEqual(gids, ["gid-mirror"])
        let payload = try XCTUnwrap(capturedPayload.value())
        let params = try XCTUnwrap(payload["params"] as? [Any])
        XCTAssertEqual(
            params[1] as? [String],
            ["https://mirror1.example.com/file.iso", "https://mirror2.example.com/file.iso"]
        )
        let options = try XCTUnwrap(params[2] as? [String: String])
        XCTAssertEqual(options["out"], "file.iso")
    }

    func testRPCClientInjectsED2KBootstrapContextForED2KDownloadsOnly() async throws {
        let capturedPayloads = LockedBox<[[String: Any]]>([])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            var payloads = capturedPayloads.value()
            payloads.append(payload)
            capturedPayloads.set(payloads)
            return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"add","result":"gid-new"}"#)
        }
        let context = ED2KDownloadContext(
            bootstrapPaths: ED2KBootstrapPaths(serverMetPath: "/cache/server.met", nodesDatPath: "/cache/nodes.dat"),
            serverList: "server.example:4661"
        )

        _ = try await client.addDownloads(
            AddDownloadDraft(rawInput: "ed2k://|file|demo.bin|10|0123456789abcdef0123456789abcdef|/"),
            fallbackDirectory: "/Downloads",
            autoOrganize: false,
            ed2kContext: context
        )
        _ = try await client.addDownloads(
            AddDownloadDraft(rawInput: "https://example.com/file.iso"),
            fallbackDirectory: "/Downloads",
            autoOrganize: false,
            ed2kContext: context
        )

        let ed2kParams = try XCTUnwrap(capturedPayloads.value()[0]["params"] as? [Any])
        let ed2kOptions = try XCTUnwrap(ed2kParams[2] as? [String: String])
        XCTAssertEqual(ed2kOptions["ed2k-server-list"], "/cache/server.met")
        XCTAssertEqual(ed2kOptions["ed2k-node-list"], "/cache/nodes.dat")
        XCTAssertEqual(ed2kOptions["ed2k-server"], "server.example:4661")

        let httpParams = try XCTUnwrap(capturedPayloads.value()[1]["params"] as? [Any])
        let httpOptions = try XCTUnwrap(httpParams[2] as? [String: String])
        XCTAssertNil(httpOptions["ed2k-server-list"])
        XCTAssertNil(httpOptions["ed2k-node-list"])
        XCTAssertNil(httpOptions["ed2k-server"])
    }

    func testRPCClientED2KSearchMethodsUseAria2NextMethodNames() async throws {
        let capturedPayloads = LockedBox<[[String: Any]]>([])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            var payloads = capturedPayloads.value()
            payloads.append(payload)
            capturedPayloads.set(payloads)
            switch payload["method"] as? String {
            case "ed2kSearch":
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"search","result":"search-gid"}"#)
            case "getEd2kSearchResults":
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"results","result":{"gid":"search-gid","moreResults":false,"results":[{"hash":"abcdef","name":"Demo","length":"1024","sourceCount":"3","completeSourceCount":"2","ed2kLink":"ed2k://|file|Demo|1024|abcdef|/"}]}}"#
                )
            default:
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"ok","result":"OK"}"#)
            }
        }

        let gid = try await client.ed2kSearch(
            keyword: "demo",
            options: ED2KSearchOptions(fileType: .video, minSourceCount: 2),
            directory: "/tmp/search",
            context: ED2KDownloadContext(
                bootstrapPaths: ED2KBootstrapPaths(serverMetPath: "/cache/server.met", nodesDatPath: "/cache/nodes.dat"),
                serverList: "server.example:4661"
            )
        )
        let results = try await client.getED2KSearchResults(gid)
        try await client.cleanupED2KSearch(gid)

        XCTAssertEqual(gid, "search-gid")
        XCTAssertEqual(results.results?.first?.displayName, "Demo")
        XCTAssertEqual(results.results?.first?.lengthBytes, 1024)

        let searchParams = try XCTUnwrap(capturedPayloads.value()[0]["params"] as? [Any])
        XCTAssertEqual(capturedPayloads.value()[0]["method"] as? String, "ed2kSearch")
        XCTAssertEqual(searchParams[0] as? String, "token:secret")
        XCTAssertEqual(searchParams[1] as? String, "demo")
        let options = try XCTUnwrap(searchParams[2] as? [String: String])
        XCTAssertEqual(options["dir"], "/tmp/search")
        XCTAssertEqual(options["fileType"], "video")
        XCTAssertEqual(options["minSourceCount"], "2")
        XCTAssertEqual(options["ed2k-server-list"], "/cache/server.met")
        XCTAssertEqual(options["ed2k-node-list"], "/cache/nodes.dat")
        XCTAssertEqual(capturedPayloads.value()[1]["method"] as? String, "getEd2kSearchResults")
        XCTAssertEqual(capturedPayloads.value()[2]["method"] as? String, "aria2.forceRemove")
    }

    func testAddDownloadRejectsOutputNameForIndependentBatch() async throws {
        let client = try makeRPCClient { request in
            try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"add","result":"gid"}"#)
        }
        let draft = AddDownloadDraft(
            rawInput: "https://example.com/a.iso\nhttps://example.com/b.iso",
            outputName: "single.iso"
        )

        do {
            _ = try await client.addDownloads(draft, fallbackDirectory: "/Users/conight/Downloads", autoOrganize: false)
            XCTFail("Expected outputNameRequiresSingleTask")
        } catch DownloadDraftError.outputNameRequiresSingleTask {
        } catch {
            XCTFail("Expected outputNameRequiresSingleTask, got \(error)")
        }
    }

    func testRPCClientChangeGlobalOptionSendsOptions() async throws {
        let capturedPayload = LockedBox<[String: Any]?>(nil)
        let client = try makeRPCClient { request in
            capturedPayload.set(try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any]))
            return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"options","result":"OK"}"#)
        }

        try await client.changeGlobalOption(["split": "64", "max-concurrent-downloads": "6"])

        let payload = try XCTUnwrap(capturedPayload.value())
        XCTAssertEqual(payload["method"] as? String, "aria2.changeGlobalOption")
        let params = try XCTUnwrap(payload["params"] as? [Any])
        XCTAssertEqual(params[0] as? String, "token:secret")
        XCTAssertEqual(params[1] as? [String: String], ["split": "64", "max-concurrent-downloads": "6"])
    }

    func testDownloadTaskControlActionMatchesAria2State() {
        XCTAssertEqual(makeTask(status: .active).primaryControlAction, .pause)
        XCTAssertEqual(makeTask(status: .waiting).primaryControlAction, .pause)
        XCTAssertEqual(makeTask(status: .paused).primaryControlAction, .resume)
        XCTAssertNil(makeTask(status: .completed).primaryControlAction)
        XCTAssertNil(makeTask(status: .failed).primaryControlAction)
        XCTAssertNil(makeTask(status: .removed).primaryControlAction)
    }

    func testDownloadTaskRemovalActionMatchesAria2State() {
        XCTAssertEqual(makeTask(status: .active).removalAction, .removeActiveDownload)
        XCTAssertEqual(makeTask(status: .waiting).removalAction, .removeActiveDownload)
        XCTAssertEqual(makeTask(status: .paused).removalAction, .removeActiveDownload)
        XCTAssertEqual(makeTask(status: .completed).removalAction, .removeDownloadResult)
        XCTAssertEqual(makeTask(status: .failed).removalAction, .removeDownloadResult)
        XCTAssertEqual(makeTask(status: .removed).removalAction, .removeDownloadResult)
    }

    func testTaskFileTrashPlansSingleFileAndControlFile() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        let file = directory.appendingPathComponent("archive.dmg")
        let task = makeTask(
            name: "archive.dmg",
            status: .completed,
            destination: directory.path,
            files: [
                DownloadFile(path: file.path, length: 100, completedLength: 100, isSelected: true)
            ]
        )

        let plan = DownloadTaskFileTrash.plan(for: task)

        XCTAssertEqual(plan.primaryTargets.map(\.path), [file.path])
        XCTAssertEqual(plan.companionTargets.map(\.path), [file.path + ".aria2"])
    }

    func testTaskFileTrashPlansTorrentFolderOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        let folder = directory.appendingPathComponent("Linux ISO", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let firstFile = folder.appendingPathComponent("disk1.iso")
        let secondFile = folder.appendingPathComponent("disk2.iso")
        let task = makeTask(
            name: "Linux ISO",
            protocolKind: .bitTorrent,
            status: .completed,
            destination: directory.path,
            files: [
                DownloadFile(path: firstFile.path, length: 100, completedLength: 100, isSelected: true),
                DownloadFile(path: secondFile.path, length: 200, completedLength: 200, isSelected: true)
            ],
            infoHash: "abcdef123456"
        )

        let plan = DownloadTaskFileTrash.plan(for: task)

        XCTAssertEqual(plan.primaryTargets.map(\.path), [folder.path])
        XCTAssertEqual(
            plan.companionTargets.map(\.path),
            [folder.path + ".aria2", directory.appendingPathComponent("abcdef123456.aria2").path]
        )
    }

    func testTaskFileTrashRefusesToGuessWhenAria2ReportsNoFiles() {
        let task = makeTask(name: "unknown.bin", status: .completed, destination: "/tmp", files: [])

        XCTAssertThrowsError(try DownloadTaskFileTrash.moveTaskFilesToTrash(task)) { error in
            XCTAssertEqual(error as? DownloadFileTrashError, .noReportedFiles(taskName: "unknown.bin"))
        }
    }

    func testTaskFileTrashNeverTargetsBareDownloadDirectory() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        let task = makeTask(
            name: "Downloads",
            status: .completed,
            destination: directory.path,
            files: [
                DownloadFile(path: directory.path, length: 100, completedLength: 100, isSelected: true)
            ]
        )

        let plan = DownloadTaskFileTrash.plan(for: task)

        XCTAssertTrue(plan.primaryTargets.isEmpty)
        XCTAssertTrue(plan.companionTargets.isEmpty)
    }

    func testTaskRPCOperationsPauseUsesForcePauseForTorrentLikeTasks() async throws {
        let capturedMethods = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: capturedMethods)
            return try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"\#(method)","result":"gid-bt"}"#
            )
        }
        let task = makeTask(id: "gid-bt", protocolKind: .bitTorrent, status: .active)

        try await DownloadTaskRPCOperations.pause(task, using: client)

        XCTAssertEqual(capturedMethods.value(), ["aria2.forcePause"])
    }

    func testTaskRPCOperationsPauseUsesGracefulPauseForHTTPTasks() async throws {
        let capturedMethods = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: capturedMethods)
            return try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"\#(method)","result":"gid-http"}"#
            )
        }
        let task = makeTask(id: "gid-http", protocolKind: .http, status: .active)

        try await DownloadTaskRPCOperations.pause(task, using: client)

        XCTAssertEqual(capturedMethods.value(), ["aria2.pause"])
    }

    func testTaskRPCOperationsRemoveLiveTaskForceRemovesThenBestEffortPurgesResult() async throws {
        let capturedMethods = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: capturedMethods)
            return try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"\#(method)","result":"OK"}"#
            )
        }
        let task = makeTask(id: "gid-live", status: .active)

        try await DownloadTaskRPCOperations.remove(task, using: client)

        XCTAssertEqual(capturedMethods.value(), ["aria2.forceRemove", "aria2.removeDownloadResult"])
    }

    func testTaskRPCOperationsRemoveTreatsStaleLiveGIDAsAlreadyGone() async throws {
        let capturedMethods = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: capturedMethods)
            switch method {
            case "aria2.forceRemove":
                return try Self.rpcHTTPResponse(
                    for: request,
                    statusCode: 400,
                    body: #"{"jsonrpc":"2.0","id":"remove","error":{"code":1,"message":"Active Download not found for GID#gid-stale"}}"#
                )
            case "aria2.removeDownloadResult":
                return try Self.rpcHTTPResponse(
                    for: request,
                    statusCode: 400,
                    body: #"{"jsonrpc":"2.0","id":"remove-result","error":{"code":1,"message":"Download result not found for GID#gid-stale"}}"#
                )
            default:
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"noop","result":"OK"}"#)
            }
        }
        let task = makeTask(id: "gid-stale", status: .active)

        try await DownloadTaskRPCOperations.remove(task, using: client)

        XCTAssertEqual(capturedMethods.value(), ["aria2.forceRemove", "aria2.removeDownloadResult"])
    }

    func testTaskRPCOperationsRemoveTerminalRecordTreatsMissingResultAsAlreadyGone() async throws {
        let capturedMethods = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            _ = try Self.captureRPCMethod(from: request, into: capturedMethods)
            return try Self.rpcHTTPResponse(
                for: request,
                statusCode: 400,
                body: #"{"jsonrpc":"2.0","id":"remove-result","error":{"code":1,"message":"Download result not found for GID#gid-done"}}"#
            )
        }
        let task = makeTask(id: "gid-done", status: .completed)

        try await DownloadTaskRPCOperations.remove(task, using: client)

        XCTAssertEqual(capturedMethods.value(), ["aria2.removeDownloadResult"])
    }

    func testTaskRPCOperationsPauseAllForcePausesOnlyActiveAndWaitingTasks() async throws {
        let capturedMethodsAndGIDs = LockedBox<[(String, String)]>([])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            let method = try XCTUnwrap(payload["method"] as? String)
            let params = try XCTUnwrap(payload["params"] as? [Any])
            let gid = (params.count > 1 ? params[1] as? String : nil) ?? ""
            var captured = capturedMethodsAndGIDs.value()
            captured.append((method, gid))
            capturedMethodsAndGIDs.set(captured)
            return try Self.rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"pause-all","result":"\#(gid)"}"#
            )
        }
        var sharingTask = makeTask(id: "sharing", protocolKind: .bitTorrent, status: .active)
        sharingTask.isSharing = true
        let tasks = [
            makeTask(id: "active", status: .active),
            makeTask(id: "waiting", status: .waiting),
            makeTask(id: "paused", status: .paused),
            makeTask(id: "completed", status: .completed),
            sharingTask
        ]

        let pausedCount = try await DownloadTaskRPCOperations.pauseAll(tasks, using: client)

        XCTAssertEqual(pausedCount, 3)
        XCTAssertEqual(
            capturedMethodsAndGIDs.value().map { "\($0.0):\($0.1)" },
            ["aria2.forcePause:active", "aria2.forcePause:waiting", "aria2.forcePause:sharing"]
        )
    }

    func testLocalHostPortProbeRejectsInvalidPorts() {
        XCTAssertFalse(LocalHostPortProbe.canConnect(port: 0))
        XCTAssertFalse(LocalHostPortProbe.canConnect(port: 65_536))
        XCTAssertFalse(LocalHostPortProbe.canBindTCP(port: 0))
        XCTAssertFalse(LocalHostPortProbe.canBindTCP(port: 65_536))
        XCTAssertFalse(LocalHostPortProbe.canBindUDP(port: 0))
        XCTAssertFalse(LocalHostPortProbe.canBindUDP(port: 65_536))
        XCTAssertFalse(LocalHostPortProbe.isTCPPortInUse(port: 0))
        XCTAssertFalse(LocalHostPortProbe.isTCPPortInUse(port: 65_536))
        XCTAssertFalse(LocalHostPortProbe.isUDPPortInUse(port: 0))
        XCTAssertFalse(LocalHostPortProbe.isUDPPortInUse(port: 65_536))
    }

    func testLocalHostPortProbeDoesNotReportFreeLoopbackPortAsOccupied() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            XCTFail(String(cString: strerror(errno)))
            return
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        let converted = "127.0.0.1".withCString { value in
            inet_pton(AF_INET, value, &address.sin_addr)
        }
        XCTAssertEqual(converted, 1)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0, String(cString: strerror(errno)))

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let socknameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        XCTAssertEqual(socknameResult, 0, String(cString: strerror(errno)))

        let port = Int(UInt16(bigEndian: boundAddress.sin_port))
        close(descriptor)

        XCTAssertFalse(LocalHostPortProbe.canConnect(port: port))
        XCTAssertTrue(LocalHostPortProbe.canBindTCP(port: port))
        XCTAssertFalse(LocalHostPortProbe.isTCPPortInUse(port: port))
    }

    func testLocalHostPortProbeDetectsListeningLoopbackSocket() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            XCTFail(String(cString: strerror(errno)))
            return
        }
        defer { close(descriptor) }

        var reuse = Int32(1)
        let setReuseResult = withUnsafePointer(to: &reuse) { value in
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, value, socklen_t(MemoryLayout<Int32>.size))
        }
        XCTAssertEqual(setReuseResult, 0, String(cString: strerror(errno)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        let converted = "127.0.0.1".withCString { value in
            inet_pton(AF_INET, value, &address.sin_addr)
        }
        XCTAssertEqual(converted, 1)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0, String(cString: strerror(errno)))
        XCTAssertEqual(listen(descriptor, 1), 0, String(cString: strerror(errno)))

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let socknameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        XCTAssertEqual(socknameResult, 0, String(cString: strerror(errno)))

        let port = Int(UInt16(bigEndian: boundAddress.sin_port))
        XCTAssertTrue(LocalHostPortProbe.canConnect(port: port))
        XCTAssertTrue(LocalHostPortProbe.isTCPPortInUse(port: port))
    }

    func testLocalHostPortProbeDetectsBoundTCPPortBeforeListening() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            XCTFail(String(cString: strerror(errno)))
            return
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        let converted = "127.0.0.1".withCString { value in
            inet_pton(AF_INET, value, &address.sin_addr)
        }
        XCTAssertEqual(converted, 1)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0, String(cString: strerror(errno)))

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let socknameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        XCTAssertEqual(socknameResult, 0, String(cString: strerror(errno)))

        let port = Int(UInt16(bigEndian: boundAddress.sin_port))
        XCTAssertTrue(LocalHostPortProbe.isTCPPortInUse(port: port))
        XCTAssertFalse(LocalHostPortProbe.canBindTCP(port: port))
    }

    func testLocalHostPortProbeDetectsBoundUDPPort() throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            XCTFail(String(cString: strerror(errno)))
            return
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        let converted = "127.0.0.1".withCString { value in
            inet_pton(AF_INET, value, &address.sin_addr)
        }
        XCTAssertEqual(converted, 1)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0, String(cString: strerror(errno)))

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let socknameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        XCTAssertEqual(socknameResult, 0, String(cString: strerror(errno)))

        let port = Int(UInt16(bigEndian: boundAddress.sin_port))
        XCTAssertTrue(LocalHostPortProbe.isUDPPortInUse(port: port))
        XCTAssertFalse(LocalHostPortProbe.canBindUDP(port: port))
    }

    func testLaunchPortPreflightAllowsAvailableConfiguredRPCPort() throws {
        var settings = EngineSettings()
        settings.rpcPort = 29_100

        XCTAssertNoThrow(
            try EngineLaunchPortPreflight.ensureConfiguredPortsAvailable(
                settings: settings,
                isTCPPortOccupied: { _ in false },
                isUDPPortOccupied: { _ in false }
            )
        )
    }

    func testLaunchPortPreflightReportsConfiguredRPCPortWhenOccupied() {
        var settings = EngineSettings()
        settings.rpcPort = 29_100

        XCTAssertThrowsError(
            try EngineLaunchPortPreflight.ensureConfiguredPortsAvailable(
                settings: settings,
                isTCPPortOccupied: { checkedPort in checkedPort == 29_100 },
                isUDPPortOccupied: { _ in false }
            )
        ) { error in
            guard case EngineError.portAlreadyInUse(let label, let port) = error else {
                XCTFail("Expected portAlreadyInUse, got \(error)")
                return
            }
            XCTAssertEqual(label, "RPC")
            XCTAssertEqual(port, 29_100)
        }
    }

    func testLaunchPortPreflightReportsConfiguredED2KTCPPortWhenOccupied() {
        var settings = EngineSettings()
        settings.rpcPort = 29_100
        settings.ed2kListenPort = 29_140

        XCTAssertThrowsError(
            try EngineLaunchPortPreflight.ensureConfiguredPortsAvailable(
                settings: settings,
                isTCPPortOccupied: { checkedPort in checkedPort == 29_140 },
                isUDPPortOccupied: { _ in false }
            )
        ) { error in
            guard case EngineError.portAlreadyInUse(let label, let port) = error else {
                XCTFail("Expected portAlreadyInUse, got \(error)")
                return
            }
            XCTAssertEqual(label, "ED2K")
            XCTAssertEqual(port, 29_140)
        }
    }

    func testLaunchPortPreflightReportsConfiguredED2KUDPPortWhenOccupied() {
        var settings = EngineSettings()
        settings.rpcPort = 29_100
        settings.ed2kUDPListenPort = 29_150

        XCTAssertThrowsError(
            try EngineLaunchPortPreflight.ensureConfiguredPortsAvailable(
                settings: settings,
                isTCPPortOccupied: { _ in false },
                isUDPPortOccupied: { checkedPort in checkedPort == 29_150 }
            )
        ) { error in
            guard case EngineError.portAlreadyInUse(let label, let port) = error else {
                XCTFail("Expected portAlreadyInUse, got \(error)")
                return
            }
            XCTAssertEqual(label, "ED2K UDP")
            XCTAssertEqual(port, 29_150)
        }
    }

    func testLaunchPortPreflightSkipsDisabledED2KPorts() throws {
        var settings = EngineSettings()
        settings.ed2kListenPort = 0
        settings.ed2kUDPListenPort = 0
        var checkedTCPPorts: [Int] = []
        var checkedUDPPorts: [Int] = []

        try EngineLaunchPortPreflight.ensureConfiguredPortsAvailable(
            settings: settings,
            isTCPPortOccupied: { checkedPort in
                checkedTCPPorts.append(checkedPort)
                return false
            },
            isUDPPortOccupied: { checkedPort in
                checkedUDPPorts.append(checkedPort)
                return false
            }
        )

        XCTAssertEqual(checkedTCPPorts, [settings.rpcPort])
        XCTAssertTrue(checkedUDPPorts.isEmpty)
    }

    func testLifecycleWatchdogTerminatesEngineWhenParentControlChannelCloses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pidFileURL = directory.appendingPathComponent("engine.pid", isDirectory: false)
        let controlPipe = Pipe()
        setCloseOnExec(controlPipe.fileHandleForWriting)

        let wrapper = Process()
        wrapper.executableURL = URL(fileURLWithPath: "/bin/sh")
        wrapper.arguments = Aria2ProcessLifecycleWatchdog.wrapperArguments(
            engineExecutablePath: "/bin/sh",
            pidFilePath: pidFileURL.path,
            engineArguments: ["-c", "trap 'exit 0' TERM; while :; do sleep 1; done"]
        )
        wrapper.standardInput = controlPipe.fileHandleForReading
        wrapper.standardOutput = Pipe()
        wrapper.standardError = Pipe()

        try wrapper.run()
        try? controlPipe.fileHandleForReading.close()
        addTeardownBlock {
            try? controlPipe.fileHandleForWriting.close()
            if wrapper.isRunning {
                wrapper.terminate()
                wrapper.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let enginePID = try waitForProcessID(at: pidFileURL, process: wrapper)
        XCTAssertTrue(isProcessAlive(enginePID))

        try controlPipe.fileHandleForWriting.close()

        XCTAssertTrue(waitForCondition(timeout: 5) { !wrapper.isRunning })
        XCTAssertFalse(isProcessAlive(enginePID))
    }

    func testEngineStartFailureDescribesUnavailableRPCPort() {
        let error = EngineError.rpcUnavailableAfterLaunch(
            port: 6800,
            reason: "RPC port did not open before timeout."
        )

        XCTAssertEqual(
            error.localizedDescription,
            "Aria2 Next launched, but RPC did not become reachable on 127.0.0.1:6800.\nRPC port did not open before timeout."
        )
    }

    func testEngineStartFailureDescribesPortAlreadyInUse() {
        let error = EngineError.portAlreadyInUse(label: "RPC", port: EngineSettings.defaultRPCPort)

        XCTAssertEqual(
            error.localizedDescription,
            "RPC port \(EngineSettings.defaultRPCPort) is already in use. Stop the app using this port, or set a different RPC port in Settings."
        )
    }

    @MainActor
    func testVisibleTasksRespectDestinationAndSearch() {
        let store = DownloadStore()
        store.tasks = [
            makeTask(id: "active", name: "Ubuntu.iso", status: .active),
            makeTask(id: "done", name: "Movie.mkv", status: .completed),
            makeTask(id: "torrent", name: "Linux.torrent", protocolKind: .bitTorrent, status: .waiting)
        ]

        store.selectedDestination = .active
        XCTAssertEqual(store.visibleTasks.map(\.id), ["active"])

        store.selectedDestination = .torrents
        XCTAssertEqual(store.visibleTasks.map(\.id), ["torrent"])

        store.selectedDestination = .all
        store.searchQuery = "movie"
        XCTAssertEqual(store.visibleTasks.map(\.id), ["done"])
    }

    @MainActor
    func testEngineCanOpenRuntimeStartWhenInputsAreMissing() {
        let store = DownloadStore()

        XCTAssertFalse(store.engineSettings.canLaunch)
        XCTAssertTrue(store.canStartEngine)
        XCTAssertTrue(store.canRestartEngine)
    }

    @MainActor
    func testStoreSeedsDraftSavePathWithDefaultDownloads() {
        let store = DownloadStore()

        XCTAssertEqual(store.engineSettings.downloadDirectoryPath, EngineSettings.defaultDownloadDirectoryPath)
        XCTAssertEqual(store.addDraft.savePath, EngineSettings.defaultDownloadDirectoryPath)
        XCTAssertEqual(store.addDraft.splitCount, store.engineSettings.splitCount)
        XCTAssertEqual(store.addDraft.userAgent, store.engineSettings.userAgent)
    }

    @MainActor
    func testDownloadStoreRestoresEngineSettingsAndTokenAcrossInstances() throws {
        let persistence = try PersistentSettingsStore(inMemory: true)

        let firstStore = DownloadStore(settingsStore: persistence)
        var settings = firstStore.engineSettings
        settings.rpcToken = "persisted-secret"
        settings.splitCount = 48
        firstStore.engineSettings = settings

        let secondStore = DownloadStore(settingsStore: persistence)

        XCTAssertEqual(secondStore.engineSettings.rpcToken, "persisted-secret")
        XCTAssertEqual(secondStore.engineSettings.splitCount, 48)
        XCTAssertEqual(secondStore.addDraft.splitCount, 48)
    }

    @MainActor
    func testDownloadStorePreventsSleepOnlyWhileRunningActiveDownloads() throws {
        let client = try makeRPCClient { request in
            try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let powerController = MockPowerAssertionController()
        let store = try makeInjectedStore(
            engineController: MockEngineController(client: client, isRunning: true),
            powerAssertionController: powerController
        )

        store.preferences.preventSleepDuringActiveDownloads = true
        XCTAssertFalse(powerController.isAcquired)

        store.tasks = [makeTask(id: "waiting", status: .waiting)]
        XCTAssertFalse(powerController.isAcquired)

        store.tasks = [makeTask(id: "active", status: .active)]
        XCTAssertTrue(powerController.isAcquired)

        store.tasks = [makeTask(id: "paused", status: .paused)]
        XCTAssertFalse(powerController.isAcquired)
    }

    @MainActor
    func testMagnetSelectionUsesSameGIDAndPreservesMetadataAcrossRetry() async throws {
        let methods = LockedBox<[String]>([])
        let fail = LockedBox(true)
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: methods)
            switch method {
            case "aria2.addUri":
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"1","result":"same-gid"}"#)
            case "aria2.tellStatus":
                if fail.value() { throw URLError(.networkConnectionLost) }
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"1","result":{"gid":"same-gid","status":"paused","dir":"/tmp","bittorrent":{"state":"paused","fileSelectionState":"awaiting","info":{"name":"Example"}},"files":[{"index":"1","path":"/tmp/Example/movie.mp4","length":"100","selected":"true"},{"index":"2","path":"/tmp/Example/empty.txt","length":"0","selected":"true"}]}}"#)
            default: return try Self.responseForStoreMutationPoll(method: method, request: request)
            }
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        defer { store.shutdown() }
        store.addDraft.rawInput = "magnet:?xt=urn:btih:BF650E61509ABA5376CB3946305B2B5270A68B17"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.addDraft.savePath = directory.path
        await store.prepareBitTorrentFileSelection()
        XCTAssertEqual(store.bitTorrentSelectionSession?.phase, .failed)
        XCTAssertEqual(store.bitTorrentSelectionSession?.metadataTaskID, "same-gid")
        XCTAssertFalse(store.isResolvingBitTorrentFiles)
        fail.set(false)
        await store.prepareBitTorrentFileSelection()
        let session = try XCTUnwrap(store.bitTorrentSelectionSession)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.downloadTaskID, "same-gid")
        XCTAssertEqual(session.files.count, 2, "Keep valid empty files")
        XCTAssertEqual(methods.value().filter { $0 == "aria2.addUri" }.count, 1)
        XCTAssertFalse(methods.value().contains("aria2.unpause"))
        XCTAssertFalse(methods.value().contains("aria2.getFiles"))
        XCTAssertFalse(methods.value().contains("aria2.forceRemove"))
        store.setBitTorrentFileIndexes([2, 99], selected: false)
        XCTAssertEqual(store.bitTorrentSelectionSession?.selectFileOption, "1")
        store.setBitTorrentFileIndexes([99], selected: true)
        XCTAssertEqual(store.bitTorrentSelectionSession?.selectFileOption, "1")
    }

    @MainActor
    func testMagnetDiscoveryReportsPeersAndCancelsWithoutPayload() async throws {
        let methods = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: methods)
            switch method {
            case "aria2.addUri":
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"1","result":"discovery-gid"}"#)
            case "aria2.tellStatus":
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"1","result":{"gid":"discovery-gid","status":"active","bittorrent":{"state":"downloadingMetadata","numPeers":"0","connectingPeers":"3"},"files":[]}}"#)
            default: return try Self.responseForStoreMutationPoll(method: method, request: request)
            }
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        defer { store.shutdown() }
        store.addDraft.rawInput = "magnet:?xt=urn:btih:BF650E61509ABA5376CB3946305B2B5270A68B17"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.addDraft.savePath = directory.path
        let waiting = Task { await store.prepareBitTorrentFileSelection() }
        for _ in 0..<100 where store.bitTorrentSelectionSession?.diagnostics == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.bitTorrentSelectionSession?.diagnostics?.connecting, 3)
        XCTAssertEqual(store.bitTorrentSelectionSession?.phase, .loading)
        await store.cancelBitTorrentFileSelection()
        await waiting.value
        XCTAssertNil(store.bitTorrentSelectionSession)
        XCTAssertFalse(store.isResolvingBitTorrentFiles)
        XCTAssertTrue(methods.value().contains("aria2.forceRemove"))
        XCTAssertFalse(methods.value().contains("aria2.unpause"))
    }

    func testTorrentTreeKeepsIdentityGroupsAndSearchSelectionScope() throws {
        let files = [
            DownloadFile(index: 1, path: "/tmp/Bundle/Video/clip.mp4", length: 100, completedLength: 0, isSelected: true),
            DownloadFile(index: 2, path: "/tmp/Bundle/Video/notes.txt", length: 10, completedLength: 0, isSelected: true),
            DownloadFile(index: 3, path: "/tmp/Bundle/Readme.txt", length: 0, completedLength: 0, isSelected: true)
        ]
        let nodes = TorrentFileTree.nodes(files: files, destination: "/tmp")
        XCTAssertEqual(nodes.map(\.name), ["Video", "Readme.txt"])
        XCTAssertEqual(nodes[0].indexes, [1, 2])
        XCTAssertEqual(nodes[0].length, 110)
        let filtered = TorrentFileTree.matching(nodes, query: "clip")
        XCTAssertEqual(filtered.first?.indexes, [1])
        XCTAssertEqual(TorrentFileTree.leaves(filtered).map(\.name), ["clip.mp4"])
        XCTAssertEqual(filtered.first?.children?.first?.id, nodes[0].children?.first?.id)
        XCTAssertTrue(TorrentFileTree.matching(nodes, query: "absent").isEmpty)
        XCTAssertEqual(TorrentFileTree.sourceName("magnet:?xt=urn:btih:abc&dn=Example%20Files"), "Example Files")
    }

    @MainActor
    func testDownloadStoreLoadsMagnetFilesThenAppliesSelectedFilesAndResumes() async throws {
        try await verifyMagnetConfirmation(startPaused: false)
    }

    @MainActor
    func testDownloadStoreResolvesMagnetButKeepsConfirmedFilesPaused() async throws {
        try await verifyMagnetConfirmation(startPaused: true)
    }

    @MainActor
    private func verifyMagnetConfirmation(startPaused: Bool) async throws {
        let capturedCalls = LockedBox<[(String, String?, [String: String]?)]>([])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            let method = try XCTUnwrap(payload["method"] as? String)
            let params = (payload["params"] as? [Any]) ?? []
            let gid = params.count > 1 ? params[1] as? String : nil
            let options = params.compactMap { $0 as? [String: String] }.last
            var calls = capturedCalls.value()
            calls.append((method, gid, options))
            capturedCalls.set(calls)

            switch method {
            case "aria2.addUri":
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"add","result":"metadata-gid"}"#)
            case "aria2.tellStatus":
                if gid == "metadata-gid" {
                    return try Self.rpcHTTPResponse(
                        for: request,
                        body: #"{"jsonrpc":"2.0","id":"metadata","result":{"gid":"metadata-gid","status":"active","followedBy":["download-gid"],"dir":"/tmp","files":[]}}"#
                    )
                }
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"download","result":{"gid":"download-gid","status":"paused","dir":"/tmp","bittorrent":{"info":{"name":"Ubuntu"}},"files":[{"index":"1","path":"/tmp/Ubuntu.iso","length":"100","completedLength":"0","selected":"true"},{"index":"2","path":"/tmp/Readme.txt","length":"10","completedLength":"0","selected":"true"}]}}"#
                )
            case "aria2.getFiles":
                XCTAssertEqual(gid, "download-gid")
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"files","result":[{"index":"1","path":"/tmp/Ubuntu.iso","length":"100","completedLength":"0","selected":"true"},{"index":"2","path":"/tmp/Readme.txt","length":"10","completedLength":"0","selected":"true"}]}"#
                )
            default:
                return try Self.responseForStoreMutationPoll(method: method, request: request)
            }
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        store.addDraft.startPaused = startPaused
        store.addDraft.rawInput = "magnet:?xt=urn:btih:BF650E61509ABA5376CB3946305B2B5270A68B17"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.addDraft.savePath = directory.path

        let didClose = await store.submitDraft()

        XCTAssertFalse(didClose)
        let session = try XCTUnwrap(store.bitTorrentSelectionSession)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.metadataTaskID, "metadata-gid")
        XCTAssertEqual(session.downloadTaskID, "download-gid")
        XCTAssertEqual(session.taskName, "Ubuntu")
        XCTAssertEqual(session.selectedFileIndexes, Set([1, 2]))

        store.setBitTorrentFile(session.files[1], isSelected: false)
        let didConfirm = await store.confirmBitTorrentFileSelection()
        XCTAssertTrue(didConfirm)

        XCTAssertFalse(store.addDraft.startPaused, "The next new task must get the normal default")
        XCTAssertNil(store.bitTorrentSelectionSession)
        let calls = capturedCalls.value()
        XCTAssertTrue(calls.contains { $0.0 == "aria2.addUri" && $0.2?["pause-metadata"] == "true" && $0.2?["pause"] == "false" })
        XCTAssertTrue(calls.contains { $0.0 == "aria2.saveSession" })
        XCTAssertTrue(calls.contains { $0.0 == "aria2.changeOption" && $0.1 == "download-gid" && $0.2?["select-file"] == "1" })
        XCTAssertEqual(calls.contains { $0.0 == "aria2.unpause" && $0.1 == "download-gid" }, !startPaused)
        XCTAssertTrue(calls.contains { $0.0 == "aria2.removeDownloadResult" && $0.1 == "metadata-gid" })
    }

    @MainActor
    func testDownloadStoreWaitsForFollowedTorrentBeforeShowingFileSelection() async throws {
        let capturedCalls = LockedBox<[(String, String?)]>([])
        let metadataStatusCount = LockedBox(0)
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            let method = try XCTUnwrap(payload["method"] as? String)
            let params = (payload["params"] as? [Any]) ?? []
            let gid = params.count > 1 ? params[1] as? String : nil
            var calls = capturedCalls.value()
            calls.append((method, gid))
            capturedCalls.set(calls)

            switch method {
            case "aria2.addUri":
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"add","result":"metadata-gid"}"#)
            case "aria2.tellStatus":
                if gid == "metadata-gid" {
                    let count = metadataStatusCount.value()
                    metadataStatusCount.set(count + 1)
                    if count == 0 {
                        return try Self.rpcHTTPResponse(
                            for: request,
                            body: #"{"jsonrpc":"2.0","id":"metadata","result":{"gid":"metadata-gid","status":"active","dir":"/tmp","files":[{"index":"1","path":"[METADATA]Example","length":"40582","completedLength":"0","selected":"true"}]}}"#
                        )
                    }
                    return try Self.rpcHTTPResponse(
                        for: request,
                        body: #"{"jsonrpc":"2.0","id":"metadata","result":{"gid":"metadata-gid","status":"complete","followedBy":["download-gid"],"dir":"/tmp","files":[{"index":"1","path":"[METADATA]Example","length":"40582","completedLength":"40582","selected":"true"}]}}"#
                    )
                }
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"download","result":{"gid":"download-gid","status":"paused","dir":"/tmp","bittorrent":{"info":{"name":"Example"}},"files":[{"index":"1","path":"/tmp/Example.mp4","length":"264963630","completedLength":"0","selected":"true"}]}}"#
                )
            case "aria2.getFiles":
                if gid == "metadata-gid" {
                    return try Self.rpcHTTPResponse(
                        for: request,
                        body: #"{"jsonrpc":"2.0","id":"files","result":[{"index":"1","path":"[METADATA]Example","length":"40582","completedLength":"0","selected":"true"}]}"#
                    )
                }
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"files","result":[{"index":"1","path":"/tmp/Example.mp4","length":"264963630","completedLength":"0","selected":"true"}]}"#
                )
            default:
                return try Self.responseForStoreMutationPoll(method: method, request: request)
            }
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        store.addDraft.rawInput = "magnet:?xt=urn:btih:BF650E61509ABA5376CB3946305B2B5270A68B17"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.addDraft.savePath = directory.path

        let didClose = await store.submitDraft()

        XCTAssertFalse(didClose)
        let session = try XCTUnwrap(store.bitTorrentSelectionSession)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.metadataTaskID, "metadata-gid")
        XCTAssertEqual(session.downloadTaskID, "download-gid")
        XCTAssertEqual(session.files.map(\.path), ["/tmp/Example.mp4"])
        XCTAssertFalse(session.files.contains { $0.path.hasPrefix("[METADATA]") })
        XCTAssertEqual(metadataStatusCount.value(), 2)
        XCTAssertFalse(capturedCalls.value().contains { $0.0 == "aria2.getFiles" }, "tellStatus already contains the file list; do not issue redundant RPCs")
    }

    @MainActor
    func testDownloadStoreRefreshDetailsLoadsTorrentPeers() async throws {
        let capturedMethods = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: capturedMethods)
            switch method {
            case "aria2.getPeers":
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"peers","result":[{"ip":"203.0.113.10","port":"51413","seeder":"true","downloadSpeed":"2048"}]}"#
                )
            default:
                return try Self.responseForStoreMutationPoll(method: method, request: request)
            }
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        store.tasks = [
            makeTask(id: "torrent-gid", name: "Example", protocolKind: .bitTorrent)
        ]
        store.selectedTaskID = "torrent-gid"

        await store.refreshDetails(for: "torrent-gid")

        let task = try XCTUnwrap(store.selectedTask)
        XCTAssertEqual(task.peers.map(\.address), ["203.0.113.10:51413"])
        XCTAssertEqual(task.peers.map(\.client), ["Seeder"])
        XCTAssertTrue(capturedMethods.value().contains("aria2.getPeers"))
    }

    @MainActor
    func testDownloadStoreStartSelectedFilesStabilizesActiveTorrentBeforeApplyingSelection() async throws {
        let capturedCalls = LockedBox<[(String, String?, [String: String]?)]>([])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            let method = try XCTUnwrap(payload["method"] as? String)
            let params = (payload["params"] as? [Any]) ?? []
            let gid = params.count > 1 ? params[1] as? String : nil
            let options = params.compactMap { $0 as? [String: String] }.last
            var calls = capturedCalls.value()
            calls.append((method, gid, options))
            capturedCalls.set(calls)

            if method == "aria2.tellStatus" {
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"download","result":{"gid":"download-gid","status":"active","dir":"/tmp","bittorrent":{"info":{"name":"Ubuntu"}},"files":[{"index":"1","path":"/tmp/Ubuntu.iso","length":"100","completedLength":"0","selected":"true"},{"index":"2","path":"/tmp/Readme.txt","length":"10","completedLength":"0","selected":"true"}]}}"#
                )
            }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        store.bitTorrentSelectionSession = BitTorrentFileSelectionSession(
            source: "magnet:?xt=urn:btih:test",
            metadataTaskID: "metadata-gid",
            downloadTaskID: "download-gid",
            taskName: "Ubuntu",
            files: [
                DownloadFile(index: 1, path: "/tmp/Ubuntu.iso", length: 100, completedLength: 0, isSelected: true),
                DownloadFile(index: 2, path: "/tmp/Readme.txt", length: 10, completedLength: 0, isSelected: true)
            ],
            selectedFileIndexes: Set([1]),
            phase: .ready
        )

        let didConfirm = await store.confirmBitTorrentFileSelection()

        XCTAssertTrue(didConfirm)
        XCTAssertNil(store.bitTorrentSelectionSession)
        let calls = capturedCalls.value()
        XCTAssertTrue(calls.contains { $0.0 == "aria2.forcePause" && $0.1 == "download-gid" })
        XCTAssertTrue(calls.contains { $0.0 == "aria2.changeOption" && $0.1 == "download-gid" && $0.2?["select-file"] == "1" })
        XCTAssertTrue(calls.contains { $0.0 == "aria2.unpause" && $0.1 == "download-gid" })
    }

    @MainActor
    func testDownloadStoreCancelTorrentSelectionCleansMetadataAndDownloadTasks() async throws {
        let capturedCalls = LockedBox<[(String, String?)]>([])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            let method = try XCTUnwrap(payload["method"] as? String)
            let params = (payload["params"] as? [Any]) ?? []
            let gid = params.count > 1 ? params[1] as? String : nil
            var calls = capturedCalls.value()
            calls.append((method, gid))
            capturedCalls.set(calls)
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        store.bitTorrentSelectionSession = BitTorrentFileSelectionSession(
            source: "magnet:?xt=urn:btih:test",
            metadataTaskID: "metadata-gid",
            downloadTaskID: "download-gid",
            taskName: "Ubuntu",
            files: [],
            selectedFileIndexes: [],
            phase: .loading
        )

        await store.cancelBitTorrentFileSelection()

        XCTAssertNil(store.bitTorrentSelectionSession)
        XCTAssertEqual(
            capturedCalls.value().map { "\($0.0):\($0.1 ?? "")" },
            [
                "aria2.tellStatus:metadata-gid",
            "aria2.forceRemove:download-gid",
                "aria2.forceRemove:metadata-gid",
                "aria2.removeDownloadResult:download-gid",
                "aria2.removeDownloadResult:metadata-gid",
                "aria2.saveSession:"
            ]
        )
    }

    func testEngineSettingsBuildMotrixStyleStartupAndRuntimeOptions() {
        var settings = EngineSettings()
        settings.rpcToken = "secret"
        settings.maxActiveDownloads = 9
        settings.maxConnectionsPerTask = 32
        settings.splitCount = 48
        settings.maxOverallDownloadLimitKB = 1024
        settings.maxOverallUploadLimitKB = 512
        settings.btForceEncryption = true
        settings.pauseMetadata = false
        settings.btTracker = "udp://tracker-a:6969/announce\nudp://tracker-b:6969/announce\nudp://tracker-a:6969/announce"
        settings.keepSharing = true
        settings.proxyURL = "http://127.0.0.1:7890"
        settings.proxyBypass = "localhost,<local>"
        settings.ed2kListenPort = 29_140
        settings.ed2kUDPListenPort = 29_150
        settings.ed2kUploadSlots = 5
        settings.ed2kServer = "server.example:4661\nserver.example:4661\nserver-two.example:4662"

        let startup = settings.engineOptions(downloadDirectoryPath: "/Downloads", includeStartupOnly: true)
        XCTAssertEqual(startup["dir"], "/Downloads")
        XCTAssertEqual(startup["rpc-listen-port"], "\(EngineSettings.defaultRPCPort)")
        XCTAssertEqual(startup["rpc-secret"], "secret")
        XCTAssertEqual(startup["max-concurrent-downloads"], "9")
        XCTAssertEqual(startup["max-connection-per-server"], "32")
        XCTAssertEqual(startup["split"], "48")
        XCTAssertEqual(startup["max-overall-download-limit"], "1024K")
        XCTAssertEqual(startup["max-overall-upload-limit"], "512K")
        XCTAssertEqual(startup["bt-force-encryption"], "true")
        XCTAssertEqual(startup["bt-require-crypto"], "true")
        XCTAssertEqual(startup["pause-metadata"], "false")
        XCTAssertEqual(startup["bt-tracker"], "udp://tracker-a:6969/announce,udp://tracker-b:6969/announce")
        XCTAssertEqual(startup["seed-ratio"], "0")
        XCTAssertEqual(startup["all-proxy"], "http://127.0.0.1:7890")
        XCTAssertEqual(startup["no-proxy"], "localhost,<local>")
        XCTAssertEqual(startup["ed2k-listen-port"], "29140")
        XCTAssertEqual(startup["ed2k-udp-listen-port"], "29150")
        XCTAssertEqual(startup["ed2k-upload-slots"], "5")
        XCTAssertEqual(startup["ed2k-server"], "server.example:4661,server-two.example:4662")
        XCTAssertEqual(startup["file-allocation"], FileAllocationMode.trunc.rawValue)
        XCTAssertEqual(startup["check-certificate"], "true")
        if let caCertificatePath = EngineSettings.defaultCACertificatePath {
            XCTAssertEqual(startup["ca-certificate"], caCertificatePath)
        }
        XCTAssertNil(startup["seed-time"])

        let runtime = settings.hotReloadableEngineOptions(downloadDirectoryPath: "/Downloads")
        XCTAssertNil(runtime["rpc-secret"])
        XCTAssertNil(runtime["bt-force-encryption"])
        XCTAssertNil(runtime["bt-require-crypto"])
        XCTAssertNil(runtime["ed2k-listen-port"])
        XCTAssertNil(runtime["ed2k-udp-listen-port"])
        XCTAssertNil(runtime["ed2k-upload-slots"])
        XCTAssertNil(runtime["ed2k-server"])
        XCTAssertNil(runtime["check-certificate"])
        XCTAssertNil(runtime["ca-certificate"])
        XCTAssertEqual(runtime["split"], "48")
        XCTAssertEqual(runtime["max-concurrent-downloads"], "9")
        XCTAssertEqual(runtime["pause-metadata"], "false")
        XCTAssertEqual(runtime["bt-tracker"], "udp://tracker-a:6969/announce,udp://tracker-b:6969/announce")
        XCTAssertEqual(runtime["all-proxy"], "http://127.0.0.1:7890")
        XCTAssertEqual(runtime["no-proxy"], "localhost,<local>")
    }

    func testEngineSettingsAllowDisabledED2KListenPorts() {
        var settings = EngineSettings()
        settings.ed2kListenPort = 0
        settings.ed2kUDPListenPort = 0

        XCTAssertFalse(settings.missingLaunchRequirements.contains("Set ED2K listen port between 0 and 65535"))
        XCTAssertFalse(settings.missingLaunchRequirements.contains("Set ED2K UDP listen port between 0 and 65535"))

        let startup = settings.engineOptions(downloadDirectoryPath: "/Downloads", includeStartupOnly: true)
        XCTAssertEqual(startup["ed2k-listen-port"], "0")
        XCTAssertEqual(startup["ed2k-udp-listen-port"], "0")
    }

    func testTrackerTextNormalizesDeduplicatesAndReducesForAria2() {
        let text = """
        udp://tracker-a:6969/announce
        udp://tracker-b:6969/announce, udp://tracker-a:6969/announce

        https://tracker-c/announce
        """

        XCTAssertEqual(
            TrackerText.lineSeparated(from: text),
            "udp://tracker-a:6969/announce\nudp://tracker-b:6969/announce\nhttps://tracker-c/announce"
        )
        XCTAssertEqual(
            TrackerText.commaSeparated(from: text),
            "udp://tracker-a:6969/announce,udp://tracker-b:6969/announce,https://tracker-c/announce"
        )
        XCTAssertEqual(
            TrackerText.reducedCommaSeparated(from: "udp://a,udp://b,udp://c", maxLength: 16),
            "udp://a,udp://b"
        )
    }

    func testTrackerSourceURLValidatorOnlyAcceptsHTTPAndHTTPS() {
        XCTAssertTrue(TrackerSourceURLValidator.isValid("https://example.com/trackers.txt"))
        XCTAssertTrue(TrackerSourceURLValidator.isValid("http://example.com/trackers.txt"))
        XCTAssertFalse(TrackerSourceURLValidator.isValid("ftp://example.com/trackers.txt"))
        XCTAssertFalse(TrackerSourceURLValidator.isValid("https://"))
        XCTAssertFalse(TrackerSourceURLValidator.isValid(""))
    }

    func testTrackerURLValidatorAcceptsAria2TrackerSchemes() {
        XCTAssertTrue(TrackerURLValidator.isValid("udp://tracker.opentrackr.org:1337/announce"))
        XCTAssertTrue(TrackerURLValidator.isValid("https://tracker.example.com/announce"))
        XCTAssertTrue(TrackerURLValidator.isValid("http://tracker.example.com/announce"))
        XCTAssertFalse(TrackerURLValidator.isValid("ftp://tracker.example.com/announce"))
        XCTAssertFalse(TrackerURLValidator.isValid("udp://"))
        XCTAssertFalse(TrackerURLValidator.isValid(""))
    }

    func testED2KServerTextNormalizesAndRejectsInvalidServers() {
        let text = """
        server.example:4661
        server-two.example:4662, server.example:4661
        invalid-server
        """

        XCTAssertEqual(
            ED2KServerText.lineSeparated(from: text),
            "server.example:4661\nserver-two.example:4662"
        )
        XCTAssertEqual(
            ED2KServerText.commaSeparated(from: text),
            "server.example:4661,server-two.example:4662"
        )
        XCTAssertTrue(ED2KServerText.containsInvalidServer(in: text))
        XCTAssertFalse(ED2KServerText.containsInvalidServer(in: "server.example:4661"))
    }

    func testED2KBootstrapURLValidatorAcceptsOnlyHTTPAndHTTPS() {
        XCTAssertTrue(ED2KBootstrapURLValidator.isValid("https://upd.emule-security.org/server.met"))
        XCTAssertTrue(ED2KBootstrapURLValidator.isValid("http://upd.emule-security.org/nodes.dat"))
        XCTAssertFalse(ED2KBootstrapURLValidator.isValid("ftp://example.com/server.met"))
        XCTAssertFalse(ED2KBootstrapURLValidator.isValid("not-a-url"))
    }

    func testED2KBootstrapCacheWritesAndReportsStatus() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }

        let initialStatus = ED2KBootstrapCache.status(applicationSupportBase: base)
        XCTAssertFalse(initialStatus.hasUsableFiles)
        XCTAssertNil(ED2KBootstrapCache.cachedPathsIfAvailable(applicationSupportBase: base))

        let status = try ED2KBootstrapCache.write(
            ED2KBootstrapFetchResult(serverMet: Data("server".utf8), nodesDat: Data("nodes".utf8)),
            applicationSupportBase: base
        )

        XCTAssertEqual(status.serverMetSize, 6)
        XCTAssertEqual(status.nodesDatSize, 5)
        XCTAssertNotNil(status.serverMetModified)
        XCTAssertNotNil(ED2KBootstrapCache.cachedPathsIfAvailable(applicationSupportBase: base))
    }

    @MainActor
    func testStartEngineWithMissingRuntimeInputsPublishesAlertAndFailedState() async {
        let store = DownloadStore()
        var receivedAlert: UserFacingAlert?
        let cancellable = store.userAlerts.sink { alert in
            receivedAlert = alert
        }

        await store.startEngine()

        XCTAssertEqual(store.runtime.phase, .failed(EngineError.missingRPCToken.localizedDescription))
        XCTAssertEqual(store.runtime.lastError, EngineError.missingRPCToken.localizedDescription)
        XCTAssertEqual(receivedAlert?.title, "Start Engine Failed")
        XCTAssertEqual(receivedAlert?.message, EngineError.missingRPCToken.localizedDescription)
        _ = cancellable
    }

    @MainActor
    func testManualTrackerSyncStoresTrackersAndAppliesRuntimeOption() async throws {
        let capturedOptions = LockedBox<[String: String]?>(nil)
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            if payload["method"] as? String == "aria2.changeGlobalOption",
               let params = payload["params"] as? [Any],
               let options = params.compactMap({ $0 as? [String: String] }).first {
                capturedOptions.set(options)
            }
            return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"ok","result":"OK"}"#)
        }
        let fetcher = MockTrackerFetcher(
            result: TrackerSourceFetchResult(
                data: [
                    "udp://tracker-a:6969/announce\nudp://tracker-b:6969/announce",
                    "udp://tracker-b:6969/announce\nhttps://tracker-c/announce"
                ],
                failures: []
            )
        )
        let store = try makeInjectedStore(
            engineController: MockEngineController(client: client),
            trackerFetcher: fetcher
        )
        store.engineSettings.trackerSourceURLs = ["https://source.example.com/trackers.txt"]

        await store.syncBitTorrentTrackersManually()

        XCTAssertEqual(fetcher.requestedSources.value(), ["https://source.example.com/trackers.txt"])
        XCTAssertEqual(
            store.engineSettings.btTracker,
            "udp://tracker-a:6969/announce\nudp://tracker-b:6969/announce\nhttps://tracker-c/announce"
        )
        XCTAssertNotNil(store.engineSettings.lastTrackerSyncAt)
        XCTAssertEqual(
            capturedOptions.value()?["bt-tracker"],
            "udp://tracker-a:6969/announce,udp://tracker-b:6969/announce,https://tracker-c/announce"
        )
    }

    @MainActor
    func testManualTrackerSyncReportsEmptySourceSelection() async throws {
        let fetcher = MockTrackerFetcher(result: TrackerSourceFetchResult(data: [], failures: []))
        let store = try makeInjectedStore(
            engineController: MockEngineController(client: makeRPCClient { request in
                try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"ok","result":"OK"}"#)
            }),
            trackerFetcher: fetcher
        )
        store.engineSettings.trackerSourceURLs = []
        var receivedAlert: UserFacingAlert?
        let cancellable = store.userAlerts.sink { alert in
            receivedAlert = alert
        }

        await store.syncBitTorrentTrackersManually()

        XCTAssertEqual(receivedAlert?.title, "Tracker Sync Failed")
        XCTAssertEqual(receivedAlert?.message, "Select at least one tracker source.")
        XCTAssertTrue(fetcher.requestedSources.value().isEmpty)
        _ = cancellable
    }

    @MainActor
    func testManualED2KBootstrapSyncStoresCacheAndLastSync() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }

        let fetcher = MockED2KBootstrapFetcher()
        let store = try makeInjectedStore(
            engineController: MockEngineController(client: makeRPCClient { request in
                try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
            }),
            ed2kBootstrapFetcher: fetcher,
            ed2kBootstrapApplicationSupportBase: base
        )
        store.engineSettings.ed2kServerMetURL = "https://example.com/server.met"
        store.engineSettings.ed2kNodesDatURL = "https://example.com/nodes.dat"
        store.engineSettings.proxyURL = "http://127.0.0.1:7890"

        await store.syncED2KBootstrapManually()

        XCTAssertEqual(fetcher.requestedArguments.value().count, 1)
        XCTAssertEqual(fetcher.requestedArguments.value().first?.serverMetURL, "https://example.com/server.met")
        XCTAssertEqual(fetcher.requestedArguments.value().first?.nodesDatURL, "https://example.com/nodes.dat")
        XCTAssertEqual(fetcher.requestedArguments.value().first?.proxyURL, "http://127.0.0.1:7890")
        XCTAssertEqual(store.ed2kBootstrapStatus.serverMetSize, 6)
        XCTAssertEqual(store.ed2kBootstrapStatus.nodesDatSize, 5)
        XCTAssertNotNil(store.engineSettings.lastED2KBootstrapSyncAt)
        XCTAssertNotNil(ED2KBootstrapCache.cachedPathsIfAvailable(applicationSupportBase: base))
    }

    @MainActor
    func testDownloadStoreED2KSearchPollsResultsAndDownloadsSelectedResult() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        _ = try ED2KBootstrapCache.write(
            ED2KBootstrapFetchResult(serverMet: Data("server".utf8), nodesDat: Data("nodes".utf8)),
            applicationSupportBase: base
        )

        let capturedCalls = LockedBox<[(method: String, options: [String: String]?)]>([])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            let method = try XCTUnwrap(payload["method"] as? String)
            let options = (payload["params"] as? [Any])?.compactMap { $0 as? [String: String] }.last
            var calls = capturedCalls.value()
            calls.append((method, options))
            capturedCalls.set(calls)
            switch method {
            case "ed2kSearch":
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"search","result":"search-gid"}"#)
            case "getEd2kSearchResults":
                return try Self.rpcHTTPResponse(
                    for: request,
                    body: #"{"jsonrpc":"2.0","id":"results","result":{"gid":"search-gid","moreResults":false,"results":[{"hash":"abcdef","name":"Demo.bin","length":"1024","sourceCount":"5","completeSourceCount":"4","ed2kLink":"ed2k://|file|Demo.bin|1024|abcdef|/"}]}}"#
                )
            case "aria2.addUri":
                return try Self.rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"add","result":"download-gid"}"#)
            default:
                return try Self.responseForStoreMutationPoll(method: method, request: request)
            }
        }
        let store = try makeInjectedStore(
            engineController: MockEngineController(client: client),
            ed2kBootstrapApplicationSupportBase: base
        )
        store.ed2kSearchKeyword = "demo"
        store.ed2kSearchFileType = .video
        store.ed2kSearchMinSources = 2
        store.engineSettings.ed2kSearchTimeoutSeconds = 10

        await store.startED2KSearch()
        let didLoadSearchResults = await waitForMainActorCondition(timeout: 4) {
            !store.isSearchingED2K && !store.ed2kSearchResults.isEmpty
        }
        XCTAssertTrue(didLoadSearchResults)
        XCTAssertEqual(store.ed2kSearchResults.first?.displayName, "Demo.bin")

        await store.downloadED2KSearchResult(try XCTUnwrap(store.ed2kSearchResults.first))

        let searchOptions = try XCTUnwrap(capturedCalls.value().first { $0.method == "ed2kSearch" }?.options)
        XCTAssertEqual(searchOptions["fileType"], "video")
        XCTAssertEqual(searchOptions["minSourceCount"], "2")
        XCTAssertEqual(searchOptions["ed2k-server-list"]?.hasSuffix("/ChopChop/ed2k/server.met"), true)
        XCTAssertEqual(searchOptions["ed2k-node-list"]?.hasSuffix("/ChopChop/ed2k/nodes.dat"), true)

        let addOptions = try XCTUnwrap(capturedCalls.value().first { $0.method == "aria2.addUri" }?.options)
        XCTAssertEqual(addOptions["out"], "Demo.bin")
        XCTAssertEqual(addOptions["ed2k-server-list"]?.hasSuffix("/ChopChop/ed2k/server.met"), true)
        XCTAssertEqual(addOptions["ed2k-node-list"]?.hasSuffix("/ChopChop/ed2k/nodes.dat"), true)
        XCTAssertEqual(store.selectedTaskID, "download-gid")
    }

    func testPreferencesResetRemovesLegacyRuntimeKeys() {
        UserDefaults.standard.set("token", forKey: PreferenceKey.rpcToken)
        UserDefaults.standard.set(false, forKey: PreferenceKey.showMenuBar)

        PreferencesStore.reset()

        XCTAssertNil(UserDefaults.standard.object(forKey: PreferenceKey.rpcToken))
        XCTAssertNil(UserDefaults.standard.object(forKey: PreferenceKey.showMenuBar))
    }

    @MainActor
    func testPostErrorPresentsAlertAndClearsActivityMessage() {
        let store = DownloadStore()
        var receivedAlert: UserFacingAlert?
        let cancellable = store.userAlerts.sink { alert in
            receivedAlert = alert
        }
        store.postActivity("Working")

        store.postError("Exploded", title: "Install Failed")

        XCTAssertNil(store.activityMessage)
        XCTAssertEqual(receivedAlert?.title, "Install Failed")
        XCTAssertEqual(receivedAlert?.message, "Exploded")
        _ = cancellable
    }

    @MainActor
    func testAlertCanOnlyBeClaimedOnce() {
        let store = DownloadStore()
        let alert = UserFacingAlert(title: "Remove Failed", message: "Aria2 RPC error 1")

        XCTAssertTrue(store.claimAlert(alert))
        XCTAssertFalse(store.claimAlert(alert))
    }

    @MainActor
    func testStopEngineWhenStoppedPublishesAlertWithoutRuntimeMutation() async {
        let store = DownloadStore()
        var receivedAlert: UserFacingAlert?
        let cancellable = store.userAlerts.sink { alert in
            receivedAlert = alert
        }

        await store.stopEngine()

        XCTAssertEqual(store.runtime.phase, .stopped)
        XCTAssertNil(store.runtime.lastError)
        XCTAssertNil(store.activityMessage)
        XCTAssertEqual(receivedAlert?.title, "Stop Engine Failed")
        XCTAssertEqual(receivedAlert?.message, EngineError.notRunning.localizedDescription)
        _ = cancellable
    }

    @MainActor
    func testDownloadStorePauseTorrentTaskRefreshesAndSavesSessionWithoutAlert() async throws {
        let capturedMethods = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            let method = try XCTUnwrap(payload["method"] as? String)
            var captured = capturedMethods.value()
            captured.append(method)
            capturedMethods.set(captured)
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let controller = MockEngineController(client: client)
        let store = try makeInjectedStore(engineController: controller)
        var receivedAlerts: [UserFacingAlert] = []
        let cancellable = store.userAlerts.sink { receivedAlerts.append($0) }
        let task = makeTask(id: "bt-task", protocolKind: .bitTorrent, status: .active)

        await store.pause(task)

        XCTAssertEqual(capturedMethods.value().first, "aria2.forcePause")
        XCTAssertFalse(capturedMethods.value().contains("aria2.pause"))
        XCTAssertTrue(capturedMethods.value().contains("aria2.tellActive"))
        XCTAssertTrue(capturedMethods.value().contains("aria2.getGlobalStat"))
        XCTAssertTrue(capturedMethods.value().contains("aria2.saveSession"))
        XCTAssertLessThan(try XCTUnwrap(capturedMethods.value().firstIndex(of: "aria2.saveSession")), try XCTUnwrap(capturedMethods.value().firstIndex(of: "aria2.getGlobalStat")))
        XCTAssertTrue(receivedAlerts.isEmpty)
        _ = cancellable
    }

    @MainActor
    func testDownloadStoreRemoveStaleTaskRefreshesAndSavesSessionWithoutAlert() async throws {
        let capturedMethods = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            let method = try XCTUnwrap(payload["method"] as? String)
            var captured = capturedMethods.value()
            captured.append(method)
            capturedMethods.set(captured)
            switch method {
            case "aria2.forceRemove":
                return try Self.rpcHTTPResponse(
                    for: request,
                    statusCode: 400,
                    body: #"{"jsonrpc":"2.0","id":"remove","error":{"code":1,"message":"Active Download not found for GID#stale-task"}}"#
                )
            case "aria2.removeDownloadResult":
                return try Self.rpcHTTPResponse(
                    for: request,
                    statusCode: 400,
                    body: #"{"jsonrpc":"2.0","id":"remove-result","error":{"code":1,"message":"Download result not found for GID#stale-task"}}"#
                )
            default:
                return try Self.responseForStoreMutationPoll(method: method, request: request)
            }
        }
        let controller = MockEngineController(client: client)
        let store = try makeInjectedStore(engineController: controller)
        store.tasks = [makeTask(id: "stale-task", status: .active)]
        store.selectedTaskID = "stale-task"
        var receivedAlerts: [UserFacingAlert] = []
        let cancellable = store.userAlerts.sink { receivedAlerts.append($0) }

        await store.remove(makeTask(id: "stale-task", status: .active))

        XCTAssertEqual(store.selectedTaskID, nil)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(
            capturedMethods.value().filter { $0 == "aria2.forceRemove" || $0 == "aria2.removeDownloadResult" },
            ["aria2.forceRemove", "aria2.removeDownloadResult"]
        )
        XCTAssertTrue(capturedMethods.value().contains("aria2.saveSession"))
        XCTAssertLessThan(try XCTUnwrap(capturedMethods.value().firstIndex(of: "aria2.saveSession")), try XCTUnwrap(capturedMethods.value().firstIndex(of: "aria2.getGlobalStat")))
        XCTAssertTrue(receivedAlerts.isEmpty)
        _ = cancellable
    }

    @MainActor
    func testDownloadStoreBeginRemovePresentsOneRemovalRequestByDefault() throws {
        let client = try makeRPCClient { request in
            try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        let task = makeTask(id: "delete-me", name: "Delete Me", status: .completed)

        store.beginRemove(task)

        XCTAssertEqual(store.removalRequest?.task.id, "delete-me")
        store.cancelRemoval()
        XCTAssertNil(store.removalRequest)
    }

    @MainActor
    func testDownloadStoreConfirmedSuppressedRemovalRemembersChosenFileBehavior() async throws {
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request)
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        let task = makeTask(id: "delete-without-files", status: .completed)
        let request = DownloadRemovalRequest(task: task)
        store.removalRequest = request
        store.preferences.suppressRemoveConfirmation = false
        store.preferences.deleteFilesWhenSkippingRemoveConfirmation = true

        await store.confirmRemoval(
            request,
            includingFiles: false,
            suppressFutureConfirmation: true
        )

        XCTAssertNil(store.removalRequest)
        XCTAssertTrue(store.preferences.suppressRemoveConfirmation)
        XCTAssertFalse(store.preferences.deleteFilesWhenSkippingRemoveConfirmation)
    }

    @MainActor
    func testDownloadStorePauseAllUsesPerTaskForcePauseAndSavesSession() async throws {
        let capturedGIDs = LockedBox<[String]>([])
        let capturedMethods = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            let method = try XCTUnwrap(payload["method"] as? String)
            var methods = capturedMethods.value()
            methods.append(method)
            capturedMethods.set(methods)
            if method == "aria2.forcePause",
               let params = payload["params"] as? [Any],
               params.count > 1,
               let gid = params[1] as? String {
                var gids = capturedGIDs.value()
                gids.append(gid)
                capturedGIDs.set(gids)
            }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let controller = MockEngineController(client: client)
        let store = try makeInjectedStore(engineController: controller)
        var sharingTask = makeTask(id: "sharing", protocolKind: .bitTorrent, status: .active)
        sharingTask.isSharing = true
        store.tasks = [
            makeTask(id: "active", status: .active),
            makeTask(id: "waiting", status: .waiting),
            makeTask(id: "paused", status: .paused),
            sharingTask
        ]

        await store.pauseAll()

        XCTAssertEqual(capturedGIDs.value(), ["active", "waiting", "sharing"])
        XCTAssertFalse(capturedMethods.value().contains("aria2.pauseAll"))
        XCTAssertTrue(capturedMethods.value().contains("aria2.saveSession"))
        XCTAssertLessThan(try XCTUnwrap(capturedMethods.value().firstIndex(of: "aria2.saveSession")), try XCTUnwrap(capturedMethods.value().firstIndex(of: "aria2.getGlobalStat")))
    }

    @MainActor
    func testPrepareForAppTerminationPausesCurrentTasksSavesSessionAndStopsEngine() async throws {
        let capturedCalls = LockedBox<[(String, String?)]>([])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBodyData(from: request)) as? [String: Any])
            let method = try XCTUnwrap(payload["method"] as? String)
            let params = (payload["params"] as? [Any]) ?? []
            let gid = params.count > 1 ? params[1] as? String : nil
            var calls = capturedCalls.value()
            calls.append((method, gid))
            capturedCalls.set(calls)
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let controller = MockEngineController(client: client)
        let store = try makeInjectedStore(engineController: controller)
        var sharingTask = makeTask(id: "sharing", protocolKind: .bitTorrent, status: .active)
        sharingTask.isSharing = true
        store.tasks = [
            makeTask(id: "active", status: .active),
            makeTask(id: "waiting", status: .waiting),
            makeTask(id: "paused", status: .paused),
            makeTask(id: "completed", status: .completed),
            sharingTask
        ]

        await store.prepareForAppTermination()

        XCTAssertEqual(
            capturedCalls.value().map { "\($0.0):\($0.1 ?? "")" },
            [
                "aria2.forcePause:active",
                "aria2.forcePause:waiting",
                "aria2.forcePause:sharing",
                "aria2.saveSession:"
            ]
        )
        XCTAssertEqual(controller.stopCallCount, 1)
        XCTAssertEqual(controller.terminateForAppExitCallCount, 0)
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(store.runtime.phase, .stopped)
    }

    @MainActor
    func testPrepareForAppTerminationTerminatesWithoutRPCWhenEngineIsNotRunning() async throws {
        let client = try makeRPCClient { request in
            try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let controller = MockEngineController(client: client, isRunning: false, hasLaunchedProcess: true)
        let store = try makeInjectedStore(engineController: controller)

        await store.prepareForAppTermination()

        XCTAssertEqual(controller.stopCallCount, 0)
        XCTAssertEqual(controller.terminateForAppExitCallCount, 1)
        XCTAssertFalse(controller.isRunning)
        XCTAssertFalse(controller.hasLaunchedProcess)
        XCTAssertEqual(store.runtime.phase, .stopped)
    }

    private func makeTask(
        id: String = "task",
        name: String = "File",
        protocolKind: TaskProtocol = .http,
        status: DownloadStatus = .active,
        totalLength: Int64 = 100,
        completedLength: Int64 = 20,
        destination: String = "/tmp",
        files: [DownloadFile] = [],
        infoHash: String? = nil
    ) -> DownloadTask {
        DownloadTask(
            id: id,
            name: name,
            protocolKind: protocolKind,
            status: status,
            totalLength: totalLength,
            completedLength: completedLength,
            downloadSpeed: 0,
            uploadSpeed: 0,
            connections: 0,
            destination: destination,
            addedAt: Date(),
            errorMessage: nil,
            files: files,
            peers: [],
            trackers: [],
            recentLogs: [],
            infoHash: infoHash
        )
    }

    @MainActor
    private func makeInjectedStore(
        engineController: any Aria2EngineControlling,
        trackerFetcher: (any BitTorrentTrackerSourceFetching)? = nil,
        ed2kBootstrapFetcher: (any ED2KBootstrapFetching)? = nil,
        ed2kBootstrapApplicationSupportBase: URL? = nil,
        powerAssertionController: (any PowerAssertionControlling)? = nil,
        engineInstallationManager: (any EngineInstallationManaging)? = nil
    ) throws -> DownloadStore {
        DownloadStore(
            settingsStore: try PersistentSettingsStore(inMemory: true),
            engineController: engineController,
            trackerFetcher: trackerFetcher,
            ed2kBootstrapFetcher: ed2kBootstrapFetcher,
            ed2kBootstrapApplicationSupportBase: ed2kBootstrapApplicationSupportBase,
            powerAssertionController: powerAssertionController,
            engineInstallationManager: engineInstallationManager
        )
    }

    private func waitForProcessID(at url: URL, process: Process) throws -> Int32 {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0 {
                return pid
            }
            if !process.isRunning {
                XCTFail("Process exited before writing pid file.")
                return -1
            }
            usleep(10_000)
        }
        XCTFail("Timed out waiting for pid file.")
        return -1
    }

    private func waitForCondition(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            usleep(10_000)
        }
        return predicate()
    }

    @MainActor
    private func waitForMainActorCondition(timeout: TimeInterval, predicate: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        errno = 0
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func setCloseOnExec(_ fileHandle: FileHandle) {
        let descriptor = fileHandle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0 else { return }
        _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
    }

    private func makeRPCClient(
        handler: @escaping RPCMockURLProtocol.Handler
    ) throws -> Aria2RPCClient {
        let handlerID = UUID().uuidString
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:6800/jsonrpc/\(handlerID)"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RPCMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        RPCMockURLProtocol.register(handler, for: handlerID)
        addTeardownBlock {
            RPCMockURLProtocol.unregisterHandler(for: handlerID)
            session.invalidateAndCancel()
        }
        return Aria2RPCClient(endpoint: endpoint, token: "secret", session: session)
    }

    func testRPCPollingDeduplicatesTasksMovingBetweenQueues() async throws {
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request)
            let status = method == "aria2.tellStopped" ? "complete" : "active"
            return try Self.rpcHTTPResponse(
                for: request,
                body: "{\"result\":[{\"gid\":\"moving-task\",\"status\":\"\(status)\"}]}"
            )
        }
        let tasks = try await client.pollTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.status, .completed)
    }

    func testEngineUpgradeBacksUpSessionOnceWithoutChangingOriginalFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let support = try Aria2NextPaths.supportDirectory(applicationSupportBase: base)
        let session = support.appendingPathComponent("aria2.session")
        let original = Data("https://example.com/file.bin\n gid=0123456789abcdef\n".utf8)
        try original.write(to: session)
        let partial = base.appendingPathComponent("file.bin")
        try Data("unfinished content".utf8).write(to: partial)

        let backup = try XCTUnwrap(EngineSessionMigration.prepare(supportDirectory: support, version: "2.8.6"))
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try Data(contentsOf: session), original)
        XCTAssertEqual(try String(contentsOf: partial, encoding: .utf8), "unfinished content")
        XCTAssertNil(try EngineSessionMigration.prepare(supportDirectory: support, version: "2.8.6"))

        let nextBackup = try XCTUnwrap(EngineSessionMigration.prepare(supportDirectory: support, version: "2.8.7"))
        XCTAssertNotEqual(nextBackup, backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testFreshEngineInstallDoesNotCreateSessionBackup() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let support = try Aria2NextPaths.supportDirectory(applicationSupportBase: base)
        XCTAssertNil(try EngineSessionMigration.prepare(supportDirectory: support, version: "2.8.6"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Session Backups").path))
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("engine-version"), encoding: .utf8), "2.8.6")
    }

    func testEngineUpgradeDoesNotMarkMigrationCompleteWhenBackupFails() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let support = try Aria2NextPaths.supportDirectory(applicationSupportBase: base)
        let session = support.appendingPathComponent("aria2.session")
        try Data("old session".utf8).write(to: session)
        try Data("not a directory".utf8).write(to: support.appendingPathComponent("Session Backups"))

        XCTAssertThrowsError(try EngineSessionMigration.prepare(supportDirectory: support, version: "2.8.6"))
        XCTAssertEqual(try String(contentsOf: session, encoding: .utf8), "old session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("engine-version").path))
    }

    func testRPCPollingLoadsWaitingTasksBeyondFirstPage() async throws {
        let offsets = LockedBox<[Int]>([])
        let client = try makeRPCClient { request in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBodyData(from: request)) as? [String: Any])
            guard payload["method"] as? String == "aria2.tellWaiting" else {
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":[]}"#)
            }
            let params = try XCTUnwrap(payload["params"] as? [Any])
            let offset = try XCTUnwrap(params[1] as? Int)
            offsets.withValue { $0.append(offset) }
            let count = offset == 0 ? 1000 : 1
            let tasks = (offset..<(offset + count)).map { ["gid": "task-\($0)", "status": "waiting"] }
            let data = try JSONSerialization.data(withJSONObject: ["result": tasks])
            return try Self.rpcHTTPResponse(for: request, body: String(decoding: data, as: UTF8.self))
        }
        let tasks = try await client.pollTasks()
        XCTAssertEqual(tasks.count, 1001)
        XCTAssertEqual(offsets.value(), [0, 1000])
        XCTAssertTrue(tasks.contains { $0.id == "task-1000" })
    }

    func testRPCRequestsBoundTimeoutAndDisableCaching() throws {
        let client = try Aria2RPCClient(port: 29100, token: "secret")
        let request = try client.makeRequest(method: "aria2.getGlobalStat", params: [])
        XCTAssertEqual(request.timeoutInterval, 5)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testRPCErrorsRedactTokenFromServerMessageAndInvalidBody() async throws {
        for body in [#"{"error":{"code":1,"message":"Invalid token:secret"}}"#, "Rejected token:secret"] {
            let client = try makeRPCClient { request in
                try Self.rpcHTTPResponse(for: request, statusCode: 400, body: body)
            }
            do {
                _ = try await client.globalStat()
                XCTFail("Expected RPC error")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("secret"))
                XCTAssertTrue(error.localizedDescription.contains("<redacted>"))
            }
        }
    }

    @MainActor
    func testRefreshPreservesAddedDateAndShowsOlderTasksByDefault() async throws {
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request)
            if method == "aria2.tellStopped" {
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":[{"gid":"old","status":"complete"}]}"#)
            }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        var existing = makeTask(id: "old", status: .completed)
        existing.addedAt = yesterday
        // Also tolerate old duplicate snapshots instead of trapping in Dictionary.
        store.tasks = [existing, existing]

        let error = await store.refreshTasks()

        XCTAssertNil(error)
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.tasks.first?.addedAt, yesterday)
        XCTAssertEqual(store.selectedDestination, .all)
        XCTAssertEqual(store.visibleTasks.map(\.id), ["old"])
    }

    @MainActor
    func testRepeatedStartLeavesRunningEngineAlone() async throws {
        let client = try makeRPCClient { request in
            try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let controller = MockEngineController(client: client)
        let store = try makeInjectedStore(engineController: controller)
        store.runtime = EngineRuntimeSnapshot(phase: .running(pid: 1234))
        await store.startEngine()
        XCTAssertEqual(controller.startCallCount, 0)
        XCTAssertEqual(controller.terminateForAppExitCallCount, 0)
        XCTAssertEqual(store.runtime.phase, .running(pid: 1234))
    }

    @MainActor
    func testStartupReachesRunningBeforeNetworkMaintenanceAndDoesNotRestartAfterShutdown() async throws {
        let client = try makeRPCClient { request in
            try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let controller = MockEngineController(client: client, isRunning: false, hasLaunchedProcess: false)
        let fetcher = SuspendedTrackerFetcher()
        let store = try makeInjectedStore(engineController: controller, trackerFetcher: fetcher)
        store.engineSettings.rpcToken = "secret"
        let startup = Task { await store.startEngine(startupSync: true) }
        let didStartSync = await waitForMainActorCondition(timeout: 2) { store.isSyncingTrackers }
        XCTAssertTrue(didStartSync)
        XCTAssertEqual(store.runtime.phase, .running(pid: 1234))
        XCTAssertFalse(store.canStartEngine)
        await store.startEngine()
        store.shutdown()
        await fetcher.finish()
        await startup.value
        XCTAssertEqual(controller.startCallCount, 1)
        XCTAssertEqual(store.runtime.phase, .stopped)
    }

    @MainActor
    func testImportedSheetsRestoreManualDraftAndNeverSubmitOnPresentation() async throws {
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request)
            XCTAssertFalse(method.hasPrefix("aria2.add"))
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let controller = MockEngineController(client: client, isRunning: false, hasLaunchedProcess: false)
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true),
                                  engineController: controller, engineInstallationManager: StartupEngineManager())
        store.engineSettings.btTrackerAutoSync = false
        store.engineSettings.ed2kBootstrapAutoSync = false
        defer { store.shutdown() }
        await store.prepareEngineOnLaunch()
        var original = AddDownloadDraft(rawInput: "https://example.com/draft")
        original.authorization = "Bearer memory-only"
        store.addDraft = original
        let document = ImportedDownloadDocument(kind: .metalink, data: Data("<metalink/>".utf8))
        store.inputCoordinator.enqueue([.init(resources: ["file:///example.meta4"],
                                               documents: ["file:///example.meta4": document], issues: ["Review this import"]),
                                        .init(resources: ["https://example.com/second"])])
        let first = UUID(), second = UUID()
        XCTAssertTrue(store.beginImportedDownload(owner: first))
        XCTAssertEqual(store.addDraft.importedDocuments["file:///example.meta4"], document)
        XCTAssertEqual(store.importIssues, ["Review this import"])
        XCTAssertTrue(store.addDraft.authorization.isEmpty)
        XCTAssertFalse(store.beginImportedDownload(owner: second))
        store.finishDownloadPanel(owner: second)
        XCTAssertEqual(store.addDraft.rawInput, "file:///example.meta4")
        store.finishDownloadPanel(owner: first)
        XCTAssertEqual(store.addDraft, original)
        XCTAssertTrue(store.importIssues.isEmpty)
        XCTAssertTrue(store.beginImportedDownload(owner: second))
        XCTAssertEqual(store.addDraft.rawInput, "https://example.com/second")
        store.finishDownloadPanel(owner: second)
        XCTAssertEqual(store.addDraft, original)
    }

    @MainActor
    func testAutomaticStartupGeneratesAndPersistsTokenAndOnlyStartsOnce() async throws {
        let settings = try PersistentSettingsStore(inMemory: true)
        let client = try makeRPCClient { request in
            try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let controller = MockEngineController(client: client, isRunning: false, hasLaunchedProcess: false)
        let manager = StartupEngineManager()
        let store = DownloadStore(settingsStore: settings, engineController: controller, engineInstallationManager: manager)
        store.engineSettings.btTrackerAutoSync = false
        defer { store.shutdown() }
        XCTAssertTrue(store.engineSettings.rpcToken.isEmpty)
        await store.prepareEngineOnLaunch()
        XCTAssertEqual(store.runtime.phase, .running(pid: 1234))
        XCTAssertEqual(store.engineSettings.rpcToken.count, 64)
        XCTAssertEqual(try settings.loadEngineSettings().rpcToken, store.engineSettings.rpcToken)
        XCTAssertNotNil(store.engineSettings.downloadDirectoryPath)
        let token = store.engineSettings.rpcToken
        await store.prepareEngineOnLaunch()
        XCTAssertEqual(controller.startCallCount, 1)
        XCTAssertEqual(store.engineSettings.rpcToken, token)
    }

    @MainActor
    func testMissingEngineRequiresInstallBeforeStartingAndFailureCanRetry() async throws {
        let client = try makeRPCClient { request in
            try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let controller = MockEngineController(client: client, isRunning: false, hasLaunchedProcess: false)
        let manager = StartupEngineManager(missing: true, failInstall: true)
        let store = try makeInjectedStore(engineController: controller, engineInstallationManager: manager)
        store.engineSettings.btTrackerAutoSync = false
        defer { store.shutdown() }
        await store.prepareEngineOnLaunch()
        XCTAssertEqual(store.engineSetupState, .required)
        XCTAssertEqual(controller.startCallCount, 0)
        let checksBeforeInstall = await manager.releaseChecks
        XCTAssertEqual(checksBeforeInstall, 0)
        store.installRequiredEngine()
        let failed = await waitForMainActorCondition(timeout: 2) {
            if case .failed = store.engineSetupState { return true }; return false
        }
        XCTAssertTrue(failed)
        XCTAssertTrue(store.engineSetupState.requiresInstallation)
        await manager.allowInstall()
        store.installRequiredEngine()
        let running = await waitForMainActorCondition(timeout: 2) { store.runtime.phase == .running(pid: 1234) }
        XCTAssertTrue(running)
        XCTAssertEqual(store.engineSetupState, .ready)
        XCTAssertEqual(controller.startCallCount, 1)
    }

    @MainActor
    func testOfflineUpdateCheckDoesNotBlockStartupOrReplaceExistingSettings() async throws {
        let client = try makeRPCClient { request in
            try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let controller = MockEngineController(client: client, isRunning: false, hasLaunchedProcess: false)
        let store = try makeInjectedStore(engineController: controller, engineInstallationManager: StartupEngineManager(offline: true))
        store.engineSettings.rpcToken = "existing-token"
        let existingFolder = FileManager.default.temporaryDirectory
        store.engineSettings.downloadDirectoryPath = existingFolder.path
        store.engineSettings.downloadDirectoryBookmark = try PreferencesStore.bookmark(for: existingFolder)
        store.engineSettings.btTrackerAutoSync = false
        defer { store.shutdown() }
        await store.prepareEngineOnLaunch()
        XCTAssertEqual(store.runtime.phase, .running(pid: 1234))
        XCTAssertEqual(store.engineSettings.rpcToken, "existing-token")
        XCTAssertEqual(store.engineSettings.downloadDirectoryPath, existingFolder.path)
        let finished = await waitForMainActorCondition(timeout: 2) { store.engineUpdateStatus.hasPrefix("Could not check") }
        XCTAssertTrue(finished)
        XCTAssertNil(store.availableEngineUpdate)
    }

    @MainActor
    func testNewerVersionPublishesReminderWhileEngineKeepsRunning() async throws {
        let client = try makeRPCClient { request in
            try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let controller = MockEngineController(client: client, isRunning: false, hasLaunchedProcess: false)
        let store = try makeInjectedStore(engineController: controller, engineInstallationManager: StartupEngineManager())
        store.engineSettings.btTrackerAutoSync = false
        defer { store.shutdown() }
        await store.prepareEngineOnLaunch()
        let notified = await waitForMainActorCondition(timeout: 2) { store.availableEngineUpdate != nil }
        XCTAssertTrue(notified)
        XCTAssertEqual(store.availableEngineUpdate?.version, EngineVersion("2.10.0"))
        XCTAssertEqual(store.runtime.phase, .running(pid: 1234))
    }

    @MainActor
    func testEngineSettingsRequestSurvivesUntilConsumedAndCanBeRepeated() throws {
        let store = try makeInjectedStore(engineController: MockEngineController(client: makeRPCClient { request in
            try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }))
        defer { store.shutdown() }
        XCTAssertFalse(store.consumeEngineSettingsRequest())
        store.requestEngineSettings()
        XCTAssertTrue(store.engineSettingsRequested)
        XCTAssertTrue(store.consumeEngineSettingsRequest())
        XCTAssertFalse(store.consumeEngineSettingsRequest())
        store.requestEngineSettings()
        XCTAssertTrue(store.consumeEngineSettingsRequest())
    }

    @MainActor
    private func makeEngineUpdateStore(manager: StartupEngineManager) async throws -> (DownloadStore, MockEngineController) {
        let client = try makeRPCClient { request in
            try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let controller = MockEngineController(client: client, isRunning: false, hasLaunchedProcess: false)
        let store = try makeInjectedStore(engineController: controller, engineInstallationManager: manager)
        store.engineSettings.btTrackerAutoSync = false
        await store.prepareEngineOnLaunch()
        let ready = await waitForMainActorCondition(timeout: 2) { store.canUpdateEngine }
        XCTAssertTrue(ready)
        return (store, controller)
    }

    @MainActor
    func testEngineUpdateReportsBytesAndCancelLeavesCurrentEngineRunning() async throws {
        let manager = StartupEngineManager()
        await manager.setInstallDelay(.seconds(10))
        let (store, controller) = try await makeEngineUpdateStore(manager: manager)
        defer { store.shutdown() }
        store.updateEngine()
        let downloading = await waitForMainActorCondition(timeout: 2) { store.engineUpgradeProgress?.stage == .downloading }
        XCTAssertTrue(downloading)
        XCTAssertEqual(store.engineUpgradeProgress?.fractionCompleted, 0.25)
        XCTAssertEqual(store.engineUpgradeProgress?.completedBytes, 250)
        store.cancelEngineUpdate()
        let finished = await waitForMainActorCondition(timeout: 2) { !store.isUpdatingEngine }
        XCTAssertTrue(finished)
        XCTAssertNil(store.engineUpgradeError)
        XCTAssertTrue(store.engineUpgradeResult?.contains("canceled") == true)
        XCTAssertEqual(store.engineVersionDescription, "2.9.0")
        XCTAssertEqual(controller.stopCallCount, 0)
        XCTAssertTrue(controller.isRunning)
        XCTAssertTrue(store.canUpdateEngine)
        let activations = await manager.activationCount
        XCTAssertEqual(activations, 0)
    }

    @MainActor
    func testRequiredEngineDownloadCanCancelAndRetry() async throws {
        let manager = StartupEngineManager(missing: true)
        await manager.setInstallDelay(.seconds(10))
        let client = try makeRPCClient { request in
            try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let controller = MockEngineController(client: client, isRunning: false, hasLaunchedProcess: false)
        let store = try makeInjectedStore(engineController: controller, engineInstallationManager: manager)
        store.engineSettings.btTrackerAutoSync = false
        defer { store.shutdown() }
        await store.prepareEngineOnLaunch()
        store.installRequiredEngine()
        store.cancelEngineInstallation()
        let canceled = await waitForMainActorCondition(timeout: 2) { store.engineSetupState == .required }
        XCTAssertTrue(canceled)
        XCTAssertEqual(controller.startCallCount, 0)
        await manager.setInstallDelay(.zero)
        store.installRequiredEngine()
        let ready = await waitForMainActorCondition(timeout: 2) { store.engineSetupState == .ready }
        XCTAssertTrue(ready)
    }

    @MainActor
    func testManualEngineUpdateRestartsAndPublishesOnlyAfterSuccessfulStartup() async throws {
        let manager = StartupEngineManager()
        let (store, controller) = try await makeEngineUpdateStore(manager: manager)
        defer { store.shutdown() }
        XCTAssertEqual(store.engineSidebarVersionDescription, "2.9.0 → 2.10.0")
        store.updateEngine()
        store.updateEngine() // A repeated click must not start a second installation.
        XCTAssertFalse(store.canStartEngine)
        XCTAssertFalse(store.canRestartEngine)
        XCTAssertFalse(store.canStopEngine)
        let finished = await waitForMainActorCondition(timeout: 3) { !store.isUpdatingEngine }
        XCTAssertTrue(finished)
        XCTAssertNil(store.engineUpgradeError)
        XCTAssertEqual(store.engineVersionDescription, "2.10.0")
        XCTAssertEqual(store.engineSidebarVersionDescription, "2.10.0")
        XCTAssertNil(store.availableEngineUpdate)
        XCTAssertEqual(controller.stopCallCount, 1)
        XCTAssertEqual(controller.startCallCount, 2)
        XCTAssertEqual(store.runtime.phase, .running(pid: 1234))
        let activations = await manager.activationCount
        XCTAssertEqual(activations, 1)
    }

    @MainActor
    func testFailedUpdateDownloadKeepsCurrentEngineRunningAndCanRetry() async throws {
        let manager = StartupEngineManager(failInstall: true)
        let (store, controller) = try await makeEngineUpdateStore(manager: manager)
        defer { store.shutdown() }
        store.updateEngine()
        let finished = await waitForMainActorCondition(timeout: 3) { !store.isUpdatingEngine }
        XCTAssertTrue(finished)
        XCTAssertNotNil(store.engineUpgradeError)
        XCTAssertEqual(store.engineVersionDescription, "2.9.0")
        XCTAssertEqual(controller.stopCallCount, 0)
        XCTAssertEqual(controller.startCallCount, 1)
        XCTAssertTrue(store.canUpdateEngine)
        XCTAssertFalse(store.engineSetupState.requiresInstallation)
        await manager.allowInstall()
        store.updateEngine()
        let retried = await waitForMainActorCondition(timeout: 3) { !store.isUpdatingEngine }
        XCTAssertTrue(retried)
        XCTAssertEqual(store.engineVersionDescription, "2.10.0")
        XCTAssertNil(store.engineUpgradeError)
    }

    @MainActor
    func testUpdatedEngineLaunchFailureRestoresPreviousEngineWithoutActivatingUpdate() async throws {
        let manager = StartupEngineManager()
        let (store, controller) = try await makeEngineUpdateStore(manager: manager)
        defer { store.shutdown() }
        controller.rejectedVersion = EngineVersion("2.10.0")
        var alerts: [UserFacingAlert] = []
        let subscription = store.userAlerts.sink { alerts.append($0) }
        defer { subscription.cancel() }
        store.updateEngine()
        let finished = await waitForMainActorCondition(timeout: 3) { !store.isUpdatingEngine }
        XCTAssertTrue(finished)
        XCTAssertEqual(store.engineVersionDescription, "2.9.0")
        XCTAssertEqual(controller.selectedInstallation?.version, EngineVersion("2.9.0"))
        XCTAssertEqual(store.runtime.phase, .running(pid: 1234))
        XCTAssertNotNil(store.engineUpgradeError)
        XCTAssertTrue(store.canUpdateEngine)
        XCTAssertTrue(alerts.isEmpty, "Manual update failures are shown in Engine settings")
        let activations = await manager.activationCount
        XCTAssertEqual(activations, 0)
    }

    @MainActor
    func testFailedInstallationCommitRestartsPreviousEngineAndRetainsUpdate() async throws {
        let manager = StartupEngineManager()
        await manager.rejectActivation()
        let (store, controller) = try await makeEngineUpdateStore(manager: manager)
        defer { store.shutdown() }
        store.updateEngine()
        let finished = await waitForMainActorCondition(timeout: 3) { !store.isUpdatingEngine }
        XCTAssertTrue(finished)
        XCTAssertNotNil(store.engineUpgradeError)
        XCTAssertEqual(store.engineVersionDescription, "2.9.0")
        XCTAssertEqual(controller.selectedInstallation?.version, EngineVersion("2.9.0"))
        XCTAssertEqual(store.runtime.phase, .running(pid: 1234))
        XCTAssertEqual(controller.startCallCount, 3)
        XCTAssertEqual(controller.stopCallCount, 2)
        XCTAssertTrue(store.canUpdateEngine)
        let activations = await manager.activationCount
        XCTAssertEqual(activations, 0)
    }

    @MainActor
    func testUpdatingStoppedEngineDoesNotStartIt() async throws {
        let (store, controller) = try await makeEngineUpdateStore(manager: StartupEngineManager())
        defer { store.shutdown() }
        await store.stopEngine()
        store.updateEngine()
        let finished = await waitForMainActorCondition(timeout: 3) { !store.isUpdatingEngine }
        XCTAssertTrue(finished)
        XCTAssertEqual(store.engineVersionDescription, "2.10.0")
        XCTAssertEqual(controller.startCallCount, 1)
        XCTAssertFalse(controller.isRunning)
    }

    @MainActor
    func testQuitDuringUpdateDownloadCancelsWithoutActivatingOrRestarting() async throws {
        let manager = StartupEngineManager()
        await manager.setInstallDelay(.seconds(10))
        let (store, controller) = try await makeEngineUpdateStore(manager: manager)
        defer { store.shutdown() }
        store.updateEngine()
        await store.prepareForAppTermination()
        XCTAssertFalse(store.isUpdatingEngine)
        XCTAssertEqual(store.engineVersionDescription, "2.9.0")
        XCTAssertEqual(controller.startCallCount, 1)
        XCTAssertFalse(controller.isRunning)
        let activations = await manager.activationCount
        XCTAssertEqual(activations, 0)
    }

    @MainActor
    func testCancelledRefreshDoesNotPublishResultsOrAlerts() async throws {
        let requestStarted = LockedBox(false)
        let gate = DispatchSemaphore(value: 0)
        let client = try makeRPCClient { request in
            if try Self.captureRPCMethod(from: request) == "aria2.tellActive" {
                requestStarted.set(true)
                _ = gate.wait(timeout: .now() + 3)
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":[{"gid":"stale","status":"active"}]}"#)
            }
            return try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        store.tasks = [makeTask(id: "original")]
        var alerts: [UserFacingAlert] = []
        let cancellable = store.userAlerts.sink { alerts.append($0) }
        let refresh = Task { await store.refreshTasks() }
        let didStart = await waitForMainActorCondition(timeout: 2) { requestStarted.value() }
        XCTAssertTrue(didStart)
        refresh.cancel()
        gate.signal()
        _ = await refresh.value
        XCTAssertEqual(store.tasks.map(\.id), ["original"])
        XCTAssertTrue(alerts.isEmpty)
        _ = cancellable
    }

    @MainActor
    func testHistorySurvivesEnginePurgingAndOfflineClearingCannotResurrectResults() async throws {
        let pollHasResult = LockedBox(true)
        let removed = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request)
            if method == "aria2.removeDownloadResult" {
                removed.set(removed.value() + [method])
            }
            if method == "aria2.tellStopped", pollHasResult.value() {
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":[{"gid":"finished","status":"complete","totalLength":"100","completedLength":"100"}]}"#)
            }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let settings = try PersistentSettingsStore(inMemory: true)
        let controller = MockEngineController(client: client)
        let store = DownloadStore(settingsStore: settings, engineController: controller)
        _ = await store.refreshTasks()
        let firstDate = try XCTUnwrap(store.tasks.first?.addedAt)
        pollHasResult.set(false)
        _ = await store.refreshTasks()
        XCTAssertEqual(store.tasks.first?.status, .completed)
        XCTAssertEqual(store.tasks.first?.addedAt, firstDate)
        let offlineController = MockEngineController(client: client, isRunning: false)
        let reopened = DownloadStore(settingsStore: settings, engineController: offlineController)
        XCTAssertEqual(reopened.tasks.first?.addedAt, firstDate)
        XCTAssertTrue(reopened.canClearFinishedRecords)
        await reopened.purgeCompletedRecords()
        XCTAssertTrue(reopened.tasks.isEmpty)
        let reconnected = DownloadStore(settingsStore: settings, engineController: controller)
        pollHasResult.set(true)
        _ = await reconnected.refreshTasks()
        XCTAssertTrue(reconnected.tasks.isEmpty)
        XCTAssertEqual(removed.value(), ["aria2.removeDownloadResult"])
    }

    @MainActor
    func testRepeatedRPCFailureUsesInlineStatusAndRecoversWithoutAlerts() async throws {
        let fails = LockedBox(true)
        let client = try makeRPCClient { request in
            if fails.value() { throw URLError(.cannotConnectToHost) }
            return try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        store.tasks = [makeTask(id: "saved", status: .active)]
        var alerts: [UserFacingAlert] = []
        let observer = store.userAlerts.sink { alerts.append($0) }
        for _ in 0..<3 { _ = await store.refreshTasks() }
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertNotNil(store.connectionIssue)
        XCTAssertEqual(store.tasks.first?.status, .paused)
        XCTAssertNil(store.tasks.first?.primaryControlAction)
        fails.set(false)
        _ = await store.refreshTasks()
        XCTAssertNil(store.connectionIssue)
        XCTAssertNil(store.runtime.lastError)
        _ = observer
    }

    @MainActor
    func testDelayedPollCannotUndoOfflineRecordClear() async throws {
        let gate = DispatchSemaphore(value: 0)
        let started = LockedBox(false)
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request)
            if method == "aria2.tellStopped" {
                started.set(true)
                _ = gate.wait(timeout: .now() + 3)
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":[{"gid":"done","status":"complete"}]}"#)
            }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let controller = MockEngineController(client: client)
        let store = try makeInjectedStore(engineController: controller)
        store.tasks = [makeTask(id: "done", status: .completed)]
        let refresh = Task { await store.refreshTasks() }
        let didStart = await waitForMainActorCondition(timeout: 2) { started.value() }
        XCTAssertTrue(didStart)
        controller.isRunning = false
        await store.purgeCompletedRecords()
        controller.isRunning = true
        gate.signal()
        _ = await refresh.value
        XCTAssertTrue(store.tasks.isEmpty)
    }

    @MainActor
    func testEditAndAddAgainOpensDraftWithoutCopyingCredentialsOrMutatingEngine() throws {
        let client = try makeRPCClient { _ in
            XCTFail("Preparing a replacement draft must not send RPC calls")
            throw URLError(.cancelled)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        var failed = makeTask(id: "failed", status: .failed, destination: "/tmp/downloads")
        failed.sourceURL = "https://example.com/file?token=current"
        store.addDraft.authorization = "Bearer old-credential"
        store.addDraft.cookie = "session=old"
        var presented = false
        let observer = store.addPanelRequests.sink { presented = true }
        store.editAndAddAgain(failed)
        XCTAssertTrue(presented)
        XCTAssertEqual(store.addDraft.rawInput, failed.sourceURL)
        XCTAssertEqual(store.addDraft.savePath, failed.destination)
        XCTAssertTrue(store.addDraft.authorization.isEmpty)
        XCTAssertTrue(store.addDraft.cookie.isEmpty)
        XCTAssertNotNil(store.addDraftNotice)
        _ = observer
    }

    @MainActor
    func testFinishedTorrentIsArchivedBeforeItsForceSavedEngineResultIsRemoved() async throws {
        let calls = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            if method == "aria2.tellStopped" {
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":[{"gid":"seed-ended","status":"complete","bittorrent":{"info":{"name":"Seed"}},"totalLength":"100","completedLength":"100"}]}"#)
            }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let settings = try PersistentSettingsStore(inMemory: true)
        let store = DownloadStore(settingsStore: settings, engineController: MockEngineController(client: client))
        _ = await store.refreshTasks()
        XCTAssertEqual(store.tasks.first?.status, .completed)
        XCTAssertEqual(store.tasks.first?.isAvailableInEngine, false)
        XCTAssertEqual(try settings.makeHistoryStore().load().first?.status, .completed)
        XCTAssertTrue(calls.value().contains("aria2.removeDownloadResult"))
        XCTAssertEqual(calls.value().last, "aria2.saveSession")
    }

    @MainActor
    func testPartialBatchIsSavedAndOnlyRemainingLinksStayInDraft() async throws {
        let additions = LockedBox(0)
        let calls = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            if method == "aria2.addUri" {
                additions.set(additions.value() + 1)
                if additions.value() == 1 {
                    return try Self.rpcHTTPResponse(for: request, body: #"{"result":"accepted"}"#)
                }
                return try Self.rpcHTTPResponse(for: request, body: #"{"error":{"code":1,"message":"Test rejection"}}"#)
            }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let settings = try PersistentSettingsStore(inMemory: true)
        let store = DownloadStore(settingsStore: settings, engineController: MockEngineController(client: client))
        store.addDraft.rawInput = "https://example.com/one\nhttps://example.com/two"
        let finished = await store.submitDraft()
        XCTAssertFalse(finished)
        XCTAssertEqual(store.addDraft.resourceLines, ["https://example.com/two"])
        XCTAssertEqual(try settings.makeHistoryStore().load().map(\.id), ["accepted"])
        XCTAssertEqual(store.tasks.first?.addedAtIsFirstSeen, false)
        XCTAssertTrue(calls.value().contains("aria2.saveSession"))
    }

    @MainActor
    func testStartupReadsRunningCapabilitiesAndRejectsUnsupportedInput() async throws {
        let calls = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            if method == "aria2.getVersion" {
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":{"product":"aria2-next","version":"2.8.6","rpcVersion":"1.1.0","enabledFeatures":["HTTPS"]}}"#)
            }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client, isRunning: false, hasLaunchedProcess: false))
        defer { store.shutdown() }
        store.engineSettings.rpcToken = "secret"
        store.engineSettings.btTrackerAutoSync = false
        await store.startEngine()
        XCTAssertEqual(store.engineCapabilities?.version, "2.8.6")
        store.addDraft.rawInput = "sftp://example.com/file.zip"
        let added = await store.submitDraft()
        XCTAssertFalse(added)
        XCTAssertFalse(calls.value().contains("aria2.addUri"))
    }

    @MainActor
    func testCompletedTorrentDoesNotReturnAfterCrashDuringSessionPruning() async throws {
        let calls = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            if method == "aria2.tellWaiting" {
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":[{"gid":"archived","status":"paused","bittorrent":{"info":{"name":"Seed"}},"totalLength":"100","completedLength":"100"}]}"#)
            }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let settings = try PersistentSettingsStore(inMemory: true)
        try settings.makeHistoryStore().save([makeTask(id: "archived", protocolKind: .bitTorrent, status: .completed)])
        let store = DownloadStore(settingsStore: settings, engineController: MockEngineController(client: client))
        _ = await store.refreshTasks()
        XCTAssertEqual(store.tasks.first?.status, .completed)
        XCTAssertNil(store.tasks.first?.primaryControlAction)
        XCTAssertTrue(calls.value().contains("aria2.forceRemove"))
        XCTAssertTrue(calls.value().contains("aria2.removeDownloadResult"))
        XCTAssertEqual(calls.value().last, "aria2.saveSession")
    }

    @MainActor
    func testClearingFinishedHistoryNeverDeletesTheDownloadedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keep.bin")
        let data = Data("downloaded content".utf8)
        try data.write(to: file)
        let client = try makeRPCClient { request in
            try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client, isRunning: false))
        store.tasks = [makeTask(id: "file", status: .completed, files: [DownloadFile(index: 1, path: file.path, length: Int64(data.count), completedLength: Int64(data.count), isSelected: true)])]
        await store.purgeCompletedRecords()
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    @MainActor
    func testRestoredTorrentSelectionKeepsOriginalGIDAndCancelKeepsTask() async throws {
        let calls = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            if method == "aria2.tellStatus" {
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":{"gid":"select-existing","status":"paused","bittorrent":{"fileSelectionState":"awaiting"}}}"#)
            }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        var restored = makeTask(id: "select-existing", protocolKind: .bitTorrent, status: .paused,
            files: [DownloadFile(index: 1, path: "/tmp/payload", length: 100, completedLength: 30, isSelected: true)])
        restored.requiresFileSelection = true
        store.tasks = [restored]
        await store.resume(restored)
        XCTAssertEqual(store.bitTorrentSelectionSession?.downloadTaskID, restored.id)
        XCTAssertEqual(store.bitTorrentSelectionSession?.removesTaskOnCancel, false)
        await store.cancelBitTorrentFileSelection()
        XCTAssertEqual(store.tasks.first?.id, restored.id)
        XCTAssertTrue(calls.value().isEmpty)
        await store.resume(restored)
        let started = await store.confirmBitTorrentFileSelection()
        XCTAssertTrue(started)
        XCTAssertTrue(calls.value().contains("aria2.unpause"))
        XCTAssertFalse(calls.value().contains("aria2.addUri"))
        XCTAssertFalse(calls.value().contains("aria2.forceRemove"))
    }

    @MainActor
    func testScheduledStartUsesSameGIDOnlyAfterManualArmingAndDueTime() async throws {
        let calls = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            if method == "aria2.unpause" || method == "aria2.pause" {
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":"scheduled"}"#)
            }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let settings = try PersistentSettingsStore(inMemory: true)
        let store = DownloadStore(settingsStore: settings, engineController: MockEngineController(client: client))
        var task = makeTask(id: "scheduled", status: .paused)
        let deadline = Date().addingTimeInterval(3600)
        task.scheduledStart = deadline
        store.tasks = [task]
        await store.runDownloadPlans(now: deadline.addingTimeInterval(1))
        XCTAssertFalse(calls.value().contains("aria2.unpause"))
        await store.scheduleTask(task.id, at: deadline)
        XCTAssertTrue(store.armedScheduledTaskIDs.contains(task.id))
        await store.runDownloadPlans(now: deadline.addingTimeInterval(-1))
        XCTAssertFalse(calls.value().contains("aria2.unpause"))
        let reloaded = DownloadStore(settingsStore: settings, engineController: MockEngineController(client: client))
        XCTAssertEqual(reloaded.tasks.first?.scheduledStart, deadline)
        XCTAssertTrue(reloaded.armedScheduledTaskIDs.isEmpty)
        await reloaded.runDownloadPlans(now: deadline.addingTimeInterval(1))
        XCTAssertFalse(calls.value().contains("aria2.unpause"))
        await store.runDownloadPlans(now: deadline)
        XCTAssertEqual(calls.value().filter { $0 == "aria2.unpause" }.count, 1)
        XCTAssertNil(store.tasks.first?.scheduledStart)
        await store.runDownloadPlans(now: deadline.addingTimeInterval(5))
        XCTAssertEqual(calls.value().filter { $0 == "aria2.unpause" }.count, 1)
    }

    @MainActor
    func testPauseAllDisarmsScheduledTasksAndPollKeepsDate() async throws {
        let client = try makeRPCClient { request in
            try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        let task = makeTask(id: "scheduled", status: .paused)
        store.tasks = [task]
        let date = Date().addingTimeInterval(3600)
        await store.scheduleTask(task.id, at: date)
        XCTAssertTrue(store.armedScheduledTaskIDs.contains(task.id))
        XCTAssertEqual(DownloadHistoryStore.merge([task], existing: store.tasks, hidden: []).first?.scheduledStart, date)
        await store.pauseAll()
        XCTAssertTrue(store.armedScheduledTaskIDs.isEmpty)
        XCTAssertNil(store.tasks.first?.scheduledStart)
    }

    func testQueuePositionsIncludeHiddenEngineEntries() async throws {
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request)
            return try Self.rpcHTTPResponse(for: request, body: method == "aria2.tellWaiting"
                ? #"{"result":[{"gid":"hidden","status":"paused","ed2k":{"searchActive":"true"}},{"gid":"visible","status":"paused"}]}"#
                : #"{"result":[]}"#)
        }
        let tasks = try await client.pollTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.queuePosition, 1)
        let queue = try await client.waitingQueueIDs()
        XCTAssertEqual(queue, ["hidden", "visible"])
    }

    @MainActor
    func testRepairMediaPassesUpdatedAuthenticationWithoutAddingOrRemovingTask() async throws {
        let calls = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            if method == "aria2.tellStatus" {
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":{"gid":"repair","status":"error","media":{"state":"error","errorCode":"auth"}}}"#)
            }
            if method == "aria2.getOption" {
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":{"header":"X-Test: keep\nAuthorization: old"}}"#)
            }
            if method == "aria2.retryMedia" {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBodyData(from: request)) as? [String: Any])
                let params = try XCTUnwrap(body["params"] as? [Any])
                XCTAssertEqual(params[1] as? String, "repair")
                XCTAssertEqual((params[2] as? [String: String])?["header"], "X-Test: keep\nAuthorization: Bearer new")
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":"repair"}"#)
            }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        var task = makeTask(id: "repair", status: .failed)
        task.media = MediaTaskProgress(state: "error")
        store.tasks = [task]
        try await store.repairConnection(task, repair: DownloadConnectionRepair(authorization: "Bearer new"))
        XCTAssertTrue(calls.value().contains("aria2.retryMedia"))
        XCTAssertTrue(calls.value().contains("aria2.saveSession"))
        XCTAssertFalse(calls.value().contains("aria2.addUri"))
        XCTAssertFalse(calls.value().contains("aria2.forceRemove"))
    }

    @MainActor
    func testCancellingDuringScheduleSaveDoesNotArmTaskLater() async throws {
        let entered = LockedBox(false)
        let release = DispatchSemaphore(value: 0)
        let client = try makeRPCClient { request in
            if try Self.captureRPCMethod(from: request) == "aria2.saveSession" {
                entered.withValue { $0 = true }
                _ = release.wait(timeout: .now() + 3)
            }
            return try Self.responseForStoreMutationPoll(method: Self.captureRPCMethod(from: request), request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        store.tasks = [makeTask(id: "schedule-race", status: .paused)]
        let work = Task { await store.scheduleTask("schedule-race", at: Date().addingTimeInterval(3600)) }
        let ready = await waitForMainActorCondition(timeout: 2) { entered.value() }
        XCTAssertTrue(ready)
        store.cancelSchedule("schedule-race")
        release.signal()
        await work.value
        XCTAssertTrue(store.armedScheduledTaskIDs.isEmpty)
        XCTAssertNil(store.tasks.first?.scheduledStart)
    }

    @MainActor
    func testScheduledStartFailureStaysVisibleWithoutAutomaticRetry() async throws {
        let calls = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            if method == "aria2.unpause" {
                return try Self.rpcHTTPResponse(for: request, body: #"{"error":{"code":1,"message":"temporarily unavailable"}}"#)
            }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        store.tasks = [makeTask(id: "fail-start", status: .paused)]
        let deadline = Date().addingTimeInterval(3600)
        await store.scheduleTask("fail-start", at: deadline)
        store.preferences.bandwidthSchedule.enabled = true
        store.preferences.bandwidthSchedule.downloadKB = -1
        await store.runDownloadPlans(now: deadline)
        XCTAssertNotNil(store.bandwidthPlanIssue)
        XCTAssertNotNil(store.downloadPlanIssue)
        XCTAssertTrue(store.armedScheduledTaskIDs.isEmpty)
        await store.runDownloadPlans(now: deadline.addingTimeInterval(2))
        XCTAssertNotNil(store.downloadPlanIssue)
        XCTAssertEqual(calls.value().filter { $0 == "aria2.unpause" }.count, 1)
    }

    func testLiveTransferRPCUsesProtocolSpecificConnectionsAndKeepsPausedMap() async throws {
        let calls = LockedBox<[String]>([])
        let phase = LockedBox("active")
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            let body: String
            switch method {
            case "aria2.tellStatus":
                body = "{\"result\":{\"gid\":\"live\",\"status\":\"\(phase.value())\",\"downloadSpeed\":\"1024\",\"uploadSpeed\":\"512\",\"uploadLength\":\"4096\",\"connections\":\"1\",\"bitfield\":\"80\",\"numPieces\":\"2\",\"pieceLength\":\"10\",\"bittorrent\":{}}}"
            case "aria2.getPeers": body = #"{"result":[{"ip":"127.0.0.1","port":"6881","state":"connected","downloadSpeed":"1024","uploadSpeed":"512","progress":"0.5"}]}"#
            case "aria2.getServers": body = #"{"result":[{"index":"1","servers":[{"uri":"https://example.org/file?token=hidden","downloadSpeed":"1024"}]}]}"#
            default: throw URLError(.badServerResponse)
            }
            return try Self.rpcHTTPResponse(for: request, body: body)
        }
        let bt = try await client.transferSnapshot("live", isTorrent: true)
        XCTAssertEqual(bt.peers.count, 1)
        XCTAssertEqual(bt.uploadSpeed, 512)
        XCTAssertEqual(bt.uploaded, 4096)
        XCTAssertEqual(calls.value(), ["aria2.tellStatus", "aria2.getPeers"])
        calls.set([])
        let http = try await client.transferSnapshot("live", isTorrent: false)
        XCTAssertEqual(http.servers.first?.address, "example.org")
        XCTAssertEqual(calls.value(), ["aria2.tellStatus", "aria2.getServers"])
        for status in ["paused", "complete", "error", "waiting"] {
            phase.set(status); calls.set([])
            let snapshot = try await client.transferSnapshot("live", isTorrent: true)
            XCTAssertEqual(snapshot.pieces?.completedCount, 1)
            XCTAssertEqual(snapshot.downloadSpeed, 0)
            XCTAssertEqual(snapshot.uploadSpeed, 0)
            XCTAssertTrue(snapshot.peers.isEmpty)
            XCTAssertEqual(calls.value(), ["aria2.tellStatus"])
        }
    }

    func testFinishingBetweenStatusAndConnectionsKeepsFinalSnapshot() async throws {
        let status = LockedBox("active")
        let client = try makeRPCClient { request in
            if try Self.captureRPCMethod(from: request) == "aria2.getServers" {
                status.set("complete")
                return try Self.rpcHTTPResponse(for: request, statusCode: 400,
                    body: #"{"error":{"code":1,"message":"No active download for GID#test"}}"#)
            }
            return try Self.rpcHTTPResponse(for: request, body: "{\"result\":{\"gid\":\"test\",\"status\":\"\(status.value())\"}}")
        }
        let snapshot = try await client.transferSnapshot("test", isTorrent: false)
        XCTAssertEqual(snapshot.connections, 0)
        XCTAssertEqual(snapshot.downloadSpeed, 0)
        XCTAssertTrue(snapshot.servers.isEmpty)
    }

    @MainActor
    func testLoadedSummarySpeedFieldsFitWithoutHorizontalClipping() async throws {
        let calls = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            XCTAssertEqual(method, "aria2.getOption")
            return try Self.rpcHTTPResponse(for: request,
                body: #"{"result":{"max-download-limit":"256K","max-upload-limit":"64K"}}"#)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        defer { store.shutdown() }
        var task = makeTask(id: "summary-layout", status: .paused)
        task.protocolKind = .bitTorrent
        task.destination = "/Users/example/Downloads/这是一个很长的下载文件夹名称 Example Torrent"
        store.tasks = [task]
        store.runtime = EngineRuntimeSnapshot(phase: .running(pid: 1))
        let output = try Aria2NextPaths.supportDirectory().appendingPathComponent("Design Previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for width: CGFloat in [400, 600] {
            let host = NSHostingController(rootView: TaskSummaryView(task: task, showDetails: {})
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)).environmentObject(store))
            host.sizingOptions = []
            host.view.frame = NSRect(x: 0, y: 0, width: width, height: 280)
            let window = NSWindow(contentRect: host.view.frame,
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0
            window.contentViewController = host; window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(350))
            let content = host.view
            content.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
            let fields = descendants(content).compactMap { $0 as? NSTextField }.filter(\.isEditable)
            XCTAssertEqual(fields.count, 2, "Both reported speed limits must be visible")
            XCTAssertEqual(Set(fields.map(\.stringValue)), ["256", "64"])
            for field in fields {
                let rect = field.convert(field.bounds, to: content).insetBy(dx: -3, dy: -3)
                XCTAssertTrue(content.bounds.contains(rect), "Native fields and focus rings must fit: \(rect)")
            }
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("summary-config-\(Int(width)).png"))
        }
        XCTAssertEqual(calls.value(), ["aria2.getOption", "aria2.getOption"])
        print("SUMMARY_PREVIEW_OUTPUT=\(output.path)")
    }

    @MainActor
    func testInlineBandwidthChangesSaveTheSameTaskWithoutResumingIt() async throws {
        let calls = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            if method == "aria2.changeOption" {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBodyData(from: request)) as? [String: Any])
                let params = try XCTUnwrap(object["params"] as? [Any])
                XCTAssertEqual(params[1] as? String, "bandwidth")
                XCTAssertEqual(params.last as? [String: String], ["max-download-limit": "256K", "max-upload-limit": "64K"])
            }
            return try Self.rpcHTTPResponse(for: request, body: #"{"result":"OK"}"#)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        defer { store.shutdown() }
        var task = makeTask(id: "bandwidth", status: .paused)
        task.protocolKind = .bitTorrent
        store.tasks = [task]
        let limits = try TaskBandwidthLimits(options: ["max-download-limit": "256K", "max-upload-limit": "64K"], isTorrent: true)
        try await store.setTaskBandwidthLimits(task, limits: limits)
        XCTAssertEqual(calls.value(), ["aria2.changeOption", "aria2.saveSession"])
        XCTAssertEqual(store.tasks.first?.status, .paused)
        calls.set([])
        store.tasks[0].isAvailableInEngine = false
        do { try await store.setTaskBandwidthLimits(task, limits: limits); XCTFail("Offline history cannot mutate the engine") } catch {}
        XCTAssertTrue(calls.value().isEmpty)
    }

    @MainActor
    func testTorrentUploadLimitChangesLiveWithoutPausingOrResuming() async throws {
        let calls = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            if method == "aria2.changeOption" {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBodyData(from: request)) as? [String: Any])
                let params = try XCTUnwrap(object["params"] as? [Any])
                XCTAssertEqual(params.last as? [String: String], ["max-upload-limit": "64K"])
            }
            return try Self.rpcHTTPResponse(for: request, body: #"{"result":"OK"}"#)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        var task = makeTask(id: "upload", status: .active)
        task.protocolKind = .bitTorrent
        store.tasks = [task]
        try await store.setTorrentUploadLimit(task, kib: 64)
        XCTAssertEqual(calls.value(), ["aria2.changeOption", "aria2.saveSession"])
        XCTAssertEqual(store.tasks.first?.status, .active)
        calls.set([])
        do { try await store.setTorrentUploadLimit(task, kib: -1); XCTFail("Negative limit must fail") } catch {}
        XCTAssertTrue(calls.value().isEmpty)
        store.tasks[0].isAvailableInEngine = false
        do { try await store.setTorrentUploadLimit(task, kib: 64); XCTFail("Offline task must fail") } catch {}
        XCTAssertTrue(calls.value().isEmpty)
    }

    @MainActor
    func testBatchResumeSkipsUnchosenTorrentAndMediaAndPersistsPartialSuccessOnce() async throws {
        let calls = LockedBox<[String]>([])
        let resumed = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            if method == "aria2.getOption" {
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":{"media-pause-after-probe":"true"}}"#)
            }
            if method == "aria2.unpause" {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBodyData(from: request)) as? [String: Any])
                let params = try XCTUnwrap(object["params"] as? [String])
                let id = try XCTUnwrap(params.last)
                resumed.withValue { $0.append(id) }
                if id == "a-fails" { throw URLError(.cannotConnectToHost) }
                return try Self.rpcHTTPResponse(for: request, body: #"{"result":"OK"}"#)
            }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        defer { store.shutdown() }
        var torrent = makeTask(id: "torrent", protocolKind: .bitTorrent, status: .paused)
        torrent.requiresFileSelection = true
        var media = makeTask(id: "media", status: .paused)
        media.media = MediaTaskProgress(state: "paused")
        store.tasks = [makeTask(id: "a-fails", status: .paused), makeTask(id: "b-works", status: .paused),
                       torrent, media, makeTask(id: "untouched", status: .paused), makeTask(id: "done", status: .completed)]
        await store.controlSelected(["a-fails", "b-works", "torrent", "media", "done", "missing"], action: .resume)
        XCTAssertEqual(resumed.value(), ["a-fails", "b-works"])
        XCTAssertEqual(calls.value().filter { $0 == "aria2.saveSession" }.count, 1)
        XCTAssertFalse(calls.value().contains("aria2.unpauseAll"))
        XCTAssertFalse(store.inputCoordinator.hasManualRequest)
        XCTAssertNotNil(store.batchOperationIssue)
    }

    @MainActor
    func testMultiSelectionContextAndRemovalKeepExactIDsAndOfflineTombstones() async throws {
        let calls = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let controller = MockEngineController(client: client, isRunning: false)
        let settings = try PersistentSettingsStore(inMemory: true)
        let store = DownloadStore(settingsStore: settings, engineController: controller)
        defer { store.shutdown() }
        store.tasks = [makeTask(id: "a", status: .completed), makeTask(id: "b", status: .failed), makeTask(id: "c", status: .paused)]
        store.selectedTaskIDs = ["a", "b"]
        XCTAssertNil(store.selectedTaskID)
        XCTAssertEqual(DownloadSelection.contextIDs(clicked: "a", selected: store.selectedTaskIDs), ["a", "b"])
        XCTAssertEqual(DownloadSelection.contextIDs(clicked: "c", selected: store.selectedTaskIDs), ["c"])
        store.beginRemoveSelected(store.selectedTaskIDs)
        let request = try XCTUnwrap(store.removalRequest)
        XCTAssertEqual(Set(request.tasks.map(\.id)), ["a", "b"])
        store.selectedTaskID = "c"
        await store.confirmRemoval(request, includingFiles: false)
        XCTAssertEqual(store.tasks.map(\.id), ["c"])
        XCTAssertEqual(store.selectedTaskID, "c")
        XCTAssertTrue(calls.value().isEmpty)
        let reloaded = DownloadStore(settingsStore: settings, engineController: controller)
        defer { reloaded.shutdown() }
        XCTAssertFalse(reloaded.tasks.contains { ["a", "b"].contains($0.id) })
    }

    @MainActor
    func testIndependentScheduleClockStartsEvenWhileRefreshIsBackedOff() async throws {
        let calls = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            if method.hasPrefix("aria2.tell") || method == "aria2.getGlobalStat" { throw URLError(.timedOut) }
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        defer { store.shutdown() }
        store.tasks = [makeTask(id: "scheduled", status: .paused)]
        store.startPolling()
        await store.scheduleTask("scheduled", at: Date().addingTimeInterval(0.15))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !calls.value().contains("aria2.unpause"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(calls.value().filter { $0 == "aria2.unpause" }.count, 1)
        XCTAssertTrue(store.armedScheduledTaskIDs.isEmpty)
        XCTAssertFalse(calls.value().contains("aria2.tellActive"), "The schedule fires before the independent refresh timer")
    }

    @MainActor
    func testResumeAllAlsoKeepsUnselectedTorrentPaused() async throws {
        let calls = LockedBox<[String]>([])
        let client = try makeRPCClient { request in
            let method = try Self.captureRPCMethod(from: request, into: calls)
            return try Self.responseForStoreMutationPoll(method: method, request: request)
        }
        let store = try makeInjectedStore(engineController: MockEngineController(client: client))
        defer { store.shutdown() }
        var task = makeTask(id: "selection-needed", protocolKind: .bitTorrent, status: .paused)
        task.requiresFileSelection = true
        store.tasks = [task]
        await store.resumeAll()
        XCTAssertFalse(calls.value().contains("aria2.unpauseAll"))
        XCTAssertFalse(calls.value().contains("aria2.unpause"))
        XCTAssertNotNil(store.batchOperationIssue)
    }

    private static func rpcHTTPResponse(
        for request: URLRequest,
        statusCode: Int = 200,
        body: String
    ) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
        return (response, Data(body.utf8))
    }

    private static func responseForStoreMutationPoll(
        method: String,
        request: URLRequest
    ) throws -> (HTTPURLResponse, Data) {
        switch method {
        case "aria2.tellActive", "aria2.tellWaiting", "aria2.tellStopped":
            return try rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"tasks","result":[]}"#)
        case "aria2.getGlobalStat":
            return try rpcHTTPResponse(
                for: request,
                body: #"{"jsonrpc":"2.0","id":"stat","result":{"downloadSpeed":"0","uploadSpeed":"0","numActive":"0","numWaiting":"0","numStopped":"0"}}"#
            )
        default:
            return try rpcHTTPResponse(for: request, body: #"{"jsonrpc":"2.0","id":"ok","result":"OK"}"#)
        }
    }

    private static func requestBodyData(from request: URLRequest) throws -> Data {
        if let httpBody = request.httpBody {
            return httpBody
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? RPCError.nonHTTPResponse
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func captureRPCMethod(from request: URLRequest, into box: LockedBox<[String]>) throws -> String {
        let method = try captureRPCMethod(from: request)
        var captured = box.value()
        captured.append(method)
        box.set(captured)
        return method
    }

    private static func captureRPCMethod(from request: URLRequest) throws -> String {
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try requestBodyData(from: request)) as? [String: Any])
        return try XCTUnwrap(payload["method"] as? String)
    }

    private func errorDescription(_ error: RPCError) -> String {
        error.localizedDescription
    }

}

@MainActor
private final class MockEngineController: Aria2EngineControlling {
    var isRunning: Bool
    var hasLaunchedProcess: Bool
    var terminationStatus: Int32?
    var clientToReturn: Aria2RPCClient
    var selectedInstallation: EngineInstallation?
    var rejectedVersion: EngineVersion?
    func selectInstallation(_ installation: EngineInstallation) { selectedInstallation = installation }
    var startCallCount = 0
    var stopCallCount = 0
    var terminateForAppExitCallCount = 0

    init(
        client: Aria2RPCClient,
        isRunning: Bool = true,
        hasLaunchedProcess: Bool = true,
        terminationStatus: Int32? = nil
    ) {
        self.clientToReturn = client
        self.isRunning = isRunning
        self.hasLaunchedProcess = hasLaunchedProcess
        self.terminationStatus = terminationStatus
    }

    func start(settings: EngineSettings) async throws -> EngineRuntimeSnapshot {
        startCallCount += 1
        if let rejectedVersion, selectedInstallation?.version == rejectedVersion { throw EngineError.notRunning }
        isRunning = true
        hasLaunchedProcess = true
        return EngineRuntimeSnapshot(phase: .running(pid: 1234))
    }

    func stop() async throws -> EngineRuntimeSnapshot {
        stopCallCount += 1
        isRunning = false
        hasLaunchedProcess = false
        return EngineRuntimeSnapshot(phase: .stopped)
    }

    func terminateForAppExit() {
        terminateForAppExitCallCount += 1
        isRunning = false
        hasLaunchedProcess = false
    }

    @discardableResult
    func clearTerminatedProcess() -> Int32? {
        guard !isRunning else { return nil }
        let status = terminationStatus
        terminationStatus = nil
        return status
    }

    func client() throws -> Aria2RPCClient {
        guard isRunning else { throw EngineError.notRunning }
        return clientToReturn
    }
}

private final class MockPowerAssertionController: PowerAssertionControlling {
    private(set) var isAcquired = false
    private(set) var updateCalls: [(preventSleep: Bool, hasActiveDownloads: Bool)] = []
    private(set) var releaseCallCount = 0
    var errorToThrow: Error?

    func update(preventSleep: Bool, hasActiveDownloads: Bool) throws {
        updateCalls.append((preventSleep, hasActiveDownloads))
        if let errorToThrow {
            throw errorToThrow
        }
        isAcquired = preventSleep && hasActiveDownloads
    }

    func release() {
        releaseCallCount += 1
        isAcquired = false
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    func set(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func value() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storedValue)
    }
}

private actor SuspendedTrackerFetcher: BitTorrentTrackerSourceFetching {
    private var continuation: CheckedContinuation<TrackerSourceFetchResult, Never>?
    private var finished = false

    func fetchTrackerSources(_ urls: [String]) async -> TrackerSourceFetchResult {
        if finished { return TrackerSourceFetchResult(data: [], failures: []) }
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        finished = true
        continuation?.resume(returning: TrackerSourceFetchResult(data: [], failures: []))
        continuation = nil
    }
}

private final class MockTrackerFetcher: BitTorrentTrackerSourceFetching, @unchecked Sendable {
    let requestedSources = LockedBox<[String]>([])
    private let result: TrackerSourceFetchResult

    init(result: TrackerSourceFetchResult) {
        self.result = result
    }

    func fetchTrackerSources(_ urls: [String]) async -> TrackerSourceFetchResult {
        requestedSources.set(urls)
        return result
    }
}

private final class MockED2KBootstrapFetcher: ED2KBootstrapFetching, @unchecked Sendable {
    let requestedArguments = LockedBox<[(serverMetURL: String, nodesDatURL: String, proxyURL: String)]>([])
    var result = ED2KBootstrapFetchResult(serverMet: Data("server".utf8), nodesDat: Data("nodes".utf8))
    var errorToThrow: Error?

    func fetch(serverMetURL: String, nodesDatURL: String, proxyURL: String) async throws -> ED2KBootstrapFetchResult {
        var arguments = requestedArguments.value()
        arguments.append((serverMetURL, nodesDatURL, proxyURL))
        requestedArguments.set(arguments)
        if let errorToThrow {
            throw errorToThrow
        }
        return result
    }
}

private final class RPCMockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlers = LockedBox<[String: Handler]>([:])

    static func register(_ handler: @escaping Handler, for id: String) {
        handlers.withValue { $0[id] = handler }
    }

    static func unregisterHandler(for id: String) {
        handlers.withValue { $0[id] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handlerID = request.url?.lastPathComponent ?? ""
        guard let handler = Self.handlers.value()[handlerID] else {
            client?.urlProtocol(self, didFailWithError: RPCError.nonHTTPResponse)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor StartupEngineManager: EngineInstallationManaging {
    var missing: Bool
    var failInstall: Bool
    var offline: Bool
    var releaseChecks = 0
    var activationCount = 0
    var failActivation = false
    func rejectActivation() { failActivation = true }
    var installDelay: Duration = .zero
    func setInstallDelay(_ delay: Duration) { installDelay = delay }
    func activate(_ installation: EngineInstallation) async throws {
        if failActivation { throw CocoaError(.fileWriteOutOfSpace) }
        activationCount += 1
    }
    func backupRuntimeState() async throws -> EngineRuntimeBackup? { nil }
    init(missing: Bool = false, failInstall: Bool = false, offline: Bool = false) {
        self.missing = missing; self.failInstall = failInstall; self.offline = offline
    }
    func allowInstall() { failInstall = false }
    func localInstallation() async -> EngineInstallation? {
        missing ? nil : EngineInstallation(executableURL: URL(fileURLWithPath: "/fake/aria2-next"), version: EngineVersion("2.9.0")!)
    }
    func latestRelease() async throws -> EngineRelease {
        releaseChecks += 1
        if offline { throw URLError(.notConnectedToInternet) }
        return EngineRelease(version: EngineVersion("2.10.0")!, downloadURL: URL(string: "https://example.com/engine")!, checksumURL: URL(string: "https://example.com/checksum")!)
    }
    func install(_ release: EngineRelease, progress: @escaping @Sendable (EngineInstallationProgress) async -> Void) async throws -> EngineInstallation {
        await progress(.init(stage: .downloading, completedBytes: 250, totalBytes: 1_000, bytesPerSecond: 100))
        try await Task.sleep(for: installDelay)
        if failInstall { throw URLError(.notConnectedToInternet) }
        return EngineInstallation(executableURL: URL(fileURLWithPath: "/unused"), version: release.version)
    }
}
