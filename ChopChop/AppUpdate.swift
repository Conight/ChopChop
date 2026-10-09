import AppKit
import Combine
import Foundation

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

nonisolated struct AppRelease: Codable, Equatable, Sendable {
    let version: AppVersion
    let notes: String
    var supportsInstallation = false
    var archiveSize: Int64 = 0
    var archiveSHA256: String?
    var archive: AppUpdateArchive { .init(version: version, size: archiveSize, sha256: archiveSHA256) }
    var pageURL: URL { URL(string: "https://github.com/Conight/ChopChop/releases/tag/v\(version)")! }
}

nonisolated protocol AppReleaseFetching: Sendable {
    func latest(for current: AppVersion?, channel: AppUpdateChannel) async throws -> AppRelease?
}

nonisolated struct GitHubAppReleaseClient: AppReleaseFetching {
    var session: URLSession = .shared
    static let endpoint = URL(string: "https://api.github.com/repos/Conight/ChopChop/releases?per_page=100")!

    func latest(for current: AppVersion?, channel: AppUpdateChannel) async throws -> AppRelease? {
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
        return try Self.select(data: data, current: current, channel: channel)
    }

    static func select(data: Data, current: AppVersion?, channel: AppUpdateChannel? = nil) throws -> AppRelease? {
        struct Release: Decodable {
            struct Asset: Decodable { var name: String; var state: String; var size: Int64; var digest: String? }
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
            if (channel ?? .initial(for: current)) == .stable && (item.prerelease || !version.prerelease.isEmpty) { return nil }
            if let current, version <= current { return nil }
            return (version, item)
        }.sorted { $0.0 > $1.0 }
        for (version, item) in candidates {
            guard let archive = item.assets.first(where: { $0.name == "ChopChop-v\(version)-macos-arm64.dmg" && $0.state == "uploaded" && $0.size > 0 && $0.size <= AppUpdateManifest.maximumSize }) else { continue }
            return AppRelease(version: version, notes: String((item.body ?? "").prefix(30_000)),
                              supportsInstallation: item.assets.contains { $0.name == AppUpdateManifest.manifestName(for: version) && $0.state == "uploaded" && $0.size > 0 && $0.size < 65_536 },
                              archiveSize: archive.size, archiveSHA256: archive.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil })
        }
        if !candidates.isEmpty { throw AppUpdateError.noCompatibleRelease }
        return nil
    }
}

@MainActor
final class AppUpdateCoordinator: ObservableObject {
    enum State: Equatable {
        case idle, checking, current, available(AppRelease), failed(AppUpdateError)
        case preparing(AppRelease, AppUpdateProgress), ready(AppRelease), installing(AppRelease)
        case downloaded(AppRelease, DownloadedAppUpdateArchive)
        case waitingToQuit(AppRelease)
    }
    @Published private(set) var state: State = .idle
    @Published var automaticallyChecks: Bool { didSet { defaults.set(automaticallyChecks, forKey: Self.automaticKey) } }
    @Published private var selectedChannel: AppUpdateChannel
    var channel: AppUpdateChannel {
        get { selectedChannel }
        set {
            guard newValue != selectedChannel, canChangeChannel else { return }
            selectedChannel = newValue
            defaults.set(newValue.rawValue, forKey: Self.channelKey)
            cancel()
            state = .idle; lastRelease = nil
            defaults.removeObject(forKey: Self.lastAttemptKey)
        }
    }
    let build: AppBuild
    let signingConfigured: Bool
    private let client: any AppReleaseFetching
    private let defaults: UserDefaults
    private let now: () -> Date
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var installer: (any AppUpdateInstalling)?
    private let makeInstaller: @MainActor () -> any AppUpdateInstalling
    private let terminateApplication: @MainActor () -> Void
    private let archiveDownloader: any AppUpdateArchiveDownloading
    private let openArchive: @MainActor (URL) -> Bool
    private let recovery: AppUpdateRecoveryStore
    private var restored = false
    private var downloadedArchive: DownloadedAppUpdateArchive?
    private var installationMonitor: Task<Void, Never>?
    private let monitorInterval: Duration
    private var token: String?
    private var lastRelease: AppRelease?
    private static let automaticKey = "appUpdates.automaticallyChecks"
    private static let lastAttemptKey = "appUpdates.lastAttempt"
    private static let channelKey = "appUpdates.channel"

