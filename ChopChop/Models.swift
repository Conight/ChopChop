import Foundation
import CFNetwork
import SystemConfiguration
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

    enum CodingKeys: String, CodingKey {
        case id, name, protocolKind, status, totalLength, completedLength, downloadSpeed, uploadSpeed
        case connections, destination, addedAt, errorMessage, files, peers, trackers, recentLogs, infoHash
        case isSharing, sourceURL, torrentDiagnostics, media, isChecking, isFetchingMetadata
        case requiresFileSelection, isAvailableInEngine, addedAtIsFirstSeen, queuePosition, scheduledStart
        case torrentDirectory
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

nonisolated struct AddDownloadDraft: Equatable, Sendable {
    var rawInput = ""
    var outputName = ""
    var savePath = ""
    var treatLinesAsMirrors = false
    var limitSpeed = false
    var speedLimitKB: Int = 0
    var splitCount = EngineSettings.defaultSplitCount
    var userAgent = EngineSettings.defaultUserAgent
    var referer = ""
    var cookie = ""
    var authorization = ""
    var customHeaders = ""
    var proxyURL = ""
    var importedDocuments: [String: ImportedDownloadDocument] = [:]
    var media = MediaDownloadOptions()
    var torrentDirectory: String? = nil

    var detectedProtocol: TaskProtocol? {
        resourceLines.first.flatMap(Self.detectProtocol)
    }

    var resourceLines: [String] {
        rawInput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var isBatch: Bool {
        resourceLines.count > 1
    }

    var containsBitTorrentResource: Bool {
        resourceLines.contains { resource in
            let protocolKind = Self.detectProtocol(for: resource)
            return protocolKind == .magnet || protocolKind == .bitTorrent
        }
    }

    var shouldResolveBitTorrentFilesBeforeSubmit: Bool {
        guard resourceLines.count == 1, !treatLinesAsMirrors else { return false }
        return detectedProtocol == .magnet || detectedProtocol == .bitTorrent
    }

    var isSubmittable: Bool {
        !resourceLines.isEmpty &&
            resourceLines.allSatisfy { Self.detectProtocol(for: $0) != nil } &&
            (!limitSpeed || speedLimitKB > 0)
    }

    func normalizedResources() throws -> [String] {
        let resources = resourceLines
        guard !resources.isEmpty else { throw DownloadDraftError.emptyResource }
        return try resources.map { resource in
            let normalized = try Self.normalizedResource(resource)
            guard Self.detectProtocol(for: normalized) != nil else { throw DownloadDraftError.unsupportedProtocol }
            return normalized
        }
    }

    func engineOptions(fallbackDirectory: String?, autoOrganize: Bool) throws -> [String: String] {
        let normalized = try normalizedResources()
        if normalized.count > 1, media.mode != .file,
           (media.mode != .automatic || normalized.contains(where: Self.isMediaManifest)) {
            throw DownloadOperationError(String(localized: "Add one media source at a time to inspect and choose its tracks."))
        }
        if normalized.count > 1, !treatLinesAsMirrors, !outputName.trimmedForEngine.isEmpty {
            throw DownloadDraftError.outputNameRequiresSingleTask
        }

        var options: [String: String] = ["pause": "false"]
        if !outputName.trimmedForEngine.isEmpty {
            options["out"] = outputName.trimmedForEngine
        }
        if !savePath.trimmedForEngine.isEmpty {
            options["dir"] = savePath.trimmedForEngine
        } else if let fallbackDirectory, !fallbackDirectory.trimmedForEngine.isEmpty {
            options["dir"] = fallbackDirectory.trimmedForEngine
        }
        if autoOrganize,
           let baseDirectory = options["dir"],
           !baseDirectory.isEmpty,
           !treatLinesAsMirrors,
           normalized.count == 1,
           let organized = FileCategoryRules.directory(for: normalized[0], baseDirectory: baseDirectory) {
            options["dir"] = organized
        }
        if limitSpeed, speedLimitKB > 0 {
            options["max-download-limit"] = "\(speedLimitKB)K"
        }
        if splitCount > 0 {
            options["split"] = "\(splitCount)"
        }
        if !proxyURL.trimmedForEngine.isEmpty {
            options["all-proxy"] = proxyURL.trimmedForEngine
        }
        if !userAgent.trimmedForEngine.isEmpty {
            try validateHeaderValue(userAgent, label: "User-Agent")
            options["user-agent"] = userAgent.trimmedForEngine
        }
        if !referer.trimmedForEngine.isEmpty {
            try validateHeaderValue(referer, label: "Referer")
            options["referer"] = referer.trimmedForEngine
        }

        let headerLines = try requestHeaderLines()
        if !headerLines.isEmpty {
            options["header"] = headerLines.joined(separator: "\n")
        }
        if media.mode != .automatic || shouldInspectMedia {
            options.merge(try media.engineOptions()) { _, new in new }
        }
        return options
    }

    private func requestHeaderLines() throws -> [String] {
        var lines: [String] = []
        if !cookie.trimmedForEngine.isEmpty {
            try validateHeaderValue(cookie, label: "Cookie")
            lines.append("Cookie: \(cookie.trimmedForEngine)")
        }
        if !authorization.trimmedForEngine.isEmpty {
            try validateHeaderValue(authorization, label: "Authorization")
            lines.append("Authorization: \(authorization.trimmedForEngine)")
        }
        for rawLine in customHeaders.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let separator = line.firstIndex(of: ":"),
                  separator != line.startIndex else {
                throw DownloadDraftError.invalidHeader(line)
            }
            try validateHeaderValue(line, label: String(localized: "Custom header"))
            lines.append(line)
        }
        return lines
    }

    private func validateHeaderValue(_ value: String, label: String) throws {
        if value.contains(where: \.isNewline) {
            throw DownloadDraftError.invalidHeader(label)
        }
    }

    static func detectProtocol(for resource: String) -> TaskProtocol? {
        let trimmed = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("ftp://") { return nil }
        if isBareBitTorrentInfoHash(trimmed) { return .magnet }
        if lowered.hasPrefix("thunder://") { return .thunder }
        if lowered.hasPrefix("magnet:") { return .magnet }
        if lowered.hasPrefix("ed2k://") { return .ed2k }
        if isTorrentResource(trimmed) { return .bitTorrent }
        if lowered.hasPrefix("sftp://") { return .sftp }
        if lowered.hasSuffix(".meta4") || lowered.hasSuffix(".metalink") { return .metalink }
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return .http }
        return nil
    }

    static func normalizedResource(_ resource: String) throws -> String {
        let trimmed = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DownloadDraftError.emptyResource }
        if isBareBitTorrentInfoHash(trimmed) {
            return "magnet:?xt=urn:btih:\(trimmed)"
        }
        if trimmed.lowercased().hasPrefix("thunder://") {
            return try decodeThunderResource(trimmed)
        }
        return trimmed
    }

    static func isBareBitTorrentInfoHash(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 40 || trimmed.count == 32 else { return false }
        if trimmed.count == 40 {
            return trimmed.allSatisfy { $0.isHexDigit }
        }
        return trimmed.allSatisfy { character in
            ("A"..."Z").contains(character) || ("2"..."7").contains(character)
        }
    }

    static func isLocalTorrentFile(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isTorrentResource(trimmed) else { return false }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            guard scheme.lowercased() == "file" else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        return FileManager.default.fileExists(atPath: trimmed)
    }

    static func localTorrentFileURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLocalTorrentFile(trimmed) else { return nil }
        if let url = URL(string: trimmed), url.scheme?.lowercased() == "file" {
            return url
        }
        return URL(fileURLWithPath: trimmed)
    }

    private static func isTorrentResource(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        if lowered.hasSuffix(".torrent") { return true }
        if let components = URLComponents(string: trimmed),
           let path = components.percentEncodedPath.removingPercentEncoding,
           path.lowercased().hasSuffix(".torrent") {
            return true
        }
        return false
    }

    private static func decodeThunderResource(_ resource: String) throws -> String {
        let payload = String(resource.dropFirst("thunder://".count))
        guard let data = Data(base64Encoded: payload),
              let decoded = String(data: data, encoding: .utf8),
              decoded.hasPrefix("AA"),
              decoded.hasSuffix("ZZ") else {
            throw DownloadDraftError.invalidThunderLink(resource)
        }
        return String(decoded.dropFirst(2).dropLast(2))
    }
}

