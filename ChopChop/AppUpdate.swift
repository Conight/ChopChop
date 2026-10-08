import Combine
import Foundation

/// App releases include prerelease identifiers; engine versions deliberately remain separate.
nonisolated struct AppVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ input: String) {
        let text = input.hasPrefix("v") ? String(input.dropFirst()) : input
        let build = text.split(separator: "+", omittingEmptySubsequences: false)
        guard build.count <= 2 else { return nil }
        func validIdentifiers(_ value: Substring) -> Bool {
            value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
            }
        }
        if build.count == 2 && !validIdentifiers(build[1]) { return nil }
        let parts = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, numbers.allSatisfy({
            !$0.isEmpty && ($0.count == 1 || $0.first != "0") && $0.utf8.allSatisfy { (48...57).contains($0) }
        }), let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2]) else { return nil }
        let identifiers = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        if parts.count == 2 {
            guard validIdentifiers(parts[1]), identifiers.allSatisfy({
                !$0.allSatisfy(\.isNumber) || $0.count == 1 || $0.first != "0"
            }) else { return nil }
        }
        self.major = major; self.minor = minor; self.patch = patch; prerelease = identifiers
    }

    var description: String { "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: ".")) }
    static func < (lhs: Self, rhs: Self) -> Bool {
        let a = (lhs.major, lhs.minor, lhs.patch), b = (rhs.major, rhs.minor, rhs.patch)
        if a != b { return a < b }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            let an = a.allSatisfy(\.isNumber), bn = b.allSatisfy(\.isNumber)
            if an != bn { return an }
            if an && a.count != b.count { return a.count < b.count }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

nonisolated struct AppBuild: Sendable {
    let version: AppVersion?
    let displayVersion: String
    let buildNumber: String

    init(bundle: Bundle = .main) {
        let tag = bundle.object(forInfoDictionaryKey: "ChopChopReleaseVersion") as? String ?? "development"
        version = AppVersion(tag)
        displayVersion = version?.description ?? ((bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1") + String(localized: " (Development)"))
        buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
    init(version: String, buildNumber: String = "1") {
        self.version = AppVersion(version); displayVersion = version; self.buildNumber = buildNumber
    }
}

nonisolated struct AppRelease: Equatable, Sendable {
    let version: AppVersion
    let notes: String
    var pageURL: URL { URL(string: "https://github.com/Conight/ChopChop/releases/tag/v\(version)")! }
}

nonisolated enum AppUpdateError: Error, Equatable {
    case offline, rateLimited, invalidResponse, noCompatibleRelease, serviceUnavailable
}

nonisolated protocol AppReleaseFetching: Sendable {
    func latest(for current: AppVersion?) async throws -> AppRelease?
}

nonisolated struct GitHubAppReleaseClient: AppReleaseFetching {
    var session: URLSession = .shared
    static let endpoint = URL(string: "https://api.github.com/repos/Conight/ChopChop/releases?per_page=100")!

    func latest(for current: AppVersion?) async throws -> AppRelease? {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ChopChop", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AppUpdateError.offline }
        guard let http = response as? HTTPURLResponse else { throw AppUpdateError.invalidResponse }
        if http.statusCode == 403 || http.statusCode == 429 { throw AppUpdateError.rateLimited }
        guard http.statusCode == 200 else { throw AppUpdateError.serviceUnavailable }
        return try Self.select(data: data, current: current)
    }

    static func select(data: Data, current: AppVersion?) throws -> AppRelease? {
        struct Release: Decodable {
            struct Asset: Decodable { var name: String; var state: String; var size: Int64 }
            var tag_name: String
            var draft: Bool
            var prerelease: Bool
            var body: String?
            var assets: [Asset]
        }
        guard data.count <= 8 * 1_024 * 1_024,
              let releases = try? JSONDecoder().decode([Release].self, from: data) else { throw AppUpdateError.invalidResponse }
        let candidates = releases.compactMap { item -> (AppVersion, Release)? in
            guard !item.draft, let version = AppVersion(item.tag_name), item.tag_name == "v\(version)" else { return nil }
            if let current, current.prerelease.isEmpty && (item.prerelease || !version.prerelease.isEmpty) { return nil }
            if let current, version <= current { return nil }
            return (version, item)
        }.sorted { $0.0 > $1.0 }
        for (version, item) in candidates {
            guard item.assets.contains(where: { $0.name == "ChopChop-v\(version)-macos-arm64.dmg" && $0.state == "uploaded" && $0.size > 0 }) else { continue }
            return AppRelease(version: version, notes: String((item.body ?? "").prefix(30_000)))
        }
        if !candidates.isEmpty { throw AppUpdateError.noCompatibleRelease }
        return nil
    }
}

@MainActor
final class AppUpdateCoordinator: ObservableObject {
    enum State: Equatable { case idle, checking, current, available(AppRelease), failed(AppUpdateError) }
    @Published private(set) var state: State = .idle
    @Published var automaticallyChecks: Bool { didSet { defaults.set(automaticallyChecks, forKey: Self.automaticKey) } }
    @Published var settingsRequested = false
    let build: AppBuild
    private let client: any AppReleaseFetching
    private let defaults: UserDefaults
    private let now: () -> Date
    private static let automaticKey = "appUpdates.automaticallyChecks"
    private static let lastAttemptKey = "appUpdates.lastAttempt"

    init(build: AppBuild = AppBuild(), client: any AppReleaseFetching = GitHubAppReleaseClient(), defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.build = build; self.client = client; self.defaults = defaults; self.now = now
        automaticallyChecks = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    func check(automatically: Bool = false) async {
        guard state != .checking else { return }
        if automatically {
            guard automaticallyChecks, build.version != nil else { return }
            if let last = defaults.object(forKey: Self.lastAttemptKey) as? Date {
                let elapsed = now().timeIntervalSince(last)
                if elapsed >= 0 && elapsed < 86_400 { return }
            }
        }
        defaults.set(now(), forKey: Self.lastAttemptKey)
        state = .checking
        do {
            state = try await client.latest(for: build.version).map(State.available) ?? .current
        } catch is CancellationError { state = .idle }
        catch { state = .failed(error as? AppUpdateError ?? .serviceUnavailable) }
    }
}