    init(build: AppBuild = AppBuild(), client: any AppReleaseFetching = GitHubAppReleaseClient(),
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         signingConfigured: Bool = Data(base64Encoded: Bundle.main.object(forInfoDictionaryKey: "ChopChopUpdatePublicKey") as? String ?? "")?.count == 32,
         startupInstallationFailed: Bool = ProcessInfo.processInfo.arguments.contains("--chopchop-update-failed"),
         archiveDownloader: any AppUpdateArchiveDownloading = AppUpdateArchiveDownloader(),
         archiveCacheDirectory: URL? = nil,
         monitorInterval: Duration = .seconds(2),
         openArchive: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
         makeInstaller: @escaping @MainActor () -> any AppUpdateInstalling = { AppUpdateInstallerRequest() },
         terminateApplication: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.build = build; self.client = client; self.defaults = defaults; self.now = now
        self.signingConfigured = signingConfigured
        self.archiveDownloader = archiveDownloader; self.openArchive = openArchive
        recovery = AppUpdateRecoveryStore(defaults: defaults, archiveDirectory: archiveCacheDirectory)
        self.monitorInterval = monitorInterval
        self.makeInstaller = makeInstaller; self.terminateApplication = terminateApplication
        if startupInstallationFailed { state = .failed(.installationFailed); restored = true; recovery.clear() }
        automaticallyChecks = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        selectedChannel = defaults.string(forKey: Self.channelKey).flatMap(AppUpdateChannel.init(rawValue:)) ?? .initial(for: build.version)
    }

    var busy: Bool {
        switch state { case .checking, .preparing, .ready, .installing, .waitingToQuit: true; default: false }
    }
    var release: AppRelease? {
        switch state { case .available(let r), .preparing(let r, _), .ready(let r), .installing(let r), .waitingToQuit(let r), .downloaded(let r, _): r; case .failed: lastRelease; default: nil }
    }
    var updateAvailable: Bool { release != nil }
    var installationNeedsAttention: Bool { state == .failed(.installationFailed) }
    var canDownloadInstaller: Bool { !busy && canChangeChannel }
    var canChangeChannel: Bool {
        switch state { case .installing, .waitingToQuit: return false; default: break }
        guard token == nil else { return false }
        return recovery.load(current: build.version, channel: channel).map { $0.archive != nil } ?? true
    }

    deinit {
        operation?.cancel(); installationMonitor?.cancel(); installer?.disconnect()
    }

    func check(automatically: Bool = false) async {
        let needsRestoration = !restored
        await restoreIfNeeded()
        if needsRestoration, state != .idle { return }
        guard !busy, canChangeChannel else { return }
        if case .downloaded = state { return }
        if automatically {
            guard automaticallyChecks, build.version != nil, !installationNeedsAttention else { return }
            if let last = defaults.object(forKey: Self.lastAttemptKey) as? Date {
                let elapsed = now().timeIntervalSince(last)
                if elapsed >= 0 && elapsed < 86_400 { return }
            }
        }
        let request = UUID(); generation = request
        defaults.set(now(), forKey: Self.lastAttemptKey)
        lastRelease = nil
        state = .checking
        do {
            let result = try await client.latest(for: build.version, channel: channel)
            guard generation == request else { return }
            lastRelease = result
            state = result.map(State.available) ?? .current
        } catch {
            guard generation == request else { return }
            state = error is CancellationError ? .idle : .failed(error as? AppUpdateError ?? .serviceUnavailable)
        }
    }

