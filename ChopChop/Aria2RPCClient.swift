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
            "Aria2 RPC returned a non-HTTP response."
        case .unexpectedHTTPStatus(let code, let body):
            if body.isEmpty {
                "Aria2 RPC returned HTTP \(code)."
            } else {
                "Aria2 RPC returned HTTP \(code).\n\(body)"
            }
        case .invalidResponseBody(let method, let body, let reason):
            if body.isEmpty {
                "Aria2 RPC response for \(method) could not be decoded.\n\(reason)"
            } else {
                "Aria2 RPC response for \(method) could not be decoded.\n\(reason)\n\(body)"
            }
        case .missingResult(let method, let body):
            if body.isEmpty {
                "Aria2 RPC response for \(method) did not contain a result or error."
            } else {
                "Aria2 RPC response for \(method) did not contain a result or error.\n\(body)"
            }
        case .invalidPort(let port):
            "RPC port must be between 1 and 65535. Current value: \(port)."
        case .serverError(let code, let message):
            "Aria2 RPC error \(code): \(message)"
        case .tokenMissing:
            "RPC token is required."
        }
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
        let options = try ed2kAwareOptions(
            draft: draft,
            resources: normalized,
            fallbackDirectory: fallbackDirectory,
            autoOrganize: autoOrganize,
            ed2kContext: ed2kContext
        )
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
            let gid: String = try await call("aria2.addUri", params: [[uri], singleOptions], as: String.self)
            gids.append(gid)
        }
        return gids
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
        options["follow-torrent"] = "true"

        if let torrentURL = AddDownloadDraft.localTorrentFileURL(resource) {
            let data = try Data(contentsOf: torrentURL)
            options["pause"] = "true"
            let gid: String = try await call("aria2.addTorrent", params: [data.base64EncodedString(), [], options], as: String.self)
            return gid
        }

        let gid: String = try await call("aria2.addUri", params: [[resource], options], as: String.self)
        return gid
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
            "followedBy"
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
    func getPeers(_ gid: String) async throws -> [ConnectionPeer] {
        let dtos: [Aria2PeerDTO] = try await call("aria2.getPeers", params: [gid], as: [Aria2PeerDTO].self)
        return dtos.map { $0.toPeer() }
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
        try await pagedTasks(method: "aria2.tellWaiting")
    }

    private func tellStopped() async throws -> [DownloadTask] {
        try await pagedTasks(method: "aria2.tellStopped")
    }

    private func pagedTasks(method: String) async throws -> [DownloadTask] {
        let pageSize = 1000
        var offset = 0
        var tasks: [DownloadTask] = []
        while true {
            try Task.checkCancellation()
            let page: [Aria2TaskDTO] = try await call(method, params: [offset, pageSize], as: [Aria2TaskDTO].self)
            tasks.append(contentsOf: page.toVisibleTasks())
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
        return text.replacingOccurrences(of: token, with: "<redacted>")
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

private nonisolated struct Aria2TaskDTO: Decodable, Sendable {
    var gid: String
    var status: String?
    var totalLength: String?
    var completedLength: String?
    var downloadSpeed: String?
    var uploadSpeed: String?
    var connections: String?
    var dir: String?
    var files: [Aria2FileDTO]?
    var uris: [Aria2URIStatusDTO]?
    var errorMessage: String?
    var bittorrent: Aria2BitTorrentDTO?
    var ed2k: Aria2ED2KDTO?
    var infoHash: String?
    var seeder: String?
    var following: String?
    var followedBy: [String]?

    var isBitTorrentMetadataPlaceholder: Bool {
        if let followedBy,
           followedBy.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return true
        }

        let mappedFiles = files ?? []
        if mappedFiles.contains(where: { $0.isBitTorrentMetadataPlaceholder }) {
            return true
        }

        if let name = bittorrent?.info?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           name.hasPrefix("[METADATA]") {
            return true
        }

        return false
    }

    var isED2KSearchPlaceholder: Bool {
        if ed2k?.isSearchTask == true {
            return true
        }
        let paths = (files ?? []).compactMap(\.path)
        return paths.contains { path in
            let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
            return path.contains("chopchop-ed2k-search-") ||
                path.contains("aria2-next-ed2k-search-") ||
                lastPathComponent.hasPrefix("aria2-next-ed2k-search-")
        }
    }

    func toTask() -> DownloadTask {
        let mappedFiles = (files ?? []).map { $0.toFile() }
        let firstPath = mappedFiles.first(where: { $0.path.isUsableAria2Path })?.path ?? ""
        let firstURI = firstReportedURI()
        let name = bittorrent?.info?.name?.usableTaskName ??
            ed2k?.name?.usableTaskName ??
            displayName(path: firstPath, uri: firstURI) ??
            gid
        let protocolKind = detectProtocol(from: firstURI.nonEmpty ?? firstPath)
        let mappedStatus = mapStatus(status)
        let logs = errorMessage.map { [$0] } ?? []
        return DownloadTask(
            id: gid,
            name: name,
            protocolKind: bittorrent == nil ? (ed2k == nil ? protocolKind : .ed2k) : .bitTorrent,
            status: mappedStatus,
            totalLength: Int64(totalLength ?? "") ?? mappedFiles.reduce(0) { $0 + $1.length },
            completedLength: Int64(completedLength ?? "") ?? mappedFiles.reduce(0) { $0 + $1.completedLength },
            downloadSpeed: Int64(downloadSpeed ?? "") ?? 0,
            uploadSpeed: Int64(uploadSpeed ?? "") ?? 0,
            connections: Int(connections ?? "") ?? 0,
            destination: dir ?? "",
            addedAt: Date(),
            errorMessage: errorMessage,
            files: mappedFiles,
            peers: [],
            trackers: bittorrent?.trackerEntries ?? [],
            recentLogs: ed2kNetworkLogs() + logs,
            infoHash: infoHash ?? ed2k?.hash,
            isSharing: mappedStatus == .active && seeder == "true"
        )
    }

    func toSnapshot() -> Aria2TaskSnapshot {
        Aria2TaskSnapshot(
            task: toTask(),
            following: following,
            followedBy: followedBy ?? []
        )
    }

    private func firstReportedURI() -> String {
        let fileURIs = (files ?? [])
            .flatMap { $0.uris ?? [] }
            .compactMap(\.uri)
        return (fileURIs + (uris ?? []).compactMap(\.uri))
            .first { !$0.trimmedForEngine.isEmpty } ?? ""
    }

    private func displayName(path: String, uri: String) -> String? {
        if path.isUsableAria2Path,
           let pathName = URL(fileURLWithPath: path).lastPathComponent.usableTaskName {
            return pathName
        }
        if let urlName = URL(string: uri)?.lastPathComponent.usableTaskName {
            return urlName
        }
        return uri.split(separator: "/").last.map(String.init)?.usableTaskName
    }

    private func mapStatus(_ raw: String?) -> DownloadStatus {
        switch raw {
        case "active": .active
        case "waiting": .waiting
        case "paused": .paused
        case "complete": .completed
        case "error": .failed
        case "removed": .removed
        default: .waiting
        }
    }

    private func detectProtocol(from path: String) -> TaskProtocol {
        let lowered = path.lowercased()
        if lowered.hasPrefix("ed2k://") { return .ed2k }
        if lowered.hasPrefix("magnet:") { return .magnet }
        if lowered.hasPrefix("ftp://") || lowered.hasPrefix("sftp://") { return .ftp }
        if lowered.hasSuffix(".meta4") || lowered.hasSuffix(".metalink") { return .metalink }
        return .http
    }

    private func ed2kNetworkLogs() -> [String] {
        guard let ed2k, !ed2k.isSearchTask else { return [] }
        return [
            ed2k.hash.map { "ED2K hash: \($0)" },
            ed2k.serverCount.map { "Servers: \($0)" },
            ed2k.connectedServerCount.map { "Connected servers: \($0)" },
            ed2k.peerCount.map { "Sources: \($0)" },
            ed2k.kadNodeCount.map { "Kad nodes: \($0)" },
            ed2k.kadFirewalled.map { "Kad firewalled: \($0.value ? "Yes" : "No")" }
        ].compactMap { $0 }
    }
}

private nonisolated struct Aria2FileDTO: Decodable, Sendable {
    var index: String?
    var path: String?
    var length: String?
    var completedLength: String?
    var selected: String?
    var uris: [Aria2URIStatusDTO]?

    var isBitTorrentMetadataPlaceholder: Bool {
        let trimmedPath = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return false }
        if trimmedPath.hasPrefix("[METADATA]") {
            return true
        }
        return URL(fileURLWithPath: trimmedPath).lastPathComponent.hasPrefix("[METADATA]")
    }

    func toFile() -> DownloadFile {
        DownloadFile(
            index: Int(index ?? "") ?? 0,
            path: path ?? "",
            length: Int64(length ?? "") ?? 0,
            completedLength: Int64(completedLength ?? "") ?? 0,
            isSelected: selected != "false"
        )
    }
}

