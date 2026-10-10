import Foundation
import SwiftUI

nonisolated enum TaskProtocol: String, CaseIterable, Codable, Identifiable, Sendable {
    case http = "HTTP"
    case sftp = "SFTP"
    case bitTorrent = "BitTorrent"
    case magnet = "Magnet"
    case ed2k = "ED2K"
    case metalink = "Metalink"
    case thunder = "Thunder"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .http: "link"
        case .sftp: "server.rack"
        case .bitTorrent: "point.3.connected.trianglepath.dotted"
        case .magnet: "link.circle"
        case .ed2k: "shared.with.you"
        case .metalink: "doc.badge.gearshape"
        case .thunder: "bolt.horizontal"
        }
    }
}

nonisolated enum DownloadStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case active = "Active"
    case waiting = "Waiting"
    case paused = "Paused"
    case completed = "Completed"
    case failed = "Failed"
    case removed = "Removed"

    var localizedTitle: String { L10n.key(rawValue) }

    var id: String { rawValue }

    var sortOrder: Int {
        switch self {
        case .active: 0
        case .waiting: 1
        case .paused: 2
        case .failed: 3
        case .completed: 4
        case .removed: 5
        }
    }

    var symbolName: String {
        switch self {
        case .active: "arrow.down.circle.fill"
        case .waiting: "clock"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .removed: "trash"
        }
    }

    var tint: Color {
        switch self {
        case .active: .cyan
        case .waiting: .secondary
        case .paused: .orange
        case .completed: .green
        case .failed: .red
        case .removed: .secondary
        }
    }
}

nonisolated enum SidebarDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all = "All"
    case active = "Active"
    case waiting = "Waiting"
    case completed = "Completed"
    case failed = "Failed"
    case torrents = "Torrents"
    case ed2k = "ED2K"
    case browserCapture = "Browser Capture"

    var localizedTitle: String { L10n.key(rawValue) }

    var id: String { rawValue }

    var accessibilityIdentifier: String {
        switch self {
        case .all: "sidebar-destination-all"
        case .active: "sidebar-destination-active"
        case .waiting: "sidebar-destination-waiting"
        case .completed: "sidebar-destination-completed"
        case .failed: "sidebar-destination-failed"
        case .torrents: "sidebar-destination-torrents"
        case .ed2k: "sidebar-destination-ed2k"
        case .browserCapture: "sidebar-destination-browser-capture"
        }
    }

    var symbolName: String {
        switch self {
        case .all: "tray.full"
        case .active: "arrow.down.circle"
        case .waiting: "clock"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .torrents: "point.3.connected.trianglepath.dotted"
        case .ed2k: "shared.with.you"
        case .browserCapture: "globe.badge.chevron.backward"
        }
    }
}

nonisolated struct DownloadFile: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var index: Int = 0
    var path: String
    var length: Int64
    var completedLength: Int64
    var isSelected: Bool

    var progress: Double {
        guard length > 0 else { return 0 }
        return min(1, max(0, Double(completedLength) / Double(length)))
    }
}

nonisolated struct Aria2TaskSnapshot: Equatable, Sendable {
    var task: DownloadTask
    var following: String?
    var followedBy: [String]

    var firstFollowedDownloadID: String? {
        followedBy.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

nonisolated enum BitTorrentFileSelectionPhase: Equatable, Sendable {
    case loading
    case ready
    case failed
}

nonisolated struct BitTorrentFileSelectionSession: Identifiable, Equatable, Sendable {
    let id = UUID()
    var source: String
    var metadataTaskID: String?
    var downloadTaskID: String?
    var taskName: String
    var files: [DownloadFile]
    var selectedFileIndexes: Set<Int>
    var phase: BitTorrentFileSelectionPhase
    var removesTaskOnCancel = true
    var startedAt = Date()
    var destination = ""
    var diagnostics: BitTorrentDiagnostics?
    var isQueued = false
    var issue: String?
    var torrentDirectory: String?
    var metadataFilePath: String?

    var selectedFiles: [DownloadFile] {
        files.filter { selectedFileIndexes.contains($0.index) }
    }

    var selectedTotalLength: Int64 {
        selectedFiles.reduce(0) { $0 + $1.length }
    }

    var selectFileOption: String {
        selectedFileIndexes.sorted().map(String.init).joined(separator: ",")
    }

    var hasSelection: Bool {
        !selectedFileIndexes.isEmpty
    }
}

nonisolated struct ConnectionPeer: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var address: String
    var client: String
    var progress: Double
    var downloadSpeed: Int64
}

nonisolated struct TrackerEntry: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var url: String
    var status: String
    var lastAnnounce: Date?
}

