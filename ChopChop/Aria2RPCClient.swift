import Foundation

nonisolated enum RPCError: LocalizedError, Sendable {
    case nonHTTPResponse
    case unexpectedHTTPStatus(code: Int, body: String)
    case invalidResponseBody(method: String, body: String, reason: String)
    case missingResult(method: String, body: String)
    case invalidPort(Int)
    case serverError(code: Int, message: String)
    case tokenMissing

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            String(localized: "Aria2 RPC returned a non-HTTP response.")
        case .unexpectedHTTPStatus(let code, let body):
            if body.isEmpty {
                String(localized: "Aria2 RPC returned HTTP \(code).")
            } else {
                String(localized: "Aria2 RPC returned HTTP \(code).\n\(body)")
            }
        case .invalidResponseBody(let method, let body, let reason):
            if body.isEmpty {
                String(localized: "Aria2 RPC response for \(method) could not be decoded.\n\(reason)")
            } else {
                String(localized: "Aria2 RPC response for \(method) could not be decoded.\n\(reason)\n\(body)")
            }
        case .missingResult(let method, let body):
            if body.isEmpty {
                String(localized: "Aria2 RPC response for \(method) did not contain a result or error.")
            } else {
                String(localized: "Aria2 RPC response for \(method) did not contain a result or error.\n\(body)")
            }
        case .invalidPort(let port):
            String(localized: "RPC port must be between 1 and 65535. Current value: \(port).")
        case .serverError(let code, let message):
            String(localized: "Aria2 RPC error \(code): \(message)")
        case .tokenMissing:
            String(localized: "RPC token is required.")
        }
    }
}

nonisolated struct PartialDownloadSubmissionError: LocalizedError, Sendable {
    var addedIDs: [String]
    var reason: String
    var errorDescription: String? {
        String(localized: "Added \(addedIDs.count) downloads. The remaining links are still in the editor. \(reason)")
    }
}