nonisolated enum DownloadDraftError: LocalizedError, Sendable {
    case emptyResource
    case unsupportedProtocol
    case invalidThunderLink(String)
    case invalidHeader(String)
    case outputNameRequiresSingleTask
    case bitTorrentSelectionRequiresSingleResource
    case documentRequiresSingleResource

    var errorDescription: String? {
        switch self {
        case .unsupportedProtocol:
            String(localized: "This protocol is not supported. Use HTTP, HTTPS, SFTP, Magnet, ED2K, torrent, or Metalink. FTP is no longer supported by Aria2 Next.")
        case .emptyResource:
            String(localized: "Enter at least one download link.")
        case .invalidThunderLink(let value):
            String(localized: "Thunder link could not be decoded: \(value)")
        case .invalidHeader(let value):
            String(localized: "Header value is invalid: \(value)")
        case .outputNameRequiresSingleTask:
            String(localized: "Output filename can only be set for one task or for a mirror group.")
        case .bitTorrentSelectionRequiresSingleResource:
            String(localized: "Add one Magnet or torrent at a time to choose files before downloading.")
        case .documentRequiresSingleResource:
            String(localized: "Review one Torrent or Metalink file at a time. Use File → Open Download File… to queue multiple files.")
        }
    }
}

nonisolated enum FileAllocationMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case none
    case trunc
    case prealloc
    case falloc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .trunc: String(localized: "Truncate")
        case .prealloc: String(localized: "Preallocate")
        case .falloc: String(localized: "Fallocate")
        }
    }
}

nonisolated enum TrackerSyncInterval: Int, CaseIterable, Identifiable, Sendable {
    case everyStartup = 0
    case sixHours = 6
    case twelveHours = 12
    case daily = 24
    case weekly = 168

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .everyStartup: String(localized: "Every startup")
        case .sixHours: String(localized: "Every 6 hours")
        case .twelveHours: String(localized: "Every 12 hours")
        case .daily: String(localized: "Daily")
        case .weekly: String(localized: "Weekly")
        }
    }
}

nonisolated enum BitTorrentSharingMode: String, CaseIterable, Identifiable, Sendable {
    case stopByCondition
    case manualStop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stopByCondition: String(localized: "Stop by ratio or time")
        case .manualStop: String(localized: "Seed until manually stopped")
        }
    }
}

nonisolated struct TrackerSourceOption: Identifiable, Hashable, Sendable {
    var provider: String
    var name: String
    var url: String
    var usesCDN: Bool

    var id: String { url }

    var displayName: String {
        usesCDN ? "\(name) (CDN)" : name
    }
}

