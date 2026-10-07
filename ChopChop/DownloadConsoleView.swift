import AppKit
import SwiftUI

struct DownloadConsoleView: View {
    @EnvironmentObject private var store: DownloadStore
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var presentedAlert: UserFacingAlert?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarSelection: SidebarDestination?
    @State private var isAddPanelPresented = false
    @State private var suppressRemovalConfirmationAfterChoice = false
    @State private var isInspectorPresented = false

    private var removalDialogBinding: Binding<Bool> {
        Binding(
            get: { store.removalRequest != nil },
            set: { isPresented in
                if !isPresented {
                    store.cancelRemoval()
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DownloadSidebar(selection: $sidebarSelection)
        } detail: {
            DownloadCanvas(destination: currentDestination)
                .navigationTitle(currentDestination.rawValue)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            scheduleAddDownloadPanelPresentation()
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .labelStyle(.iconOnly)
                        .help("Add Download")
                        .accessibilityIdentifier("toolbar-add-button")
                    }

                    ToolbarSpacer(.fixed, placement: .primaryAction)

                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            pasteClipboardIntoDraft()
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        .labelStyle(.iconOnly)
                        .help("Paste Download Link")
                        .accessibilityIdentifier("toolbar-paste-button")

                        Button {
                            runStoreTask { await store.refreshTasks() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .labelStyle(.iconOnly)
                        .disabled(!store.canStopEngine)
                        .help("Refresh Downloads")
                        .accessibilityIdentifier("toolbar-refresh-button")
                    }

                    ToolbarSpacer(.fixed, placement: .primaryAction)

                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Pause All") { runStoreTask { await store.pauseAll() } }
                                .disabled(!store.canStopEngine)
                            Button("Force Pause All") { runStoreTask { await store.forcePauseAll() } }
                                .disabled(!store.canStopEngine)
                            Button("Resume All") { runStoreTask { await store.resumeAll() } }
                                .disabled(!store.canStopEngine)
                            Divider()
                            Button("Clear Finished Records", role: .destructive) {
                                runStoreTask { await store.purgeCompletedRecords() }
                            }
                            .disabled(!store.canStopEngine)
                            Divider()
                            Menu("Engine") {
                                Button("Start Engine") { runStoreTask { await store.startEngine() } }
                                    .disabled(!store.canStartEngine)
                                Button("Restart Engine") { runStoreTask { await store.restartEngine() } }
                                    .disabled(!store.canRestartEngine)
                                Button("Stop Engine") { runStoreTask { await store.stopEngine() } }
                                    .disabled(!store.canStopEngine)
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis")
                        }
                        .labelStyle(.iconOnly)
                        .help("More Actions")
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) {
                        Toggle(isOn: $isInspectorPresented) {
                            Label("Details", systemImage: "sidebar.right")
                        }
                        .toggleStyle(.button)
                        .disabled(store.selectedTask == nil)
                        .help(isInspectorPresented ? "Hide Details" : "Show Details")
                        .accessibilityIdentifier("toolbar-inspector-button")
                    }
                }
                .searchable(text: $store.searchQuery, placement: .toolbar, prompt: "Search downloads")
                .inspector(isPresented: $isInspectorPresented) {
                    if let task = store.selectedTask {
                        TaskInspectorView(task: task)
                            .environmentObject(store)
                            .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                    }
                }
        }
        .sheet(isPresented: $isAddPanelPresented) {
            AddDownloadPanel(onDismiss: dismissAddDownloadPanel)
                .environmentObject(store)
        }
        .onChange(of: isAddPanelPresented) { _, isPresented in
            guard !isPresented else { return }
            Task { @MainActor in
                await store.cancelBitTorrentFileSelection()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .focusedSceneValue(\.downloadWindowActions, DownloadWindowActions(
            newDownload: scheduleAddDownloadPanelPresentation,
            pasteDownload: pasteClipboardIntoDraft,
            toggleInspector: { isInspectorPresented.toggle() },
            inspectorPresented: isInspectorPresented,
            hasSelection: store.selectedTask != nil,
            canPresentDownload: !isAddPanelPresented && !store.engineSetupState.requiresInstallation
        ))
        .onChange(of: store.selectedTaskID) { _, id in
            isInspectorPresented = id != nil
        }
        .onAppear {
            if sidebarSelection == nil {
                sidebarSelection = store.selectedDestination
            }
            store.publishStartupAlerts()
            isInspectorPresented = store.selectedTask != nil
        }
        .onChange(of: sidebarSelection) { _, destination in
            guard let destination else { return }
            Task { @MainActor in
                guard store.selectedDestination != destination else { return }
                store.selectedDestination = destination
            }
        }
        .onReceive(store.userAlerts) { alert in
            guard controlActiveState == .key, !isAddPanelPresented else { return }
            guard store.claimAlert(alert) else { return }
            presentedAlert = alert
        }
        .onReceive(store.addPanelRequests) { _ in
            scheduleAddDownloadPanelPresentation()
        }
        .onChange(of: store.removalRequest?.id) { _, requestID in
            if requestID != nil {
                suppressRemovalConfirmationAfterChoice = false
            }
        }
        .confirmationDialog(
            "Remove Download?",
            isPresented: removalDialogBinding,
            titleVisibility: .visible,
            presenting: store.removalRequest
        ) { request in
            Button("Remove from List", role: .destructive) {
                runStoreTask {
                    await store.confirmRemoval(
                        request,
                        includingFiles: false,
                        suppressFutureConfirmation: suppressRemovalConfirmationAfterChoice
                    )
                }
            }
            Button("Move Files to Trash and Remove", role: .destructive) {
                runStoreTask {
                    await store.confirmRemoval(
                        request,
                        includingFiles: true,
                        suppressFutureConfirmation: suppressRemovalConfirmationAfterChoice
                    )
                }
            }
            .disabled(!request.task.hasReportedTrashableFiles)
            Button("Cancel", role: .cancel) {
                suppressRemovalConfirmationAfterChoice = false
                store.cancelRemoval(request)
            }
        } message: { request in
            Text("\"\(request.task.name)\" will be removed from Aria2 Next. You can keep downloaded files or move the files reported by Aria2 Next to Trash.")
        }
        .dialogIcon(Image(systemName: "trash"))
        .dialogSeverity(.standard)
        .dialogSuppressionToggle("Do not ask again", isSuppressed: $suppressRemovalConfirmationAfterChoice)
        .alert(item: $presentedAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func runStoreTask(_ operation: @escaping @MainActor () async -> Void) {
        DispatchQueue.main.async {
            Task { @MainActor in
                await operation()
            }
        }
    }

    private func scheduleAddDownloadPanelPresentation() {
        DispatchQueue.main.async {
            presentAddDownloadPanel()
        }
    }

    private func presentAddDownloadPanel() {
        store.prepareAddDraftForPresentation()
        isAddPanelPresented = true
    }

    private func dismissAddDownloadPanel() {
        isAddPanelPresented = false
    }

    private var currentDestination: SidebarDestination {
        sidebarSelection ?? store.selectedDestination
    }

    private func pasteClipboardIntoDraft() {
        guard let pasted = NSPasteboard.general.string(forType: .string),
              !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.postError("Clipboard does not contain a download link.", title: "Paste Failed")
            return
        }
        DispatchQueue.main.async {
            store.addDraft.rawInput = pasted
            presentAddDownloadPanel()
        }
    }
}

private struct DownloadSidebar: View {
    @EnvironmentObject private var store: DownloadStore
    @Binding var selection: SidebarDestination?

    private let library: [SidebarDestination] = [.today, .all, .active, .waiting, .completed, .failed]
    private let smartCollections: [SidebarDestination] = [.torrents, .ed2k, .browserCapture]

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Downloads") {
                    ForEach(library) { destination in
                        SidebarRow(destination: destination, count: store.count(for: destination))
                            .tag(destination)
                    }
                }
                Section("Smart Collections") {
                    ForEach(smartCollections) { destination in
                        SidebarRow(destination: destination, count: store.count(for: destination))
                            .tag(destination)
                    }
                }
            }
            .listStyle(.sidebar)

            SidebarQuickStatsCard()
                .environmentObject(store)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 320)
    }
}

