import Foundation
import XCTest
@testable import ChopChop

final class BrowserCaptureTests: XCTestCase {
    private let token = String(repeating: "a", count: 64)
    private func request(body: String = #"{"urls":["https://example.com/file"]}"#, extra: String = "") -> Data {
        Data("POST /v1/import HTTP/1.1\r\nHost: 127.0.0.1:29101\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(extra)\r\n\(body)".utf8)
    }

    func testIncrementalHTTPParsingPreservesSignedSourceOnlyInPayload() throws {
        let data = request(body: #"{"urls":["https://example.com/video.m3u8?signature=private"]}"#)
        if case .incomplete = BrowserCaptureHTTP.parse(data.prefix(40)) {} else { XCTFail("Partial headers must wait") }
        guard case .request(let headers, let body) = BrowserCaptureHTTP.parse(data) else { return XCTFail("Valid request rejected") }
        XCTAssertEqual(BrowserCaptureHTTP.authorizedURLs(headers: headers, body: body, token: token, port: 29101), ["https://example.com/video.m3u8?signature=private"])
    }

    func testAuthenticationOriginAndHostAreAllRequired() throws {
        guard case .request(let original, let body) = BrowserCaptureHTTP.parse(request()) else { return XCTFail() }
        for (key, value) in [("authorization", "Bearer wrong"), ("host", "evil.example:29101"), ("origin", "https://example.com"), ("content-type", "text/plain")] {
            var headers = original; headers[key] = value
            XCTAssertNil(BrowserCaptureHTTP.authorizedURLs(headers: headers, body: body, token: token, port: 29101), key)
        }
        var extensionHeaders = original
        extensionHeaders["origin"] = "chrome-extension://abcdef"
        XCTAssertNotNil(BrowserCaptureHTTP.authorizedURLs(headers: extensionHeaders, body: body, token: token, port: 29101))
        XCTAssertNil(BrowserCaptureHTTP.authorizedURLs(headers: original, body: body, token: "", port: 29101))
    }

    func testRejectsAmbiguousFramingOversizeBodiesAndUnsafeURLs() throws {
        for data in [request(extra: "Content-Length: 1\r\n"), request(extra: "Transfer-Encoding: chunked\r\n"),
                     Data("POST /v1/import HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8),
                     Data(repeating: 65, count: BrowserCaptureHTTP.maximumHeader + 1)] {
            if case .rejected = BrowserCaptureHTTP.parse(data) {} else { XCTFail("Unsafe request accepted") }
        }
        for url in ["file:///tmp/secret", "javascript:alert(1)", "https://user:password@example.com/file"] {
            let data = request(body: "{\"urls\":[\"\(url)\"]}")
            guard case .request(let headers, let body) = BrowserCaptureHTTP.parse(data) else { return XCTFail() }
            XCTAssertNil(BrowserCaptureHTTP.authorizedURLs(headers: headers, body: body, token: token, port: 29101))
        }
    }

    @MainActor
    func testLoopbackBridgeRequiresPairingQueuesInputAndStopsCleanly() async throws {
        let server = BrowserCaptureServer()
        server.start(token: token, port: 0)
        defer { server.stop() }
        for _ in 0..<100 where !server.isListening { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(server.isListening, server.status)
        guard server.isListening else { return }
        XCTAssertNotEqual(server.port, 0)
        var imported: [String] = []
        server.onImport = { imported = $0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/import")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"urls":["https://example.com/file"]}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, denied) = try await session.data(for: request)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertTrue(imported.isEmpty)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, accepted) = try await session.data(for: request)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 202)
        XCTAssertEqual(imported, ["https://example.com/file"])
        let (_, limited) = try await session.data(for: request)
        XCTAssertEqual((limited as? HTTPURLResponse)?.statusCode, 429)
        server.stop()
        XCTAssertFalse(server.isListening)
    }

    @MainActor
    func testBrowserPairingDefaultsOffAndPersistsWithoutStartingDuringTests() throws {
        let persistence = try PersistentSettingsStore(inMemory: true)
        let store = DownloadStore(settingsStore: persistence)
        defer { store.shutdown() }
        XCTAssertFalse(store.preferences.browserCaptureEnabled)
        store.setBrowserCaptureEnabled(true)
        let token = store.preferences.browserCaptureToken
        XCTAssertEqual(token.count, 64)
        XCTAssertFalse(store.browserCapture.isListening)
        XCTAssertEqual(try persistence.loadAppPreferences().browserCaptureToken, token)
        store.resetBrowserPairing()
        XCTAssertNotEqual(store.preferences.browserCaptureToken, token)
        store.setBrowserCaptureEnabled(false)
        XCTAssertFalse(try persistence.loadAppPreferences().browserCaptureEnabled)
    }
}
