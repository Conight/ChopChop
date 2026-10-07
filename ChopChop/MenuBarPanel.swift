import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @EnvironmentObject private var store: DownloadStore
    @Environment(\.openSettings) private var openSettings

    private var activeTasks: [DownloadTask] {
        Array(store.tasks.filter { $0.status == .active }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ChopChop")
                        .font(.headline)
                    Text(runtimeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(ByteFormat.speed(store.activeSpeed))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }

            HStack(spacing: 12) {
                MetricColumn(title: "Down", value: ByteFormat.speed(store.activeSpeed), symbol: "arrow.down", tint: .accentColor)
                MetricColumn(title: "Up", value: ByteFormat.speed(store.uploadSpeed), symbol: "arrow.up", tint: .gray)
            }

            if activeTasks.isEmpty {
                Text("No active downloads.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelRowBackground()
            } else {
                VStack(spacing: 8) {
                    ForEach(activeTasks) { task in
                        HStack {
                            Text(task.name)
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(task.progress * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(10)
                        .panelRowBackground()
                    }
                }
            }

            HStack {
                Button {
                    Task { await store.pauseAll() }
                } label: {
                    Label("Pause All", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!store.tasks.contains { $0.primaryControlAction == .pause } || store.isUpdatingEngine)

                Button {
                    Task { await store.resumeAll() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!store.tasks.contains { $0.primaryControlAction == .resume } || store.isUpdatingEngine)

                Button {
                    store.requestAddPanel()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            HStack {
                Button("Settings") {
                    openSettings()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private var runtimeText: String {
        switch store.runtime.phase {
        case .stopped:
            "Engine stopped"
        case .starting:
            "Engine starting"
        case .running:
            "Engine running"
        case .stopping:
            "Engine stopping"
        case .failed:
            "Engine failed"
        }
    }
}

private extension View {
    func panelRowBackground() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
