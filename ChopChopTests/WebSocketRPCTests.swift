import Foundation
import XCTest
@testable import ChopChop

final class WebSocketRPCTests: XCTestCase {
    private func transport(_ socket: StubRPCSocket) -> Aria2WebSocketTransport {
        Aria2WebSocketTransport(endpoint: URL(string: "ws://127.0.0.1:29200/jsonrpc")!, token: "test-secret",
            makeSocket: { _ in socket })
    }

    private func eventually(_ predicate: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    func testWebSocketOnlyAuthenticatesAndReceivesAllSixNotifications() async throws {
        let socket = StubRPCSocket()
        let transport = transport(socket)
        let connected = expectation(description: "authenticated")
        let notifications = expectation(description: "all six native notifications")
        notifications.expectedFulfillmentCount = 6
        let events = Task {
            for await event in transport.events {
                switch event {
                case .connected: connected.fulfill()
                case .download(_, let gid): XCTAssertEqual(gid, "download"); notifications.fulfill()
                case .disconnected: XCTFail("Unexpected disconnect")
                }
            }
        }
        await transport.start()
        await transport.start()
        await fulfillment(of: [connected], timeout: 2)
        socket.reply(id: "unknown", result: "ignore")
        for (index, method) in ["onDownloadStart", "onDownloadPause", "onDownloadStop", "onDownloadComplete", "onDownloadError", "onBtDownloadComplete"].enumerated() {
            socket.notify("aria2." + method, gid: "download", binary: index.isMultiple(of: 2))
        }
        socket.notify("aria2.unknown", gid: "ignored")
        await fulfillment(of: [notifications], timeout: 2)
        XCTAssertEqual(socket.requests.count, 1)
        XCTAssertEqual(socket.requests.first?["method"] as? String, "aria2.getVersion")
        XCTAssertEqual(socket.requests.first?["params"] as? [String], ["token:test-secret"])
        await transport.close()
        await events.value
        XCTAssertEqual(socket.resumeCount, 1)
    }

    func testHTTPQueriesAndMutationsWorkWhileNotificationHandshakeIsStalled() async throws {
        let socket = StubRPCSocket()
        socket.answerHeartbeat = false
        let stream = transport(socket)
        let methods = TestLocked<[String]>([])
        let fixture = HybridHTTPFixture { request in
            let body = try HybridHTTPFixture.body(request)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.scheme, "http")
            XCTAssertFalse(request.url!.absoluteString.contains("test-secret"))
            XCTAssertEqual((body["params"] as? [Any])?.first as? String, "token:test-secret")
            let method = try XCTUnwrap(body["method"] as? String)
            methods.modify { $0.append(method) }
            return ["result": method == "aria2.getVersion" ? StubRPCSocket.capabilities : "OK"]
        }
        let client = fixture.client(eventStream: stream)
        await client.startEvents()
        try await eventually { socket.requests.count == 1 }
        let version = try await client.getVersion()
        XCTAssertEqual(version.version, "3.0.8")
        try await client.pause("gid")
        try await client.changeGlobalOption(["bt-tracker": "https://tracker.example/announce"])
        try await client.replaceTorrentTrackers("gid", trackers: [.init(url: "https://tracker.example/announce", tier: 3)])
        XCTAssertEqual(methods.value, ["aria2.getVersion", "aria2.pause", "aria2.changeGlobalOption", "aria2.replaceBtTrackers"])
        XCTAssertEqual(socket.requests.count, 1, "All application RPCs must use HTTP")
        await client.close()
    }

