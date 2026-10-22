import Foundation
import CryptoKit

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

nonisolated enum TrackerSyncSchedule {
    static func nextDate(settings: EngineSettings, now: Date, force: Bool, retryAfter: Date?) -> Date? {
        guard settings.btTrackerAutoSync, !settings.trackerSourceURLs.isEmpty else { return nil }
        if let retryAfter { return max(now, retryAfter) }
        if force { return now }
        guard settings.btTrackerSyncIntervalHours > 0 else { return nil }
        return max(now, settings.lastTrackerSyncAt?.addingTimeInterval(Double(settings.btTrackerSyncIntervalHours) * 3_600) ?? now)
    }
}

nonisolated struct TorrentTrackerAddress: Equatable, Sendable {
    var url: String
    var tier: Int

    static func merging(_ current: [BitTorrentTrackerStatus], additional: [String]) -> [Self] {
        var seen = Set<String>()
        var result = current.compactMap { entry -> Self? in
            guard seen.insert(entry.url).inserted else { return nil }
            return Self(url: entry.url, tier: min(255, max(0, Int(entry.tier ?? "0") ?? 0)))
        }
        var tier = min(255, (result.map(\.tier).max() ?? -1) + 1)
        for url in additional where seen.insert(url).inserted {
            result.append(Self(url: url, tier: tier))
            tier = min(255, tier + 1)
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
    var successfulSources: [String: String] = [:]
}

nonisolated protocol BitTorrentTrackerSourceFetching: Sendable {
    func fetchTrackerSources(_ urls: [String]) async -> TrackerSourceFetchResult
}

nonisolated struct URLSessionBitTorrentTrackerSourceFetcher: BitTorrentTrackerSourceFetching {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()
    @concurrent
    func fetchTrackerSources(_ urls: [String]) async -> TrackerSourceFetchResult {
        var data: [String] = []
        var failures: [TrackerSourceFetchFailure] = []
        var successfulSources: [String: String] = [:]

        for urlString in urls {
            guard !Task.isCancelled else { break }
            guard let url = URL(string: urlString) else {
                failures.append(TrackerSourceFetchFailure(url: urlString, reason: String(localized: "Invalid URL.")))
                continue
            }
            do {
                let (bytes, response) = try await Self.session.bytes(from: url)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    failures.append(
                        TrackerSourceFetchFailure(
                            url: urlString,
                            reason: String(localized: "HTTP \(httpResponse.statusCode).")
                        )
                    )
                    bytes.task.cancel()
                    continue
                }
                var body = Data()
                for try await byte in bytes {
                    guard body.count < 2 * 1024 * 1024 else {
                        bytes.task.cancel()
                        throw DownloadOperationError(String(localized: "Tracker source exceeds the 2 MiB limit."))
                    }
                    body.append(byte)
                }
                guard let text = String(data: body, encoding: .utf8) else {
                    failures.append(TrackerSourceFetchFailure(url: urlString, reason: String(localized: "Response is not valid UTF-8.")))
                    continue
                }
                guard TrackerText.trackers(from: text).contains(where: TrackerURLValidator.isValid) else {
                    failures.append(TrackerSourceFetchFailure(url: urlString, reason: String(localized: "No trackers found.")))
                    continue
                }
                data.append(text)
                successfulSources[urlString] = text
            } catch {
                failures.append(TrackerSourceFetchFailure(url: urlString, reason: error.localizedDescription))
            }
        }

        return TrackerSourceFetchResult(data: data, failures: failures, successfulSources: successfulSources)
    }
}

/// Only addresses positively added by this app may be retired later. Binding to
/// the torrent hash prevents a reused engine ID from inheriting another task's list.
nonisolated struct PublicTrackerOwnership: Codable, Hashable, Sendable {
    var infoHash: String
    var urlFingerprints: [String]
}

nonisolated enum PublicTrackerPolicy {
    static func fingerprint(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func replacement(current: [BitTorrentTrackerStatus], selected: [String],
                            previous: PublicTrackerOwnership?, infoHash: String?) -> (trackers: [TorrentTrackerAddress], ownership: PublicTrackerOwnership?) {
        let hash = infoHash.flatMap { $0.isEmpty ? nil : $0 }
        let owned = hash != nil && previous?.infoHash == hash ? Set(previous?.urlFingerprints ?? []) : []
        let protected = current.filter { !owned.contains(fingerprint($0.url)) }
        let protectedURLs = Set(protected.map(\.url))
        let desired = TrackerText.trackers(from: selected.joined(separator: "\n"))
        let trackers = TorrentTrackerAddress.merging(protected, additional: desired)
        let ownership = hash.map { PublicTrackerOwnership(infoHash: $0, urlFingerprints: desired.filter { !protectedURLs.contains($0) }.map(fingerprint)) }
        return (trackers, ownership)
    }
}
