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
        lhs.scheduleArmed == rhs.scheduleArmed && lhs.compact == rhs.compact &&
        lhs.context.window?.detailsPresented == rhs.context.window?.detailsPresented
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 16) {
                identity.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                progress.frame(width: 180)
                if !compact {
                    DownloadTaskTransferSummary(task: task, compact: false)
                        .frame(width: 188, alignment: .trailing)
                }
                HStack(spacing: 4) {
                    ZStack { primaryAction }.frame(width: 24, height: 28)
                    rowAction(.details)
                    rowAction(.remove).disabled(!removalEnabled)
                }
            }
            if compact, display.showsTransferRates {
                DownloadTaskTransferSummary(task: task, compact: true)
                    .padding(.leading, 44)
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 48 : 44)
        .padding(.vertical, 7)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 44 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        .contentShape(Rectangle())
        .help(taskHelp)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-row-\(task.id)")
    }

    private var identity: some View {
        HStack(spacing: 12) {
            DownloadTaskIcon(task: task, size: 32)
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                Text(task.name).font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("task-\(task.id)-name")
                HStack(spacing: 5) {
                    Label(task.phaseLabel, systemImage: display.statusSymbol)
                        .foregroundStyle((task.status == .failed || task.torrentFileIssue != nil) && !isSelected ? Color.red : .secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .accessibilityIdentifier("task-\(task.id)-status")
                    if let error = task.errorMessage, task.status == .failed {
                        Text("·").accessibilityHidden(true)
                        Text(error).truncationMode(.tail)
                    } else if let date = task.scheduledStart {
                        Image(systemName: "calendar")
                            .accessibilityLabel(scheduleDescription(date))
                    } else {
                        Text("·").accessibilityHidden(true)
                        Text(task.protocolKind.rawValue).truncationMode(.tail)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            HStack(spacing: 6) {
                Text(display.sizeLabel).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if task.progressLabel != "—" {
                    Text(task.progressLabel).foregroundStyle(.secondary).fixedSize()
                }
            }
            .font(.caption).monospacedDigit()
            TaskProgressIndicator(task: task)
                .frame(maxWidth: .infinity)
                .controlSize(.small).accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Progress"))
        .accessibilityValue("\(task.phaseLabel), \(task.progressLabel), \(task.transferSizeLabel)")
        .accessibilityIdentifier("task-\(task.id)-progress")
    }

    private func rowAction(_ action: DownloadAction) -> some View {
        let title = action == .details && context.window?.detailsPresented == true
            ? String(localized: "Hide Details") : action.title
        return Group {
            if action == .details {
                Button(title, systemImage: action.symbol) { context.window?.toggleDetails() }
                    .disabled(!action.isEnabled(in: context))
            } else {
                DownloadActionButton(action: action, context: context)
            }
        }
            .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
            .frame(width: 24, height: 28)
            .help(title)
            .accessibilityLabel("\(title) \(task.name)")
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
                .help(DownloadAction.editAgain.title)
        }
    }

    private func scheduleDescription(_ date: Date) -> String {
        "\(date.formatted(date: .abbreviated, time: .shortened)) · \(scheduleArmed ? String(localized: "Scheduled") : String(localized: "Schedule disabled"))"
    }

    private var taskHelp: String {
        var lines = [task.name, "\(task.phaseLabel) · \(task.progressLabel)", task.transferSizeLabel]
        if let remaining = TaskInspectorDisplay(task: task).remainingTime {
            lines.append(String(localized: "ETA \(remaining)"))
        }
        if let error = task.errorMessage, task.status == .failed { lines.append(error) }
        if let issue = task.torrentFileIssue { lines.append(issue.explanation) }
        if let date = task.scheduledStart { lines.append(scheduleDescription(date)) }
        return lines.joined(separator: "\n")
    }
}

/// Rates and ETA have independent positions, including when torrent upload
/// activity crosses zero. Narrow rows use the available width below the filename.
struct DownloadTaskTransferSummary: View {
    let task: DownloadTask
    let compact: Bool

    var body: some View {
        // Keep a real layout container when idle, so the reserved transfer
        // column and neighboring progress bars stay aligned across all rows.
        VStack(alignment: compact ? .leading : .trailing, spacing: 0) {
            if DownloadListTaskDisplay(task: task).showsTransferRates {
                if compact {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            HStack(spacing: 10) { rates }.fixedSize()
                            Spacer(minLength: 0)
                            remainingTime.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            fittingRates
                            remainingTime
                        }
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 5) {
                        fittingRates
                        remainingTime
                    }
                }
            }
        }
        .font(.caption).monospacedDigit().lineLimit(1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-\(task.id)-transfer")
    }

    private var fittingRates: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { rates }.fixedSize()
            VStack(alignment: compact ? .leading : .trailing, spacing: 3) { rates }
        }
    }

    @ViewBuilder private var rates: some View {
        if !task.isSharing { rate(task.downloadSpeed, uploading: false) }
        if task.isTorrentLike || task.isSharing { rate(task.uploadSpeed, uploading: true) }
    }

    private func rate(_ speed: Int64, uploading: Bool) -> some View {
        let title = uploading ? String(localized: "Upload speed") : String(localized: "Download speed")
        let value = ByteFormat.speed(speed)
        return Label(value, systemImage: uploading ? "arrow.up" : "arrow.down")
            .foregroundStyle(uploading && !task.isSharing ? .secondary : .primary)
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .accessibilityIdentifier("task-\(task.id)-\(uploading ? "upload" : "download")-speed")
    }

    @ViewBuilder private var remainingTime: some View {
        if let remaining = TaskInspectorDisplay(task: task).remainingTime {
            Text(String(localized: "ETA \(remaining)"))
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "ETA \(remaining)"))
                .accessibilityIdentifier("task-\(task.id)-eta")
        }
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
