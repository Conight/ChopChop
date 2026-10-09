import SwiftUI

nonisolated enum LiveTableOrder {
    /// Keep rows under the pointer still while their values refresh; append newly connected peers.
    static func reconcile(_ previous: [String], incoming: [String]) -> [String] {
        let current = Set(incoming), existing = Set(previous)
        return previous.filter { current.contains($0) } + incoming.filter { !existing.contains($0) }
    }
}

nonisolated private struct PeerTableRow: Identifiable {
    let peer: PeerTransfer
    var id: String { peer.id }
    var address: String { peer.address }
    var client: String { peer.peerClientName ?? String(localized: "Client not reported") }
    var down: Int64 { peer.down }
    var up: Int64 { peer.up }
    var state: String { peer.seeder == "true" ? String(localized: "Seeder") : peer.stateLabel }
}

struct PeerTransfersView: View {
    let peers: [PeerTransfer]
    @State private var width: CGFloat = 440
    @State private var search = ""
    @State private var selection: String?
    @State private var order: [String] = []
    @State private var sort = [KeyPathComparator(\PeerTableRow.address, comparator: .localizedStandard)]
    private var allRows: [PeerTableRow] {
        // Never feed duplicate identities to a native table.
        Dictionary(peers.map { ($0.id, PeerTableRow(peer: $0)) }, uniquingKeysWith: { _, last in last }).values.sorted(using: sort)
    }
    private var rows: [PeerTableRow] {
        let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return allRows.filter { search.isEmpty || $0.address.localizedStandardContains(search) || $0.client.localizedStandardContains(search) }
            .sorted { (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Peers (\(peers.count))")).font(.headline)
            if peers.isEmpty {
                Text(String(localized: "No live peers. Paused tasks do not keep peer connections.")).foregroundStyle(.secondary)
            } else {
                NativeSearchField(text: $search, move: { _ in }, submit: {}, dismiss: { search = "" },
                                  prompt: String(localized: "Filter address or client"), focusOnAppear: false, size: .regular).frame(height: 26)
                Table(rows, selection: $selection, sortOrder: $sort) {
                    TableColumn(String(localized: "Address"), value: \.address) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.address).font(.callout.monospaced()).lineLimit(1)
                            Text(row.client + " · " + row.state).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.help(row.address + "\n" + row.client)
                    }.width(max(80, width - 200))
                    TableColumn("↓", value: \.down) { Text(ByteFormat.speed($0.down)).monospacedDigit().accessibilityLabel(String(localized: "Download speed")).accessibilityValue(ByteFormat.speed($0.down)) }
                        .width(68)
                    TableColumn("↑", value: \.up) { Text(ByteFormat.speed($0.up)).monospacedDigit().accessibilityLabel(String(localized: "Upload speed")).accessibilityValue(ByteFormat.speed($0.up)) }
                        .width(68)
                }.frame(height: min(320, max(120, CGFloat(rows.count) * 42 + 30)))
                    .accessibilityLabel(String(localized: "Peers"))
                HStack(alignment: .top) {
                    Text("Values update live. Sort again to reorder.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Refresh Order")) { order = allRows.map(\.id) }.controlSize(.small)
                }
                if rows.isEmpty { Text(String(localized: "No matching peers")).foregroundStyle(.secondary) }
                if let peer = peers.first(where: { $0.id == selection }) { PeerTransferRow(peer: peer) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: peers.map(\.id), initial: true) { _, ids in
            order = LiveTableOrder.reconcile(order, incoming: allRows.map(\.id))
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .onChange(of: sort) { _, _ in order = allRows.map(\.id) }
        .onChange(of: search) { _, _ in if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil } }
    }
}

struct ServerTransfersView: View {
    let servers: [ServerTransfer]
    @State private var width: CGFloat = 440
    @State private var sort = [KeyPathComparator(\ServerTransfer.address, comparator: .localizedStandard)]
    @State private var selection: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Server transfers")).font(.headline)
            if servers.isEmpty {
                Text(String(localized: "No active server connections reported.")).foregroundStyle(.secondary).font(.callout)
            } else {
                Table(servers.sorted(using: sort), selection: $selection, sortOrder: $sort) {
                    TableColumn(String(localized: "Address"), value: \.address) { server in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.address).lineLimit(1).help(server.address)
                            Text(server.transport).font(.caption).foregroundStyle(.secondary)
                        }
                    }.width(max(80, width - 178))
                    TableColumn(String(localized: "File"), value: \.fileIndex) { Text($0.fileIndex.formatted()) }.width(40)
                    TableColumn("↓", value: \.downloadSpeed) { Text(ByteFormat.speed($0.downloadSpeed)).monospacedDigit() }.width(74)
                }.frame(height: min(260, max(100, CGFloat(servers.count) * 42 + 30)))
                    .accessibilityLabel(String(localized: "Server transfers"))
                if let server = servers.first(where: { $0.id == selection }) {
                    Text(server.address).font(.callout.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(String(localized: "HTTP entries are server summaries and can combine multiple connections. Individual connection speeds, byte ranges and progress are not exposed by this engine."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
