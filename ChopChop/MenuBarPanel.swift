import AppKit
import Combine
import SwiftUI

struct MenuBarPanel: View {
    @Environment(DownloadStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    private var activeRows: [DownloadRowState] {
        Array(store.listPresentation.visibleRows(for: .active).prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.rowSpacing) {
            MenuBarTransferMetrics()
            TemporaryBandwidthControls()

            if activeRows.isEmpty {
                Text(String(localized: "No active downloads."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, AppLayout.controlSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(activeRows) { row in MenuBarDownloadRow(row: row) }
                }
            }

            HStack {
                Button {
                    DownloadAction.pauseAll.perform(in: DownloadActionContext(store: store))
                } label: {
                    Label(String(localized: "Pause All"), systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!store.listPresentation.orderedRows.contains { $0.presentation.primaryControlAction == .pause } || !DownloadAction.engineReady(in: store))

                Button {
                    DownloadAction.resumeAll.perform(in: DownloadActionContext(store: store))
                } label: {
                    Label(String(localized: "Resume"), systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!store.listPresentation.orderedRows.contains { $0.presentation.primaryControlAction == .resume } || !DownloadAction.engineReady(in: store))

                Button {
                    store.requestAddPanel()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label(String(localized: "Add"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            Button {
                store.downloadWindowRequests.send()
            } label: {
                Label(String(localized: "Show Downloads"), systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            HStack {
                Button(String(localized: "Settings")) {
                    openSettings()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(String(localized: "Quit")) {
                    AppTermination.request()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: 360)
        .desktopControls()
    }

}

private struct MenuBarDownloadRow: View {
    let row: DownloadRowState
    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.controlSpacing) {
            HStack {
                Text(row.presentation.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                MenuBarDownloadPercentage(row: row)
            }
            MenuBarDownloadProgress(row: row)
        }.font(.callout).padding(.vertical, AppLayout.focusClearance)
    }
}

private struct MenuBarDownloadProgress: View {
    let row: DownloadRowState
    var body: some View {
        TaskProgressIndicator(task: row.task).controlSize(.small)
    }
}

private struct MenuBarDownloadPercentage: View {
    let row: DownloadRowState
    var body: some View { TaskProgressValue(task: row.task).foregroundStyle(.secondary) }
}

private struct MenuBarTransferMetrics: View {
    @Environment(DownloadStore.self) private var store
    var body: some View {
        HStack(spacing: 12) {
            transferMetric(String(localized: "Download speed"), speed: store.activeSpeed, symbol: "arrow.down")
            transferMetric(String(localized: "Upload speed"), speed: store.uploadSpeed, symbol: "arrow.up")
        }
    }

    private func transferMetric(_ title: String, speed: Int64, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: AppLayout.focusClearance) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            TransferByteValue(bytes: speed, perSecond: true).font(.body.weight(.medium))
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(ByteFormat.speed(speed))
    }
}