nonisolated struct DownloadTask: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var protocolKind: TaskProtocol
    var status: DownloadStatus
    var totalLength: Int64
    var completedLength: Int64
    var downloadSpeed: Int64
    var uploadSpeed: Int64
    var connections: Int
    var destination: String
    var addedAt: Date
    var errorMessage: String?
    var files: [DownloadFile]
    var peers: [ConnectionPeer]
    var trackers: [TrackerEntry]
    var recentLogs: [String]
    var infoHash: String?
    var isSharing = false
    var sourceURL: String? = nil // Ephemeral; history only keeps credential-free sources.
    var torrentDiagnostics: BitTorrentDiagnostics? = nil
    var media: MediaTaskProgress? = nil
    var isChecking: Bool = false
    var isFetchingMetadata: Bool = false
    var requiresFileSelection: Bool = false
    var isAvailableInEngine: Bool = true
    var addedAtIsFirstSeen: Bool = true
    var queuePosition: Int? = nil
    var scheduledStart: Date? = nil
    var torrentDirectory: String? = nil
    var torrentFileIssue: TorrentFileIssue? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, protocolKind, status, totalLength, completedLength, downloadSpeed, uploadSpeed
        case connections, destination, addedAt, errorMessage, files, peers, trackers, recentLogs, infoHash
        case isSharing, sourceURL, torrentDiagnostics, media, isChecking, isFetchingMetadata
        case requiresFileSelection, isAvailableInEngine, addedAtIsFirstSeen, queuePosition, scheduledStart
        case torrentDirectory, torrentFileIssue
    }

    var hasReportedTrashableFiles: Bool {
        files.contains { DownloadTaskTrashPath.isReportedUserContentPath($0.path) }
    }

    var progress: Double {
        progressState.fraction ?? 0
    }

    var isTorrentLike: Bool {
        protocolKind == .bitTorrent || protocolKind == .magnet
    }

    var primaryControlAction: DownloadTaskControlAction? {
        guard isAvailableInEngine, media?.state != "finalizing" else { return nil }
        return switch status {
        case .active, .waiting:
            .pause
        case .paused:
            .resume
        case .completed, .failed, .removed:
            nil
        }
    }

    var removalAction: DownloadTaskRemovalAction {
        switch status {
        case .active, .waiting, .paused:
            .removeActiveDownload
        case .completed, .failed, .removed:
            .removeDownloadResult
        }
    }
}

nonisolated enum DownloadTaskControlAction: Equatable, Sendable {
    var accessibilityName: String { self == .pause ? "pause" : "resume" }
    case pause
    case resume

    var symbolName: String {
        switch self {
        case .pause:
            "pause.fill"
        case .resume:
            "play.fill"
        }
    }

    var helpTitle: String {
        switch self {
        case .pause:
            String(localized: "Pause")
        case .resume:
            String(localized: "Resume")
        }
    }
}

nonisolated enum DownloadTaskRemovalAction: Equatable, Sendable {
    case removeActiveDownload
    case removeDownloadResult
}

nonisolated struct SpeedSample: Identifiable, Hashable, Sendable {
    static let rollingWindowDuration: TimeInterval = 10 * 60

    var id = UUID()
    var timestamp: Date
    var downloadBytesPerSecond: Int64
    var uploadBytesPerSecond: Int64

    static func rollingWindowSamples(_ samples: [SpeedSample], now: Date = Date()) -> [SpeedSample] {
        let cutoff = now.addingTimeInterval(-rollingWindowDuration)
        return samples.filter { $0.timestamp >= cutoff }
    }
}
