import SwiftUI

nonisolated struct PieceGridLayout {
    var width: Double
    var count: Int
    var columns: Int { max(1, min(64, Int(max(1, width) / 14))) }
    var height: Double { Double((count + columns - 1) / columns) * 14 }
    func rect(_ index: Int) -> CGRect {
        CGRect(x: Double(index % columns) * width / Double(columns), y: Double(index / columns) * 14,
               width: max(1, width / Double(columns) - 3), height: 11)
    }
    // Canvas strokes are centered on their paths. Inset by half the width so
    // edge pieces have the same border as interior pieces, without clipping.
    func outline(_ index: Int, lineWidth: Double) -> Path {
        Path(roundedRect: rect(index).insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
             cornerRadius: max(0, 2 - lineWidth / 2))
    }
    func index(at point: CGPoint) -> Int? {
        guard width > 0, point.x >= 0, point.y >= 0, point.x < width else { return nil }
        let index = Int(point.y / 14) * columns + Int(point.x / (width / Double(columns)))
        guard (0..<count).contains(index), rect(index).contains(point) else { return nil }
        return index
    }
}

/// Page navigation and keyboard inspection never pin the pointer's highlight.
nonisolated struct PieceMapInspection {
    private(set) var navigationIndex = 0
    private(set) var hoveredIndex: Int?
    private(set) var detailIndex: Int?

    mutating func point(at location: CGPoint?, in layout: PieceGridLayout, start: Int) {
        hoveredIndex = location.flatMap { layout.index(at: $0) }.map { start + $0 }
        detailIndex = hoveredIndex
    }

    mutating func navigate(to index: Int, count: Int, inspect: Bool = true) {
        navigationIndex = max(0, min(count - 1, index))
        hoveredIndex = nil
        detailIndex = inspect && count > 0 ? navigationIndex : nil
    }
}

struct PieceGrid: View {
    let map: PieceMap
    let start: Int
    let layout: PieceGridLayout
    let hoveredIndex: Int?

