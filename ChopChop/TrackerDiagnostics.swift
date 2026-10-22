import CryptoKit
import Foundation
import Network
import Observation

nonisolated struct TrackerSourceSnapshot: Codable, Equatable, Sendable {
    var urls: [String]
    var lastSuccess: Date
}
nonisolated struct TrackerHealthObservation: Codable, Equatable, Sendable {
    var reachable: Bool
    var latency: Double?
    var checkedAt: Date
    var route: String
    var consecutiveFailures: Int
    var samples: [Bool]? = nil
}

/// Public-list curation only. These observations never claim announce success.
@MainActor @Observable
final class TrackerDiagnostics {
    struct Saved: Codable {
        var sources: [String: TrackerSourceSnapshot] = [:]
        var health: [String: TrackerHealthObservation] = [:]
        var managed: [String] = []
        var excluded: [String] = []
        var selection: [String]? = nil
    }
    private var saved = Saved()
    private let file: URL?
    private var monitor: NWPathMonitor?
    private var networkGeneration = UUID().uuidString
    private var probeGeneration = UUID()
    private(set) var isProbing = false
    private(set) var issue: String?
    var sources: [String: TrackerSourceSnapshot] { saved.sources }
    var health: [String: TrackerHealthObservation] { saved.health }
    var managed: [String] { saved.managed }
    var selected: [String] { saved.selection ?? saved.managed }
    var candidates: [String] {
        let selected = Set(self.selected)
        return Set(saved.sources.values.flatMap(\.urls)).sorted {
            if selected.contains($0) != selected.contains($1) { return selected.contains($0) }
            return $0 < $1
        }
    }
    func resetExclusions() { saved.excluded = []; persist() }

