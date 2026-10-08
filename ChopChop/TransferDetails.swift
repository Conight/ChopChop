import Foundation
import Combine

/// Live diagnostics stay in memory, outside task history and exported diagnostics.
nonisolated struct PieceMap: Equatable, Sendable {
    enum State: Sendable { case complete, missing, unknown }
    let count: Int
    let pieceLength: Int64
    let totalSpan: Int64?
    let bytes: [UInt8]
    let completedCount: Int
    var reportedCount: Int { min(count, bytes.count * 8) }
    var completionSummary: String {
        reportedCount == count ? String(localized: "\(completedCount) of \(count) pieces complete")
            : String(localized: "\(completedCount) complete · \(count - reportedCount) not reported")
    }
    let overview: [Double?]

    init?(count: Int, pieceLength: Int64, bitfield: String?, totalSpan: Int64?) {
        guard count > 0, count <= 10_000_000, pieceLength > 0,
              pieceLength <= Int64.max / Int64(count) else { return nil }
        self.count = count; self.pieceLength = pieceLength
        self.totalSpan = totalSpan.flatMap { span in
            span > 0 && (span - 1) / pieceLength + 1 == Int64(count) ? span : nil
        }
        let hex = Array((bitfield ?? "").utf8.prefix(((count + 7) / 8) * 2))
        func nibble(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: c - 48; case 65...70: c - 55; case 97...102: c - 87; default: nil }
        }
        var decoded: [UInt8] = []
        if hex.count.isMultiple(of: 2) {
            for i in stride(from: 0, to: hex.count, by: 2) {
                guard let a = nibble(hex[i]), let b = nibble(hex[i + 1]) else { decoded = []; break }
                decoded.append(a << 4 | b)
            }
        }
        bytes = decoded
        var completed = 0
        let bins = min(count, 240)
        var overview: [Double?] = []
        for bin in 0..<bins {
            let range = (bin * count / bins)..<((bin + 1) * count / bins)
            var done = 0, known = 0
            for index in range where index / 8 < decoded.count {
                known += 1
                if decoded[index / 8] & (0x80 >> (index % 8)) != 0 { done += 1 }
            }
            completed += done
            overview.append(known == range.count ? Double(done) / Double(range.count) : nil)
        }
        completedCount = completed; self.overview = overview
    }

    func state(at index: Int) -> State {
        guard (0..<count).contains(index), index / 8 < bytes.count else { return .unknown }
        return bytes[index / 8] & (0x80 >> (index % 8)) == 0 ? .missing : .complete
    }
    func size(at index: Int) -> Int64? {
        guard (0..<count).contains(index), let totalSpan else { return nil }
        return min(pieceLength, totalSpan - Int64(index) * pieceLength)
    }
    func description(at index: Int) -> String {
        let state: String = switch state(at: index) {
        case .complete: String(localized: "Complete piece")
        case .missing: String(localized: "Not complete")
        case .unknown: String(localized: "Not reported")
        }
        let size = size(at: index).map { String(localized: "\($0.formatted()) bytes") }
            ?? String(localized: "Up to \(ByteFormat.size(pieceLength)) (including any padding)")
        return String(localized: "Piece \(index + 1)") + " · " + state + " · " + size
    }
}

nonisolated struct TransferProgressDTO: Decodable, Sendable {
    var gid: String
    var status: String?
    var bitfield: String?
    var pieceLength: String?
    var numPieces: String?
    var connections: String?
    var downloadSpeed: String?
    var uploadSpeed: String?
    var uploadLength: String?
    var files: [Aria2FileDTO]?
    var bittorrent: TorrentInfo?
    struct TorrentInfo: Decodable, Sendable { var infoHashV2: String? }

    var pieceMap: PieceMap? {
        guard bittorrent != nil, let count = Int(numPieces ?? ""), let length = Int64(pieceLength ?? "") else { return nil }
        var span: Int64 = 0
        var valid = !(files ?? []).isEmpty && bittorrent?.infoHashV2?.isEmpty != false
        for file in files ?? [] {
            guard let length = Int64(file.length ?? ""), length >= 0,
                  !span.addingReportingOverflow(length).overflow else { valid = false; break }
            span += length
        }
        return PieceMap(count: count, pieceLength: length, bitfield: bitfield, totalSpan: valid ? span : nil)
    }
}

