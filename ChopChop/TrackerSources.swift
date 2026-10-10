import Foundation

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