private nonisolated struct Aria2URIStatusDTO: Decodable, Sendable {
    var uri: String?
}

private nonisolated struct Aria2BitTorrentDTO: Decodable, Sendable {
    nonisolated struct Info: Decodable, Sendable {
        var name: String?
    }

    var info: Info?
    var announceList: [[String]]?

    var trackerEntries: [TrackerEntry] {
        (announceList ?? [])
            .flatMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { TrackerEntry(url: $0, status: "Announced", lastAnnounce: nil) }
    }
}

private nonisolated struct Aria2ED2KDTO: Decodable, Sendable {
    var hash: String?
    var name: String?
    var length: String?
    var completedLength: String?
    var serverCount: String?
    var connectedServerCount: String?
    var peerCount: String?
    var queuedPeerCount: String?
    var acceptedPeerCount: String?
    var deadPeerCount: String?
    var lowIdPeerCount: String?
    var callbackWaitingPeerCount: String?
    var kadNodeCount: String?
    var kadRouterCount: String?
    var kadFirewalled: FlexibleBool?
    var searchActive: FlexibleBool?
    var searchMoreResults: FlexibleBool?
    var searchResultCount: String?

    var isSearchTask: Bool {
        searchActive != nil || searchMoreResults != nil || searchResultCount != nil
    }
}

