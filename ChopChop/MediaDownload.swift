import Combine
import Foundation

nonisolated enum MediaSourceMode: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto", file, hls, dash
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .file: String(localized: "Original file")
        case .hls: String(localized: "HLS video or live stream")
        case .dash: String(localized: "DASH video or live stream")
        }
    }
}

nonisolated struct MediaTrack: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var type: String
    var language: String?
    var codec: String?
    var width: String?
    var height: String?
    var bandwidth: String?
    var frameRate: String?
    var selected: String?

    var title: String {
        var parts: [String] = []
        if let height, let value = Int(height), value > 0 { parts.append("\(value)p") }
        if let frameRate, let value = Double(frameRate), value.isFinite, value > 0 {
            parts.append(String(localized: "\(value.formatted(.number.precision(.fractionLength(0...2)))) fps"))
        }
        if let language, !language.isEmpty { parts.append(Locale.current.localizedString(forLanguageCode: language) ?? language) }
        if let codec, !codec.isEmpty { parts.append(codec) }
        if let bandwidth, let value = Int64(bandwidth), value > 0 { parts.append("\(value / 1_000) kbps") }
        return parts.isEmpty ? type.capitalized : parts.joined(separator: " · ")
    }
}

nonisolated struct MediaDownloadOptions: Equatable, Sendable {
    var mode: MediaSourceMode = .automatic
    var format = "mp4"
    var video = "best"
    var audio = "best"
    var subtitles = "none"
    var recordSeconds = 0
    var startSeconds = 0
    var endSeconds = 0

    func engineOptions(probing: Bool = false, live: Bool? = nil, tracks: [MediaTrack]? = nil) throws -> [String: String] {
        guard ["mp4", "mkv"].contains(format),
              (0...Int(Int32.max)).contains(recordSeconds),
              (0...Int(Int32.max)).contains(startSeconds),
              (0...Int(Int32.max)).contains(endSeconds),
              endSeconds == 0 || endSeconds > startSeconds else {
            throw DownloadOperationError(String(localized: "Use a valid duration and an end time after the start time."))
        }
        if live == true, startSeconds != 0 || endSeconds != 0 {
            throw DownloadOperationError(String(localized: "Time ranges apply to videos. For a live stream, set a recording duration instead."))
        }
        if live == false, recordSeconds != 0 {
            throw DownloadOperationError(String(localized: "Recording duration applies to live streams. Use a time range for this video."))
        }
        guard video != "none" || audio != "none" || subtitles != "none" else {
            throw DownloadOperationError(String(localized: "Select at least one video, audio, or subtitle track."))
        }
        if let tracks {
            for (choice, types) in [(video, ["video", "muxed"]), (audio, ["audio", "muxed"]), (subtitles, ["subtitle"])] {
                guard choice == "best" || choice == "none" || tracks.contains(where: { $0.id == choice && types.contains($0.type) }) else {
                    throw DownloadOperationError(String(localized: "The selected track is no longer available. Inspect the source again."))
                }
            }
            if tracks.contains(where: { $0.id == video && $0.type == "muxed" }),
               audio != "none", audio != "best", audio != video {
                throw DownloadOperationError(String(localized: "This video already includes audio. Choose its included audio or no audio."))
            }
        }
        return ["media": mode.rawValue, "media-format": format, "media-video": video,
                "media-audio": audio, "media-subtitles": subtitles,
                "media-record-time": String(recordSeconds), "media-start-time": String(startSeconds),
                "media-end-time": String(endSeconds), "media-pause-after-probe": probing ? "true" : "false"]
    }

    static func restored(from options: [String: String], media: MediaTaskProgress) -> Self {
        var result = Self()
        result.mode = MediaSourceMode(rawValue: options["media"] ?? "auto") ?? .automatic
        result.format = options["media-format"] ?? "mp4"
        result.video = options["media-video"] ?? "best"
        result.audio = options["media-audio"] ?? "best"
        result.subtitles = options["media-subtitles"] ?? "none"
        result.recordSeconds = Int(options["media-record-time"] ?? "0") ?? 0
        result.startSeconds = Int(options["media-start-time"] ?? "0") ?? 0
        result.endSeconds = Int(options["media-end-time"] ?? "0") ?? 0
        result.useInspectedDefaults(media)
        return result
    }

    mutating func useInspectedDefaults(_ media: MediaTaskProgress) {
        let selected = (media.tracks ?? []).filter { $0.selected == "true" }
        if video == "best" { video = selected.first { ["video", "muxed"].contains($0.type) }?.id ?? "none" }
        if audio == "best" { audio = selected.first { ["audio", "muxed"].contains($0.type) }?.id ?? "none" }
    }
}

