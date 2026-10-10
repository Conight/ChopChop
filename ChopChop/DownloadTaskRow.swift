import SwiftUI

/// A flat desktop row. List owns selection, separators and pointer
/// behavior; only the content has app-defined spacing.
struct DownloadTaskRow: View, Equatable {
    let context: DownloadActionContext
    @ObservedObject var row: DownloadRowState
    let isSelected: Bool
    let actionsEnabled: Bool
    let removalEnabled: Bool
    let scheduleArmed: Bool
    let compact: Bool
    private var store: DownloadStore { context.store }
    private var task: DownloadTask { row.task }
    private var display: DownloadListTaskDisplay { DownloadListTaskDisplay(task: task) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row === rhs.row && lhs.isSelected == rhs.isSelected &&
        lhs.actionsEnabled == rhs.actionsEnabled && lhs.removalEnabled == rhs.removalEnabled &&
        lhs.scheduleArmed == rhs.scheduleArmed && lhs.compact == rhs.compact
    }

    var body: some View {
        HStack(spacing: 16) {
            identity.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                progress
                if compact {
                    HStack(spacing: 8) {
                        transferLabels
                        Spacer(minLength: 0)
                    }
                    .font(.caption).monospacedDigit().lineLimit(1)
                    .frame(minHeight: 13)
                }
            }.frame(width: compact ? 180 : 172)
            if !compact { transfer.frame(width: 100, alignment: .trailing) }
            HStack(spacing: 4) {
                ZStack { primaryAction }.frame(width: 24, height: 28)
                rowAction(.details)
                rowAction(.remove).disabled(!removalEnabled)
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 7)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 44 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-row-\(task.id)")
    }

    private var identity: some View {
        HStack(spacing: 12) {
            DownloadTaskIcon(task: task, size: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(task.name).font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle).help(task.name)
                    .accessibilityIdentifier("task-\(task.id)-name")
                HStack(spacing: 5) {
                    Label(task.phaseLabel, systemImage: display.statusSymbol)
                        .foregroundStyle(task.status == .failed && !isSelected ? Color.red : .secondary)
                        .fixedSize()
                        .accessibilityIdentifier("task-\(task.id)-status")
                    if let error = task.errorMessage, task.status == .failed {
                        Text("·").accessibilityHidden(true)
                        Text(error).truncationMode(.tail).help(error)
                    } else if let date = task.scheduledStart {
                        Image(systemName: "calendar").help(scheduleDescription(date))
                            .accessibilityLabel(scheduleDescription(date))
                    } else {
                        Text("·").accessibilityHidden(true)
                        Text(task.protocolKind.rawValue).truncationMode(.tail)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            HStack(spacing: 6) {
                Text(display.sizeLabel).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if display.showsProgress, task.progressLabel != "—" {
                    Text(task.progressLabel).foregroundStyle(.secondary).fixedSize()
                }
            }
            .font(.caption).monospacedDigit()
            if display.showsProgress {
                TaskProgressIndicator(task: task)
                    .controlSize(.small).accessibilityHidden(true)
            }
        }
        .help(task.transferSizeLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Progress"))
        .accessibilityValue("\(task.phaseLabel), \(task.progressLabel), \(task.transferSizeLabel)")
        .accessibilityIdentifier("task-\(task.id)-progress")
    }

    private var transfer: some View {
        VStack(alignment: .trailing, spacing: 5) {
            transferLabels
        }
        .font(.caption).monospacedDigit().lineLimit(1)
        .accessibilityIdentifier("task-\(task.id)-transfer")
    }

    @ViewBuilder private var transferLabels: some View {
        if display.showsTransferRates {
            Label(ByteFormat.speed(task.isSharing ? task.uploadSpeed : task.downloadSpeed),
                  systemImage: task.isSharing ? "arrow.up" : "arrow.down")
                .fixedSize()
                .accessibilityLabel(task.isSharing ? String(localized: "Upload speed") : String(localized: "Download speed"))
                .accessibilityValue(ByteFormat.speed(task.isSharing ? task.uploadSpeed : task.downloadSpeed))
            if task.isTorrentLike, !task.isSharing, task.uploadSpeed > 0 {
                Label(ByteFormat.speed(task.uploadSpeed), systemImage: "arrow.up")
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "Upload speed"))
                    .accessibilityValue(ByteFormat.speed(task.uploadSpeed))
            } else if let remaining = TaskInspectorDisplay(task: task).remainingTime {
                Text(compact ? remaining : String(localized: "ETA \(remaining)"))
                    .foregroundStyle(.secondary)
                    .help(String(localized: "ETA \(remaining)"))
                    .accessibilityLabel(String(localized: "ETA \(remaining)"))
            }
        }
    }

    private func rowAction(_ action: DownloadAction) -> some View {
        DownloadActionButton(action: action, context: context)
            .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
            .frame(width: 24, height: 28)
            .help(action.title)
            .accessibilityLabel("\(action.title) \(task.name)")
            .accessibilityIdentifier("task-\(task.id)-\(action.id)-button")
    }

    @ViewBuilder private var primaryAction: some View {
        if let action = task.primaryControlAction {
            Button {
                (action == .pause ? DownloadAction.pause : .resume).perform(in: context)
            } label: {
                Label("\(action.helpTitle) \(task.name)", systemImage: action.symbolName).labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless).controlSize(.small)
            .disabled(!actionsEnabled).help(action.helpTitle)
            .accessibilityIdentifier("task-\(task.id)-\(action.accessibilityName)-button")
        } else if task.status == .completed {
            Button(String(localized: "Show in Finder"), systemImage: "magnifyingglass") { store.showInFinder(task) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
                .help(String(localized: "Show in Finder"))
                .disabled(DownloadFileLocation.revealURL(for: task) == nil)
        } else if task.canEditAndAddAgain {
            DownloadActionButton(action: .editAgain, context: context)
                .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
        }
    }

    private func scheduleDescription(_ date: Date) -> String {
        "\(date.formatted(date: .abbreviated, time: .shortened)) · \(scheduleArmed ? String(localized: "Scheduled") : String(localized: "Schedule disabled"))"
    }
}

struct DownloadTaskContextMenu: View {
    let task: DownloadTask
    let context: DownloadActionContext

    var body: some View {
        DownloadActionButton(action: .details, context: context)
        Divider()
        if DownloadAction.reveal.isEnabled(in: context) {
            DownloadActionButton(action: .reveal, context: context)
            Divider()
        }
        if context.tasks.count > 1 {
            DownloadActionButton(action: .pause, context: context)
            DownloadActionButton(action: .resume, context: context)
        } else if let action = task.primaryControlAction {
            DownloadActionButton(action: action == .pause ? .pause : .resume, context: context)
        }
        if task.isAvailableInEngine, task.primaryControlAction != nil, !task.requiresFileSelection {
            DownloadActionButton(action: .speedLimits, context: context)
            DownloadActionButton(action: .schedule, context: context)
        }
        if task.canFinishRecording { DownloadActionButton(action: .finishRecording, context: context) }
        if task.canRetryMedia { DownloadActionButton(action: .retryMedia, context: context) }
        if task.canEditAndAddAgain { DownloadActionButton(action: .editAgain, context: context) }
        if task.queuePosition != nil { DownloadActionButton(action: .moveToTop, context: context) }
        DownloadActionButton(action: .remove, context: context)
    }
}
