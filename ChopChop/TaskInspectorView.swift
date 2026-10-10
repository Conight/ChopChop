import AppKit
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case files = "Files"
    case network = "Network"
    case logs = "Logs"

    var localizedTitle: String { L10n.key(rawValue) }

    var id: String { rawValue }
}

/// System-drawn capsule tabs with equal segment widths. AppKit retains keyboard,
/// focus-ring and accessibility behavior; SwiftUI owns only the selected page.
struct TaskInspectorTabs: NSViewRepresentable {
    @Binding var selection: InspectorTab

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: InspectorTab.allCases.map(\.localizedTitle),
            trackingMode: .selectOne, target: context.coordinator,
            action: #selector(Coordinator.selectTab(_:)))
        control.segmentStyle = .automatic
        control.borderShape = .capsule
        control.controlSize = .large
        control.segmentDistribution = .fillEqually
        if #available(macOS 27.0, *) { control.role = .tabs }
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel(String(localized: "Inspector"))
        control.setAccessibilityIdentifier("details-tabs")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        for (index, tab) in InspectorTab.allCases.enumerated() {
            control.setLabel(tab.localizedTitle, forSegment: index)
        }
        control.selectedSegment = InspectorTab.allCases.firstIndex(of: selection) ?? 0
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: nsView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject {
        var selection: Binding<InspectorTab>
        init(selection: Binding<InspectorTab>) { self.selection = selection }

        @objc func selectTab(_ sender: NSSegmentedControl) {
            guard InspectorTab.allCases.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = InspectorTab.allCases[sender.selectedSegment]
        }
    }
}

struct TaskInspectorView: View {
    @EnvironmentObject private var store: DownloadStore
    @State private var showsSpeedLimits = false
    @State private var localTab: InspectorTab
    private var tabSelection: Binding<InspectorTab>?
    private var selection: Binding<InspectorTab> { tabSelection ?? $localTab }
    private var tab: InspectorTab { selection.wrappedValue }
    var task: DownloadTask
    var sectionRequest: TaskDetailRequest?