nonisolated struct Aria2RPCClient: Sendable {
    private static let localSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()
    private let endpoint: URL
    private let token: String
    private let session: URLSession

    init(port: Int, token: String, session: URLSession? = nil) throws {
        guard (1...65535).contains(port) else {
            throw RPCError.invalidPort(port)
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/jsonrpc"
        guard let endpoint = components.url else {
            throw RPCError.invalidPort(port)
        }
        self.init(endpoint: endpoint, token: token, session: session)
    }

    init(endpoint: URL, token: String, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.token = token
        self.session = session ?? Self.localSession
    }

    @concurrent
    func addDownload(
        _ draft: AddDownloadDraft,
        fallbackDirectory: String?,
        autoOrganize: Bool = false,
        ed2kContext: ED2KDownloadContext? = nil
    ) async throws -> String {
        let gids = try await addDownloads(
            draft,
            fallbackDirectory: fallbackDirectory,
            autoOrganize: autoOrganize,
            ed2kContext: ed2kContext
        )
        guard let gid = gids.first else {
            throw RPCError.missingResult(method: "aria2.addUri", body: "")
        }
        return gid
    }

    @concurrent
    func addDownloads(
        _ draft: AddDownloadDraft,
        fallbackDirectory: String?,
        autoOrganize: Bool,
        ed2kContext: ED2KDownloadContext? = nil
    ) async throws -> [String] {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RPCError.tokenMissing
        }
        let normalized = try draft.normalizedResources()
        if normalized.count > 1, normalized.contains(where: { resource in
            URL(string: resource)?.isFileURL == true || resource.hasPrefix("/")
        }) { throw DownloadDraftError.documentRequiresSingleResource }
        let options = try ed2kAwareOptions(
            draft: draft,
            resources: normalized,
            fallbackDirectory: fallbackDirectory,
            autoOrganize: autoOrganize,
            ed2kContext: ed2kContext
        )
        if normalized.count == 1, let resource = normalized.first,
           let document = try localDocument(resource, draft: draft), document.kind == .metalink {
            return try await call("aria2.addMetalink", params: [document.data.base64EncodedString(), options], as: [String].self)
        }
        if draft.treatLinesAsMirrors || normalized.count == 1 {
            let gid: String = try await call("aria2.addUri", params: [normalized, options], as: String.self)
            return [gid]
        }

        var gids: [String] = []
        for uri in normalized {
            var singleDraft = draft
            singleDraft.rawInput = uri
            let singleOptions = try ed2kAwareOptions(
                draft: singleDraft,
                resources: [uri],
                fallbackDirectory: fallbackDirectory,
                autoOrganize: autoOrganize,
                ed2kContext: ed2kContext
            )
            do {
                let gid: String = try await call("aria2.addUri", params: [[uri], singleOptions], as: String.self)
                gids.append(gid)
            } catch {
                guard !gids.isEmpty else { throw error }
                throw PartialDownloadSubmissionError(addedIDs: gids, reason: DownloadPrivacy.redact(error.localizedDescription))
            }
        }
        return gids
    }

    @concurrent
    func inspectMedia(_ draft: AddDownloadDraft, fallbackDirectory: String?) async throws -> String {
        guard draft.shouldInspectMedia else { throw DownloadOperationError(String(localized: "Use one HTTP or HTTPS media source.")) }
        var options = try draft.engineOptions(fallbackDirectory: fallbackDirectory, autoOrganize: false)
        options.merge(try draft.media.engineOptions(probing: true)) { _, new in new }
        options["pause"] = "false"
        return try await call("aria2.addUri", params: [try draft.normalizedResources(), options], as: String.self)
    }

    @concurrent
    func finishMedia(_ gid: String) async throws {
        let _: String = try await call("aria2.finishMedia", params: [gid], as: String.self)
    }

    @concurrent
    func retryMedia(_ gid: String, options: [String: String] = [:]) async throws {
        let _: String = try await call("aria2.retryMedia", params: [gid, options], as: String.self)
    }

    @concurrent
    func getURIs(_ gid: String) async throws -> [String] {
        let values: [Aria2URIStatusDTO] = try await call("aria2.getUris", params: [gid], as: [Aria2URIStatusDTO].self)
        return values.compactMap(\.uri)
    }

    @concurrent
    func replaceURI(_ gid: String, old: [String], new: String) async throws {
        let result: [Int] = try await call("aria2.changeUri", params: [gid, 1, old, [new], 0], as: [Int].self)
        guard result.count == 2, result[1] == 1 else { throw DownloadOperationError(String(localized: "The engine did not accept the replacement address.")) }
    }

    @concurrent
    func getOption(_ gid: String) async throws -> [String: String] {
        try await call("aria2.getOption", params: [gid], as: [String: String].self)
    }

    @concurrent
    func addBitTorrentMetadataDownload(
        _ draft: AddDownloadDraft,
        fallbackDirectory: String?,
        autoOrganize: Bool
    ) async throws -> String {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RPCError.tokenMissing
        }
        let normalized = try draft.normalizedResources()
        guard normalized.count == 1, let resource = normalized.first else {
            throw DownloadDraftError.bitTorrentSelectionRequiresSingleResource
        }

        var options = try draft.engineOptions(fallbackDirectory: fallbackDirectory, autoOrganize: autoOrganize)
        options["pause-metadata"] = "true"
        options["force-save"] = "true" // Preserve active seeding in crash-recovery sessions.
        options["follow-torrent"] = "true"

        if let document = try localDocument(resource, draft: draft), document.kind == .torrent {
            let data = document.data
            options["pause"] = "true"
            let gid: String = try await call("aria2.addTorrent", params: [data.base64EncodedString(), [], options], as: String.self)
            return gid
        }

        let gid: String = try await call("aria2.addUri", params: [[resource], options], as: String.self)
        return gid
    }

    private func localDocument(_ resource: String, draft: AddDownloadDraft) throws -> ImportedDownloadDocument? {
        if let document = draft.importedDocuments[resource] { return document }
        let url: URL?
        if let parsed = URL(string: resource), parsed.isFileURL { url = parsed }
        else if resource.hasPrefix("/") { url = URL(fileURLWithPath: resource) }
        else { url = nil }
        guard let url else { return nil }
        return try DownloadImportReader.readDocument(url, preferences: AppPreferences())
    }

    @concurrent
    func ed2kSearch(
        keyword: String,
        options: ED2KSearchOptions,
        directory: String,
        context: ED2KDownloadContext?
    ) async throws -> String {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RPCError.tokenMissing
        }
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else {
            throw DownloadDraftError.emptyResource
        }
        let gid: String = try await call(
            "ed2kSearch",
            params: [
                trimmedKeyword,
                options.engineOptions(directory: directory, context: context)
            ],
            as: String.self
        )
        return gid
    }

    @concurrent
    func getED2KSearchResults(_ gid: String) async throws -> ED2KSearchResults {
        try await call("getEd2kSearchResults", params: [gid], as: ED2KSearchResults.self)
    }

    @concurrent
    func cleanupED2KSearch(_ gid: String) async throws {
        do {
            try await forceRemove(gid)
            return
        } catch {
            do {
                try await removeDownloadResult(gid)
            } catch {
                return
            }
        }
    }

    @concurrent
    func pause(_ gid: String) async throws {
        let _: String = try await call("aria2.pause", params: [gid], as: String.self)
    }

    @concurrent
    func forcePause(_ gid: String) async throws {
        let _: String = try await call("aria2.forcePause", params: [gid], as: String.self)
    }

    @concurrent
    func resume(_ gid: String) async throws {
        let _: String = try await call("aria2.unpause", params: [gid], as: String.self)
    }

    @concurrent
    func remove(_ gid: String) async throws {
        let _: String = try await call("aria2.remove", params: [gid], as: String.self)
    }

    @concurrent
    func forceRemove(_ gid: String) async throws {
        let _: String = try await call("aria2.forceRemove", params: [gid], as: String.self)
    }

    @concurrent
    func removeDownloadResult(_ gid: String) async throws {
        let _: String = try await call("aria2.removeDownloadResult", params: [gid], as: String.self)
    }

    @concurrent
    func purgeDownloadResult() async throws {
        let _: String = try await call("aria2.purgeDownloadResult", params: [], as: String.self)
    }

    @concurrent
    func pauseAll() async throws {
        let _: String = try await call("aria2.pauseAll", params: [], as: String.self)
    }

    @concurrent
    func forcePauseAll() async throws {
        let _: String = try await call("aria2.forcePauseAll", params: [], as: String.self)
    }

    @concurrent
    func unpauseAll() async throws {
        let _: String = try await call("aria2.unpauseAll", params: [], as: String.self)
    }

    @concurrent
    func saveSession() async throws {
        let _: String = try await call("aria2.saveSession", params: [], as: String.self)
    }

    @concurrent
    func changeGlobalOption(_ options: [String: String]) async throws {
        let _: String = try await call("aria2.changeGlobalOption", params: [options], as: String.self)
    }

    @concurrent
    func changeOption(gid: String, options: [String: String]) async throws {
        let _: String = try await call("aria2.changeOption", params: [gid, options], as: String.self)
    }

    @concurrent
    func tellStatus(_ gid: String) async throws -> Aria2TaskSnapshot {
        let fields = [
            "gid",
            "status",
            "totalLength",
            "completedLength",
            "downloadSpeed",
            "uploadSpeed",
            "connections",
            "dir",
            "files",
            "uris",
            "errorMessage",
            "bittorrent",
            "ed2k",
            "infoHash",
            "seeder",
            "following",
            "followedBy",
            "media",
            "verifiedLength",
            "verifyIntegrityPending"
        ]
        let dto: Aria2TaskDTO = try await call("aria2.tellStatus", params: [gid, fields], as: Aria2TaskDTO.self)
        return dto.toSnapshot()
    }

    @concurrent
    func getFiles(_ gid: String) async throws -> [DownloadFile] {
        let dtos: [Aria2FileDTO] = try await call("aria2.getFiles", params: [gid], as: [Aria2FileDTO].self)
        return dtos.map { $0.toFile() }
    }

    @concurrent
    func getTorrentTrackers(_ gid: String) async throws -> [TrackerEntry] {
        let trackers: [BitTorrentTrackerStatus] = try await call("aria2.getBtTrackers", params: [gid], as: [BitTorrentTrackerStatus].self)
        return trackers.map(\.entry)
    }

    @concurrent
    func reannounceTorrent(_ gid: String) async throws {
        let _: String = try await call("aria2.forceBtAnnounce", params: [gid], as: String.self)
    }

    @concurrent
    func recheckTorrent(_ gid: String) async throws {
        let _: String = try await call("aria2.forceBtRecheck", params: [gid], as: String.self)
    }

    @concurrent
    func getPeers(_ gid: String) async throws -> [ConnectionPeer] {
        let dtos: [Aria2PeerDTO] = try await call("aria2.getPeers", params: [gid], as: [Aria2PeerDTO].self)
        return dtos.map { $0.toPeer() }
    }

    @concurrent
    func transferProgress(_ gid: String) async throws -> TransferProgressDTO {
        try await call("aria2.tellStatus", params: [gid, ["gid", "status", "bitfield", "pieceLength", "numPieces",
            "connections", "downloadSpeed", "uploadSpeed", "uploadLength", "files", "bittorrent"]], as: TransferProgressDTO.self)
    }

    @concurrent
    func peerTransfers(_ gid: String) async throws -> [PeerTransfer] {
        try await call("aria2.getPeers", params: [gid], as: [PeerTransfer].self)
    }

    @concurrent
    func serverTransfers(_ gid: String) async throws -> [ServerTransfer] {
        let result = try await call("aria2.getServers", params: [gid], as: [ServerTransferDTO].self)
        return ServerTransferDTO.connections(result)
    }

    @concurrent
    func getGlobalOption() async throws -> [String: String] {
        try await call("aria2.getGlobalOption", params: [], as: [String: String].self)
    }

    @concurrent
    func transferSnapshot(_ gid: String, isTorrent: Bool) async throws -> TransferSnapshot {
        var state = try await transferProgress(gid)
        var connections: [PeerTransfer] = [], streams: [ServerTransfer] = []
        if state.status == "active" {
            do {
                if isTorrent { connections = try await peerTransfers(gid) }
                else { streams = try await serverTransfers(gid) }
            } catch {
                // Completion/pause can race the connection request. Recheck status before
                // treating "no active download" as an unavailable engine.
                try Task.checkCancellation()
                let latest = try await transferProgress(gid)
                guard latest.status != "active" else { throw error }
                state = latest
            }
        }
        let live = state.status == "active"
        return TransferSnapshot(pieces: state.pieceMap,
            peers: live ? Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values.sorted { $0.id < $1.id } : [],
            servers: live ? streams : [], downloadSpeed: live ? max(0, Int64(state.downloadSpeed ?? "") ?? 0) : 0,
            uploadSpeed: live ? max(0, Int64(state.uploadSpeed ?? "") ?? 0) : 0,
            uploaded: Int64(state.uploadLength ?? ""), connections: live ? max(0, Int(state.connections ?? "") ?? 0) : 0)
    }

    @concurrent
    func pollTasks() async throws -> [DownloadTask] {
        async let active = tellActive()
        async let waiting = tellWaiting()
        async let stopped = tellStopped()
        // Tasks can move between queues while the three requests are in flight.
        // Keep the newest (terminal, then waiting, then active) observation.
        let observations = try await (active + waiting + stopped)
        var tasksByID: [String: DownloadTask] = [:]
        for task in observations { tasksByID[task.id] = task }
        return tasksByID.values
            .sorted { lhs, rhs in
                if lhs.status == rhs.status {
                    return lhs.id < rhs.id
                }
                return lhs.status.sortOrder < rhs.status.sortOrder
            }
    }

    @concurrent
    func waitingQueueIDs() async throws -> [String] { try await pagedTaskDTOs(method: "aria2.tellWaiting").map(\.gid) }

    @concurrent
    func changePosition(_ gid: String, to position: Int) async throws {
        let _: Int = try await call("aria2.changePosition", params: [gid, position, "POS_SET"], as: Int.self)
    }

    @concurrent
    func getVersion() async throws -> EngineCapabilities {
        try await call("aria2.getVersion", params: [], as: EngineCapabilities.self)
    }

    @concurrent
    func globalStat() async throws -> Aria2GlobalStat {
        try await call("aria2.getGlobalStat", params: [], as: Aria2GlobalStat.self)
    }

    func makeRequest(method: String, params: [Any]) throws -> URLRequest {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RPCError.tokenMissing
        }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var rpcParams: [Any] = ["token:\(token)"]
        rpcParams.append(contentsOf: params)
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": rpcParams
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func tellActive() async throws -> [DownloadTask] {
        let dtos: [Aria2TaskDTO] = try await call("aria2.tellActive", params: [], as: [Aria2TaskDTO].self)
        return dtos.toVisibleTasks()
    }

    private func tellWaiting() async throws -> [DownloadTask] {
        try await pagedTaskDTOs(method: "aria2.tellWaiting").enumerated().compactMap { position, dto in
            guard var task = [dto].toVisibleTasks().first else { return nil }
            task.queuePosition = position
            return task
        }
    }

    private func tellStopped() async throws -> [DownloadTask] {
        try await pagedTaskDTOs(method: "aria2.tellStopped").toVisibleTasks()
    }

    private func pagedTaskDTOs(method: String) async throws -> [Aria2TaskDTO] {
        let pageSize = 1000
        var offset = 0
        var tasks: [Aria2TaskDTO] = []
        while true {
            try Task.checkCancellation()
            let page: [Aria2TaskDTO] = try await call(method, params: [offset, pageSize], as: [Aria2TaskDTO].self)
            tasks.append(contentsOf: page)
            guard page.count == pageSize else { return tasks }
            offset += page.count
        }
    }

    private func ed2kAwareOptions(
        draft: AddDownloadDraft,
        resources: [String],
        fallbackDirectory: String?,
        autoOrganize: Bool,
        ed2kContext: ED2KDownloadContext?
    ) throws -> [String: String] {
        var options = try draft.engineOptions(fallbackDirectory: fallbackDirectory, autoOrganize: autoOrganize)
        guard resources.contains(where: { AddDownloadDraft.detectProtocol(for: $0) == .ed2k }) else {
            return options
        }
        ed2kContext?.apply(to: &options)
        return options
    }

    private func call<T: Decodable & Sendable>(_ method: String, params: [Any], as type: T.Type) async throws -> T {
        let request = try makeRequest(method: method, params: params)
        let (data, response) = try await session.data(for: request)
        let body = sanitizedBody(from: data)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RPCError.nonHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let envelope = try? JSONDecoder().decode(RPCEnvelope<T>.self, from: data),
               let error = envelope.error {
                throw RPCError.serverError(code: error.code, message: redactToken(error.message))
            }
            throw RPCError.unexpectedHTTPStatus(code: httpResponse.statusCode, body: body)
        }

        let envelope: RPCEnvelope<T>
        do {
            envelope = try JSONDecoder().decode(RPCEnvelope<T>.self, from: data)
        } catch {
            throw RPCError.invalidResponseBody(method: method, body: body, reason: error.localizedDescription)
        }
        if let error = envelope.error {
            throw RPCError.serverError(code: error.code, message: redactToken(error.message))
        }
        guard let result = envelope.result else {
            throw RPCError.missingResult(method: method, body: body)
        }
        return result
    }

    private func sanitizedBody(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let raw = redactToken(String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>")
        let oneLine = raw.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > 500 else { return oneLine }
        return "\(oneLine.prefix(500))..."
    }

    private func redactToken(_ text: String) -> String {
        guard !token.isEmpty else { return text }
        return DownloadPrivacy.redact(text.replacingOccurrences(of: token, with: "<redacted>"))
    }

}

nonisolated struct Aria2GlobalStat: Decodable, Equatable, Sendable {
    var downloadSpeed: String
    var uploadSpeed: String
    var numActive: String
    var numWaiting: String
    var numStopped: String

    var downloadBytesPerSecond: Int64 { Int64(downloadSpeed) ?? 0 }
    var uploadBytesPerSecond: Int64 { Int64(uploadSpeed) ?? 0 }
}

private nonisolated struct RPCEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    var result: T?
    var error: RPCServerError?
}

private nonisolated struct RPCServerError: Decodable, Sendable {
    var code: Int
    var message: String
}
