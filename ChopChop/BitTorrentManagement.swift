import SwiftUI

nonisolated enum TorrentFilePriority: String, CaseIterable, Identifiable, Sendable {
    case off, normal, high, top
    var id: String { rawValue }
    var title: String { self == .off ? String(localized: "Skip") : L10n.key(rawValue.capitalized) }
}

nonisolated struct BitTorrentTaskOptions: Equatable, Sendable {
    var priorities: [Int: TorrentFilePriority] = [:]
    var sequential = false
    var previewPieces = false
    var seedRatio = "1"
    var seedMinutes = ""

    init(files: [DownloadFile], options: [String: String]) {
        priorities = Dictionary(files.map { ($0.index, $0.isSelected ? .normal : .off) }, uniquingKeysWith: { a, _ in a })
        for entry in (options["bt-file-priority"] ?? "").split(separator: ",") {
            let parts = entry.split(separator: "=")
            if parts.count == 2, let index = Int(parts[0]), priorities[index] != nil,
               let priority = TorrentFilePriority(rawValue: String(parts[1])) { priorities[index] = priority }
        }
        sequential = options["force-sequential"] == "true"
        previewPieces = options["bt-first-last-piece-first"] == "true"
        seedRatio = options["seed-ratio"] ?? "1"
        seedMinutes = options["seed-time"] ?? ""
    }

    func engineOptions() throws -> [String: String] {
        guard !priorities.isEmpty, priorities.keys.allSatisfy({ $0 > 0 }), priorities.values.contains(where: { $0 != .off }) else {
            throw DownloadOperationError(String(localized: "Select at least one file. Use Pause to stop all transfers."))
        }
        guard let ratio = Double(seedRatio), ratio.isFinite, ratio >= 0 else {
            throw DownloadOperationError(String(localized: "Enter a sharing ratio of zero or more."))
        }
        var result = [
            "select-file": priorities.keys.filter { priorities[$0] != .off }.sorted().map(String.init).joined(separator: ","),
            "bt-file-priority": priorities.keys.sorted().map { "\($0)=\(priorities[$0]!.rawValue)" }.joined(separator: ","),
            "force-sequential": String(sequential),
            "bt-first-last-piece-first": String(previewPieces),
            "seed-ratio": seedRatio
        ]
        if !seedMinutes.isEmpty {
            guard let minutes = Double(seedMinutes), minutes.isFinite, minutes >= 0 else {
                throw DownloadOperationError(String(localized: "Enter a sharing duration of zero or more minutes."))
            }
            result["seed-time"] = seedMinutes
        }
        return result
    }
}

nonisolated struct BitTorrentTrackerStatus: Decodable, Sendable {
    var url: String
    var status: String?
    var failures: String?
    var seeders: String?
    var leechers: String?
    var nextAnnounce: String?
    var message: String?

    var entry: TrackerEntry {
        var parts = [status?.capitalized ?? String(localized: "Unknown")]
        if let count = Int(seeders ?? ""), count >= 0 { parts.append(String(localized: "\(count) seeds")) }
        if let count = Int(failures ?? ""), count > 0 { parts.append(String(localized: "\(count) failures")) }
        if let seconds = Int(nextAnnounce ?? ""), seconds >= 0 { parts.append(String(localized: "Announce in \(seconds)s")) }
        if let message, !message.isEmpty { parts.append(DownloadPrivacy.redact(message)) }
        return TrackerEntry(url: DownloadPrivacy.redact(url), status: parts.joined(separator: " · "), lastAnnounce: nil)
    }
}

nonisolated struct BitTorrentDiagnostics: Codable, Hashable, Sendable {
    var state: String?
    var peers: Int?
    var seeds: Int?
    var availability: Double?
    var connecting: Int?
    var handshaking: Int?
    var seedingSeconds: Int?
    var failedBytes: Int64?
}

nonisolated extension EngineCapabilities {
    var supportsTorrentManagement: Bool {
        enabledFeatures?.contains("BitTorrent") == true && version.compare("2.8.6", options: .numeric) != .orderedAscending
    }
}

