import Foundation

nonisolated enum EngineRPCEvent: Equatable, Sendable {
    case connected
    case disconnected
    case download(method: String, gid: String)
}

nonisolated protocol RPCWebSocketConnection: Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel()
}

private nonisolated struct URLSessionRPCSocket: RPCWebSocketConnection {
    let task: URLSessionWebSocketTask
    func resume() { task.resume() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

/// Notification connection for one engine process. Only the internal getVersion
/// heartbeat uses request/reply; application operations and queries always use HTTP.
actor Aria2WebSocketTransport {
    nonisolated let events: AsyncStream<EngineRPCEvent>
    private let eventContinuation: AsyncStream<EngineRPCEvent>.Continuation
    private let endpoint: URL
    private let token: String
    private let session: URLSession
    private let makeSocket: @Sendable (URLRequest) -> any RPCWebSocketConnection
    private let requestTimeout: Duration
    private let heartbeatInterval: Duration
    private let reconnectDelay: Duration
    private var socket: (any RPCWebSocketConnection)?
    private var connectionID = UUID()
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var failures = 0
    private var closed = false
    private var authenticated = false

    private struct Pending {
        var continuation: CheckedContinuation<Data, any Error>
        var timeout: Task<Void, Never>
        var send: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]

    init(endpoint: URL, token: String, requestTimeout: Duration = .seconds(5),
         heartbeatInterval: Duration = .seconds(20), reconnectDelay: Duration = .seconds(1),
         makeSocket: (@Sendable (URLRequest) -> any RPCWebSocketConnection)? = nil) {
        self.endpoint = endpoint
        self.token = token
        self.requestTimeout = requestTimeout
        self.heartbeatInterval = heartbeatInterval
        self.reconnectDelay = reconnectDelay
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        // The connection is long-lived; individual RPCs have their own deadline.
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let session = URLSession(configuration: configuration)
        self.session = session
        self.makeSocket = makeSocket ?? {
            let task = session.webSocketTask(with: $0)
            task.maximumMessageSize = 1024 * 1024 // Notifications and capability replies are small.
            return URLSessionRPCSocket(task: task)
        }
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(128))
    }

    deinit {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        socket?.cancel()
        session.invalidateAndCancel()
        eventContinuation.finish()
    }

    func start() {
        guard !closed, socket == nil, reconnectTask == nil else { return }
        connect()
    }

    private func request(_ payload: Data, id: String) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard let socket else { throw URLError(.networkConnectionLost) }
        let generation = connectionID
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    await self?.disconnect(generation, error: URLError(.timedOut))
                }
                let send = Task { [weak self] in
                    do { try await socket.send(.string(String(decoding: payload, as: UTF8.self))) }
                    catch { await self?.sendFailed(id, generation: generation, error: error) }
                }
                pending[id] = Pending(continuation: continuation, timeout: timeout, send: send)
            }
        } onCancel: {
            Task { await self.finish(id, result: .failure(CancellationError())) }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        reconnectTask?.cancel()
        reconnectTask = nil
        tearDown(error: CancellationError())
        eventContinuation.finish()
        session.invalidateAndCancel()
    }

    private func connect() {
        guard !closed, socket == nil else { return }
        reconnectTask = nil
        let generation = UUID()
        connectionID = generation
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let connection = makeSocket(request)
        socket = connection
        connection.resume()
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await connection.receive()
                    await self?.receive(message, generation: generation)
                }
            } catch { await self?.disconnect(generation, error: error) }
        }
        heartbeatTask = Task { [weak self, heartbeatInterval] in
            do {
                while !Task.isCancelled {
                    try await self?.authenticate(generation)
                    try await Task.sleep(for: heartbeatInterval)
                }
            } catch { await self?.disconnect(generation, error: error) }
        }
    }

    private func authenticate(_ generation: UUID) async throws {
        let id = UUID().uuidString
        let payload = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": "aria2.getVersion", "params": ["token:\(token)"]
        ])
        let data = try await request(payload, id: id)
        let envelope = try JSONDecoder().decode(RPCEnvelope<EngineCapabilities>.self, from: data)
        if let error = envelope.error {
            let message = token.isEmpty ? error.message : error.message.replacingOccurrences(of: token, with: "<redacted>")
            throw RPCError.serverError(code: error.code, message: DownloadPrivacy.redact(message))
        }
        guard let capabilities = envelope.result, capabilities.product == "aria2-next",
              let version = EngineVersion(capabilities.version), version.description == capabilities.version else {
            throw EngineInstallationError.unsupportedVersion
        }
        guard generation == connectionID, socket != nil, !closed else { return }
        failures = 0
        if !authenticated {
            authenticated = true
            // A full snapshot on reconnect recovers notifications missed while offline.
            eventContinuation.yield(.connected)
        }
    }

    private func receive(_ message: URLSessionWebSocketTask.Message, generation: UUID) {
        guard generation == connectionID, !closed else { return }
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["jsonrpc"] as? String == "2.0" else {
            disconnect(generation, error: URLError(.cannotParseResponse))
            return
        }
        if let id = object["id"] as? String {
            finish(id, result: .success(data))
        } else if authenticated, let method = object["method"] as? String,
                  Self.downloadNotifications.contains(method), let params = object["params"] as? [[String: Any]] {
            for item in params {
                if let gid = item["gid"] as? String, !gid.isEmpty {
                    eventContinuation.yield(.download(method: method, gid: gid))
                }
            }
        }
    }

    private static let downloadNotifications: Set<String> = [
        "aria2.onDownloadStart", "aria2.onDownloadPause", "aria2.onDownloadStop",
        "aria2.onDownloadComplete", "aria2.onDownloadError", "aria2.onBtDownloadComplete"
    ]

    private func finish(_ id: String, result: Result<Data, any Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.send.cancel()
        request.continuation.resume(with: result)
    }

    private func sendFailed(_ id: String, generation: UUID, error: any Error) {
        guard pending[id] != nil else { return }
        disconnect(generation, error: error)
    }

    private func tearDown(error: any Error) {
        connectionID = UUID() // Late replies/errors cannot affect the replacement connection.
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socket?.cancel()
        socket = nil
        authenticated = false
        for id in Array(pending.keys) { finish(id, result: .failure(error)) }
    }

    private func disconnect(_ generation: UUID, error: any Error) {
        guard generation == connectionID, !closed else { return }
        tearDown(error: error)
        eventContinuation.yield(.disconnected)
        let delay = reconnectDelay * (1 << min(failures, 5))
        failures += 1
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.connect()
        }
    }
}