private nonisolated struct FlexibleBool: Decodable, Sendable, Equatable {
    var value: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue == "true" || stringValue == "1"
        } else {
            value = false
        }
    }
}

private nonisolated struct Aria2PeerDTO: Decodable, Sendable {
    var ip: String?
    var port: String?
    var peerId: String?
    var seeder: String?
    var downloadSpeed: String?
    var completedLength: String?

    func toPeer() -> ConnectionPeer {
        let addressParts = [
            ip?.trimmingCharacters(in: .whitespacesAndNewlines),
            port?.trimmingCharacters(in: .whitespacesAndNewlines)
        ].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let address = addressParts.isEmpty ? "Unknown peer" : addressParts.joined(separator: ":")
        let client = seeder == "true" ? "Seeder" : "Peer"
        return ConnectionPeer(
            address: address,
            client: client,
            progress: 0,
            downloadSpeed: Int64(downloadSpeed ?? "") ?? 0
        )
    }
}

private nonisolated extension Array where Element == Aria2TaskDTO {
    func toVisibleTasks() -> [DownloadTask] {
        filter { !$0.isBitTorrentMetadataPlaceholder && !$0.isED2KSearchPlaceholder }.map { $0.toTask() }
    }
}

private nonisolated extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var usableTaskName: String? {
        let trimmed = trimmedForEngine
        guard !trimmed.isEmpty, trimmed != "/", trimmed != "." else { return nil }
        return trimmed
    }

    var isUsableAria2Path: Bool {
        usableTaskName != nil
    }
}