struct BitTorrentManagementView: View {
    @EnvironmentObject private var store: DownloadStore
    let task: DownloadTask
    @State private var options: BitTorrentTaskOptions?
    @State private var appliedOptions: BitTorrentTaskOptions?
    @State private var busy = false
    @State private var issue: String?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let options {
                ForEach(task.files) { file in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(URL(fileURLWithPath: file.path).lastPathComponent).lineLimit(2)
                        HStack {
                            Text(ByteFormat.size(file.length)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Picker(String(localized: "Priority"), selection: priorityBinding(file.index)) {
                                ForEach(TorrentFilePriority.allCases) { value in Text(value.title).tag(value) }
                            }.pickerStyle(.menu).labelsHidden().frame(maxWidth: 110)
                        }
                        if (options.priorities[file.index] != .off) != file.isSelected {
                            Label(String(localized: "Selection change not applied"), systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        DownloadFileProgressView(file: file)
                        if file.isCompleteOnDisk {
                            DownloadedFileActions(file: file)
                            FileVerificationView(file: file)
                        }
                    }.contentPanel()
                        .contextMenu {
                            if let url = DownloadFileLocation.existingFile(file.path) {
                                Button(String(localized: "Show in Finder"), systemImage: "folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        }
                }
                Toggle(String(localized: "Download in order"), isOn: optionBinding(\.sequential, fallback: options.sequential))
                Toggle(String(localized: "Prioritize first and last pieces"), isOn: optionBinding(\.previewPieces, fallback: options.previewPieces))
                DisclosureGroup(String(localized: "Sharing Limits")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(String(localized: "Share ratio"), text: optionBinding(\.seedRatio, fallback: options.seedRatio))
                        TextField(String(localized: "Share minutes"), text: optionBinding(\.seedMinutes, fallback: options.seedMinutes))
                        Text(String(localized: "Sharing stops when either limit is reached. Ratio 0 ignores the ratio; minutes 0 stops sharing after completion. Leave minutes empty to keep the engine setting."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
                Button(String(localized: "Apply to This Torrent")) { apply() }.buttonStyle(.borderedProminent)
                Text(String(localized: "Priority and sharing changes take effect when you apply them."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(String(localized: "Recheck Downloaded Pieces")) { Task { await store.recheckTorrent(task) } }
                Text(String(localized: "Rechecking uses the torrent's piece hashes; no data is discarded unless the engine finds a mismatch."))
                    .font(.caption).foregroundStyle(.secondary)
                if saved { Label(String(localized: "Torrent settings saved"), systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                Text(String(localized: "Changes keep this torrent's progress. Aria2 Next may briefly restart its connections. Skipped files already on disk are kept."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if busy { ProgressView(String(localized: "Loading torrent settings…")) }
            if let issue {
                Text(issue).foregroundStyle(.red).font(.callout)
                if options == nil { Button(String(localized: "Retry")) { Task { await load() } } }
            }
        }
        .nativeTextFieldStyle().disabled(busy && options != nil)
        .task(id: task.id) { await load() }
        .onChange(of: task.files.map { "\($0.index):\($0.isSelected)" }) {
            // Selection can change in the add sheet while this inspector stays mounted.
            // Refresh applied priorities without discarding edits waiting for Apply.
            guard !busy, options == appliedOptions else { return }
            Task { await load() }
        }
    }

    private func priorityBinding(_ index: Int) -> Binding<TorrentFilePriority> {
        Binding(get: { options?.priorities[index] ?? .normal }, set: { options?.priorities[index] = $0; saved = false })
    }
    private func optionBinding<Value>(_ key: WritableKeyPath<BitTorrentTaskOptions, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { options?[keyPath: key] ?? fallback }, set: { options?[keyPath: key] = $0; saved = false })
    }
    private func load() async {
        busy = true; issue = nil
        defer { busy = false }
        do {
            let loaded = BitTorrentTaskOptions(files: task.files, options: try await store.taskOptions(task.id))
            options = loaded; appliedOptions = loaded
        }
        catch { issue = DownloadPrivacy.redact(error.localizedDescription) }
    }
    private func apply() {
        guard let options else { return }
        busy = true; saved = false; issue = nil
        Task {
            defer { busy = false }
            do { try await store.updateTorrent(task, options: options); appliedOptions = options; saved = true }
            catch { issue = DownloadPrivacy.redact(error.localizedDescription) }
        }
    }
}

struct BitTorrentDiagnosticsView: View {
    let diagnostics: BitTorrentDiagnostics
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            row(String(localized: "Peers"), diagnostics.peers.map(String.init))
            row(String(localized: "Seeds"), diagnostics.seeds.map(String.init))
            row(String(localized: "Connecting"), diagnostics.connecting.map(String.init))
            row(String(localized: "Handshaking"), diagnostics.handshaking.map(String.init))
            row(String(localized: "Availability"), diagnostics.availability.map { $0.formatted(.number.precision(.fractionLength(2))) })
            row(String(localized: "Seeding time"), diagnostics.seedingSeconds.map(ByteFormat.duration))
            row(String(localized: "Rejected data"), diagnostics.failedBytes.map(ByteFormat.size))
        }.font(.callout).contentPanel()
    }
    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value { GridRow { Text(label).foregroundStyle(.secondary); Text(value).monospacedDigit() } }
    }
}
