import Foundation

// The wire contract is kept separate from transport and application history.
nonisolated struct Aria2TaskDTO: Decodable, Sendable {
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
    var media: MediaTaskProgress?
    var verifiedLength: String?
    var verifyIntegrityPending: FlexibleBool?

    var isBitTorrentMetadataPlaceholder: Bool {
        if bittorrent?.state == "downloadingMetadata" { return true }
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
        let failure = [media?.error, errorMessage].compactMap { $0 }.first { !$0.isEmpty }.map(DownloadPrivacy.redact)
        let logs = failure.map { [$0] } ?? []
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
            errorMessage: failure,
            files: mappedFiles,
            peers: [],
            trackers: bittorrent?.trackerEntries ?? [],
            recentLogs: ed2kNetworkLogs() + logs,
            infoHash: infoHash ?? ed2k?.hash,
            isSharing: mappedStatus == .active && seeder == "true",
            sourceURL: firstURI.isEmpty ? nil : firstURI,
            torrentDiagnostics: bittorrent?.diagnostics,
            media: media,
            isChecking: ["checking", "recovering"].contains(bittorrent?.state ?? "") || verifyIntegrityPending?.value == true || ((Int64(verifiedLength ?? "0") ?? 0) > 0 && (Int64(verifiedLength ?? "0") ?? 0) < (Int64(totalLength ?? "0") ?? 0)),
            isFetchingMetadata: isBitTorrentMetadataPlaceholder,
            requiresFileSelection: bittorrent?.fileSelectionState == "awaiting"
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
        if lowered.hasPrefix("sftp://") { return .sftp }
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

nonisolated struct Aria2FileDTO: Decodable, Sendable {
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

nonisolated struct Aria2URIStatusDTO: Decodable, Sendable {
    var uri: String?
}

nonisolated struct Aria2BitTorrentDTO: Decodable, Sendable {
    nonisolated struct Info: Decodable, Sendable {
        var name: String?
    }

    var info: Info?
    var announceList: [[String]]?
    var state: String?
    var fileSelectionState: String?
    var numPeers: String?
    var numSeeds: String?
    var connectingPeers: String?
    var handshakingPeers: String?
    var availability: String?
    var seedingTime: String?
    var failedLength: String?

    var diagnostics: BitTorrentDiagnostics {
        BitTorrentDiagnostics(state: state, peers: numPeers.flatMap(Int.init), seeds: numSeeds.flatMap(Int.init),
            availability: availability.flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, connecting: connectingPeers.flatMap(Int.init),
            handshaking: handshakingPeers.flatMap(Int.init), seedingSeconds: seedingTime.flatMap(Int.init),
            failedBytes: failedLength.flatMap(Int64.init))
    }


    var trackerEntries: [TrackerEntry] {
        (announceList ?? [])
            .flatMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { TrackerEntry(url: $0, status: "Configured", lastAnnounce: nil) }
    }
}

nonisolated struct Aria2ED2KDTO: Decodable, Sendable {
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

nonisolated struct FlexibleBool: Decodable, Sendable, Equatable {
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

nonisolated struct Aria2PeerDTO: Decodable, Sendable {
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

nonisolated extension Array where Element == Aria2TaskDTO {
    func toVisibleTasks() -> [DownloadTask] {
        filter { ($0.followedBy ?? []).isEmpty && !$0.isED2KSearchPlaceholder }.map { $0.toTask() }
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
