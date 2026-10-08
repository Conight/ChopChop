import Foundation
import SwiftUI

nonisolated struct DownloadOperationError: LocalizedError, Sendable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

nonisolated struct EngineCapabilities: Decodable, Equatable, Sendable {
    var product: String?
    var rpcVersion: String?
    var version: String
    var enabledFeatures: [String]?
    var mediaFeatures: [String]?

    // Missing capability information is unknown, rather than proof of no support.
    func supports(_ kind: TaskProtocol) -> Bool {
        guard let enabledFeatures else { return true }
        let feature: String
        switch kind {
        case .sftp: feature = "SFTP"
        case .bitTorrent, .magnet: feature = "BitTorrent"
        case .ed2k: feature = "ED2K"
        case .metalink: feature = "Metalink"
        case .http, .thunder: return true
        }
        return enabledFeatures.contains { $0.caseInsensitiveCompare(feature) == .orderedSame }
    }
}

nonisolated struct MediaTaskProgress: Codable, Hashable, Sendable {
    var state: String?
    var live: String?
    var duration: String?
    var completedDuration: String?
    var downloadedLength: String?
    var progress: String?
    var error: String?
    var errorCode: String?
    var `protocol`: String?
    var tracks: [MediaTrack]?

    var fraction: Double? {
        guard live != "true", state == "downloading" || state == "paused" else { return nil }
        if let duration = Double(duration ?? ""), duration.isFinite, duration > 0,
           let completed = Double(completedDuration ?? ""), completed.isFinite {
            return min(1, max(0, completed / duration))
        }
        guard let progress = Double(progress ?? ""), progress.isFinite, progress >= 0 else { return nil }
        return min(1, progress)
    }
}

nonisolated enum DownloadProgressState: Equatable, Sendable {
    case determinate(Double)
    case indeterminate

    var fraction: Double? {
        if case .determinate(let value) = self { return value }
        return nil
    }
}

nonisolated extension DownloadTask {
    var progressState: DownloadProgressState {
        if status == .completed { return .determinate(1) }
        if isChecking || isFetchingMetadata { return .indeterminate }
        if let media { return media.fraction.map(DownloadProgressState.determinate) ?? .indeterminate }
        guard totalLength > 0 else { return .indeterminate }
        return .determinate(min(1, max(0, Double(completedLength) / Double(totalLength))))
    }

    var phaseLabel: String {
        if !isAvailableInEngine && removalAction == .removeActiveDownload { return String(localized: "Saved · not connected") }
        if status == .paused && media?.state == "awaiting-selection" { return String(localized: "Choose media tracks") }
        if status == .paused && requiresFileSelection { return String(localized: "Choose torrent files") }
        if status != .active { return status.localizedTitle }
        if isChecking { return String(localized: "Checking files") }
        if isFetchingMetadata { return String(localized: "Getting metadata") }
        if isSharing { return String(localized: "Seeding") }
        switch media?.state {
        case "probing": return String(localized: "Inspecting media")
        case "awaiting-selection": return String(localized: "Waiting for selection")
        case "recording": return String(localized: "Recording")
        case "finalizing": return String(localized: "Finalizing file")
        case "waiting": return String(localized: "Waiting")
        default: return String(localized: "Downloading")
        }
    }

    var progressLabel: String {
        if let fraction = progressState.fraction { return "\(Int(fraction * 100))%" }
        if let media, let milliseconds = Int64(media.completedDuration ?? ""), milliseconds > 0 {
            return ByteFormat.duration(Int(min(milliseconds / 1_000, Int64(Int.max))))
        }
        return "—"
    }

    var transferSizeLabel: String {
        if let media, status != .completed {
            return String(localized: "\(ByteFormat.size(Int64(media.downloadedLength ?? "") ?? 0)) downloaded")
        }
        guard totalLength > 0 else { return String(localized: "\(ByteFormat.size(completedLength)) downloaded · size unknown") }
        return "\(ByteFormat.size(completedLength)) / \(ByteFormat.size(totalLength))"
    }

    var canEditAndAddAgain: Bool { status == .failed || status == .paused || !isAvailableInEngine }

    var disconnectedSnapshot: DownloadTask {
        var copy = self
        copy.isAvailableInEngine = false
        copy.downloadSpeed = 0
        copy.uploadSpeed = 0
        copy.connections = 0
        copy.isSharing = false
        if copy.status == .active || copy.status == .waiting { copy.status = .paused }
        return copy
    }
}

struct TaskProgressIndicator: View {
    var task: DownloadTask

