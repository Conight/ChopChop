import SwiftUI

/// A flat desktop row. List owns selection, separators and pointer
/// behavior; only the content has app-defined spacing.
struct DownloadTaskRow: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completionCount = 0
    let context: DownloadActionContext
    let row: DownloadRowState
    let isSelected: Bool
    let isEmphasized: Bool
    let actionsEnabled: Bool
    let removalEnabled: Bool
    let scheduleArmed: Bool
    let compact: Bool
    let usesNativeReordering: Bool
    private var store: DownloadStore { context.store }
    private var task: DownloadRowPresentation { row.presentation }
    private var highlighted: Bool { isSelected && isEmphasized }
    private var primaryColor: Color {
        Color(nsColor: highlighted ? .alternateSelectedControlTextColor : .labelColor)
    }
    private var secondaryColor: Color {
        highlighted ? primaryColor.opacity(0.80) : Color(nsColor: .secondaryLabelColor)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row === rhs.row && lhs.isSelected == rhs.isSelected &&
        lhs.isEmphasized == rhs.isEmphasized &&
        lhs.actionsEnabled == rhs.actionsEnabled && lhs.removalEnabled == rhs.removalEnabled &&
        lhs.scheduleArmed == rhs.scheduleArmed && lhs.compact == rhs.compact &&
        lhs.usesNativeReordering == rhs.usesNativeReordering &&
        lhs.context.window?.detailsPresented == rhs.context.window?.detailsPresented
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 16) {
                identity.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                DownloadTaskLiveProgress(row: row, compact: compact).frame(width: 180)
                if !compact {
                    DownloadTaskLiveRates(row: row, compact: false)
                        .frame(width: 188, alignment: .trailing)
                }
                HStack(spacing: 4) {
                    ZStack { primaryAction }.frame(width: 24, height: 28)
                    rowAction(.details)
                    rowAction(.remove).disabled(!removalEnabled)
                }
            }
            if compact, task.showsTransferRates {
                DownloadTaskLiveRates(row: row, compact: true)
                    .padding(.leading, 44)
            }
        }
        // Keep content contrast tied to real selection/focus, independently of
        // transient native hosting updates while live values are redrawn.
        .foregroundStyle(primaryColor, secondaryColor)
        .frame(maxWidth: .infinity, minHeight: compact ? 48 : 44)
        .padding(.vertical, 7)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 44 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        .contentShape(Rectangle())
        .modifier(QueueReordering(store: store, taskID: task.id,
            canReorder: task.canReorderInQueue, enabled: !usesNativeReordering))
        .help(taskHelp)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-row-\(task.id)")
        .onChange(of: task.status) { previous, current in
            if previous != .completed && current == .completed { completionCount += 1 }
        }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            DownloadTaskIcon(name: task.name, isTorrentLike: task.isTorrentLike, size: 32)
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                Text(task.name).font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("task-\(task.id)-name")
                HStack(spacing: 5) {
                    Label {
                        Text(task.phaseLabel).contentTransition(.opacity)
                    } icon: {
                        Image(systemName: task.statusSymbol)
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : completionCount)
                    }
                        .stateChangeMotion(task.phaseLabel)
                        .foregroundStyle((task.status == .failed || task.torrentFileIssue != nil) && !highlighted ? Color.red : secondaryColor)
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
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .stateChangeMotion(action.symbolName)
            }
            .buttonStyle(.borderless).controlSize(.small)
            .disabled(!actionsEnabled).help(action.helpTitle)
            .accessibilityIdentifier("task-\(task.id)-\(action.accessibilityName)-button")
        } else if task.status == .completed {
            Button(String(localized: "Show in Finder"), systemImage: "magnifyingglass") { store.showInFinder(row.task) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
                .help(String(localized: "Show in Finder"))
                .disabled(!task.canRevealInFinder)
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
        // Tooltips describe the item. Live counters already have visible and
        // accessible fields; replacing the whole row's tooltip each second
        // needlessly invalidates native hover/selection content.
        var lines = [task.name, task.phaseLabel]
        if let error = task.errorMessage, task.status == .failed { lines.append(error) }
        if let issue = task.torrentFileIssue { lines.append(issue.explanation) }
        if let date = task.scheduledStart { lines.append(scheduleDescription(date)) }
        return lines.joined(separator: "\n")
    }
}

private struct DownloadTaskLiveProgress: View {
    let row: DownloadRowState
    let compact: Bool
    private var task: DownloadTask { row.task }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            HStack(spacing: 6) {
                Group {
                    if task.totalLength > 0, task.media == nil, task.status != .completed, !task.isSharing {
                        TransferSizeValue(completed: task.completedLength, total: task.totalLength)
                    } else {
                        Text(DownloadListTaskDisplay(task: task).sizeLabel).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                TaskProgressValue(task: task).foregroundStyle(.secondary)
                    .opacity(task.progressLabel == "—" ? 0 : 1)
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
}

private struct DownloadTaskLiveRates: View {
    let row: DownloadRowState
    let compact: Bool
    var body: some View { DownloadTaskTransferSummary(task: row.task, compact: compact) }
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
        return TransferSpeedLabel(speed: speed, uploading: uploading)
            .foregroundStyle(uploading && !task.isSharing ? .secondary : .primary)
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .accessibilityIdentifier("task-\(task.id)-\(uploading ? "upload" : "download")-speed")
    }

    private var remainingTime: some View {
        let remaining = TaskInspectorDisplay(task: task).remainingTime
        let value = remaining.map { String(localized: "ETA \($0)") } ?? ""
        return StableMetricText(value: value,
            reference: String(localized: "ETA \(ByteFormat.duration(999 * 3_600 + 59 * 60))"))
            .foregroundStyle(.secondary)
            .opacity(remaining == nil ? 0 : 1).accessibilityHidden(remaining == nil)
            .accessibilityIdentifier("task-\(task.id)-eta")
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
        if task.isTorrentLike { DownloadActionButton(action: .findTorrentSources, context: context) }
        if task.canRetryMedia { DownloadActionButton(action: .retryMedia, context: context) }
        if task.canEditAndAddAgain { DownloadActionButton(action: .editAgain, context: context) }
        if task.queuePosition != nil { DownloadActionButton(action: .moveToTop, context: context) }
        DownloadActionButton(action: .remove, context: context)
    }
}