    func testHTTPTimeoutDoesNotDropNotificationsOrReplayMutation() async throws {
        let socket = StubRPCSocket()
        let stream = transport(socket)
        let calls = TestLocked(0)
        let fixture = HybridHTTPFixture { _ in
            calls.modify { $0 += 1 }
            throw URLError(.timedOut)
        }
        let client = fixture.client(eventStream: stream)
        let connected = expectation(description: "connected")
        let notification = expectation(description: "notifications survive HTTP failure")
        let events = Task {
            for await event in stream.events {
                switch event {
                case .connected: connected.fulfill()
                case .download: notification.fulfill()
                case .disconnected: XCTFail("HTTP error closed the notification stream")
                }
            }
        }
        await client.startEvents()
        await fulfillment(of: [connected], timeout: 2)
        do { _ = try await client.addDownload(AddDownloadDraft(rawInput: "https://example.com/file"), fallbackDirectory: nil); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        socket.notify("aria2.onDownloadComplete", gid: "existing")
        await fulfillment(of: [notification], timeout: 2)
        XCTAssertEqual(calls.value, 1, "A lost mutation reply must never trigger an automatic retry")
        XCTAssertEqual(socket.resumeCount, 1)
        await client.close()
        await events.value
    }

    func testCancellationAndCloseCancelHTTPRequestsAndRejectStaleClientCopies() async throws {
        let socket = StubRPCSocket()
        let stream = transport(socket)
        let calls = TestLocked(0)
        let fixture = HybridHTTPFixture { request in
            calls.modify { $0 += 1 }
            if try HybridHTTPFixture.body(request)["method"] as? String == "aria2.getVersion" {
                return ["result": StubRPCSocket.capabilities]
            }
            return nil // Remain in flight until cancellation.
        }
        let client = fixture.client(eventStream: stream)
        let staleCopy = client
        await client.startEvents()
        let cancelled = Task { try await client.pause("cancel") }
        try await eventually { calls.value == 1 }
        let concurrentVersion = try await client.getVersion()
        XCTAssertEqual(concurrentVersion.version, "3.0.8", "A stalled HTTP request must not block other requests")
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        let version = try await client.getVersion()
        XCTAssertEqual(version.version, "3.0.8", "Cancelling one request must leave HTTP usable")
        let waiting = Task { try await client.pause("close") }
        try await eventually { calls.value == 4 }
        await client.close()
        do { try await waiting.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        do { try await staleCopy.pause("stale"); XCTFail("Closed client sent a new command") }
        catch { XCTAssertTrue(error is CancellationError) }
        await staleCopy.startEvents()
        XCTAssertEqual(calls.value, 4)
        XCTAssertEqual(socket.resumeCount, 1)
    }

    func testHTTPServerErrorStillRedactsRPCSecret() async throws {
        let fixture = HybridHTTPFixture { _ in ["error": ["code": 1, "message": "Rejected token:test-secret"]] }
        let client = fixture.client()
        do { try await client.pause("gid"); XCTFail("Expected server error") }
        catch {
            XCTAssertFalse(error.localizedDescription.contains("test-secret"))
            XCTAssertTrue(error.localizedDescription.contains("<redacted>"))
        }
        await client.close()
    }

    func testHandshakeDeadlineReconnectsAndRejectsPreAuthenticationNotifications() async throws {
        let first = StubRPCSocket(), second = StubRPCSocket()
        first.answerHeartbeat = false
        let sockets = SocketSequence([first, second])
        let stream = Aria2WebSocketTransport(endpoint: URL(string: "ws://127.0.0.1/jsonrpc")!, token: "test-secret",
            requestTimeout: .milliseconds(100), reconnectDelay: .milliseconds(20), makeSocket: { _ in sockets.next() })
        let disconnected = expectation(description: "handshake timed out")
        let connected = expectation(description: "replacement authenticated")
        let notification = expectation(description: "only current authenticated events")
        let events = Task {
            for await event in stream.events {
                switch event {
                case .connected: connected.fulfill()
                case .disconnected: disconnected.fulfill()
                case .download(_, let gid): XCTAssertEqual(gid, "current"); notification.fulfill()
                }
            }
        }
        await stream.start()
        try await eventually { first.requests.count == 1 }
        first.notify("aria2.onDownloadComplete", gid: "unauthenticated")
        await fulfillment(of: [disconnected, connected], timeout: 2)
        first.notify("aria2.onDownloadComplete", gid: "stale")
        second.notify("aria2.onDownloadComplete", gid: "current")
        await fulfillment(of: [notification], timeout: 2)
        await stream.close()
        await events.value
    }

    func testMalformedFrameReconnectsNotificationStream() async throws {
        let first = StubRPCSocket(), second = StubRPCSocket()
        let sockets = SocketSequence([first, second])
        let stream = Aria2WebSocketTransport(endpoint: URL(string: "ws://127.0.0.1/jsonrpc")!, token: "test-secret",
            reconnectDelay: .milliseconds(20), makeSocket: { _ in sockets.next() })
        let connections = expectation(description: "initial and replacement authenticated")
        connections.expectedFulfillmentCount = 2
        let events = Task {
            for await event in stream.events {
                if event == .connected {
                    connections.fulfill()
                    if second.resumeCount == 0 { first.incoming.yield(.string("not JSON")) }
                }
            }
        }
        await stream.start()
        await fulfillment(of: [connections], timeout: 2)
        await stream.close()
        await events.value
    }

    func testHeartbeatRecoversAnIdleHalfOpenConnection() async throws {
        let first = StubRPCSocket(), second = StubRPCSocket()
        let sockets = SocketSequence([first, second])
        let stream = Aria2WebSocketTransport(endpoint: URL(string: "ws://127.0.0.1/jsonrpc")!, token: "test-secret",
            requestTimeout: .milliseconds(100), heartbeatInterval: .milliseconds(50), reconnectDelay: .milliseconds(20),
            makeSocket: { _ in sockets.next() })
        let reconnected = expectation(description: "heartbeat detected the silent socket")
        let events = Task {
            for await event in stream.events {
                if event == .connected {
                    if second.resumeCount > 0 { reconnected.fulfill(); return }
                    first.answerHeartbeat = false
                }
            }
        }
        await stream.start()
        await fulfillment(of: [reconnected], timeout: 2)
        XCTAssertTrue((first.requests + second.requests).allSatisfy { $0["method"] as? String == "aria2.getVersion" })
        await stream.close()
        await events.value
    }

    func testCloseDuringHandshakeStopsReconnects() async throws {
        let socket = StubRPCSocket()
        socket.answerHeartbeat = false
        let stream = Aria2WebSocketTransport(endpoint: URL(string: "ws://127.0.0.1/jsonrpc")!, token: "test-secret",
            requestTimeout: .milliseconds(40), reconnectDelay: .milliseconds(10), makeSocket: { _ in socket })
        await stream.start()
        try await eventually { socket.requests.count == 1 }
        await stream.close()
        await stream.start()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(socket.resumeCount, 1)
    }

    func testEventAwareRefreshStillSamplesActiveProgressAndReconcilesIdleState() {
        XCTAssertEqual(DownloadRefreshPolicy.interval(foreground: true, hasTransfers: true, failures: 0, receivesEvents: true), .seconds(1))
        XCTAssertEqual(DownloadRefreshPolicy.interval(foreground: false, hasTransfers: true, failures: 0, receivesEvents: true), .seconds(5))
        XCTAssertEqual(DownloadRefreshPolicy.interval(foreground: true, hasTransfers: false, failures: 0, receivesEvents: true), .seconds(60))
        XCTAssertEqual(DownloadRefreshPolicy.interval(foreground: true, hasTransfers: false, failures: 0, receivesEvents: false), .seconds(8))
    }
}

private final class TestLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    func modify(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}

private final class HybridHTTPFixture: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> [String: Any]?
    let endpoint = URL(string: "http://127.0.0.1/\(UUID().uuidString)")!
    let session: URLSession
    init(_ handler: @escaping Handler) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HybridURLProtocol.self]
        session = URLSession(configuration: configuration)
        HybridURLProtocol.handlers.modify { $0[endpoint.path] = handler }
    }
    deinit {
        HybridURLProtocol.handlers.modify { $0[endpoint.path] = nil }
        session.invalidateAndCancel()
    }
    func client(eventStream: Aria2WebSocketTransport? = nil) -> Aria2RPCClient {
        Aria2RPCClient(endpoint: endpoint, token: "test-secret", session: session, eventStream: eventStream)
    }
    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class HybridURLProtocol: URLProtocol {
    static let handlers = TestLocked<[String: HybridHTTPFixture.Handler]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handlers.value[request.url!.path])
            guard let body = try handler(request) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class StubRPCSocket: RPCWebSocketConnection, @unchecked Sendable {
    static var capabilities: [String: Any] { ["product": "aria2-next", "version": "3.0.8", "rpcVersion": "1.1.0",
        "enabledFeatures": ["BitTorrent"], "mediaFeatures": []] }
    private let messages: AsyncThrowingStream<URLSessionWebSocketTask.Message, any Error>
    let incoming: AsyncThrowingStream<URLSessionWebSocketTask.Message, any Error>.Continuation
    private let lock = NSLock()
    private var storedRequests: [[String: Any]] = []
    private var resumes = 0
    private var respondsToHeartbeat = true
    var answerHeartbeat: Bool {
        get { lock.withLock { respondsToHeartbeat } }
        set { lock.withLock { respondsToHeartbeat = newValue } }
    }
    var requests: [[String: Any]] { lock.withLock { storedRequests } }
    var resumeCount: Int { lock.withLock { resumes } }

    init() { (messages, incoming) = AsyncThrowingStream.makeStream() }
    func resume() { lock.withLock { resumes += 1 } }
    func cancel() { incoming.finish(throwing: URLError(.cancelled)) }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        for try await message in messages { return message }
        throw URLError(.networkConnectionLost)
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else { throw URLError(.cannotParseResponse) }
        let request = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        lock.withLock { storedRequests.append(request) }
        if request["method"] as? String == "aria2.getVersion", answerHeartbeat {
            reply(id: request["id"] as! String, result: Self.capabilities)
        }
    }
    func reply(id: String, result: Any, binary: Bool = false) { push(["jsonrpc": "2.0", "id": id, "result": result], binary: binary) }
    func notify(_ method: String, gid: String, binary: Bool = false) { push(["jsonrpc": "2.0", "method": method, "params": [["gid": gid]]], binary: binary) }
    func push(_ object: [String: Any], binary: Bool = false) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        incoming.yield(binary ? .data(data) : .string(String(decoding: data, as: UTF8.self)))
    }
}

private final class SocketSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [StubRPCSocket]
    init(_ sockets: [StubRPCSocket]) { self.sockets = sockets }
    func next() -> StubRPCSocket { lock.withLock { sockets.count > 1 ? sockets.removeFirst() : sockets[0] } }
}
