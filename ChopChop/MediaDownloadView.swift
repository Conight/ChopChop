import SwiftUI

struct MediaDownloadOptionsView: View {
    @EnvironmentObject private var store: DownloadStore
    @ObservedObject var coordinator: MediaDownloadCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if coordinator.phase == .inspecting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Inspecting available tracks…"))
                }
                Text(String(localized: "Reading the media manifest. Video and audio will download after you confirm your selection."))
                    .font(.callout).foregroundStyle(.secondary)
            } else if let media = coordinator.snapshot, coordinator.phase == .ready {
                Label(media.live == "true" ? String(localized: "Live stream") : String(localized: "Video and audio"), systemImage: media.live == "true" ? "dot.radiowaves.left.and.right" : "film")
                    .font(.headline)
                if media.live != "true", let milliseconds = Int64(media.duration ?? ""), milliseconds > 0 {
                    Text(String(localized: "Duration: \(ByteFormat.duration(Int(milliseconds / 1000)))"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                selectionControls(media)
            } else if store.engineCapabilities?.supportsMedia == true && store.addDraft.isHTTPSource {
                Picker(String(localized: "Download as"), selection: $store.addDraft.media.mode) {
                    ForEach(MediaSourceMode.allCases) { Text($0.title).tag($0) }
                }
                if store.addDraft.shouldInspectMedia {
                    Text(String(localized: "Inspect this source to choose video quality, audio, subtitles, and output format."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = coordinator.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func selectionControls(_ media: MediaTaskProgress) -> some View {
        let tracks = media.tracks ?? []
        trackPicker(String(localized: "Video"), selection: $coordinator.selection.video, tracks: tracks.filter { ["video", "muxed"].contains($0.type) })
            .onChange(of: coordinator.selection.video) { _, id in
                if tracks.contains(where: { $0.id == id && $0.type == "muxed" }) {
                    coordinator.selection.audio = id
                } else if tracks.contains(where: { $0.id == coordinator.selection.audio && $0.type == "muxed" }), id != "none" {
                    coordinator.selection.audio = tracks.first { $0.type == "audio" }?.id ?? "none"
                }
            }
        let videoIsMuxed = tracks.contains { $0.id == coordinator.selection.video && $0.type == "muxed" }
        let audioTracks = tracks.filter { videoIsMuxed ? $0.id == coordinator.selection.video : ($0.type == "audio" || ($0.type == "muxed" && coordinator.selection.video == "none")) }
        trackPicker(String(localized: "Audio"), selection: $coordinator.selection.audio, tracks: audioTracks)
        trackPicker(String(localized: "Subtitles"), selection: $coordinator.selection.subtitles, tracks: tracks.filter { $0.type == "subtitle" })
        Picker(String(localized: "Save as"), selection: $coordinator.selection.format) {
            Text("MP4").tag("mp4")
            Text("MKV").tag("mkv")
        }
        if media.live == "true" {
            LabeledContent(String(localized: "Record for")) {
                TextField(String(localized: "Seconds"), value: $coordinator.selection.recordSeconds, format: .number.grouping(.never))
                    .nativeTextFieldStyle().frame(width: 100)
                Text("seconds").foregroundStyle(.secondary)
            }
            Text(String(localized: "Use 0 to record until you choose Finish Recording. Pausing keeps the task for later."))
                .font(.callout).foregroundStyle(.secondary)
        } else {
            DisclosureGroup(String(localized: "Time Range")) {
                VStack(spacing: 10) {
                    LabeledContent(String(localized: "Start (seconds)")) {
                        TextField(String(localized: "Start"), value: $coordinator.selection.startSeconds, format: .number.grouping(.never))
                            .nativeTextFieldStyle().frame(width: 100)
                    }
                    LabeledContent(String(localized: "End (seconds)")) {
                        TextField(String(localized: "End"), value: $coordinator.selection.endSeconds, format: .number.grouping(.never))
                            .nativeTextFieldStyle().frame(width: 100)
                    }
                    Text(String(localized: "Use 0 for the beginning or end of the source. Boundaries follow media segments, so the result may differ slightly from these times."))
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(6)
            }
        }
        Text(String(localized: "Tracks are saved without transcoding. Choose MKV if the selected codecs or subtitles are incompatible with MP4."))
            .font(.callout).foregroundStyle(.secondary)
    }

    private func trackPicker(_ title: String, selection: Binding<String>, tracks: [MediaTrack]) -> some View {
        Picker(title, selection: selection) {
            Text(String(localized: "None")).tag("none")
            if !tracks.isEmpty { Text(String(localized: "Best available")).tag("best") }
            ForEach(tracks) { track in Text(track.title).tag(track.id) }
        }
    }
}

struct MediaTaskActions: View {
    @EnvironmentObject private var store: DownloadStore
    var task: DownloadTask

    var body: some View {
        if task.media != nil {
            VStack(alignment: .leading, spacing: 8) {
                if task.canFinishRecording {
                    Button(String(localized: "Finish Recording and Save"), systemImage: "stop.circle") {
                        Task { await store.finishRecording(task) }
                    }
                }
                if task.canRetryMedia {
                    Button(String(localized: "Retry with Saved Progress"), systemImage: "arrow.clockwise") {
                        Task { await store.retryMedia(task) }
                    }
                }
                if let message = task.media?.actionableError, task.status == .failed {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            .disabled(store.isUpdatingEngine)
        }
    }
}
