import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @EnvironmentObject private var store: DownloadStore
    @Environment(\.openSettings) private var openSettings

    private var activeTasks: [DownloadTask] {
        Array(store.tasks.filter { $0.status == .active }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.rowSpacing) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ChopChop")
                        .font(.headline)
                    Text(runtimeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                transferMetric(String(localized: "Download speed"), value: ByteFormat.speed(store.activeSpeed), symbol: "arrow.down")
                transferMetric(String(localized: "Upload speed"), value: ByteFormat.speed(store.uploadSpeed), symbol: "arrow.up")
            }

            if activeTasks.isEmpty {
                Text(String(localized: "No active downloads."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, AppLayout.controlSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(activeTasks) { task in
                        VStack(alignment: .leading, spacing: AppLayout.controlSpacing) {
                            HStack {
                                Text(task.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(task.progressLabel).monospacedDigit().foregroundStyle(.secondary)
                            }
                            TaskProgressIndicator(task: task).controlSize(.small)
                        }.font(.callout).padding(.vertical, AppLayout.focusClearance)
                    }
                }
            }

            HStack {
                Button {
                    DownloadAction.pauseAll.perform(in: DownloadActionContext(store: store))
                } label: {
                    Label(String(localized: "Pause All"), systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!store.tasks.contains { $0.primaryControlAction == .pause } || !DownloadAction.engineReady(in: store))

                Button {
                    DownloadAction.resumeAll.perform(in: DownloadActionContext(store: store))
                } label: {
                    Label(String(localized: "Resume"), systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!store.tasks.contains { $0.primaryControlAction == .resume } || !DownloadAction.engineReady(in: store))

                Button {
                    store.requestAddPanel()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label(String(localized: "Add"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            HStack {
                Button(String(localized: "Settings")) {
                    openSettings()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(String(localized: "Quit")) {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: 360)
        .desktopControls()
    }

    private func transferMetric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: AppLayout.focusClearance) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(value)
    }

    private var runtimeText: String {
        switch store.runtime.phase {
        case .stopped:
            String(localized: "Engine stopped")
        case .starting:
            String(localized: "Engine starting")
        case .running:
            String(localized: "Engine running")
        case .stopping:
            String(localized: "Engine stopping")
        case .failed:
            String(localized: "Engine failed")
        }
    }
}