    func download() {
        guard case .available(let release) = state else { return }
        guard signingConfigured && release.supportsInstallation else { downloadInstaller(); return }
        let request = UUID(); generation = request
        let installer = makeInstaller()
        self.installer = installer
        state = .preparing(release, .init(stage: .connecting))
        operation = Task { [self] in
            do {
                let token = try await installer.prepare(version: release.version.description) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == request, case .preparing = self.state else { return }
                        self.state = .preparing(release, progress)
                    }
                }
                guard generation == request else { return }
                self.token = token
                recovery.save(release)
                state = .ready(release)
            } catch {
                guard generation == request else { return }
                installer.cancel(); self.installer = nil
                state = error is CancellationError ? .available(release) : .failed(error as? AppUpdateError ?? .downloadFailed)
            }
        }
    }

    func downloadInstaller() {
        guard canDownloadInstaller, let release else { return }
        let request = UUID(); generation = request
        state = .preparing(release, .init(stage: .connecting))
        operation = Task { [self] in
            do {
                let archive = try await archiveDownloader.download(release.archive) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == request, case .preparing = self.state else { return }
                        self.state = .preparing(release, progress)
                    }
                }
                guard generation == request else { return }
                downloadedArchive = archive
                recovery.save(release, archive: archive)
                state = .downloaded(release, archive)
            } catch {
                guard generation == request else { return }
                state = error is CancellationError ? .available(release) : .failed(error as? AppUpdateError ?? .downloadFailed)
            }
        }
    }

    func openInstaller() {
        guard !busy, let release, let archive = downloadedArchive else { return }
        let request = UUID(); generation = request
        state = .preparing(release, .init(stage: .verifying))
        operation = Task { [self] in
            do {
                try await archive.verify()
                guard generation == request else { return }
                guard openArchive(archive.url) else { state = .failed(.openingInstallerFailed); return }
                state = .waitingToQuit(release)
                terminateApplication()
            } catch {
                guard generation == request else { return }
                downloadedArchive = nil; recovery.clear()
                state = .failed(.invalidSignature)
            }
        }
    }

    func cancel() {
        switch state { case .installing, .waitingToQuit: return; default: break }
        let previous = release
        generation = UUID()
        operation?.cancel(); operation = nil
        installationMonitor?.cancel(); installationMonitor = nil
        installer?.cancel(); installer = nil; token = nil
        downloadedArchive = nil; recovery.clear()
        state = previous.map(State.available) ?? .idle
    }

    func installAndRestart() {
        guard case .ready(let release) = state, let installer, let token else { return }
        state = .installing(release)
        operation = Task { [self] in
            do {
                try await installer.install(token: token)
                state = .waitingToQuit(release)
                monitorInstallation(installer, token: token, release: release)
                // The normal application delegate saves sessions and stops the engine before replying to termination.
                terminateApplication()
            } catch {
                // Retain the verified package and token so a retry does not redownload it.
                state = .failed(error as? AppUpdateError ?? .installationFailed)
            }
        }
    }

    func retryQuit() {
        guard case .waitingToQuit = state else { return }
        terminateApplication()
    }

    func retry() {
        guard case .failed = state, release != nil else { return }
        if downloadedArchive != nil { openInstaller(); return }
        if let pending = recovery.load(current: build.version, channel: channel), pending.archive == nil {
            operation = Task { [self] in
                installer?.disconnect(); installer = nil; token = nil; restored = false
                await restoreIfNeeded()
                if case .ready = state { installAndRestart() }
            }
            return
        }
        cancel(); download()
    }

    private func monitorInstallation(_ installer: any AppUpdateInstalling, token: String, release: AppRelease) {
        installationMonitor?.cancel()
        let request = generation
        let interval = monitorInterval
        installationMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                    let status = try await installer.status(token: token)
                    guard let self, self.generation == request else { return }
                    if status != .waitingForExit {
                        self.state = .failed(status == .terminationTimedOut ? .terminationTimedOut : .installationFailed)
                        return
                    }
                } catch is CancellationError { return }
                catch {
                    // A broken connection cannot prove the detached installer stopped.
                    // Keep waiting for quit; never launch a competing replacement worker.
                    guard let self, self.generation == request else { return }
                    self.state = .waitingToQuit(release)
                }
            }
        }
    }

    func restoreIfNeeded() async {
        guard !restored else { return }
        restored = true
        guard let pending = recovery.load(current: build.version, channel: channel) else { return }
        let request = UUID(); generation = request
        let release = pending.release
        lastRelease = release
        state = .preparing(release, .init(stage: .verifying))
        do {
            if let archive = pending.archive {
                try await archive.verify()
                guard generation == request else { return }
                downloadedArchive = archive
                state = .downloaded(release, archive)
            } else {
                guard signingConfigured else { recovery.clear(); state = .available(release); return }
                let installer = makeInstaller(); self.installer = installer
                let token = try await installer.resume(version: release.version.description)
                guard generation == request else { return }
                if let token { self.token = token; state = .ready(release) }
                else { installer.cancel(); self.installer = nil; recovery.clear(); state = .available(release) }
            }
        } catch {
            guard generation == request else { return }
            self.installer?.cancel(); self.installer = nil
            if error as? AppUpdateError != .installerUnavailable { recovery.clear() }
            state = .failed(error as? AppUpdateError ?? .invalidSignature)
        }
    }
}
