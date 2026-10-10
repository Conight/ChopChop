import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Classify metadata paths without opening files that have not been downloaded.
nonisolated enum TorrentFileKind: String, CaseIterable, Identifiable {
    case videos, images, audio, subtitles, archives
    var id: String { rawValue }

    var selectionTitle: String {
        switch self {
        case .videos: String(localized: "Only Videos")
        case .images: String(localized: "Only Images")
        case .audio: String(localized: "Only Audio")
        case .subtitles: String(localized: "Only Subtitles")
        case .archives: String(localized: "Only Archives")
        }
    }

    func matches(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        let type = UTType(filenameExtension: ext)
        switch self {
        case .videos:
            return type?.conforms(to: .movie) == true ||
                ["mkv", "webm", "avi", "wmv", "flv", "ts", "mts", "m2ts", "vob", "rmvb"].contains(ext)
        case .images:
            return type?.conforms(to: .image) == true || ["avif", "webp"].contains(ext)
        case .audio:
            return type?.conforms(to: .audio) == true || ["flac", "ogg", "opus", "ape"].contains(ext)
        case .subtitles:
            return ["srt", "ass", "ssa", "vtt", "sub", "idx", "sup", "smi", "ttml"].contains(ext)
        case .archives:
            return type?.conforms(to: .archive) == true || ["rar", "7z", "zst"].contains(ext)
        }
    }

    func indexes(in files: [DownloadFile]) -> Set<Int> {
        Set(TorrentFileTree.contentFiles(files).filter { matches($0.path) }.map(\.index))
    }
}

/// Presentation and readiness are independent of the engine's legacy followedBy chain.
nonisolated enum TorrentFileTree {
    static func sourceName(_ source: String) -> String {
        if let components = URLComponents(string: source), components.scheme?.lowercased() == "magnet" {
            return components.queryItems?.first(where: { $0.name == "dn" })?.value?.nonEmptyValue
                ?? String(localized: "Magnet download")
        }
        return URL(string: source)?.lastPathComponent.nonEmptyValue ?? String(localized: "Torrent download")
    }

    static func contentFiles(_ files: [DownloadFile]) -> [DownloadFile] {
        files.filter {
            $0.index > 0 && $0.length >= 0 && !$0.path.isEmpty &&
            !$0.path.hasPrefix("[METADATA]") && !URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix("[METADATA]")
        }
    }

    static func isResolved(_ snapshot: Aria2TaskSnapshot, source: String, followed: Bool) -> Bool {
        if snapshot.task.requiresFileSelection { return true }
        guard !snapshot.task.isFetchingMetadata else { return false }
        return followed || AddDownloadDraft.localTorrentFileURL(source) != nil ||
            (source.lowercased().hasPrefix("magnet:") && snapshot.task.torrentDiagnostics != nil &&
             !contentFiles(snapshot.task.files).isEmpty)
    }

    static func nodes(files: [DownloadFile], destination: String) -> [TorrentFileNode] {
        final class Branch {
            var folders: [String: Branch] = [:]
            var leaves: [TorrentFileNode] = []
            func build(prefix: String = "") -> [TorrentFileNode] {
                let groups = folders.map { name, branch in
                    let path = prefix + name
                    let children = branch.build(prefix: path + "/")
                    return TorrentFileNode(id: "folder:" + path, name: name, path: path,
                        length: children.reduce(0) { $0 + $1.length },
                        indexes: children.reduce(into: Set<Int>()) { $0.formUnion($1.indexes) }, children: children)
                }
                return groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    + leaves.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        var base = destination.split(separator: "/").map(String.init)
        if base.isEmpty, let first = files.first, first.path.hasPrefix("/") {
            base = first.path.split(separator: "/").dropLast().map(String.init)
            while !base.isEmpty && !files.allSatisfy({ Array($0.path.split(separator: "/").map(String.init).prefix(base.count)) == base }) {
                base.removeLast()
            }
        }
        let root = Branch()
        for file in contentFiles(files) {
            var parts = file.path.split(separator: "/").map(String.init)
            if !base.isEmpty && Array(parts.prefix(base.count)) == base { parts.removeFirst(base.count) }
            guard let name = parts.last else { continue }
            var branch = root
            for part in parts.dropLast() {
                if branch.folders[part] == nil { branch.folders[part] = Branch() }
                branch = branch.folders[part]!
            }
            branch.leaves.append(TorrentFileNode(id: "file:\(file.index)", name: name,
                path: parts.joined(separator: "/"), length: file.length, indexes: [file.index]))
        }
        let result = root.build()
        // The sheet already names the torrent. Don't make users expand that root again.
        return result.count == 1 ? result[0].children ?? result : result
    }

    static func leaves(_ nodes: [TorrentFileNode]) -> [TorrentFileNode] {
        nodes.flatMap { $0.children.map(leaves) ?? [$0] }
    }

    static func matching(_ nodes: [TorrentFileNode], query: String) -> [TorrentFileNode] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nodes }
        return nodes.compactMap { node in
            if node.path.localizedStandardContains(query) { return node }
            guard let children = node.children else { return nil }
            let filtered = matching(children, query: query)
            guard !filtered.isEmpty else { return nil }
            var result = node
            result.children = filtered
            result.indexes = filtered.reduce(into: []) { $0.formUnion($1.indexes) }
            result.length = filtered.reduce(0) { $0 + $1.length }
            return result
        }
    }
}

nonisolated struct TorrentFileNode: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var path: String
    var length: Int64
    var indexes: Set<Int>
    var children: [TorrentFileNode]?
}