private struct SidebarRow: View {
    var destination: SidebarDestination
    var count: Int

    var body: some View {
        Label(destination.rawValue, systemImage: destination.symbolName)
            .badge(count)
            .accessibilityLabel(destination.rawValue)
            .accessibilityValue(count > 0 ? "\(count)" : "")
            .accessibilityIdentifier(destination.accessibilityIdentifier)
    }
}

private struct SidebarQuickStatsCard: View {
    @EnvironmentObject private var store: DownloadStore
    @Environment(\.openSettings) private var openSettings

    private var totalConnections: Int {
        store.tasks.reduce(0) { $0 + $1.connections }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Quick Stats")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("10 min")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            SpeedSparkline(samples: store.recentSpeedSamples, height: 32)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("sidebar-speed-curve")

            Divider()

            SidebarQuickStatRow(
                title: "Network",
                value: ByteFormat.speed(store.activeSpeed),
                systemImage: "waveform.path.ecg",
                tint: .accentColor,
                accessibilityIdentifier: "sidebar-quick-stats-network-row"
            )

            SidebarQuickStatRow(
                title: "Connections",
                value: "\(totalConnections)",
                systemImage: "wifi",
                tint: .gray,
                accessibilityIdentifier: "sidebar-quick-stats-connections-row"
            )

            Divider()

            engineSettingsButton
        }
        .padding(12)
        .contentPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-quick-stats-card")
    }

    private var engineSettingsButton: some View {
        Button {
            store.requestEngineSettings()
            openSettings()
        } label: {
            VStack(spacing: 10) {
                SidebarQuickStatRow(
                    title: "Engine",
                    value: store.engineSidebarVersionDescription,
                    systemImage: store.availableEngineUpdate == nil ? "cpu" : "arrow.up.circle.fill",
                    tint: store.availableEngineUpdate == nil ? .purple : .accentColor,
                    accessibilityIdentifier: "sidebar-quick-stats-engine-version-row",
                    helpText: engineSettingsHelp
                )
                SidebarQuickStatRow(
                    title: "Status",
                    value: runtimeStatusLabel,
                    systemImage: runtimeStatusSymbol,
                    tint: runtimeStatusTint,
                    accessibilityIdentifier: "sidebar-quick-stats-engine-status-row",
                    helpText: store.availableEngineUpdate == nil ? runtimeStatusHelp : engineSettingsHelp,
                    showsUpdateBadge: store.availableEngineUpdate != nil && !store.isUpdatingEngine
                )
                .frame(minHeight: 22)
                if let progress = store.engineUpgradeProgress {
                    ProgressView(value: progress.fractionCompleted)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(progress.title)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(engineSettingsHelp)
        .accessibilityLabel("Engine \(store.engineSidebarVersionDescription). \(runtimeStatusLabel)")
        .accessibilityHint(engineSettingsHelp)
        .accessibilityIdentifier("sidebar-engine-settings-button")
    }

    private var engineSettingsHelp: String {
        if let progress = store.engineUpgradeProgress { return "\(progress.title) Open Engine settings for details." }
        if let release = store.availableEngineUpdate {
            return "Aria2 Next \(release.version) is available. Open Engine settings to update."
        }
        return "Open Engine settings in ChopChop"
    }

    private var runtimeStatusLabel: String {
        if let progress = store.engineUpgradeProgress {
            return progress.sidebarDescription
        }
        if let status = store.engineSetupState.statusLabel { return status }
        return switch store.runtime.phase {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .running:
            "Running"
        case .stopping:
            "Stopping"
        case .failed:
            "Failed"
        }
    }

    private var runtimeStatusSymbol: String {
        if store.isUpdatingEngine { return "arrow.down.circle" }
        if case .failed = store.engineSetupState { return "exclamationmark.triangle.fill" }
        if store.engineSetupState.requiresInstallation { return "arrow.down.circle" }
        if store.engineSetupState == .checking { return "magnifyingglass.circle" }
        return switch store.runtime.phase {
        case .stopped:
            "stop.circle"
        case .starting:
            "arrow.clockwise.circle"
        case .running:
            "checkmark.circle.fill"
        case .stopping:
            "pause.circle"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var runtimeStatusTint: Color {
        if store.isUpdatingEngine { return .accentColor }
        if case .failed = store.engineSetupState { return .red }
        if store.engineSetupState.requiresInstallation || store.engineSetupState == .checking { return .orange }
        return switch store.runtime.phase {
        case .stopped:
            .secondary
        case .starting, .stopping:
            .orange
        case .running:
            .green
        case .failed:
            .red
        }
    }

    private var runtimeStatusHelp: String? {
        switch store.runtime.phase {
        case .running(let pid):
            return "Aria2 Next is running (PID \(pid))."
        case .failed(let message):
            return message
        default:
            return store.runtime.lastError
        }
    }
}

private struct SidebarQuickStatRow: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color
    var accessibilityIdentifier: String? = nil
    var helpText: String? = nil
    var showsUpdateBadge = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            if showsUpdateBadge {
                EngineUpdateBadge()
                    .accessibilityHidden(true)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
        .help(helpText ?? "")
    }
}

private struct DownloadCanvas: View {
    @EnvironmentObject private var store: DownloadStore
    var destination: SidebarDestination

    private var visibleTasks: [DownloadTask] {
        store.visibleTasks(for: destination)
    }

    var body: some View {
        Group {
            if destination == .browserCapture {
                BrowserCaptureView()
            } else {
                VStack(spacing: 0) {
                    DownloadSummaryStrip()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    Divider()
                    List(selection: $store.selectedTaskID) {
                        ForEach(visibleTasks) { task in
                            DownloadTaskRow(task: task)
                                .tag(task.id)
                        }
                    }
                    .listStyle(.inset)
                    .accessibilityIdentifier("download-task-list")
                    .overlay {
                        if visibleTasks.isEmpty { emptyState }
                    }
                }
            }
        }
        .onChange(of: destination) { _, _ in clearHiddenSelection() }
        .onChange(of: store.searchQuery) { _, _ in clearHiddenSelection() }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var emptyState: some View {
        if !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView {
                Label("No Matching Downloads", systemImage: "magnifyingglass")
            } description: {
                Text("Try a different name or save location.")
            } actions: {
                Button("Clear Search") { store.searchQuery = "" }
            }
        } else {
            EmptyContentState(
                title: "No Downloads",
                message: "Add a download link to get started. Your downloads in this category will appear here.",
                systemImage: destination.symbolName,
                actionTitle: "Add Download…",
                action: { store.requestAddPanel() }
            )
        }
    }

    private func clearHiddenSelection() {
        guard let id = store.selectedTaskID else { return }
        if !visibleTasks.contains(where: { $0.id == id }) { store.selectedTaskID = nil }
    }
}

private struct DownloadSummaryStrip: View {
    @EnvironmentObject private var store: DownloadStore

    private var totalSize: Int64 {
        store.tasks.reduce(0) { $0 + max(0, $1.totalLength) }
    }

    var body: some View {
        HStack(spacing: 0) {
            DownloadSummaryItem(
                title: "Active",
                value: "\(store.count(for: .active))",
                subtitle: "In progress",
                systemImage: "waveform.path.ecg",
                tint: .accentColor
            )

            Divider()
                .padding(.vertical, 16)

            DownloadSummaryItem(
                title: "Completed",
                value: "\(store.count(for: .completed))",
                subtitle: ByteFormat.size(completedSize),
                systemImage: "checkmark.circle.fill",
                tint: .green
            )

            Divider()
                .padding(.vertical, 16)

            DownloadSummaryItem(
                title: "Total Size",
                value: ByteFormat.size(totalSize),
                subtitle: "\(store.tasks.count) items",
                systemImage: "externaldrive.fill",
                tint: .purple
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .contentPanel()
        .accessibilityIdentifier("download-summary-strip")
    }

    private var completedSize: Int64 {
        store.tasks
            .filter { $0.status == .completed }
            .reduce(0) { $0 + max(0, $1.totalLength) }
    }
}

private struct DownloadSummaryItem: View {
    var title: String
    var value: String
    var subtitle: String
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DownloadTaskRow: View {
    @EnvironmentObject private var store: DownloadStore
    var task: DownloadTask

    private var isSelected: Bool {
        store.selectedTaskID == task.id
    }

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.name)
                            .font(.headline)
                            .lineLimit(1)
                            .accessibilityIdentifier("task-\(task.id)-name")
                        Text(detailLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 12)

                    trailingStatus
                }

                ProgressView(value: task.progress)
                    .progressViewStyle(.linear)
                    .tint(task.status.tint)

                HStack(spacing: 8) {
                    Text("\(ByteFormat.size(task.completedLength)) / \(ByteFormat.size(task.totalLength))")
                    Text("·")
                    Text("\(task.connections) connections")
                    if let etaLabel {
                        Text("·")
                        Text(etaLabel)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Divider()
                .frame(height: 54)

            actionButtons
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            if let action = task.primaryControlAction {
                Button(action.helpTitle) {
                    Task {
                        if action == .pause { await store.pause(task) }
                        else { await store.resume(task) }
                    }
                }
            }
            Button("Remove Download…", role: .destructive) { store.beginRemove(task) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-row-\(task.id)")
    }

    private var icon: some View {
        Image(systemName: task.protocolKind.symbolName)
            .font(.title2.weight(.semibold))
            .foregroundStyle(isSelected ? Color.primary : task.status.tint)
            .frame(width: 32, height: 32)

    }

    private var trailingStatus: some View {
        VStack(alignment: .trailing, spacing: 5) {
            if task.status == .active {
                Text(ByteFormat.speed(task.downloadSpeed))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            } else {
                StatusBadge(status: task.status, isSelected: isSelected)
                    .accessibilityIdentifier("task-\(task.id)-status")
            }

            Text("\(Int(task.progress * 100))%")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(width: 92, alignment: .trailing)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if let controlAction = task.primaryControlAction {
                Button {
                    Task {
                        switch controlAction {
                        case .pause:
                            await store.pause(task)
                        case .resume:
                            await store.resume(task)
                        }
                    }
                } label: {
                    Label("\(controlAction.helpTitle) \(task.name)", systemImage: controlAction.symbolName)
                        .labelStyle(.iconOnly)
                }
                .help(controlAction.helpTitle)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("\(controlAction.helpTitle) \(task.name)")
                .accessibilityIdentifier("task-\(task.id)-\(controlAction.helpTitle.lowercased())-button")
            }

            Button(role: .destructive) {
                store.beginRemove(task)
            } label: {
                Label("Remove \(task.name)", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .help("Remove")
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Remove \(task.name)")
            .accessibilityIdentifier("task-\(task.id)-remove-button")
        }
        .controlSize(.regular)
    }

    private var detailLine: String {
        let destination = task.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return task.protocolKind.rawValue }
        return "\(task.protocolKind.rawValue) · \(destination)"
    }

    private var etaLabel: String? {
        guard task.status == .active, task.downloadSpeed > 0 else { return nil }
        let remainingBytes = max(0, task.totalLength - task.completedLength)
        guard remainingBytes > 0 else { return nil }
        let seconds = Int(ceil(Double(remainingBytes) / Double(task.downloadSpeed)))
        return "ETA \(ByteFormat.duration(seconds))"
    }


}

private struct BrowserCaptureView: View {
    @EnvironmentObject private var store: DownloadStore

    var body: some View {
        ContentUnavailableView {
            Label("Browser Capture Is Unavailable", systemImage: "globe")
        } description: {
            Text("This version doesn't include a browser extension. Copy a download link from your browser and add it to ChopChop.")
        } actions: {
            Button("Add Download…") { store.requestAddPanel() }
                .buttonStyle(.borderedProminent)
        }
    }
}