    init(file: URL? = nil, monitorNetwork: Bool = false) {
        self.file = file
        if let file, FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                guard data.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                saved = try JSONDecoder().decode(Saved.self, from: data)
            } catch { issue = String(localized: "Tracker diagnostics cache could not be read.") }
        }
        if monitorNetwork {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in
                Task { @MainActor [weak self] in self?.networkGeneration = UUID().uuidString }
            }
            monitor.start(queue: DispatchQueue(label: "tracker-network-observation"))
            self.monitor = monitor
        }
    }
    isolated deinit { monitor?.cancel() }

    func curate(_ result: TrackerSourceFetchResult, sourceURLs: [String], current: String, proxy: String, now: Date = Date()) -> String {
        let perSourceLimit = min(512, 2048 / max(1, sourceURLs.prefix(32).count))
        for (source, text) in result.successfulSources where sourceURLs.prefix(32).contains(source) {
            saved.sources[source] = TrackerSourceSnapshot(urls: Array(TrackerText.trackers(from: text).filter { $0.utf8.count <= 1024 && TrackerURLValidator.isValid($0) }.prefix(perSourceLimit)), lastSuccess: now)
        }
        saved.sources = saved.sources.filter { sourceURLs.prefix(32).contains($0.key) && now.timeIntervalSince($0.value.lastSuccess) < 7 * 86400 }
        let route = routeKey(proxy)
        let candidates = Set(saved.sources.values.flatMap(\.urls))
        let previousManaged = Set(saved.managed)
        let previousSelected = Set(saved.selection ?? saved.managed)
        let currentURLs = Set(TrackerText.trackers(from: current))
        saved.excluded = Array(Set(saved.excluded).union(previousSelected.subtracting(currentURLs)).intersection(candidates)).sorted()
        let excluded = Set(saved.excluded)
        let manual = TrackerText.trackers(from: current).filter { !previousManaged.contains($0) }
        let ranked = candidates.filter { !excluded.contains($0) }.sorted { a, b in
            @MainActor func score(_ url: String) -> Double {
                guard let h = saved.health[url], h.route == route, now.timeIntervalSince(h.checkedAt) < 1800 else { return previousSelected.contains(url) ? 0.1 : 0 }
                let samples = h.samples ?? [h.reachable]
                let successRate = Double(samples.filter { $0 }.count) / Double(max(1, samples.count))
                return successRate * 10 + (h.reachable ? 1 : -1) - min(5, floor(h.latency ?? 5)) * 0.1 + (previousSelected.contains(url) ? 0.1 : 0)
            }
            let x = score(a), y = score(b)
            return x == y ? a < b : x > y
        }.filter { url in
            guard let h = saved.health[url], h.route == route, now.timeIntervalSince(h.checkedAt) < 1800 else { return true }
            return h.reachable || h.consecutiveFailures < 3
        }
        var selected: [String] = [], hosts = Set<String>()
        let explorers = ranked.filter { url in
            guard let observation = saved.health[url] else { return true }
            return observation.route != route || now.timeIntervalSince(observation.checkedAt) >= 1800
        }.prefix(6)
        for url in explorers {
            if hosts.insert(URLComponents(string: url)?.host ?? url).inserted { selected.append(url) }
        }
        for url in ranked where selected.count < 64 && !selected.contains(url) {
            if hosts.insert(URLComponents(string: url)?.host ?? url).inserted { selected.append(url) }
        }
        for url in ranked where selected.count < 64 && !selected.contains(url) { selected.append(url) }
        saved.selection = selected
        let manualURLs = Set(manual)
        saved.managed = selected.filter { !manualURLs.contains($0) }
        saved.health = saved.health.filter { candidates.contains($0.key) }
        persist()
        // Legacy injected fetchers provide unlabelled chunks. Preserve that test
        // and migration contract until a successful labelled snapshot is available.
        if saved.sources.isEmpty, result.data.isEmpty { return TrackerText.lineSeparated(fromChunks: manual) }
        if saved.sources.isEmpty { return TrackerText.lineSeparated(fromChunks: result.failures.isEmpty ? result.data : [current] + result.data) }
        return TrackerText.lineSeparated(fromChunks: manual + selected)
    }
    func observation(_ url: String, proxy: String, now: Date = Date()) -> TrackerHealthObservation? {
        guard let value = saved.health[url], value.route == routeKey(proxy),
              now.timeIntervalSince(value.checkedAt) >= 0, now.timeIntervalSince(value.checkedAt) < 1800 else { return nil }
        return value
    }
    func selectionReason(_ url: String, proxy: String, now: Date = Date()) -> String {
        if saved.excluded.contains(url) { return String(localized: "Excluded by your tracker list edits") }
        if let h = saved.health[url], h.route == routeKey(proxy), now.timeIntervalSince(h.checkedAt) < 1800 {
            if !h.reachable, h.consecutiveFailures >= 3 { return String(localized: "Cooling down after repeated connection failures") }
            if h.reachable { return String(localized: "Connection reachable; announce not verified") }
            return String(localized: "Connection attempt failed; retained for another attempt")
        }
        return selected.contains(url) ? String(localized: "Selected without a recent connection observation") : String(localized: "Not selected: tracker capacity or host diversity")
    }
    func probe(urls: [String], proxy: String, measure: @escaping @Sendable (String, String) async -> Double? = TrackerProbe.measure) async {
        guard !isProbing else { return }
        isProbing = true
        let generation = UUID(); probeGeneration = generation
        let route = routeKey(proxy)
        defer { if probeGeneration == generation { isProbing = false } }
        if !proxy.isEmpty {
            guard let configured = URLComponents(string: proxy), configured.scheme == "http", configured.host != nil,
                  configured.user == nil, configured.password == nil else {
                issue = String(localized: "Connection tests cannot use this proxy configuration; no direct connection was attempted.")
                return
            }
        }
        let selected = Array(TrackerText.trackers(from: urls.joined(separator: "\n")).prefix(64))
        for batchStart in stride(from: 0, to: selected.count, by: 8) {
            guard !Task.isCancelled, route == routeKey(proxy), probeGeneration == generation else { return }
            let batch = Array(selected[batchStart..<min(batchStart + 8, selected.count)])
            let results = await withTaskGroup(of: (String, Double?).self) { group in
                for url in batch { group.addTask { (url, await measure(url, proxy)) } }
                var results: [(String, Double?)] = []
                for await result in group { results.append(result) }
                return results
            }
            guard !Task.isCancelled, route == routeKey(proxy), probeGeneration == generation else { return }
            for (url, measuredLatency) in results {
                let latency = measuredLatency.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                // A configured HTTP proxy cannot carry UDP. Leave it unmeasured.
                if url.hasPrefix("udp:"), !proxy.isEmpty { continue }
                let previous = observation(url, proxy: proxy)
                let samples = Array(((previous?.samples ?? []) + [latency != nil]).suffix(16))
                saved.health[url] = TrackerHealthObservation(reachable: latency != nil, latency: latency,
                    checkedAt: Date(), route: route,
                    consecutiveFailures: latency == nil ? min(99, ((previous?.route == route && Date().timeIntervalSince(previous?.checkedAt ?? .distantPast) < 1800 ? previous?.consecutiveFailures : nil) ?? 0) + 1) : 0, samples: samples)
            }
        }
        persist()
    }
    private func routeKey(_ proxy: String) -> String {
        SHA256.hash(data: Data((networkGeneration + proxy).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func persist() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: file, options: .atomic)
            issue = nil
        } catch { issue = String(localized: "Tracker diagnostics cache could not be saved.") }
    }
}