struct BitTorrentFileSelectionView: View {
    @EnvironmentObject private var store: DownloadStore
    var session: BitTorrentFileSelectionSession
    @State private var query = ""
    @State private var nodes: [TorrentFileNode] = []
    @State private var availableKinds: Set<TorrentFileKind> = []

    private var visible: [TorrentFileNode] {
        let matches = TorrentFileTree.matching(nodes, query: query)
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? matches : TorrentFileTree.leaves(matches)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.taskName).font(.headline).lineLimit(2).textSelection(.enabled)
                .help(session.taskName).accessibilityIdentifier("bt-file-selection-title")
            if session.phase == .ready {
                fileList
            } else {
                discovery
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: rebuildTree)
        .onChange(of: session.files) { _, _ in rebuildTree() }
        .accessibilityIdentifier("bt-file-selection")
    }

    private func rebuildTree() {
        nodes = TorrentFileTree.nodes(files: session.files, destination: session.destination)
        availableKinds = Set(TorrentFileKind.allCases.filter { !$0.indexes(in: session.files).isEmpty })
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(String(localized: "Search files"), text: $query)
                .nativeTextFieldStyle().accessibilityIdentifier("bt-file-selection-search")
            HStack(spacing: AppLayout.controlSpacing) {
                Button(String(localized: "Select All")) {
                    store.setAllBitTorrentFilesSelected(true)
                    query = ""
                }
                    .disabled(session.selectedFileIndexes.count == session.files.count)
                    .accessibilityIdentifier("bt-file-selection-all")
                Button(String(localized: "Deselect All")) {
                    store.setAllBitTorrentFilesSelected(false)
                    query = ""
                }
                    .disabled(!session.hasSelection)
                    .accessibilityIdentifier("bt-file-selection-none")
                Spacer(minLength: 0)
                Menu(String(localized: "Select by Type")) {
                    ForEach(TorrentFileKind.allCases) { kind in
                        Button(kind.selectionTitle) {
                            store.selectBitTorrentFiles(ofKind: kind)
                            query = ""
                        }
                        .disabled(!availableKinds.contains(kind))
                    }
                }
                .fixedSize()
                .help(String(localized: "Replaces the selection across the entire torrent. You can then adjust individual files."))
                .accessibilityIdentifier("bt-file-selection-type")
            }
            List(visible, children: \.children) { node in
                HStack(spacing: 8) {
                    TorrentSelectionCheckbox(indexes: node.indexes, selected: session.selectedFileIndexes,
                        title: node.name) { selected in
                        store.setBitTorrentFileIndexes(node.indexes, selected: selected)
                    }
                    Image(systemName: node.children == nil ? "doc" : "folder")
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name).lineLimit(2).truncationMode(.middle)
                        if !query.isEmpty && node.path != node.name {
                            Text(node.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).help(node.path)
                    Text(ByteFormat.size(node.length)).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize()
                }.padding(.vertical, 3)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("bt-file-selection-\(node.id)")
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .accessibilityIdentifier("bt-file-selection-list")
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "\(session.selectedFileIndexes.count) of \(session.files.count) files selected"))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.size(session.selectedTotalLength)).fontWeight(.medium).monospacedDigit()
            }.font(.callout).accessibilityIdentifier("bt-file-selection-summary")
            Text(String(localized: "Only selected files will download. You can change file priorities later in Details."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var discovery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if session.phase == .failed {
                    Label(String(localized: "Couldn’t retrieve the file list"), systemImage: "exclamationmark.triangle")
                        .fontWeight(.medium)
                    Text(session.issue ?? "").textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(localized: "Try again to check the same task, or change the source. Any metadata already received is kept until you cancel."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text(discoveryTitle).fontWeight(.medium)
                    Text(session.source.lowercased().hasPrefix("magnet:")
                         ? String(localized: "A magnet link needs a reachable peer to provide its file list. File downloads begin only after you confirm your selection.")
                         : String(localized: "Reading the torrent’s file list. File downloads begin only after you confirm your selection."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent(String(localized: "Elapsed"), value: ByteFormat.duration(Int(context.date.timeIntervalSince(session.startedAt))))
                            if let peers = session.diagnostics?.peers {
                                LabeledContent(String(localized: "Connected peers"), value: peers.formatted())
                            }
                            if let connecting = session.diagnostics?.connecting {
                                LabeledContent(String(localized: "Connecting peers"), value: connecting.formatted())
                            }
                            if context.date.timeIntervalSince(session.startedAt) >= 20 {
                                Label(String(localized: "Still waiting? A local .torrent file can show the file list without peer discovery. You can change the source below."), systemImage: "info.circle")
                                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }.monospacedDigit()
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        }.accessibilityIdentifier("bt-file-selection-loading")
    }

    private var discoveryTitle: String {
        if session.isQueued { return String(localized: "Waiting for an available download slot…") }
        if (session.diagnostics?.peers ?? 0) > 0 { return String(localized: "Requesting the file list from connected peers…") }
        return session.source.lowercased().hasPrefix("magnet:")
            ? String(localized: "Finding peers for this magnet link…")
            : String(localized: "Reading the torrent file list…")
    }
}

/// NSButton supplies the standard mixed-state checkbox, keyboard focus and VoiceOver value.
private struct TorrentSelectionCheckbox: NSViewRepresentable {
    var indexes: Set<Int>
    var selected: Set<Int>
    var title: String
    var onChange: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.toggle))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        let count = indexes.intersection(selected).count
        button.state = count == 0 ? .off : count == indexes.count ? .on : .mixed
        button.setAccessibilityLabel(title)
        context.coordinator.action = { onChange(count != indexes.count) }
    }
    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func toggle() { action?() }
    }
}