    var body: some View {
        // A paused/failed unknown-size task must not animate as if it were working.
        if task.progressState.fraction == nil && (task.status != .active || !task.isAvailableInEngine) {
            RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(height: 4)
                .accessibilityLabel(task.phaseLabel)
                .accessibilityValue(task.progressState.fraction == nil ? task.transferSizeLabel : task.progressLabel)
        } else {
            ProgressView(value: task.progressState.fraction)
                .progressViewStyle(.linear)
                .tint(task.status == .active ? Color.accentColor : Color.secondary)
                .accessibilityLabel(task.phaseLabel)
                .accessibilityValue(task.progressState.fraction == nil ? task.transferSizeLabel : task.progressLabel)
        }
    }
}

nonisolated enum DownloadPrivacy {
    static func reusableSource(_ source: String?) -> String? {
        guard let source, let parts = URLComponents(string: source),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["http", "https", "sftp", "file", "ed2k"].contains(parts.scheme?.lowercased() ?? "") else { return nil }
        return source
    }

    static func redact(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\/", with: "/")
        // Diagnostics can echo request headers, URL credentials or signed query parameters.
        for pattern in [#"(?i)(authorization|proxy-authorization|cookie|set-cookie)\s*[\"']?\s*[:=]\s*[^\r\n]+"#,
                        #"(?i)\b(?:https?|sftp)://[^\s\"<>]+"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let value = String(result[range])
                if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") || value.lowercased().hasPrefix("sftp://"), var parts = URLComponents(string: value) {
                    let sensitive = parts.query != nil || parts.fragment != nil || parts.user != nil || parts.password != nil
                    parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
                    result.replaceSubrange(range, with: (parts.string ?? "<redacted>") + (sensitive ? " [redacted]" : ""))
                } else {
                    result.replaceSubrange(range, with: "<redacted>")
                }
            }
        }
        return result
    }

    static func historySnapshot(_ task: DownloadTask) -> DownloadTask {
        var copy = task.disconnectedSnapshot
        copy.name = redact(copy.name)
        copy.sourceURL = reusableSource(copy.sourceURL)
        copy.errorMessage = copy.errorMessage.map(redact)
        let mediaError = copy.media?.error.map(redact)
        copy.media?.error = mediaError
        copy.peers = []
        copy.trackers = []
        copy.recentLogs = []
        return copy
    }
}

// Synthesized Decodable does not apply property defaults to absent keys. History snapshots
// predate media, scheduling and availability fields, so decode additions with explicit defaults.
nonisolated extension DownloadTask {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        protocolKind = try values.decode(TaskProtocol.self, forKey: .protocolKind)
        status = try values.decode(DownloadStatus.self, forKey: .status)
        totalLength = try values.decode(Int64.self, forKey: .totalLength)
        completedLength = try values.decode(Int64.self, forKey: .completedLength)
        downloadSpeed = try values.decode(Int64.self, forKey: .downloadSpeed)
        uploadSpeed = try values.decode(Int64.self, forKey: .uploadSpeed)
        connections = try values.decode(Int.self, forKey: .connections)
        destination = try values.decode(String.self, forKey: .destination)
        addedAt = try values.decode(Date.self, forKey: .addedAt)
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
        files = try values.decode([DownloadFile].self, forKey: .files)
        peers = try values.decode([ConnectionPeer].self, forKey: .peers)
        trackers = try values.decode([TrackerEntry].self, forKey: .trackers)
        recentLogs = try values.decode([String].self, forKey: .recentLogs)
        infoHash = try values.decodeIfPresent(String.self, forKey: .infoHash)
        isSharing = try values.decodeIfPresent(Bool.self, forKey: .isSharing) ?? false
        sourceURL = try values.decodeIfPresent(String.self, forKey: .sourceURL)
        torrentDiagnostics = try values.decodeIfPresent(BitTorrentDiagnostics.self, forKey: .torrentDiagnostics)
        media = try values.decodeIfPresent(MediaTaskProgress.self, forKey: .media)
        isChecking = try values.decodeIfPresent(Bool.self, forKey: .isChecking) ?? false
        isFetchingMetadata = try values.decodeIfPresent(Bool.self, forKey: .isFetchingMetadata) ?? false
        requiresFileSelection = try values.decodeIfPresent(Bool.self, forKey: .requiresFileSelection) ?? false
        torrentDirectory = try values.decodeIfPresent(String.self, forKey: .torrentDirectory)
        isAvailableInEngine = try values.decodeIfPresent(Bool.self, forKey: .isAvailableInEngine) ?? true
        addedAtIsFirstSeen = try values.decodeIfPresent(Bool.self, forKey: .addedAtIsFirstSeen) ?? true
        queuePosition = try values.decodeIfPresent(Int.self, forKey: .queuePosition)
        scheduledStart = try values.decodeIfPresent(Date.self, forKey: .scheduledStart)
    }
}