nonisolated enum TrackerProbe {
    @concurrent static func measure(_ value: String, proxy: String) async -> Double? {
        guard let url = URL(string: value), let scheme = url.scheme else { return nil }
        if scheme == "udp" {
            guard proxy.isEmpty else { return nil }
            return await TrackerUDPProbe().measure(url)
        }
        guard ["http", "https"].contains(scheme) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        if !proxy.isEmpty {
            guard let p = URLComponents(string: proxy), p.scheme == "http", let host = p.host,
                  p.user == nil, p.password == nil else { return nil }
            config.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": p.port ?? 8080,
                                               "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": p.port ?? 8080]
        }
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = "HEAD"
        let started = ContinuousClock.now
        do {
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode < 500 else { return nil }
            return Double(started.duration(to: .now).components.attoseconds) / 1e18 + Double(started.duration(to: .now).components.seconds)
        } catch { return nil }
    }
}

private nonisolated final class TrackerUDPProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Double?, Never>?
    private var connection: NWConnection?
    private var timeout: Task<Void, Never>?
    private var cancelled = false
    private let transaction = UInt32.random(in: 0...UInt32.max)
    private let started = ContinuousClock.now
    func measure(_ url: URL) async -> Double? {
        guard let host = url.host, let port = url.port, (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(returning: nil); return }
                self.continuation = continuation
                let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
                self.connection = connection
                self.timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.finish(nil)
                }
                lock.unlock()
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let self, let connection else { return }
                    switch state {
                    case .ready:
                        var bytes: [UInt8] = [0, 0, 4, 23, 39, 16, 25, 128, 0, 0, 0, 0]
                        bytes += [UInt8(truncatingIfNeeded: self.transaction >> 24), UInt8(truncatingIfNeeded: self.transaction >> 16), UInt8(truncatingIfNeeded: self.transaction >> 8), UInt8(truncatingIfNeeded: self.transaction)]
                        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in if error != nil { self?.finish(nil) } })
                        connection.receiveMessage { [weak self] data, _, _, error in
                            guard let self else { return }
                            guard error == nil, let data, data.count == 16 else { self.finish(nil); return }
                            let bytes = [UInt8](data)
                            let transaction = bytes[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                            guard bytes[0..<4].allSatisfy({ $0 == 0 }), transaction == self.transaction else { self.finish(nil); return }
                            let duration = self.started.duration(to: .now).components
                            self.finish(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                        }
                    case .failed, .cancelled: self.finish(nil)
                    default: break
                    }
                }
                connection.start(queue: DispatchQueue.global(qos: .utility))
            }
        } onCancel: { self.finish(nil) }
    }
    private func finish(_ value: Double?) {
        lock.lock(); cancelled = true
        let continuation = self.continuation; self.continuation = nil
        let connection = self.connection; self.connection = nil
        let timeout = self.timeout; self.timeout = nil
        lock.unlock()
        timeout?.cancel(); connection?.cancel(); continuation?.resume(returning: value)
    }
}