nonisolated extension AddDownloadDraft {
    var isHTTPSource: Bool {
        guard resourceLines.count == 1, let source = try? normalizedResources().first,
              let scheme = URL(string: source)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func isMediaManifest(_ resource: String) -> Bool {
        guard let url = URL(string: resource), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return ["m3u8", "mpd"].contains(url.pathExtension.lowercased())
    }

    var shouldInspectMedia: Bool {
        guard isHTTPSource, !treatLinesAsMirrors else { return false }
        return media.mode == .hls || media.mode == .dash ||
            (media.mode == .automatic && resourceLines.contains(where: Self.isMediaManifest))
    }
}

nonisolated extension EngineCapabilities {
    var supportsMedia: Bool {
        enabledFeatures?.contains("HLS/DASH") == true && mediaFeatures?.contains("stable-track-ids") == true
    }
}

nonisolated extension DownloadTask {
    var canFinishRecording: Bool {
        isAvailableInEngine && media?.live == "true" && (status == .active || status == .paused) &&
            ["recording", "paused"].contains(media?.state ?? "") && (Int64(media?.completedDuration ?? "0") ?? 0) > 0
    }
    var canRetryMedia: Bool { isAvailableInEngine && status == .failed && media != nil }
}

@MainActor
final class MediaDownloadCoordinator: ObservableObject {
    enum Phase: Equatable { case idle, inspecting, ready }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var snapshot: MediaTaskProgress?
    @Published private(set) var gid: String?
    @Published private(set) var error: String?
    @Published var selection = MediaDownloadOptions()
    var onAdded: ((String, AddDownloadDraft) -> Void)?
    var onDiscarded: ((String) -> Void)?
    var onSaveError: ((String) -> Void)?
    private var ownsTask = false
    private var generation = UUID()
    var isPresented: Bool { phase != .idle }

    func inspect(_ draft: AddDownloadDraft, using client: Aria2RPCClient, fallbackDirectory: String?, timeout: Duration = .seconds(60)) async {
        guard phase == .idle else { return }
        let request = UUID()
        generation = request
        phase = .inspecting
        error = nil
        selection = draft.media
        ownsTask = true
        do {
            let id = try await client.inspectMedia(draft, fallbackDirectory: fallbackDirectory)
            guard generation == request, !Task.isCancelled else {
                try await discard(id, using: client)
                return
            }
            gid = id
            onAdded?(id, draft)
            try await client.saveSession()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while generation == request, !Task.isCancelled {
                let task = try await client.tellStatus(id).task
                guard generation == request else { return }
                if task.status == .failed { throw DownloadOperationError(task.media?.actionableError ?? task.errorMessage ?? String(localized: "Could not inspect this media source.")) }
                if task.status == .paused, let media = task.media, !(media.tracks ?? []).isEmpty {
                    snapshot = media
                    selection.useInspectedDefaults(media)
                    phase = .ready
                    try await client.saveSession()
                    return
                }
                guard clock.now < deadline else { throw DownloadOperationError(String(localized: "Media inspection timed out. Check the link and authentication, then try again.")) }
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            guard generation == request else { return }
            self.error = DownloadPrivacy.redact(error.localizedDescription)
            // An inspection never transfers payload. Remove its provisional engine record on failure.
            if let gid {
                do { try await discard(gid, using: client) }
                catch { self.error = String(localized: "\(self.error ?? String(localized: "Inspection failed.")) The paused task is still in the list; remove it there if needed.") }
            }
            gid = nil; snapshot = nil; phase = .idle; ownsTask = false
        }
    }

    func clearError() {
        if phase == .idle { error = nil }
    }

    func restore(_ task: DownloadTask, options: [String: String]) {
        guard let media = task.media else { return }
        generation = UUID()
        gid = task.id; snapshot = media; phase = .ready; ownsTask = false; error = nil
        selection = .restored(from: options, media: media)
    }

    func confirm(using client: Aria2RPCClient, startPaused: Bool = false) async -> Bool {
        guard phase == .ready, let gid, let snapshot else { return false }
        let request = generation
        do {
            let options = try selection.engineOptions(live: snapshot.live == "true", tracks: snapshot.tracks ?? [])
            let current = try await client.tellStatus(gid).task
            guard request == generation else { return false }
            guard current.status == .paused else { throw DownloadOperationError(String(localized: "This media task is no longer paused. Refresh its state before continuing.")) }
            try await client.changeOption(gid: gid, options: options)
            guard request == generation else { return false }
            if !startPaused { try await client.resume(gid) }
            guard request == generation else { return false }
            self.gid = nil; self.snapshot = nil; phase = .idle; ownsTask = false; error = nil
            do { try await client.saveSession() } catch { onSaveError?(DownloadPrivacy.redact(error.localizedDescription)) }
            return true
        } catch {
            if request == generation { self.error = DownloadPrivacy.redact(error.localizedDescription) }
            return false
        }
    }

    func cancel(using client: Aria2RPCClient?) async {
        generation = UUID()
        let discardedID = ownsTask ? gid : nil
        gid = nil; snapshot = nil; phase = .idle; ownsTask = false; error = nil
        if let discardedID, let client {
            do { try await discard(discardedID, using: client) }
            catch { onSaveError?(String(localized: "The media inspection task could not be removed. It remains available in the download list.")) }
        }
    }

    private func discard(_ id: String, using client: Aria2RPCClient) async throws {
        do {
            let task = try await client.tellStatus(id).task
            try await DownloadTaskRPCOperations.remove(task, using: client)
        } catch {
            guard case RPCError.serverError(_, let message) = error,
                  message.lowercased().contains("not found") else { throw error }
        }
        onDiscarded?(id)
        try await client.saveSession()
    }
}

nonisolated extension MediaTaskProgress {
    var actionableError: String? {
        switch errorCode {
        case "authentication_required": String(localized: "The source needs authentication. Review Cookie, Authorization, and Referer in Advanced Options.")
        case "protected_media": String(localized: "This source uses DRM or unsupported encryption and cannot be downloaded by this engine.")
        case "unsupported_selection": String(localized: "The selected tracks or output format are incompatible. Try another selection or MKV.")
        case "unsupported_source": String(localized: "This is not a supported media source. Use a direct HLS or DASH manifest URL.")
        case "probe_failed": String(localized: "The media source could not be inspected. Check the link, connection, and authentication.")
        default: error.flatMap { $0.isEmpty ? nil : DownloadPrivacy.redact($0) }
        }
    }
}
