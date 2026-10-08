import SwiftUI

struct TaskSummaryView: View {
    @EnvironmentObject private var store: DownloadStore
    let task: DownloadTask
    let showDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.rowSpacing) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow(alignment: .firstTextBaseline) {
                    Text(String(localized: "Save location")).foregroundStyle(.secondary)
                    Text(DownloadLocationDisplay.taskPath(task))
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        .help(DownloadLocationDisplay.taskURL(task)?.path ?? task.destination)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text(task.protocolKind.rawValue).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Text(String(localized: "\(task.connections) connections"))
                        if task.isTorrentLike {
                            Label(ByteFormat.speed(task.status == .active ? task.uploadSpeed : 0), systemImage: "arrow.up")
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(String(localized: "Upload speed"))
                                .accessibilityValue(ByteFormat.speed(task.status == .active ? task.uploadSpeed : 0))
                        }
                    }.foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityElement(children: .contain)
                }
            }
            if task.isAvailableInEngine, task.primaryControlAction != nil, store.canStopEngine, !store.isUpdatingEngine {
                TaskBandwidthView(task: task).id(task.id)
            }
            HStack(spacing: 8) {
                Button(String(localized: "Show in Finder"), systemImage: "folder") { store.showInFinder(task) }
                    .disabled(DownloadFileLocation.revealURL(for: task) == nil)
                Button(String(localized: "Show Details…"), systemImage: "info.circle", action: showDetails)
                    .help(String(localized: "Show task details (Space)"))
            }
        }
        .font(.callout).controlSize(.small).buttonStyle(.bordered)
        // The native outline supplies one indentation level. Add only the
        // remaining icon-column space, instead of indenting the entire block twice.
        .padding(.leading, 16).padding(.vertical, AppLayout.controlSpacing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-summary-\(task.id)")
    }
}

nonisolated struct TaskBandwidthLimits: Equatable {
    var downloadKiB: Int
    var uploadKiB: Int?

    init(options: [String: String], isTorrent: Bool) throws {
        let upload = isTorrent ? TransferRateLimit.bytes(options["max-upload-limit"]) : nil
        guard let download = TransferRateLimit.bytes(options["max-download-limit"]),
              !isTorrent || upload != nil else {
            throw DownloadOperationError(String(localized: "The engine did not report this task’s speed limits."))
        }
        downloadKiB = Int((Double(download) / 1024).rounded(.up))
        uploadKiB = upload.map { Int((Double($0) / 1024).rounded(.up)) }
    }

    func engineOptions() throws -> [String: String] {
        let values = [downloadKiB] + (uploadKiB.map { [$0] } ?? [])
        guard values.allSatisfy({ (0...Int(Int32.max)).contains($0) }) else {
            throw DownloadOperationError(String(localized: "Enter a valid speed limit of zero or more KiB/s."))
        }
        var options = ["max-download-limit": "\(downloadKiB)K"]
        if let uploadKiB { options["max-upload-limit"] = "\(uploadKiB)K" }
        return options
    }
}

struct TaskBandwidthView: View {
    @EnvironmentObject private var store: DownloadStore
    let task: DownloadTask
    @State private var limits: TaskBandwidthLimits?
    @State private var original: TaskBandwidthLimits?
    @State private var busy = false
    @State private var issue: String?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let limits {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) { fields(limits); applyButton }
                    VStack(alignment: .leading, spacing: 8) { fields(limits); applyButton }
                }
                .disabled(busy || store.isUpdatingEngine || task.primaryControlAction == nil)
                Text(String(localized: "KiB/s · 0 removes the task limit; global limits still apply."))
                    .font(.caption).foregroundStyle(.secondary)
                if saved {
                    Label(String(localized: "Speed limits saved"), systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if busy {
                ProgressView(String(localized: "Loading speed limits…")).controlSize(.small)
            }
            if let issue {
                Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                if limits == nil { Button(String(localized: "Retry")) { Task { await load() } } }
            }
        }
        .nativeTextFieldStyle()
        .task(id: task.id) { await load() }
    }

    @ViewBuilder
    private func fields(_ values: TaskBandwidthLimits) -> some View {
        HStack {
            Text(String(localized: "Download limit"))
            TextField(String(localized: "Download limit (KiB/s)"), value: Binding(
                get: { limits?.downloadKiB ?? values.downloadKiB },
                set: { limits?.downloadKiB = $0; saved = false }), format: .number.grouping(.never))
                .labelsHidden().frame(width: 88)
        }
        if let upload = values.uploadKiB {
            HStack {
                Text(String(localized: "Upload limit"))
                TextField(String(localized: "Task upload limit (KiB/s)"), value: Binding(
                    get: { limits?.uploadKiB ?? upload },
                    set: { limits?.uploadKiB = $0; saved = false }), format: .number.grouping(.never))
                    .labelsHidden().frame(width: 88)
            }
        }
    }

    private var applyButton: some View {
        Button(String(localized: "Apply")) {
            guard let limits else { return }
            busy = true; issue = nil; saved = false
            Task {
                defer { busy = false }
                do {
                    try await store.setTaskBandwidthLimits(task, limits: limits)
                    original = limits; saved = true
                } catch { issue = DownloadPrivacy.redact(error.localizedDescription) }
            }
        }.disabled(busy || limits == original)
    }

    private func load() async {
        busy = true; issue = nil
        defer { busy = false }
        do {
            let values = try await store.transferClient(for: task.id).getOption(task.id)
            try Task.checkCancellation()
            let loaded = try TaskBandwidthLimits(options: values, isTorrent: task.isTorrentLike)
            limits = loaded; original = loaded
        } catch is CancellationError { }
        catch { if !Task.isCancelled { issue = DownloadPrivacy.redact(error.localizedDescription) } }
    }
}