nonisolated enum TrackerSourceCatalog {
    static let all: [TrackerSourceOption] = [
        TrackerSourceOption(
            provider: "ngosang/trackerslist",
            name: "trackers_best.txt",
            url: "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt",
            usesCDN: false
        ),
        TrackerSourceOption(
            provider: "ngosang/trackerslist",
            name: "trackers_best_ip.txt",
            url: "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best_ip.txt",
            usesCDN: false
        ),
        TrackerSourceOption(
            provider: "ngosang/trackerslist",
            name: "trackers_all.txt",
            url: "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt",
            usesCDN: false
        ),
        TrackerSourceOption(
            provider: "ngosang/trackerslist",
            name: "trackers_all_ip.txt",
            url: "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_ip.txt",
            usesCDN: false
        ),
        TrackerSourceOption(
            provider: "ngosang/trackerslist",
            name: "trackers_best.txt",
            url: "https://cdn.jsdelivr.net/gh/ngosang/trackerslist/trackers_best.txt",
            usesCDN: true
        ),
        TrackerSourceOption(
            provider: "ngosang/trackerslist",
            name: "trackers_best_ip.txt",
            url: "https://cdn.jsdelivr.net/gh/ngosang/trackerslist/trackers_best_ip.txt",
            usesCDN: true
        ),
        TrackerSourceOption(
            provider: "ngosang/trackerslist",
            name: "trackers_all.txt",
            url: "https://cdn.jsdelivr.net/gh/ngosang/trackerslist/trackers_all.txt",
            usesCDN: true
        ),
        TrackerSourceOption(
            provider: "ngosang/trackerslist",
            name: "trackers_all_ip.txt",
            url: "https://cdn.jsdelivr.net/gh/ngosang/trackerslist/trackers_all_ip.txt",
            usesCDN: true
        ),
        TrackerSourceOption(
            provider: "XIU2/TrackersListCollection",
            name: "best.txt",
            url: "https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/best.txt",
            usesCDN: false
        ),
        TrackerSourceOption(
            provider: "XIU2/TrackersListCollection",
            name: "all.txt",
            url: "https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/all.txt",
            usesCDN: false
        ),
        TrackerSourceOption(
            provider: "XIU2/TrackersListCollection",
            name: "http.txt",
            url: "https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/http.txt",
            usesCDN: false
        ),
        TrackerSourceOption(
            provider: "XIU2/TrackersListCollection",
            name: "best.txt",
            url: "https://cdn.jsdelivr.net/gh/XIU2/TrackersListCollection/best.txt",
            usesCDN: true
        ),
        TrackerSourceOption(
            provider: "XIU2/TrackersListCollection",
            name: "all.txt",
            url: "https://cdn.jsdelivr.net/gh/XIU2/TrackersListCollection/all.txt",
            usesCDN: true
        ),
        TrackerSourceOption(
            provider: "XIU2/TrackersListCollection",
            name: "http.txt",
            url: "https://cdn.jsdelivr.net/gh/XIU2/TrackersListCollection/http.txt",
            usesCDN: true
        )
    ]

    static var defaultSourceURLs: [String] {
        all.filter(\.usesCDN).map(\.url)
    }

    static var providers: [String] {
        var seen = Set<String>()
        var providers: [String] = []
        for option in all where seen.insert(option.provider).inserted {
            providers.append(option.provider)
        }
        return providers
    }

    static func options(for provider: String) -> [TrackerSourceOption] {
        all.filter { $0.provider == provider }
    }
}

nonisolated enum TrackerText {
    static let maxAria2OptionLength = 6_144

    static func trackers(from text: String) -> [String] {
        uniqueTrackers(
            text
                .components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    static func lineSeparated(from text: String) -> String {
        trackers(from: text).joined(separator: "\n")
    }

    static func lineSeparated(fromChunks chunks: [String]) -> String {
        lineSeparated(from: chunks.joined(separator: "\n"))
    }

    static func commaSeparated(from text: String) -> String {
        trackers(from: text).joined(separator: ",")
    }

    static func reducedCommaSeparated(from text: String, maxLength: Int = maxAria2OptionLength) -> String {
        let commaSeparated = commaSeparated(from: text)
        guard commaSeparated.count > maxLength else { return commaSeparated }
        let prefix = String(commaSeparated.prefix(maxLength))
        guard let lastComma = prefix.lastIndex(of: ",") else { return prefix }
        return String(prefix[..<lastComma])
    }

    private static func uniqueTrackers(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !value.isEmpty {
            guard seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }
}

nonisolated enum TrackerSourceURLValidator {
    static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return false
        }
        return true
    }
}

nonisolated enum TrackerURLValidator {
    static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "udp"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return true
    }
}

nonisolated struct TrackerSourceFetchFailure: Equatable, Sendable {
    var url: String
    var reason: String
}

nonisolated struct TrackerSourceFetchResult: Equatable, Sendable {
    var data: [String]
    var failures: [TrackerSourceFetchFailure]
}

nonisolated protocol BitTorrentTrackerSourceFetching: Sendable {
    func fetchTrackerSources(_ urls: [String]) async -> TrackerSourceFetchResult
}