    init(task: DownloadTask, initialTab: InspectorTab = .overview, selection: Binding<InspectorTab>? = nil, sectionRequest: TaskDetailRequest? = nil) {
        self.task = task
        self.sectionRequest = sectionRequest
        _localTab = State(initialValue: initialTab)
        tabSelection = selection
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, AppLayout.detailInset)
                .padding(.top, AppLayout.detailInset)
                .padding(.bottom, AppLayout.detailSectionSpacing)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("details-header")
            TaskInspectorTabs(selection: selection)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, AppLayout.detailInset)
                .padding(.bottom, AppLayout.detailTabSpacing)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: AppLayout.detailSectionSpacing) {
                        switch tab {
                        case .overview: overview
                        case .files: files
                        case .network: network
                        case .logs: logs
                        }
                    }
                    .id(task.id) // Reset task-specific editors, keeping the surrounding tabs and window stable.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppLayout.detailInset)
                    .padding(.bottom, AppLayout.detailInset)
                }
                .onChange(of: sectionRequest, initial: true) { _, request in
                    guard let request else { return }
                    Task { @MainActor in
                        await Task.yield()
                        if request.section == .speedLimits { showsSpeedLimits = true }
                        proxy.scrollTo(request.section, anchor: .top)
                    }
                }
            }
            .accessibilityIdentifier("details-content")
        }
        .background { DownloadWorkspaceBackdrop().ignoresSafeArea() }
        .onChange(of: task.id) { _, _ in showsSpeedLimits = false }
        .desktopControls()
        .buttonStyle(.bordered)
        .task(id: task.id) {
            await store.refreshDetails(for: task.id)
        }
        .onChange(of: tab) { _, newTab in
            guard newTab == .network else { return }
            Task { await store.refreshDetails(for: task.id) }
        }
    }

    private var header: some View {
        VStack(spacing: AppLayout.detailSectionSpacing) {
            HStack(alignment: .top, spacing: AppLayout.detailSectionSpacing) {
                DownloadTaskIcon(task: task, size: 88)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.name)
                            .font(AppTypography.windowTitle)
                            .lineLimit(2).truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled).help(task.name)
                        Text(display.sourceHost ?? taskLocation)
                            .font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(display.sourceHost ?? taskLocation)
                    }
                    HStack(spacing: 10) {
                        Text(task.protocolKind.rawValue)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        Label(task.phaseLabel, systemImage: DownloadListTaskDisplay(task: task).statusSymbol)
                            .font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 12) {
                            TaskProgressIndicator(task: task)
                            Text(task.progressLabel)
                                .font(.callout.weight(.semibold)).monospacedDigit()
                                .fixedSize()
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                Text(task.transferSizeLabel)
                                if task.status == .active {
                                    Text("·")
                                    Text(ByteFormat.speed(task.downloadSpeed))
                                }
                            }.fixedSize()
                            Text(task.transferSizeLabel)
                        }
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) { overviewActions }
                .controlSize(.large)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("details-actions")
        }
    }

    private var display: TaskInspectorDisplay { TaskInspectorDisplay(task: task) }
    private var taskLocation: String {
        let path = DownloadLocationDisplay.taskPath(task)
        return path.isEmpty ? String(localized: "No destination reported") : path
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: AppLayout.detailSectionSpacing) {
            if let issue = task.torrentFileIssue {
                VStack(alignment: .leading, spacing: 10) {
                    Label(issue.explanation, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if task.isAvailableInEngine, store.engineCapabilities?.supportsTorrentManagement == true {
                        Button(String(localized: "Recheck Downloaded Pieces")) {
                            Task { await store.recheckTorrent(task) }
                        }
                        .disabled(store.isUpdatingEngine)
                    }
                }.contentPanel()
            }
            if let error = task.errorMessage, task.status == .failed {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentPanel()
            }
            GroupBox {
                VStack(spacing: 0) {
                    if let source = display.sourceAddress {
                        informationRow(String(localized: "Source"), source)
                    }
                    informationRow(String(localized: "Save location"), taskLocation, symbol: "folder")
                    informationRow(String(localized: "Size"), task.totalLength > 0 ? ByteFormat.size(task.totalLength) : String(localized: "Unknown"))
                    informationRow(String(localized: "Downloaded"), task.transferSizeLabel)
                    informationRow(String(localized: "Download speed"), ByteFormat.speed(task.status == .active ? task.downloadSpeed : 0))
                    if task.isTorrentLike {
                        informationRow(String(localized: "Upload speed"), ByteFormat.speed(task.status == .active ? task.uploadSpeed : 0))
                    }
                    if let remaining = display.remainingTime {
                        informationRow(String(localized: "Time remaining"), remaining)
                    }
                    informationRow(String(localized: "Connections"), task.connections.formatted())
                    informationRow(task.addedAtIsFirstSeen ? String(localized: "First recorded") : String(localized: "Added"),
                                   task.addedAt.formatted(date: .abbreviated, time: .shortened), divider: false)
                }.padding(.horizontal, 12).padding(.vertical, 4)
            }
            if task.media != nil { MediaTaskActions(task: task).labelStyle(.titleOnly) }
            if task.canRepairConnection || canSchedule {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "Task settings")).font(AppTypography.sectionTitle)
                    VStack(alignment: .leading, spacing: 12) {
                        if canSchedule {
                            DisclosureGroup(String(localized: "Speed Limits"), isExpanded: $showsSpeedLimits) {
                                TaskBandwidthView(task: task).padding(.top, AppLayout.controlSpacing)
                            }.id(TaskDetailSection.speedLimits)
                            Divider()
                        }
                        if task.canRepairConnection { DownloadRepairView(task: task) }
                        if task.canRepairConnection && canSchedule { Divider() }
                        if canSchedule {
                            TaskScheduleView(task: task, initiallyExpanded: sectionRequest?.section == .schedule)
                                .id(sectionRequest?.section == .schedule)
                                .id(TaskDetailSection.schedule)
                        }
                    }.contentPanel()
                }
            }
        }
    }

    private func informationRow(_ title: String, _ value: String, symbol: String? = nil, divider: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).foregroundStyle(.secondary).frame(width: AppLayout.detailLabelWidth, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(Color.accentColor) }
                    Text(value).textSelection(.enabled)
                        .lineLimit(3).truncationMode(.middle).help(value)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout).monospacedDigit()
            .padding(.vertical, 9)
            if divider { Divider() }
        }
    }

    private var canSchedule: Bool {
        task.isAvailableInEngine && task.primaryControlAction != nil && !task.requiresFileSelection
    }

    private var commandContext: DownloadActionContext { DownloadActionContext(store: store, taskID: task.id) }

    @ViewBuilder
    private var overviewActions: some View {
        if let action = task.primaryControlAction {
            if action == .resume { controlButton(for: action).buttonStyle(.borderedProminent) }
            else { controlButton(for: action) }
        }
        DownloadActionButton(action: .reveal, context: commandContext)
            .help(String(localized: "Show in Finder"))
        Menu {
            if task.canEditAndAddAgain {
                DownloadActionButton(action: .editAgain, context: commandContext)
                Divider()
            }
            DownloadActionButton(action: .remove, context: commandContext)
        } label: {
            Label(String(localized: "More Actions"), systemImage: "ellipsis")
        }
        .menuStyle(.borderedButton).labelStyle(.iconOnly).fixedSize()
        .help(String(localized: "More Actions"))
    }

    private func controlButton(for action: DownloadTaskControlAction) -> some View {
        Button {
            (action == .pause ? DownloadAction.pause : .resume).perform(in: commandContext)
        } label: {
            Label(action.helpTitle, systemImage: action.symbolName)
        }
        .disabled(!(action == .pause ? DownloadAction.pause : .resume).isEnabled(in: commandContext))
        .help(action.helpTitle)
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: AppLayout.rowSpacing) {
            if task.isTorrentLike, task.isAvailableInEngine, task.primaryControlAction != nil,
               !task.files.isEmpty, !task.isFetchingMetadata, store.engineCapabilities?.supportsTorrentManagement == true {
                BitTorrentManagementView(task: task).id(task.id)
            } else if task.files.isEmpty {
                Text(String(localized: "No file list reported by Aria2 Next yet."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentPanel()
            } else {
                DownloadFilesTable(files: task.files, directory: task.torrentDirectory ?? task.destination).id(task.id)
            }
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: AppLayout.rowSpacing) {
            if task.isTorrentLike {
                HStack {
                    Button(String(localized: "Refresh Details")) { Task { await store.refreshDetails(for: task.id) } }
                    if store.engineCapabilities?.supportsTorrentManagement == true, task.isAvailableInEngine {
                        Button(String(localized: "Announce Now")) { Task { await store.reannounceTorrent(task) } }.disabled(task.status != .active)
                    }
                }.controlSize(.small)
                if let diagnostics = task.torrentDiagnostics { BitTorrentDiagnosticsView(diagnostics: diagnostics) }
                TransferDetailsView(task: task).id(task.id)
                networkSection(title: String(localized: "Trackers"), emptyMessage: String(localized: "No tracker state reported yet."), rows: task.trackers.map { "\($0.status) · \($0.url)" })
            } else if task.protocolKind == .ed2k {
                networkSection(
                    title: String(localized: "Sources"),
                    emptyMessage: String(localized: "No ED2K source details reported yet."),
                    rows: task.recentLogs.filter { $0.hasPrefix(String(localized: "Servers:")) || $0.hasPrefix(String(localized: "Connected servers:")) || $0.hasPrefix(String(localized: "Sources:")) || $0.hasPrefix("Kad") }
                )
                networkSection(
                    title: String(localized: "Hash"),
                    emptyMessage: String(localized: "Hash verification details will appear after Aria2 Next reports them."),
                    rows: task.recentLogs.filter { $0.hasPrefix(String(localized: "ED2K hash:")) }
                )
            } else if task.media != nil {
                Text(String(localized: "Media uses its own segment scheduler. Track its stage and duration in Overview."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TransferDetailsView(task: task).id(task.id)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentPanel()
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: AppLayout.rowSpacing) {
            if let error = task.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentPanel()
            }

            if task.recentLogs.isEmpty {
                Text(String(localized: "No task logs reported."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentPanel()
            } else {
                ForEach(Array(task.recentLogs.enumerated()), id: \.offset) { offset, log in
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
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

/// Display-only source details never expose credentials or signed query parameters.
nonisolated struct TaskInspectorDisplay {
    let task: DownloadTask

    private var source: URLComponents? {
        guard let raw = task.sourceURL, let parts = URLComponents(string: raw),
              ["http", "https", "sftp"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty else { return nil }
        return parts
    }

    var sourceHost: String? { source?.host }

    var sourceAddress: String? {
        guard var parts = source else { return nil }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        return parts.string
    }

    var remainingTime: String? {
        guard task.status == .active, task.isAvailableInEngine, task.media == nil, !task.isSharing,
              task.progressState.fraction != nil, task.downloadSpeed > 0,
              task.totalLength > task.completedLength, task.completedLength >= 0 else { return nil }
        let seconds = ceil(Double(task.totalLength - task.completedLength) / Double(task.downloadSpeed))
        guard seconds.isFinite, seconds < Double(Int.max) else { return nil }
        return ByteFormat.duration(Int(seconds))
    }
}
