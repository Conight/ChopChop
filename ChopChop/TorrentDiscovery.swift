import Foundation

/// Per-task observations. Session-wide connection counters are deliberately not
/// used as this torrent's peer count or as evidence that its metadata is available.
nonisolated struct TorrentDiscovery: Equatable, Sendable {
    struct Trackers: Equatable, Sendable {
        struct Entry: Equatable, Sendable {
            var address: String
            var status: String
            var message: String?

            var statusTitle: String {
                switch status {
                case "working": String(localized: "Responded")
                case "updating": String(localized: "Announcing")
                case "error": String(localized: "Failed")
                default: String(localized: "Not contacted")
                }
            }
        }
        var total: Int
        var responded: Int
        var failed: Int
        var announcing: Int
        var entries: [Entry] = []

        init(_ values: [BitTorrentTrackerStatus]) {
            total = values.count
            responded = values.filter { $0.verified == "true" || $0.status == "working" }.count
            failed = values.filter { $0.status == "error" }.count
            announcing = values.filter { $0.status == "updating" }.count
            entries = values.map {
                let url = URLComponents(string: $0.url)
                // Tracker credentials and passkeys are not useful in this summary.
                let address = url?.host.map { host in
                    (url?.scheme.map { $0 + "://" } ?? "") + host + (url?.port.map { ":\($0)" } ?? "")
                } ?? String(localized: "Tracker")
                return Entry(address: address, status: $0.status ?? "notContacted",
                             message: $0.message.flatMap { $0.isEmpty ? nil : DownloadPrivacy.redact($0) })
            }
        }
    }

    struct Peers: Equatable, Sendable {
        var connected = 0
        var connecting = 0
        var handshaking = 0
        var unknown = 0

        init(_ values: [PeerTransfer]) {
            for peer in values {
                switch peer.state {
                case "connected": connected += 1
                case "connecting": connecting += 1
                case "handshaking": handshaking += 1
                default: unknown += 1
                }
            }
        }
    }

    var trackers: Trackers?
    var peers: Peers?
    var dhtNodes: Int?
    var updatedAt = Date()
    var hasUnavailableDetails: Bool { trackers == nil || peers == nil || dhtNodes == nil }
}

nonisolated struct TorrentDiscoverySessionDTO: Decodable, Sendable {
    var dhtNodes: String?
}

nonisolated enum TorrentDiscoveryStage: Equatable {
    case reading, queued, paused, checking, trackers, findingPeers, connecting, handshaking, metadata

    var title: String {
        switch self {
        case .reading: String(localized: "Reading the torrent file list…")
        case .queued: String(localized: "Waiting for an available download slot…")
        case .paused: String(localized: "Metadata discovery is paused")
        case .checking: String(localized: "Checking connection status…")
        case .trackers: String(localized: "Waiting for Tracker responses…")
        case .findingPeers: String(localized: "Finding peers for this magnet link…")
        case .connecting: String(localized: "Connecting to peers…")
        case .handshaking: String(localized: "Waiting for BitTorrent handshakes…")
        case .metadata: String(localized: "Requesting the file list from connected peers…")
        }
    }

    var waitingReason: String {
        switch self {
        case .reading: String(localized: "The source has not provided a usable torrent file yet. Retry or open a local .torrent file.")
        case .queued: String(localized: "This task is waiting for a download slot. Pause another active task or increase the active download limit.")
        case .paused: String(localized: "This task is paused before its file list is available. Retry to resume metadata discovery.")
        case .checking: String(localized: "Connection details are unavailable. The task is still being checked; this does not mean there are zero peers.")
        case .trackers: String(localized: "No Tracker response has been confirmed and no peer has completed a handshake. Check the Tracker errors below or try another source.")
        case .findingPeers: String(localized: "No peer has completed a handshake yet. Tracker seed counts and DHT nodes do not guarantee a reachable metadata provider. Retry or try another source.")
        case .connecting: String(localized: "Connection attempts have not completed a BitTorrent handshake. The peers may be unreachable or the network path may be blocked.")
        case .handshaking: String(localized: "Network connections exist, but the peers have not completed their BitTorrent handshakes. The file list cannot be requested from them yet.")
        case .metadata: String(localized: "Peers have completed their handshakes but have not supplied the complete file list. They may not have or support the required metadata.")
        }
    }
}

nonisolated extension BitTorrentFileSelectionSession {
    static let slowDiscoveryInterval: TimeInterval = 60

    func isDiscoverySlow(at now: Date) -> Bool {
        phase == .loading && now.timeIntervalSince(startedAt) >= Self.slowDiscoveryInterval
    }

    var discoveryStage: TorrentDiscoveryStage {
        if isQueued { return .queued }
        if isPaused { return .paused }
        guard source.lowercased().hasPrefix("magnet:") else { return .reading }
        // Unknown diagnostics must not be interpreted as zero peers.
        guard let discovery, let peers = discovery.peers else { return .checking }
        if peers.connected > 0 { return .metadata }
        if peers.handshaking > 0 { return .handshaking }
        if peers.connecting > 0 { return .connecting }
        if peers.unknown > 0 { return .checking }
        if (discovery.trackers?.responded ?? 0) > 0 || (discovery.dhtNodes ?? 0) > 0 { return .findingPeers }
        if let trackers = discovery.trackers, trackers.total > 0 { return .trackers }
        return .findingPeers
    }
}