nonisolated struct URLSessionBitTorrentTrackerSourceFetcher: BitTorrentTrackerSourceFetching {
    @concurrent
    func fetchTrackerSources(_ urls: [String]) async -> TrackerSourceFetchResult {
        var data: [String] = []
        var failures: [TrackerSourceFetchFailure] = []

        for urlString in urls {
            guard let url = URL(string: urlString) else {
                failures.append(TrackerSourceFetchFailure(url: urlString, reason: String(localized: "Invalid URL.")))
                continue
            }
            do {
                let (body, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    failures.append(
                        TrackerSourceFetchFailure(
                            url: urlString,
                            reason: String(localized: "HTTP \(httpResponse.statusCode).")
                        )
                    )
                    continue
                }
                guard let text = String(data: body, encoding: .utf8) else {
                    failures.append(TrackerSourceFetchFailure(url: urlString, reason: String(localized: "Response is not valid UTF-8.")))
                    continue
                }
                guard !TrackerText.trackers(from: text).isEmpty else {
                    failures.append(TrackerSourceFetchFailure(url: urlString, reason: String(localized: "No trackers found.")))
                    continue
                }
                data.append(text)
            } catch {
                failures.append(TrackerSourceFetchFailure(url: urlString, reason: error.localizedDescription))
            }
        }

        return TrackerSourceFetchResult(data: data, failures: failures)
    }
}

nonisolated struct ED2KBootstrapPaths: Equatable, Sendable {
    var serverMetPath: String
    var nodesDatPath: String
}

nonisolated struct ED2KBootstrapStatus: Equatable, Sendable {
    var serverMetSize: Int64?
    var nodesDatSize: Int64?
    var serverMetModified: Date?
    var nodesDatModified: Date?

    var hasUsableFiles: Bool {
        (serverMetSize ?? 0) > 0 && (nodesDatSize ?? 0) > 0
    }

    var latestModificationDate: Date? {
        [serverMetModified, nodesDatModified].compactMap { $0 }.max()
    }
}

nonisolated struct ED2KBootstrapFetchResult: Equatable, Sendable {
    var serverMet: Data
    var nodesDat: Data
}

nonisolated struct ED2KBootstrapFetchFailure: LocalizedError, Sendable {
    var reason: String

    var errorDescription: String? { reason }
}

nonisolated protocol ED2KBootstrapFetching: Sendable {
    func fetch(serverMetURL: String, nodesDatURL: String, proxyURL: String) async throws -> ED2KBootstrapFetchResult
}

nonisolated struct URLSessionED2KBootstrapFetcher: ED2KBootstrapFetching {
    private static let maxBootstrapFileSize = 16 * 1024 * 1024

    @concurrent
    func fetch(serverMetURL: String, nodesDatURL: String, proxyURL: String) async throws -> ED2KBootstrapFetchResult {
        async let serverMet = download(urlString: serverMetURL, proxyURL: proxyURL)
        async let nodesDat = download(urlString: nodesDatURL, proxyURL: proxyURL)
        return try await ED2KBootstrapFetchResult(serverMet: serverMet, nodesDat: nodesDat)
    }

    private func download(urlString: String, proxyURL: String) async throws -> Data {
        guard ED2KBootstrapURLValidator.isValid(urlString),
              let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ED2KBootstrapFetchFailure(reason: String(localized: "ED2K bootstrap URL must use HTTP or HTTPS."))
        }

        let session = URLSession(configuration: sessionConfiguration(proxyURL: proxyURL))
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw ED2KBootstrapFetchFailure(reason: String(localized: "ED2K bootstrap file returned HTTP \(httpResponse.statusCode)."))
        }
        guard !data.isEmpty, data.count <= Self.maxBootstrapFileSize else {
            throw ED2KBootstrapFetchFailure(reason: String(localized: "Invalid ED2K bootstrap file size: \(data.count)."))
        }
        return data
    }

    private func sessionConfiguration(proxyURL: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        let trimmedProxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedProxy),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              let port = url.port else {
            return configuration
        }

        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port
        ]
        return configuration
    }
}

nonisolated enum ED2KBootstrapURLValidator {
    static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return false
        }
        return true
    }
}