    var body: some View {
        Canvas { context, _ in
            for index in 0..<layout.count {
                switch map.state(at: start + index) {
                case .complete:
                    context.fill(Path(roundedRect: layout.rect(index), cornerRadius: 2), with: .color(.accentColor))
                case .missing:
                    context.stroke(layout.outline(index, lineWidth: 1), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                case .unknown:
                    context.stroke(layout.outline(index, lineWidth: 1), with: .color(.secondary),
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                if start + index == hoveredIndex {
                    context.stroke(layout.outline(index, lineWidth: 2), with: .color(.primary), lineWidth: 2)
                }
            }
        }
        .frame(height: layout.height)
    }
}

struct PieceMapView: View {
    let map: PieceMap
    @State private var inspection = PieceMapInspection()
    @State private var width = 280.0
    private let pageSize = 256
    private var page: Int { min(inspection.navigationIndex, map.count - 1) / pageSize }
    private var start: Int { page * pageSize }
    private var visibleCount: Int { min(pageSize, map.count - start) }
    private var layout: PieceGridLayout { PieceGridLayout(width: width, count: visibleCount) }

    private var inspectionDescription: String {
        inspection.detailIndex.map { map.description(at: $0) }
            ?? String(localized: "Point to a piece to see its status and size.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Pieces")).font(.headline)
            Text(map.completionSummary)
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Text(String(localized: "Piece status can trail file progress by a few seconds."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GeometryReader { geometry in
                Canvas { context, size in
                    for (index, fraction) in map.overview.enumerated() {
                        let step = size.width / Double(map.overview.count)
                        let rect = CGRect(x: Double(index) * step, y: 0, width: max(1, step), height: size.height)
                        context.fill(Path(rect), with: .color(fraction.map { Color.accentColor.opacity(0.12 + $0 * 0.88) } ?? .gray.opacity(0.2)))
                    }
                    let rect = CGRect(x: Double(start) / Double(map.count) * size.width, y: 0,
                                      width: max(2, Double(visibleCount) / Double(map.count) * size.width), height: size.height)
                    context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(.primary), lineWidth: 2)
                }
                .onTapGesture { location in
                    navigate(Int(max(0, min(1, location.x / max(1, geometry.size.width))) * Double(map.count)), inspect: false)
                }
            }.frame(height: 18)
                .accessibilityLabel(String(localized: "Whole-torrent overview"))
                .accessibilityValue(map.completionSummary)
                .help(String(localized: "Overview of all pieces. Click to inspect that part of the torrent."))
            Text(String(localized: "Each square below is one piece. The strip above summarizes the whole torrent."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PieceGrid(map: map, start: start, layout: layout, hoveredIndex: inspection.hoveredIndex)
            .contentShape(Rectangle())
            .onGeometryChange(for: Double.self) { $0.size.width } action: {
                width = $0
                inspection.point(at: nil, in: layout, start: start)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): inspection.point(at: location, in: layout, start: start)
                case .ended: inspection.point(at: nil, in: layout, start: start)
                }
            }
            .help(inspectionDescription)
            .focusable()
            .onMoveCommand { direction in
                let index = inspection.detailIndex ?? inspection.navigationIndex
                switch direction {
                case .left: navigate(index - 1); case .right: navigate(index + 1)
                case .up: navigate(index - layout.columns); case .down: navigate(index + layout.columns)
                default: break
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Piece map"))
            .accessibilityValue(inspection.detailIndex.map { map.description(at: $0) } ?? map.completionSummary)
            .accessibilityAdjustableAction { direction in
                navigate(inspection.navigationIndex + (direction == .increment ? 1 : -1))
            }
            HStack(spacing: 12) {
                Label(String(localized: "Complete piece"), systemImage: "square.fill").foregroundStyle(Color.accentColor)
                Label(String(localized: "Not complete"), systemImage: "square").foregroundStyle(.secondary)
            }.font(.caption)
            if map.reportedCount < map.count {
                Label(String(localized: "Not reported"), systemImage: "square.dashed").font(.caption).foregroundStyle(.secondary)
            }
            Text(inspectionDescription).font(.caption).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 30, alignment: .topLeading)
            HStack {
                Button { navigate(start - pageSize, inspect: false) } label: { Image(systemName: "chevron.left") }
                    .disabled(page == 0).help(String(localized: "Previous pieces")).accessibilityLabel(String(localized: "Previous pieces"))
                Text(String(localized: "\(page + 1) / \((map.count + pageSize - 1) / pageSize)"))
                    .font(.caption).monospacedDigit()
                Button { navigate(start + pageSize, inspect: false) } label: { Image(systemName: "chevron.right") }
                    .disabled(start + visibleCount >= map.count).help(String(localized: "Next pieces")).accessibilityLabel(String(localized: "Next pieces"))
                Spacer()
                Stepper(String(localized: "Piece \(inspection.navigationIndex + 1)"),
                        value: Binding(get: { inspection.navigationIndex }, set: { navigate($0) }),
                        in: 0...(map.count - 1))
                    .font(.caption)
            }.controlSize(.small)
            Text(String(localized: "Includes pieces belonging to skipped files. Incomplete pieces may be missing or partially received; the engine does not report their individual percentages."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .contentPanel()
        .onChange(of: map.count) { navigate(inspection.navigationIndex, inspect: false) }
    }
    private func navigate(_ index: Int, inspect: Bool = true) {
        inspection.navigate(to: index, count: map.count, inspect: inspect)
    }
}

struct TransferDetailsView: View {
    @EnvironmentObject private var store: DownloadStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var monitor = TransferDetailMonitor()
    @State private var windowVisible = false
    let task: DownloadTask

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.rowSpacing) {
            if let snapshot = monitor.snapshot {
                TransferRateSummary(snapshot: snapshot, isTorrent: task.isTorrentLike)
                if let map = snapshot.pieces { PieceMapView(map: map) }
                else if task.isTorrentLike {
                    Text(String(localized: "The piece map appears when the engine reports torrent metadata."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if task.isAvailableInEngine, task.primaryControlAction != nil {
                    DisclosureGroup(task.isTorrentLike ? String(localized: "Upload bandwidth") : String(localized: "Connection limits")) {
                        TransferOptionsView(task: task)
                    }.font(.callout)
                }
                if task.isTorrentLike { PeerTransfersView(peers: snapshot.peers) }
                else { ServerTransfersView(servers: snapshot.servers) }
                Text(String(localized: "Live snapshot · \(snapshot.updatedAt.formatted(date: .omitted, time: .standard))"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let issue = monitor.issue {
                Label(issue, systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(.secondary)
            } else if task.isAvailableInEngine && scenePhase == .active && windowVisible {
                ProgressView(String(localized: "Loading transfer details…")).controlSize(.small)
            } else {
                Text(String(localized: "Live details are available while this window and the engine are active."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .background(WindowVisibilityReader(visible: $windowVisible).frame(width: 0, height: 0))
        .task(id: "\(task.id):\(task.isAvailableInEngine):\(scenePhase == .active && windowVisible):\(store.isUpdatingEngine)") {
            guard scenePhase == .active && windowVisible, task.isAvailableInEngine, !store.isUpdatingEngine else { return }
            let id = task.id, torrent = task.isTorrentLike, store = store
            await monitor.observe {
                let client = try await store.transferClient(for: id)
                return try await client.transferSnapshot(id, isTorrent: torrent)
            }
        }
    }
}

struct TransferRateSummary: View {
    let snapshot: TransferSnapshot
    let isTorrent: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(ByteFormat.speed(snapshot.downloadSpeed), systemImage: "arrow.down.circle")
                    .accessibilityLabel(String(localized: "Download speed")).accessibilityValue(ByteFormat.speed(snapshot.downloadSpeed))
                Spacer()
                if isTorrent {
                    Label(ByteFormat.speed(snapshot.uploadSpeed), systemImage: "arrow.up.circle")
                        .accessibilityLabel(String(localized: "Upload speed")).accessibilityValue(ByteFormat.speed(snapshot.uploadSpeed))
                }
            }.font(.headline).monospacedDigit()
            Text(String(localized: "\(snapshot.connections) active connections")).font(.caption).foregroundStyle(.secondary)
            if isTorrent, let uploaded = snapshot.uploaded {
                Text(String(localized: "Uploaded \(ByteFormat.size(uploaded))")).font(.caption).foregroundStyle(.secondary)
            }
        }.contentPanel()
    }
}

struct PeerTransferRow: View {
    let peer: PeerTransfer
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(peer.address).font(.callout.monospaced()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                Text(peer.peerClientName ?? String(localized: "Client not reported")).lineLimit(1).help(peer.peerClientName ?? "")
                Spacer()
                Text(peer.seeder == "true" ? String(localized: "Seeder") : peer.stateLabel)
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Label(ByteFormat.speed(peer.down), systemImage: "arrow.down").accessibilityLabel(String(localized: "Download speed"))
                    .accessibilityValue(ByteFormat.speed(peer.down))
                Spacer()
                Label(ByteFormat.speed(peer.up), systemImage: "arrow.up").accessibilityLabel(String(localized: "Upload speed"))
                    .accessibilityValue(ByteFormat.speed(peer.up))
            }.font(.callout).monospacedDigit()
            if let fraction = peer.fraction {
                ProgressView(value: fraction) { Text(String(localized: "Peer has \(fraction.formatted(.percent.precision(.fractionLength(1))))")) }
                    .font(.caption)
            }
            DisclosureGroup(String(localized: "Connection details")) {
                VStack(alignment: .leading, spacing: 6) {
                    if let transport = peer.transport { Text(String(localized: "Transport: \(transport.uppercased())")) }
                    if let incoming = peer.incoming { Text(incoming == "true" ? String(localized: "Incoming connection") : String(localized: "Outgoing connection")) }
                    if let encryption = peer.encryptionLabel { Text(String(localized: "Encryption: \(encryption)")) }
                    if let bytes = peer.downloaded.flatMap(Int64.init) { Text(String(localized: "Received this connection: \(ByteFormat.size(bytes))")) }
                    if let bytes = peer.uploaded.flatMap(Int64.init) { Text(String(localized: "Sent this connection: \(ByteFormat.size(bytes))")) }
                    if peer.peerChoking == "true" { Text(String(localized: "The peer has not granted us a download slot.")) }
                    if peer.amChoking == "true" { Text(String(localized: "We have not granted this peer an upload slot.")) }
                    if peer.amInterested == "false" { Text(String(localized: "We are not requesting data from this peer.")) }
                    if peer.peerInterested == "false" { Text(String(localized: "This peer is not requesting our data.")) }
                    if peer.snubbed == "true" { Text(String(localized: "This peer has not responded to recent data requests.")) }
                    if peer.optimisticUnchoke == "true" { Text(String(localized: "Temporary upload slot granted")) }
                    if !peer.sourceLabels.isEmpty { Text(String(localized: "Discovered via: \(peer.sourceLabels.joined(separator: ", "))")) }
                }.padding(.top, 6).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TransferOptionsView: View {
    @EnvironmentObject private var store: DownloadStore
    let task: DownloadTask
    @State private var uploadKiB = 0
    @State private var originalKiB: Int?
    @State private var globalUpload: Int64?
    @State private var split: String?
    @State private var perServer: String?
    @State private var busy = false
    @State private var issue: String?
    @State private var saved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(task.isTorrentLike ? String(localized: "Upload bandwidth") : String(localized: "Connection limits")).font(.headline)
            if task.isTorrentLike {
                Text(String(localized: "Task upload limit (KiB/s)")).font(.caption).foregroundStyle(.secondary)
                TextField(String(localized: "Task upload limit (KiB/s)"), value: $uploadKiB, format: .number.grouping(.never))
                    .nativeTextFieldStyle().disabled(busy || originalKiB == nil)
                Button(String(localized: "Apply Upload Limit")) {
                    busy = true; saved = false
                    Task {
                        defer { busy = false }
                        do { try await store.setTorrentUploadLimit(task, kib: uploadKiB); originalKiB = uploadKiB; issue = nil; saved = true }
                        catch { issue = DownloadPrivacy.redact(error.localizedDescription) }
                    }
                }.disabled(busy || originalKiB == nil || uploadKiB == originalKiB || task.primaryControlAction == nil)
                    .controlSize(.small)
                if saved { Label(String(localized: "Upload limit saved"), systemImage: "checkmark.circle").font(.caption) }
                Text(String(localized: "0 removes this task's cap. The global cap still applies; it is not a way to turn off seeding."))
                    .font(.caption).foregroundStyle(.secondary)
                if store.engineCapabilities?.version == "2.8.6" {
                    Text(String(localized: "Aria2 Next 2.8.6 exempts local-network peers from global bandwidth limits. Set a task upload limit to cap their speed too."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let globalUpload {
                    Text(globalUpload == 0 ? String(localized: "Global upload: Unlimited") : String(localized: "Global upload: \(ByteFormat.speed(globalUpload))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(String(localized: "Refresh Limits")) { Task { await load() } }.controlSize(.small).disabled(busy)
                Text(String(localized: "Change global bandwidth in Settings → Network. Scheduled limits may override it."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if let split { LabeledContent(String(localized: "Split count"), value: split) }
                if let perServer { LabeledContent(String(localized: "Max connections per server"), value: perServer) }
                Text(String(localized: "These are upper limits. Actual connections depend on file size, range support and the server. Media and ED2K use their own transfer strategies."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.red); Button(String(localized: "Retry")) { Task { await load() } } }
        }.contentPanel().task(id: task.id) { await load() }
    }
    private func load() async {
        busy = true; originalKiB = nil; saved = false; defer { busy = false }
        do {
            let client = try store.transferClient(for: task.id)
            async let options = client.getOption(task.id)
            async let global = client.getGlobalOption()
            let (values, globals) = try await (options, global)
            guard !Task.isCancelled else { return }
            if let bytes = TransferRateLimit.bytes(values["max-upload-limit"]) {
                uploadKiB = Int((Double(bytes) / 1024).rounded(.up)); originalKiB = uploadKiB
            }
            globalUpload = TransferRateLimit.bytes(globals["max-overall-upload-limit"])
            split = values["split"]; perServer = values["max-connection-per-server"]; issue = nil
        } catch { if !Task.isCancelled { issue = DownloadPrivacy.redact(error.localizedDescription) } }
    }
}