nonisolated struct PeerTransfer: Decodable, Identifiable, Sendable {
    var ip: String?
    var port: String?
    var peerClientName: String?
    var state: String?
    var progress: String?
    var seeder: String?
    var downloadSpeed: String?
    var uploadSpeed: String?
    var downloaded: String?
    var uploaded: String?
    var incoming: String?
    var transport: String?
    var encryption: String?
    var sources: [String]?
    var amChoking: String?
    var peerChoking: String?
    var amInterested: String?
    var peerInterested: String?
    var snubbed: String?
    var optimisticUnchoke: String?
    var encryptionLabel: String? {
        switch encryption {
        case "plain": String(localized: "Unencrypted")
        case "encryptedHandshake": String(localized: "Encrypted handshake")
        case "rc4": "RC4"
        case "tls": "TLS"
        default: nil
        }
    }
    var sourceLabels: [String] {
        (sources ?? []).compactMap {
            switch $0 {
            case "tracker": String(localized: "Tracker")
            case "dht": "DHT"
            case "pex": String(localized: "Peer exchange")
            case "lsd": String(localized: "Local discovery")
            case "resume": String(localized: "Saved peers")
            case "incoming": String(localized: "Incoming connection")
            default: nil
            }
        }
    }
    var id: String { address + "/" + (transport ?? "") }
    var address: String {
        let host = ip ?? String(localized: "Unknown peer")
        return (host.contains(":") ? "[\(host)]" : host) + (port.map { ":\($0)" } ?? "")
    }
    var fraction: Double? {
        guard state == nil || state == "connected", let value = Double(progress ?? ""), value.isFinite,
              (0...1).contains(value) else { return nil }
        return value
    }
    var down: Int64 { max(0, Int64(downloadSpeed ?? "") ?? 0) }
    var up: Int64 { max(0, Int64(uploadSpeed ?? "") ?? 0) }
    var stateLabel: String {
        switch state {
        case "connecting": String(localized: "Connecting")
        case "handshaking": String(localized: "Handshaking")
        case "connected": String(localized: "Connected")
        default: String(localized: "Not reported")
        }
    }
}

nonisolated struct ServerTransferDTO: Decodable, Sendable {
    var index: String?
    var servers: [Server]?
    struct Server: Decodable, Sendable { var uri: String?; var currentUri: String?; var downloadSpeed: String? }
    static func connections(_ entries: [Self]) -> [ServerTransfer] {
        entries.flatMap { entry in
            (entry.servers ?? []).enumerated().map { offset, server in
                let parts = (server.currentUri ?? server.uri).flatMap(URLComponents.init(string:))
                let host = parts?.host ?? String(localized: "Unknown server")
                let address = (host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host) + (parts?.port.map { ":\($0)" } ?? "")
                return ServerTransfer(id: "\(entry.index ?? "0"):\(offset)", fileIndex: Int(entry.index ?? "") ?? 0,
                    address: address, transport: parts?.scheme?.uppercased() ?? "—",
                    downloadSpeed: max(0, Int64(server.downloadSpeed ?? "") ?? 0))
            }
        }
    }
}

nonisolated struct ServerTransfer: Identifiable, Equatable, Sendable {
    var id: String
    var fileIndex: Int
    var address: String
    var transport: String
    var downloadSpeed: Int64
}

nonisolated struct TransferSnapshot: Sendable {
    var pieces: PieceMap?
    var peers: [PeerTransfer] = []
    var servers: [ServerTransfer] = []
    var downloadSpeed: Int64 = 0
    var uploadSpeed: Int64 = 0
    var uploaded: Int64?
    var connections: Int = 0
    var updatedAt = Date()
}

@MainActor
final class TransferDetailMonitor: ObservableObject {
    @Published private(set) var snapshot: TransferSnapshot?
    @Published private(set) var issue: String?
    private var generation = UUID()

    func observe(fetch: @escaping @Sendable () async throws -> TransferSnapshot) async {
        let request = UUID(); generation = request
        snapshot = nil; issue = nil
        defer { if generation == request { snapshot = nil } }
        while !Task.isCancelled {
            do {
                let fresh = try await fetch()
                guard !Task.isCancelled, generation == request else { return }
                snapshot = fresh; issue = nil
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                snapshot = nil
                issue = String(localized: "Live details are unavailable. Retrying automatically.")
            }
            do { try await Task.sleep(for: .seconds(issue == nil ? 2 : 6)) }
            catch { return }
        }
    }
}

nonisolated enum TransferRateLimit {
    static func bytes(_ value: String?) -> Int64? {
        guard let value, !value.isEmpty else { return nil }
        var number = value.uppercased()
        var multiplier = 1.0
        if let suffix = number.last, let power = ["K": 1, "M": 2, "G": 3][String(suffix)] {
            number.removeLast(); multiplier = pow(1024, Double(power))
        }
        guard let parsed = Double(number), parsed.isFinite, parsed >= 0,
              parsed * multiplier < Double(Int64.max) else { return nil }
        return Int64(parsed * multiplier)
    }
    static func option(kib: Int) throws -> String {
        guard (0...Int(Int32.max)).contains(kib) else {
            throw DownloadOperationError(String(localized: "Enter an upload limit of zero or more KiB/s."))
        }
        return "\(kib)K"
    }
}