nonisolated enum ED2KServerText {
    static func servers(from text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawValue in text.components(separatedBy: CharacterSet(charactersIn: ",\n\r")) {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, isValidServer(value), seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    static func lineSeparated(from text: String) -> String {
        servers(from: text).joined(separator: "\n")
    }

    static func commaSeparated(from text: String) -> String {
        servers(from: text).joined(separator: ",")
    }

    static func containsInvalidServer(in text: String) -> Bool {
        let values = text.components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.contains { !isValidServer($0) }
    }

    private static func isValidServer(_ value: String) -> Bool {
        let separator = value.lastIndex(of: ":")
        guard let separator, separator != value.startIndex, separator != value.index(before: value.endIndex) else {
            return false
        }
        let host = value[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = value[value.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = Int(portText), (1...65_535).contains(port) else {
            return false
        }
        return true
    }
}

nonisolated enum ED2KBootstrapCache {
    static let directoryName = "ed2k"
    static let serverMetFileName = "server.met"
    static let nodesDatFileName = "nodes.dat"

    static func paths(applicationSupportBase: URL? = nil) throws -> ED2KBootstrapPaths {
        let directory = try directory(applicationSupportBase: applicationSupportBase)
        return ED2KBootstrapPaths(
            serverMetPath: directory.appendingPathComponent(serverMetFileName, isDirectory: false).path,
            nodesDatPath: directory.appendingPathComponent(nodesDatFileName, isDirectory: false).path
        )
    }

    static func cachedPathsIfAvailable(applicationSupportBase: URL? = nil) -> ED2KBootstrapPaths? {
        guard let paths = try? paths(applicationSupportBase: applicationSupportBase),
              FileManager.default.fileExists(atPath: paths.serverMetPath),
              FileManager.default.fileExists(atPath: paths.nodesDatPath),
              (fileSize(at: paths.serverMetPath) ?? 0) > 0,
              (fileSize(at: paths.nodesDatPath) ?? 0) > 0 else {
            return nil
        }
        return paths
    }

    static func status(applicationSupportBase: URL? = nil) -> ED2KBootstrapStatus {
        guard let paths = try? paths(applicationSupportBase: applicationSupportBase) else {
            return ED2KBootstrapStatus()
        }
        return status(paths: paths)
    }

    static func status(paths: ED2KBootstrapPaths) -> ED2KBootstrapStatus {
        ED2KBootstrapStatus(
            serverMetSize: fileSize(at: paths.serverMetPath),
            nodesDatSize: fileSize(at: paths.nodesDatPath),
            serverMetModified: modificationDate(at: paths.serverMetPath),
            nodesDatModified: modificationDate(at: paths.nodesDatPath)
        )
    }

    static func write(_ result: ED2KBootstrapFetchResult, applicationSupportBase: URL? = nil) throws -> ED2KBootstrapStatus {
        let paths = try paths(applicationSupportBase: applicationSupportBase)
        try atomicWrite(result.serverMet, to: URL(fileURLWithPath: paths.serverMetPath))
        try atomicWrite(result.nodesDat, to: URL(fileURLWithPath: paths.nodesDatPath))
        return status(paths: paths)
    }

    private static func directory(applicationSupportBase: URL?) throws -> URL {
        let support = try Aria2NextPaths.supportDirectory(
            applicationSupportBase: applicationSupportBase ?? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        )
        let directory = support.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).tmp", isDirectory: false)
        if FileManager.default.fileExists(atPath: temporaryURL.path) {
            try FileManager.default.removeItem(at: temporaryURL)
        }
        try data.write(to: temporaryURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    private static func fileSize(at path: String) -> Int64? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private static func modificationDate(at path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }
}

nonisolated enum ED2KSearchFileType: String, CaseIterable, Identifiable, Sendable {
    case any = ""
    case audio
    case video
    case document = "doc"
    case archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: String(localized: "Any")
        case .audio: String(localized: "Audio")
        case .video: String(localized: "Video")
        case .document: String(localized: "Document")
        case .archive: String(localized: "Archive")
        }
    }
}

nonisolated struct ED2KSearchOptions: Equatable, Sendable {
    var fileType: ED2KSearchFileType = .any
    var minSourceCount: Int?

    func engineOptions(directory: String, context: ED2KDownloadContext?) -> [String: String] {
        var options: [String: String] = ["dir": directory]
        if fileType != .any {
            options["fileType"] = fileType.rawValue
        }
        if let minSourceCount, minSourceCount > 0 {
            options["minSourceCount"] = "\(minSourceCount)"
        }
        context?.apply(to: &options)
        return options
    }
}

nonisolated struct ED2KSearchResult: Identifiable, Decodable, Equatable, Sendable {
    var hash: String?
    var name: String?
    var length: String?
    var sourceCount: String?
    var completeSourceCount: String?
    var fileType: String?
    var extensionName: String?
    var sourceNetwork: String?
    var ed2kLink: String?

    enum CodingKeys: String, CodingKey {
        case hash
        case name
        case length
        case sourceCount
        case completeSourceCount
        case fileType
        case extensionName = "extension"
        case sourceNetwork
        case ed2kLink
    }

    var id: String {
        ed2kLink?.trimmedForEngine.nonEmptyValue ??
            hash?.trimmedForEngine.nonEmptyValue ??
            "\(name ?? "unknown")-\(length ?? "0")-\(sourceCount ?? "0")"
    }

    var displayName: String {
        name?.trimmedForEngine.nonEmptyValue ?? String(localized: "Unnamed ED2K file")
    }

    var lengthBytes: Int64 {
        Int64(length ?? "") ?? 0
    }
}

nonisolated struct ED2KSearchResults: Decodable, Equatable, Sendable {
    var gid: String?
    var status: String?
    var moreResults: Bool?
    var results: [ED2KSearchResult]?
}

nonisolated struct ED2KDownloadContext: Equatable, Sendable {
    var bootstrapPaths: ED2KBootstrapPaths?
    var serverList: String

    var hasBootstrapOrServer: Bool {
        bootstrapPaths != nil || !serverList.trimmedForEngine.isEmpty
    }

    func apply(to options: inout [String: String]) {
        if let bootstrapPaths {
            options["ed2k-server-list"] = bootstrapPaths.serverMetPath
            options["ed2k-node-list"] = bootstrapPaths.nodesDatPath
        }
        if !serverList.trimmedForEngine.isEmpty {
            options["ed2k-server"] = serverList.trimmedForEngine
        }
    }
}

nonisolated enum ED2KSearchTempCache {
    static let directoryPrefix = "chopchop-ed2k-search-"

    static func createDirectory(root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = root.appendingPathComponent("\(directoryPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func cleanup(_ url: URL?) {
        guard let url else { return }
        guard url.lastPathComponent.hasPrefix(directoryPrefix) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

nonisolated struct SystemProxyInfo: Equatable, Sendable {
    var server: String
    var bypass: String
    var isSocks: Bool
}

nonisolated enum SystemProxyDetector {
    static func detect() -> SystemProxyInfo? {
        guard let proxyDictionary = SCDynamicStoreCopyProxies(nil) as NSDictionary? else {
            return nil
        }
        var rawDictionary: [String: Any] = [:]
        for (key, value) in proxyDictionary {
            guard let key = key as? String else { continue }
            rawDictionary[key] = value
        }
        return proxyInfo(from: rawDictionary)
    }

    static func proxyInfo(from dictionary: [String: Any]) -> SystemProxyInfo? {
        if boolValue(dictionary, key: kSCPropNetProxiesHTTPEnable) {
            if let info = buildProxyInfo(
                dictionary,
                hostKey: kSCPropNetProxiesHTTPProxy,
                portKey: kSCPropNetProxiesHTTPPort,
                scheme: "http",
                isSocks: false
            ) {
                return info
            }
        }

        if boolValue(dictionary, key: kSCPropNetProxiesHTTPSEnable) {
            if let info = buildProxyInfo(
                dictionary,
                hostKey: kSCPropNetProxiesHTTPSProxy,
                portKey: kSCPropNetProxiesHTTPSPort,
                scheme: "http",
                isSocks: false
            ) {
                return info
            }
        }

        if boolValue(dictionary, key: kSCPropNetProxiesSOCKSEnable) {
            if let info = buildProxyInfo(
                dictionary,
                hostKey: kSCPropNetProxiesSOCKSProxy,
                portKey: kSCPropNetProxiesSOCKSPort,
                scheme: "socks5",
                isSocks: true
            ) {
                return info
            }
        }

        return nil
    }

    private static func buildProxyInfo(
        _ dictionary: [String: Any],
        hostKey: CFString,
        portKey: CFString,
        scheme: String,
        isSocks: Bool
    ) -> SystemProxyInfo? {
        guard let host = stringValue(dictionary, key: hostKey), !host.isEmpty else { return nil }
        guard let port = intValue(dictionary, key: portKey), (1...65_535).contains(port) else { return nil }
        return SystemProxyInfo(
            server: "\(scheme)://\(host):\(port)",
            bypass: bypassList(from: dictionary),
            isSocks: isSocks
        )
    }

    private static func bypassList(from dictionary: [String: Any]) -> String {
        var entries: [String] = []
        if let exceptions = dictionary[kSCPropNetProxiesExceptionsList as String] as? [String] {
            for exception in exceptions {
                let trimmed = exception.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !entries.contains(trimmed) {
                    entries.append(trimmed)
                }
            }
        }

        if boolValue(dictionary, key: kSCPropNetProxiesExcludeSimpleHostnames),
           !entries.contains("<local>") {
            entries.append("<local>")
        }
        return entries.joined(separator: ",")
    }

    private static func boolValue(_ dictionary: [String: Any], key: CFString) -> Bool {
        intValue(dictionary, key: key) == 1
    }

    private static func intValue(_ dictionary: [String: Any], key: CFString) -> Int? {
        if let value = dictionary[key as String] as? Int {
            return value
        }
        if let value = dictionary[key as String] as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private static func stringValue(_ dictionary: [String: Any], key: CFString) -> String? {
        (dictionary[key as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated struct EngineSettings: Equatable, Sendable {
    static let defaultRPCPort = 29100
    static let defaultSplitCount = 64
    static let defaultBTListenPort = 29120
    static let defaultDHTListenPort = 29130
    static let defaultED2KListenPort = 29140
    static let defaultED2KUDPListenPort = 29150
    static let validED2KListenPortRange = 0...65_535
    static let defaultED2KServerMetURL = "https://upd.emule-security.org/server.met"
    static let defaultED2KNodesDatURL = "https://upd.emule-security.org/nodes.dat"
    static let defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"
    static let systemCACertificatePath = "/etc/ssl/cert.pem"

    static var defaultDownloadDirectoryPath: String? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    static var defaultCACertificatePath: String? {
        FileManager.default.fileExists(atPath: systemCACertificatePath) ? systemCACertificatePath : nil
    }

    static func isDefaultDownloadDirectoryPath(_ path: String) -> Bool {
        guard let defaultDownloadDirectoryPath else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path ==
            URL(fileURLWithPath: defaultDownloadDirectoryPath).resolvingSymlinksInPath().standardizedFileURL.path
    }

    var rpcToken = ""
    var rpcPort: Int = EngineSettings.defaultRPCPort
    var downloadDirectoryPath: String? = EngineSettings.defaultDownloadDirectoryPath
    var downloadDirectoryBookmark: Data?
    var maxActiveDownloads = 6
    var maxConnectionsPerTask = 64
    var splitCount = EngineSettings.defaultSplitCount
    var maxOverallDownloadLimitKB = 0
    var maxOverallUploadLimitKB = 0
    var retryCount = 0
    var retryWaitSeconds = 10
    var connectTimeoutSeconds = 10
    var timeoutSeconds = 10
    var fileAllocation: FileAllocationMode = .trunc
    var asyncDNS = false
    var userAgent = EngineSettings.defaultUserAgent
    var proxyURL = ""
    var proxyBypass = ""
    var btMaxPeers = 128
    var btDHTEnabled = true
    var btPeerExchangeEnabled = true
    var btLocalPeerDiscoveryEnabled = true
    var btForceEncryption = false
    var pauseMetadata = true
    var keepSharing = false
    var shareRatio = 2
    var shareTimeMinutes = 2_880
    var listenPort = EngineSettings.defaultBTListenPort
    var dhtListenPort = EngineSettings.defaultDHTListenPort
    var btTracker = ""
    var btTrackerAutoSync = true
    var btTrackerSyncIntervalHours = TrackerSyncInterval.daily.rawValue
    var trackerSourceURLs = TrackerSourceCatalog.defaultSourceURLs
    var customTrackerSourceURLs: [String] = []
    var lastTrackerSyncAt: Date?
    var ed2kListenPort = EngineSettings.defaultED2KListenPort
    var ed2kUDPListenPort = EngineSettings.defaultED2KUDPListenPort
    var ed2kServer = ""
    var ed2kServerMetURL = EngineSettings.defaultED2KServerMetURL
    var ed2kNodesDatURL = EngineSettings.defaultED2KNodesDatURL
    var ed2kBootstrapAutoSync = false
    var ed2kBootstrapSyncIntervalHours = TrackerSyncInterval.daily.rawValue
    var lastED2KBootstrapSyncAt: Date?
    var ed2kUploadSlots = 3
    var ed2kSearchTimeoutSeconds = 20

    var sharingMode: BitTorrentSharingMode {
        keepSharing ? .manualStop : .stopByCondition
    }

    var hasDownloadDirectoryAccess: Bool {
        guard let downloadDirectoryPath,
              !downloadDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return downloadDirectoryBookmark != nil ||
            Self.isDefaultDownloadDirectoryPath(downloadDirectoryPath)
    }

    var missingLaunchRequirements: [String] {
        var requirements: [String] = []
        if rpcToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requirements.append(String(localized: "Generate an RPC token"))
        }
        if !(1...65535).contains(rpcPort) {
            requirements.append(String(localized: "Set RPC port between 1 and 65535"))
        }
        if !(1...65535).contains(listenPort) {
            requirements.append(String(localized: "Set BT listen port between 1 and 65535"))
        }
        if !(1...65535).contains(dhtListenPort) {
            requirements.append(String(localized: "Set DHT listen port between 1 and 65535"))
        }
        if !Self.validED2KListenPortRange.contains(ed2kListenPort) {
            requirements.append(String(localized: "Set ED2K listen port between 0 and 65535"))
        }
        if !Self.validED2KListenPortRange.contains(ed2kUDPListenPort) {
            requirements.append(String(localized: "Set ED2K UDP listen port between 0 and 65535"))
        }
        if !(1...100).contains(ed2kUploadSlots) {
            requirements.append(String(localized: "Set ED2K upload slots between 1 and 100"))
        }
        if !(10...600).contains(ed2kSearchTimeoutSeconds) {
            requirements.append(String(localized: "Set ED2K search timeout between 10 and 600 seconds"))
        }
        if !hasDownloadDirectoryAccess {
            requirements.append(String(localized: "Choose a default download folder"))
        }
        return requirements
    }

    var canLaunch: Bool {
        missingLaunchRequirements.isEmpty
    }

    func validateLaunchRequirements() throws {
        guard !rpcToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.missingRPCToken
        }
        guard (1...65535).contains(rpcPort) else {
            throw EngineError.invalidRPCPort(rpcPort)
        }
        guard (1...65535).contains(listenPort) else {
            throw EngineError.invalidListenPort(label: String(localized: "BT listen port"), port: listenPort)
        }
        guard (1...65535).contains(dhtListenPort) else {
            throw EngineError.invalidListenPort(label: String(localized: "DHT listen port"), port: dhtListenPort)
        }
        guard Self.validED2KListenPortRange.contains(ed2kListenPort) else {
            throw EngineError.invalidNumericSetting(
                label: String(localized: "ED2K listen port"),
                value: ed2kListenPort,
                range: Self.validED2KListenPortRange
            )
        }
        guard Self.validED2KListenPortRange.contains(ed2kUDPListenPort) else {
            throw EngineError.invalidNumericSetting(
                label: String(localized: "ED2K UDP listen port"),
                value: ed2kUDPListenPort,
                range: Self.validED2KListenPortRange
            )
        }
        guard (1...100).contains(ed2kUploadSlots) else {
            throw EngineError.invalidNumericSetting(label: String(localized: "ED2K upload slots"), value: ed2kUploadSlots, range: 1...100)
        }
        guard (10...600).contains(ed2kSearchTimeoutSeconds) else {
            throw EngineError.invalidNumericSetting(label: String(localized: "ED2K search timeout"), value: ed2kSearchTimeoutSeconds, range: 10...600)
        }
        guard hasDownloadDirectoryAccess else {
            throw EngineError.missingDownloadDirectory
        }
    }

    func engineOptions(downloadDirectoryPath: String? = nil, includeStartupOnly: Bool) -> [String: String] {
        var options: [String: String] = [
            "dir": downloadDirectoryPath ?? self.downloadDirectoryPath ?? "",
            "continue": "true",
            "content-disposition-default-utf8": "true",
            "max-concurrent-downloads": "\(maxActiveDownloads)",
            "max-connection-per-server": "\(maxConnectionsPerTask)",
            "split": "\(splitCount)",
            "max-overall-download-limit": speedLimit(maxOverallDownloadLimitKB),
            "max-overall-upload-limit": speedLimit(maxOverallUploadLimitKB),
            "max-tries": "\(retryCount)",
            "retry-wait": "\(retryWaitSeconds)",
            "connect-timeout": "\(connectTimeoutSeconds)",
            "timeout": "\(timeoutSeconds)",
            "file-allocation": fileAllocation.rawValue,
            "async-dns": asyncDNS.description,
            "user-agent": userAgent,
            "seed-ratio": keepSharing ? "0" : "\(shareRatio)",
            "pause-metadata": pauseMetadata.description,
            "bt-tracker": TrackerText.reducedCommaSeparated(from: btTracker)
        ]
        if !keepSharing {
            options["seed-time"] = "\(shareTimeMinutes)"
        }
        if !proxyURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            options["all-proxy"] = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !proxyBypass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            options["no-proxy"] = proxyBypass.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if includeStartupOnly {
            options["rpc-listen-port"] = "\(rpcPort)"
            options["rpc-secret"] = rpcToken
            options["listen-port"] = "\(listenPort)"
            options["dht-listen-port"] = "\(dhtListenPort)"
            options["ed2k-listen-port"] = "\(ed2kListenPort)"
            options["ed2k-udp-listen-port"] = "\(ed2kUDPListenPort)"
            options["ed2k-upload-slots"] = "\(ed2kUploadSlots)"
            options["ed2k-server"] = ED2KServerText.commaSeparated(from: ed2kServer)
            options["bt-max-peers"] = "\(btMaxPeers)"
            options["enable-dht"] = btDHTEnabled.description
            options["enable-peer-exchange"] = btPeerExchangeEnabled.description
            options["bt-enable-lpd"] = btLocalPeerDiscoveryEnabled.description
            options["bt-force-encryption"] = btForceEncryption.description
            options["bt-require-crypto"] = btForceEncryption.description
            options["check-certificate"] = "true"
            if let caCertificatePath = Self.defaultCACertificatePath {
                options["ca-certificate"] = caCertificatePath
            }
        }
        return options.filter { !$0.value.isEmpty }
    }

    func hotReloadableEngineOptions(downloadDirectoryPath: String? = nil) -> [String: String] {
        engineOptions(downloadDirectoryPath: downloadDirectoryPath, includeStartupOnly: false)
    }

    private func speedLimit(_ kilobytesPerSecond: Int) -> String {
        kilobytesPerSecond > 0 ? "\(kilobytesPerSecond)K" : "0"
    }
}

nonisolated struct AppPreferences: Equatable, Sendable {
    var launchAtLogin = false
    var showMenuBar = true
    var notifyOnDownloadCompletion = false
    var bandwidthSchedule = BandwidthSchedule()
    var browserCaptureEnabled = false
    var browserCaptureToken = ""
    var keepRunningAfterClose = true
    var autoRevealCompletedFile = true
    var askBeforeOverwrite = true
    var autoOrganizeFiles = false
    var preventSleepDuringActiveDownloads = false
    var handleMagnetLinks = true
    var handleED2KLinks = true
    var handleTorrentFiles = true
    var handleMetalinkFiles = true
    var captureAskBeforeSending = true
    var captureMinimumSizeMB = 20
    var captureForwardCookies = true
    var captureIgnoreImagesAndFonts = true
    var suppressRemoveConfirmation = false
    var deleteFilesWhenSkippingRemoveConfirmation = false
}

nonisolated enum DownloadTaskTrashPath {
    static func isReportedUserContentPath(_ path: String) -> Bool {
        let trimmed = path.trimmedForEngine
        guard !trimmed.isEmpty, trimmed != "/", trimmed != "." else { return false }
        return trimmed.hasPrefix("/")
    }
}

nonisolated enum FileCategoryRules {
    private static let templates: [(extensions: Set<String>, subdirectory: String)] = [
        (["mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "ts", "m4v", "rmvb"], "Videos"),
        (["mp3", "flac", "aac", "ogg", "wav", "wma", "m4a", "opus", "ape"], "Music"),
        (["jpg", "jpeg", "png", "gif", "bmp", "svg", "webp", "ico", "tiff", "psd", "raw"], "Images"),
        (["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "epub", "md", "rtf"], "Documents"),
        (["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso", "zst"], "Archives"),
        (["exe", "msi", "deb", "rpm", "appimage", "pkg", "apk", "snap"], "Programs")
    ]

    static func directory(for resource: String, baseDirectory: String) -> String? {
        guard let ext = extensionName(from: resource) else { return nil }
        guard let template = templates.first(where: { $0.extensions.contains(ext) }) else { return nil }
        return URL(fileURLWithPath: baseDirectory)
            .appendingPathComponent(template.subdirectory, isDirectory: true)
            .path
    }

    private static func extensionName(from resource: String) -> String? {
        if resource.lowercased().hasPrefix("magnet:") { return nil }
        let path: String
        if let url = URL(string: resource), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            path = components.path
        } else {
            path = resource.components(separatedBy: "?").first?.components(separatedBy: "#").first ?? resource
        }
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
}

nonisolated extension String {
    var trimmedForEngine: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nonEmptyValue: String? {
        isEmpty ? nil : self
    }
}

nonisolated enum ByteFormat {
    static func size(_ bytes: Int64) -> String {
        let clampedBytes = max(0, bytes)
        guard clampedBytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: clampedBytes, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Int64) -> String {
        "\(size(bytesPerSecond))/s"
    }

    static func duration(_ seconds: Int) -> String {
        let clampedSeconds = max(0, seconds)
        if clampedSeconds < 60 {
            return String(localized: "\(clampedSeconds)s")
        }

        let minutes = clampedSeconds / 60
        let remainingSeconds = clampedSeconds % 60
        if minutes < 60 {
            return String(localized: "\(minutes)m \(remainingSeconds)s")
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return String(localized: "\(hours)h \(remainingMinutes)m")
    }
}
