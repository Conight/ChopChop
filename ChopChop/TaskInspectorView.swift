import AppKit
import SwiftUI

private enum InspectorTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case files = "Files"
    case network = "Network"
    case logs = "Logs"

    var id: String { rawValue }
}

struct TaskInspectorView: View {
    @EnvironmentObject private var store: DownloadStore
    @State private var tab: InspectorTab = .overview
    var task: DownloadTask

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                Picker("Inspector", selection: $tab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)

                switch tab {
                case .overview:
                    overview
                case .files:
                    files
                case .network:
                    network
                case .logs:
                    logs
                }
            }
            .padding(16)
        }
        .task(id: task.id) {
            await store.refreshDetails(for: task.id)
        }
        .onChange(of: tab) { _, newTab in
            guard newTab == .network else { return }
            Task { await store.refreshDetails(for: task.id) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: task.protocolKind.symbolName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(task.status.tint)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(task.destination.isEmpty ? "No destination reported" : task.destination)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            StatusBadge(status: task.status)
        }
    }

    private var overview: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                MetricColumn(title: "Progress", value: "\(Int(task.progress * 100))%", symbol: "chart.line.uptrend.xyaxis", tint: .secondary)
                MetricColumn(title: "Speed", value: ByteFormat.speed(task.downloadSpeed), symbol: "speedometer", tint: .secondary)
            }
            HStack(spacing: 12) {
                MetricColumn(title: "Size", value: ByteFormat.size(task.totalLength), symbol: "externaldrive", tint: .secondary)
                MetricColumn(title: "Connections", value: "\(task.connections)", symbol: "point.3.connected.trianglepath.dotted", tint: .secondary)
            }

            ProgressView(value: task.progress)
                .progressViewStyle(.linear)
                .tint(task.status.tint)
                .padding(.top, 4)

            HStack {
                if let action = task.primaryControlAction {
                    if action == .resume {
                        controlButton(for: action)
                            .buttonStyle(.borderedProminent)
                    } else {
                        controlButton(for: action)
                            .buttonStyle(.bordered)
                    }
                }

                Button(role: .destructive) {
                    store.beginRemove(task)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func controlButton(for action: DownloadTaskControlAction) -> some View {
        Button {
            Task {
                switch action {
                case .pause:
                    await store.pause(task)
                case .resume:
                    await store.resume(task)
                }
            }
        } label: {
            Label(action.helpTitle, systemImage: action.symbolName)
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 10) {
            if task.files.isEmpty {
                Text("No file list reported by Aria2 Next yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentPanel()
            } else {
                ForEach(task.files) { file in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Image(systemName: file.isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(file.isSelected ? .green : .secondary)
                            Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(file.progress * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: file.progress)
                            .tint(.accentColor)
                    }
                    .padding(12)
                    .contentPanel()
                }
            }
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 12) {
            if task.isTorrentLike {
                networkSection(title: "Peers", emptyMessage: "No peer details reported yet.", rows: task.peers.map { "\($0.address) · \($0.client)" })
                networkSection(title: "Trackers", emptyMessage: "No tracker state reported yet.", rows: task.trackers.map { "\($0.status) · \($0.url)" })
            } else if task.protocolKind == .ed2k {
                networkSection(
                    title: "Sources",
                    emptyMessage: "No ED2K source details reported yet.",
                    rows: task.recentLogs.filter { $0.hasPrefix("Servers:") || $0.hasPrefix("Connected servers:") || $0.hasPrefix("Sources:") || $0.hasPrefix("Kad") }
                )
                networkSection(
                    title: "Hash",
                    emptyMessage: "Hash verification details will appear after Aria2 Next reports them.",
                    rows: task.recentLogs.filter { $0.hasPrefix("ED2K hash:") }
                )
            } else {
                networkSection(title: "Segments", emptyMessage: "Segment details are not reported in the current polling pass.", rows: [])
                networkSection(title: "Headers", emptyMessage: "Header diagnostics appear when Aria2 Next returns HTTP metadata.", rows: [])
            }
        }
    }

    private func networkSection(title: String, emptyMessage: String, rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if rows.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { offset, row in
                    Text(row)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("inspector-network-\(networkSectionID(for: title))-row-\(offset)")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentPanel()
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = task.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if task.recentLogs.isEmpty {
                Text("No task logs reported.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentPanel()
            } else {
                ForEach(Array(task.recentLogs.enumerated()), id: \.offset) { offset, log in
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentPanel()
                        .accessibilityIdentifier("inspector-log-row-\(offset)")
                }
            }
        }
    }

    private func networkSectionID(for title: String) -> String {
        title
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
