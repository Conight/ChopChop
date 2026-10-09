import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DownloadConsoleView: View {
    var supportNavigation: AppSupportNavigation?
    var updates: AppUpdateCoordinator?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @StateObject private var commandSearch = CommandSearchPresentation()
    @ObservedObject var inputCoordinator: DownloadInputCoordinator
    @EnvironmentObject private var store: DownloadStore
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var presentedAlert: UserFacingAlert?
    @State private var sidebarSelection: SidebarDestination?
    @State private var isAddPanelPresented = false
    @State private var windowID = UUID()
    @State private var isDropTargeted = false
    @State private var suppressRemovalConfirmationAfterChoice = false
    @StateObject private var detailsPresentation = TaskDetailsPresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(inputCoordinator: DownloadInputCoordinator, presentation: TaskDetailsPresentation = TaskDetailsPresentation(), updates: AppUpdateCoordinator? = nil, supportNavigation: AppSupportNavigation? = nil) {
        self.supportNavigation = supportNavigation
        self.updates = updates
        _inputCoordinator = ObservedObject(wrappedValue: inputCoordinator)
        _detailsPresentation = StateObject(wrappedValue: presentation)
    }

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
        NavigationSplitView(columnVisibility: .constant(.all)) {
            DownloadSidebar(selection: $sidebarSelection)
                .desktopControls()
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 320)
        } detail: {
            // Row disclosure changes list height, not the owning window's size.
            GeometryReader { available in
                VStack(spacing: 0) {
                    DownloadCanvas(destination: currentDestination, onPaste: pasteClipboardIntoDraft,
                                   onOpenFile: openDownloadFile, showDetails: presentDetails, toggleDetails: toggleDetails)
                        .environmentObject(detailsPresentation)
                    if showsStatusBar { DownloadStatusBar() }
                }
                .desktopControls()
                .frame(width: available.size.width, height: available.size.height)
            }
            .navigationTitle(currentDestination.localizedTitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        scheduleAddDownloadPanelPresentation()
                    } label: {
                        Label(String(localized: "Add"), systemImage: "plus")
                    }
                    .labelStyle(.iconOnly)
                    .help(String(localized: "Add Download"))
                    .accessibilityIdentifier("toolbar-add-button")

                    Button {
                        pasteClipboardIntoDraft()
                    } label: {
                        Label(String(localized: "Paste"), systemImage: "doc.on.clipboard")
                    }
                    .labelStyle(.iconOnly)
                    .help(String(localized: "Paste Download Link"))
                    .accessibilityIdentifier("toolbar-paste-button")

                }

                ToolbarSpacer(.fixed, placement: .primaryAction)

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(String(localized: "Search Commands…"), systemImage: "magnifyingglass") { presentCommandSearch() }
                        Divider()
                        ForEach([DownloadAction.refresh, .pauseAll, .forcePauseAll, .resumeAll, .clearFinished]) { action in
                            DownloadActionButton(action: action, context: commandContext)
                        }
                        Divider()
                        Menu(String(localized: "Engine")) {
                            ForEach([DownloadAction.startEngine, .restartEngine, .stopEngine, .engineSettings]) { action in
                                DownloadActionButton(action: action, context: commandContext)
                            }
                        }
                    } label: {
                        Label(String(localized: "More"), systemImage: "ellipsis")
                    }
                    .labelStyle(.iconOnly)
                    .menuIndicator(.hidden)
                    .help(String(localized: "More Actions"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: Binding(get: { detailsPresentation.isPresented }, set: { _ in toggleDetails() })) {
                        Label(String(localized: "Details"), systemImage: "info.circle")
                    }
                    .toggleStyle(.button)
                    .disabled(store.selectedTask == nil)
                    .help(detailsPresentation.isPresented ? String(localized: "Hide Details") : String(localized: "Show Details"))
                    .accessibilityIdentifier("toolbar-inspector-button")
                }
                if let updates {
                    ToolbarItem(placement: .primaryAction) {
                        AppUpdateIndicator(updates: updates)
                    }
                }
            }
            .searchable(text: $store.searchQuery, placement: .toolbar, prompt: String(localized: "Search downloads"))
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $isAddPanelPresented, onDismiss: finishAddDownloadPanel) {
            AddDownloadPanel(mediaCoordinator: store.mediaDownloads, onDismiss: dismissAddDownloadPanel)
                .environmentObject(store)
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $isDropTargeted) { providers in
            store.importDroppedItems(providers)
            return !providers.isEmpty
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .background(DownloadWindowIdentity())
        .background(TaskDetailsWindowAnchor(presentation: detailsPresentation))
        .frame(minWidth: 900, minHeight: 600)
        .focusedSceneValue(\.downloadWindowActions, windowActions)
        .onChange(of: store.selectedTask?.id, initial: true) { _, id in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                detailsPresentation.selectionChanged(to: id)
            }
        }
        .onAppear {
            if sidebarSelection == nil {
                sidebarSelection = store.selectedDestination
            }
            store.publishStartupAlerts()
            schedulePendingImport()
        }
        .onChange(of: sidebarSelection) { _, destination in
            guard let destination else { return }
            Task { @MainActor in
                guard store.selectedDestination != destination else { return }
                store.selectedDestination = destination
            }
        }
        .onReceive(store.userAlerts) { alert in
            guard controlActiveState == .key || detailsPresentation.panel?.isKeyWindow == true,
                  !isAddPanelPresented else { return }
            guard store.claimAlert(alert) else { return }
            commandSearch.dismiss(returnFocus: false)
            detailsPresentation.dismiss()
            presentedAlert = alert
        }
        .onReceive(inputCoordinator.$revision) { _ in
            commandSearch.dismiss(returnFocus: false)
            detailsPresentation.dismiss()
            schedulePendingImport()
        }
        .onChange(of: store.engineSetupState) { _, _ in schedulePendingImport() }
        .onChange(of: controlActiveState) { _, _ in schedulePendingImport() }
        .onChange(of: store.selectedDestination) { _, destination in sidebarSelection = destination }
        .onDisappear {
            commandSearch.dismiss(returnFocus: false)
            detailsPresentation.dismiss(returnFocus: false)
            guard inputCoordinator.owner == windowID else { return }
            Task { @MainActor in
                await store.cancelBitTorrentFileSelection()
                await store.cancelMediaSelection()
                store.finishDownloadPanel(owner: windowID)
            }
        }
        .onChange(of: store.removalRequest?.id) { _, requestID in
            if requestID != nil {
                detailsPresentation.dismiss()
                suppressRemovalConfirmationAfterChoice = false
            }
            else { schedulePendingImport() }
        }
        .onChange(of: presentedAlert?.id) { _, id in
            if id == nil { schedulePendingImport() }
        }
        .confirmationDialog(
            String(localized: "Remove Download?"),
            isPresented: removalDialogBinding,
            titleVisibility: .visible,
            presenting: store.removalRequest
        ) { request in
            Button(String(localized: "Remove from List"), role: .destructive) {
                runStoreTask {
                    await store.confirmRemoval(
                        request,
                        includingFiles: false,
                        suppressFutureConfirmation: suppressRemovalConfirmationAfterChoice
                    )
                }
            }
            Button(String(localized: "Move Files to Trash and Remove"), role: .destructive) {
                runStoreTask {
                    await store.confirmRemoval(
                        request,
                        includingFiles: true,
                        suppressFutureConfirmation: suppressRemovalConfirmationAfterChoice
                    )
                }
            }
            .disabled(!request.canTrashFiles)
            Button(String(localized: "Cancel"), role: .cancel) {
                suppressRemovalConfirmationAfterChoice = false
                store.cancelRemoval(request)
            }
        } message: { request in
            Text(request.message)
        }
        .dialogIcon(Image(systemName: "trash"))
        .dialogSeverity(.standard)
        .dialogSuppressionToggle(String(localized: "Do not ask again"), isSuppressed: $suppressRemovalConfirmationAfterChoice)
        .alert(item: $presentedAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var commandContext: DownloadActionContext {
        DownloadActionContext(store: store, taskID: store.selectedTaskID, window: windowActions, taskIDs: store.selectedTaskIDs)
    }

    private var windowActions: DownloadWindowActions {
        DownloadWindowActions(newDownload: scheduleAddDownloadPanelPresentation,
            pasteDownload: pasteClipboardIntoDraft, openDownloadFile: openDownloadFile,
            toggleDetails: toggleDetails, detailsPresented: detailsPresentation.isPresented,
            hasSelection: store.selectedTask != nil,
            canPresentDownload: inputCoordinator.owner == nil && !store.engineSetupState.requiresInstallation,
            showDetails: { section in
                detailsPresentation.selectionChanged(to: store.selectedTaskID)
                if let section {
                    detailsPresentation.selectedTab = .overview
                    detailsPresentation.sectionRequest = TaskDetailRequest(section: section)
                }
                presentDetails()
            }, searchCommands: presentCommandSearch,
            openEngineSettings: { store.requestEngineSettings(); openSettings() },
            checkUpdates: updates.map { updates in { @MainActor in
                openWindow(id: AppWindowID.updates)
                Task { await updates.check() }
            } },
            openDiagnostics: supportNavigation.map { navigation in { @MainActor in
                navigation.diagnosticPreviewRequested = true
                openWindow(id: AppWindowID.help)
            } },
            openHelp: { openWindow(id: AppWindowID.help) })
    }

    private func presentCommandSearch() {
        guard !isAddPanelPresented, presentedAlert == nil, store.removalRequest == nil else { return }
        detailsPresentation.dismiss()
        commandSearch.present(owner: detailsPresentation.owner, store: store) { commandContext }
    }

    private func toggleDetails() {
        if detailsPresentation.isPresented { detailsPresentation.dismiss() }
        else { presentDetails() }
    }

    private func presentDetails() {
        detailsPresentation.present(store: store) { direction in
            let ids = store.visibleTasks(for: currentDestination).map(\.id)
            if let id = TaskDetailsKeyboard.nextSelection(store.selectedTaskID, direction: direction, ids: ids) {
                store.selectedTaskID = id
            }
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
        guard !store.engineSetupState.requiresInstallation,
              inputCoordinator.claimManualSheet(owner: windowID) else { return }
        store.prepareAddDraftForPresentation()
        isAddPanelPresented = true
    }

    private func schedulePendingImport() {
        DispatchQueue.main.async {
            guard controlActiveState == .key, !isAddPanelPresented,
                  presentedAlert == nil, store.removalRequest == nil else { return }
            if inputCoordinator.hasManualRequest {
                guard store.engineSetupState == .ready else { return }
                presentAddDownloadPanel()
            } else if store.beginImportedDownload(owner: windowID) {
                isAddPanelPresented = true
            }
        }
    }

    private func finishAddDownloadPanel() {
        Task { @MainActor in
            await store.cancelBitTorrentFileSelection()
            await store.cancelMediaSelection()
            store.finishDownloadPanel(owner: windowID)
            schedulePendingImport()
        }
    }

    private func openDownloadFile() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open Download File")
        panel.prompt = String(localized: "Open")
        panel.allowedContentTypes = ["torrent", "metalink", "meta4"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            store.importDownloads(panel.urls.map(DownloadImportInput.url))
        }
    }

    private func dismissAddDownloadPanel() {
        isAddPanelPresented = false
    }

    private var showsStatusBar: Bool { currentDestination != .browserCapture }

    private var currentDestination: SidebarDestination {
        sidebarSelection ?? store.selectedDestination
    }

    private func pasteClipboardIntoDraft() {
        guard let pasted = NSPasteboard.general.string(forType: .string),
              !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.postError(String(localized: "Clipboard does not contain a download link."), title: String(localized: "Paste Failed"))
            return
        }
        store.importDownloads([.text(pasted)])
    }
}

private struct DownloadSidebar: View {
    @EnvironmentObject private var store: DownloadStore
    @Binding var selection: SidebarDestination?

    private let library: [SidebarDestination] = [.all, .active, .waiting, .completed, .failed]
    private let smartCollections: [SidebarDestination] = [.torrents, .ed2k, .browserCapture]

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section(String(localized: "Downloads")) {
                    ForEach(library) { destination in
                        SidebarRow(destination: destination, count: store.count(for: destination))
                            .tag(destination)
                    }
                }
                Section(String(localized: "Smart Collections")) {
                    ForEach(smartCollections.filter { destination in
                        switch destination {
                        case .ed2k: store.engineCapabilities?.supports(.ed2k) != false
                        case .torrents: store.engineCapabilities?.supports(.bitTorrent) != false
                        default: true
                        }
                    }) { destination in
                        SidebarRow(destination: destination, count: store.count(for: destination))
                            .tag(destination)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            GroupBox {
                SidebarActivityFooter()
                    .padding(6)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(DownloadWorkspaceBackdrop(sidebar: true))
    }
}

private struct SidebarRow: View {
    var destination: SidebarDestination
    var count: Int

    var body: some View {
        Label(destination.localizedTitle, systemImage: destination.symbolName)
            .badge(count)
            .accessibilityLabel(destination.localizedTitle)
            .accessibilityValue(count > 0 ? "\(count)" : "")
            .accessibilityIdentifier(destination.accessibilityIdentifier)
    }
}

private struct SidebarActivityFooter: View {
    @EnvironmentObject private var store: DownloadStore
    @Environment(\.openSettings) private var openSettings

    private var uploadSpeed: Int64 {
        store.tasks.filter { $0.status == .active }.reduce(0) { total, task in
            let result = total.addingReportingOverflow(max(0, task.uploadSpeed))
            return result.overflow ? .max : result.partialValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(ByteFormat.speed(store.activeSpeed), systemImage: "arrow.down")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "Download speed"))
                    .accessibilityValue(ByteFormat.speed(store.activeSpeed))
                    .accessibilityIdentifier("sidebar-quick-stats-network-row")
                Spacer(minLength: 8)
                Label(ByteFormat.speed(uploadSpeed), systemImage: "arrow.up")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "Upload speed"))
                    .accessibilityValue(ByteFormat.speed(uploadSpeed))
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            .accessibilityElement(children: .contain)
            SpeedSparkline(samples: store.recentSpeedSamples, height: 22)
                .help(String(localized: "10 min"))
                .accessibilityIdentifier("sidebar-speed-curve")
            Divider()
            engineSettingsButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-quick-stats-card")
    }

    private var engineSettingsButton: some View {
        Button {
            store.requestEngineSettings()
            openSettings()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Engine \(store.engineSidebarVersionDescription)"))
                            .font(.callout.weight(.medium)).lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .accessibilityIdentifier("sidebar-quick-stats-engine-version-row")
                        Label {
                            Text(runtimeStatusLabel).foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: runtimeStatusSymbol).foregroundStyle(runtimeStatusTint)
                        }
                        .font(.caption).lineLimit(1)
                        .accessibilityIdentifier("sidebar-quick-stats-engine-status-row")
                    }
                    Spacer(minLength: 4)
                    if store.availableEngineUpdate != nil && !store.isUpdatingEngine {
                        EngineUpdateBadge().accessibilityHidden(true)
                    } else {
                        Image(systemName: "chevron.forward").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if let progress = store.engineUpgradeProgress {
                    ProgressView(value: progress.fractionCompleted)
                        .progressViewStyle(.linear).controlSize(.small)
                        .accessibilityLabel(progress.title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(engineSettingsHelp)
        .accessibilityLabel(String(localized: "Engine \(store.engineSidebarVersionDescription). \(runtimeStatusLabel)"))
        .accessibilityHint(engineSettingsHelp)
        .accessibilityIdentifier("sidebar-engine-settings-button")
    }

    private var engineSettingsHelp: String {
        if let progress = store.engineUpgradeProgress { return String(localized: "\(progress.title) Open Engine settings for details.") }
        if let release = store.availableEngineUpdate {
            return String(localized: "Aria2 Next \(release.version.description) is available. Open Engine settings to update.")
        }
        return String(localized: "Open Engine settings in ChopChop")
    }

    private var runtimeStatusLabel: String {
        if let progress = store.engineUpgradeProgress {
            return progress.sidebarDescription
        }
        if let status = store.engineSetupState.statusLabel { return status }
        return switch store.runtime.phase {
        case .stopped:
            String(localized: "Stopped")
        case .starting:
            String(localized: "Starting")
        case .running:
            String(localized: "Running")
        case .stopping:
            String(localized: "Stopping")
        case .failed:
            String(localized: "Failed")
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

}

private struct DownloadCanvas: View {
    @EnvironmentObject private var store: DownloadStore
    @EnvironmentObject private var detailsPresentation: TaskDetailsPresentation
    var destination: SidebarDestination
    var onPaste: () -> Void
    var onOpenFile: () -> Void
    var showDetails: () -> Void
    var toggleDetails: () -> Void

    private var visibleTasks: [DownloadTask] {
        store.visibleTasks(for: destination)
    }

    var body: some View {
        Group {
            if destination == .browserCapture {
                BrowserCaptureView()
            } else {
                VStack(spacing: 0) {
                    if let issue = store.connectionIssue ?? store.historyIssue ?? store.downloadPlanIssue ?? store.bandwidthPlanIssue ?? store.batchOperationIssue {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(issue).lineLimit(3).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, AppLayout.pageInset).padding(.vertical, AppLayout.groupInset)
                        .accessibilityIdentifier("download-connection-status")
                        Divider()
                    }
                    if store.selectedTaskIDs.count > 1 {
                        HStack(spacing: 12) {
                            Text(String(localized: "\(store.selectedTaskIDs.count) selected")).foregroundStyle(.secondary)
                            Spacer()
                            let context = DownloadActionContext(store: store, taskIDs: store.selectedTaskIDs)
                            DownloadActionButton(action: .pause, context: context).labelStyle(.iconOnly)
                            DownloadActionButton(action: .resume, context: context).labelStyle(.iconOnly)
                            DownloadActionButton(action: .remove, context: context).labelStyle(.iconOnly)
                        }.padding(.horizontal, AppLayout.pageInset).padding(.vertical, 8)
                    }
                    List(selection: $store.selectedTaskIDs) {
                        ForEach(visibleTasks) { task in
                            DownloadTaskRow(store: store, detailsPresentation: detailsPresentation,
                                row: store.listPresentation.row(for: task),
                                isSelected: store.selectedTaskIDs.contains(task.id),
                                isExpanded: detailsPresentation.expandedTaskID == task.id,
                                actionsEnabled: DownloadAction.engineReady(in: store),
                                isUpdatingEngine: store.isUpdatingEngine,
                                scheduleArmed: store.armedScheduledTaskIDs.contains(task.id),
                                destination: destination, showDetails: showDetails)
                                .tag(task.id)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .onKeyPress(.space, phases: .down) { key in
                        guard key.modifiers.intersection([.command, .control, .option, .shift]).isEmpty, store.selectedTask != nil,
                              TaskDetailsKeyboard.permitsPreviewShortcut(in: detailsPresentation.owner) else { return .ignored }
                        toggleDetails()
                        return .handled
                    }
                    .onKeyPress(.escape, phases: .down) { _ in
                        guard detailsPresentation.isPresented,
                              TaskDetailsKeyboard.permitsPreviewShortcut(in: detailsPresentation.owner) else { return .ignored }
                        detailsPresentation.dismiss()
                        return .handled
                    }
                    .accessibilityIdentifier("download-task-list")
                    .overlay {
                        if visibleTasks.isEmpty { emptyState }
                    }
                }
            }
        }
        .onChange(of: destination) { _, _ in clearHiddenSelection() }
        .onChange(of: store.searchQuery) { _, _ in clearHiddenSelection() }
        .background(DownloadWorkspaceBackdrop())
    }

    @ViewBuilder
    private var emptyState: some View {
        if !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No Matching Downloads"), systemImage: "magnifyingglass")
            } description: {
                Text(String(localized: "Try a different name or save location."))
            } actions: {
                Button(String(localized: "Clear Search")) { store.searchQuery = "" }
            }
        } else {
            ContentUnavailableView {
                Label {
                    Text(emptyTitle)
                } icon: {
                    Image(systemName: destination.symbolName).foregroundStyle(.tint)
                }
            } description: {
                Text(emptyDescription).frame(maxWidth: 360)
            } actions: {
                VStack(spacing: 12) {
                    if !store.tasks.isEmpty {
                        Button(String(localized: "Show All Downloads")) { store.selectedDestination = .all }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(String(localized: "Add Download…")) { store.requestAddPanel() }
                            .buttonStyle(.borderedProminent)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { importActions }
                        VStack(spacing: 8) { importActions }
                    }
                }
            }
        }
    }

    private var emptyTitle: String {
        if store.tasks.isEmpty { return String(localized: "No Downloads") }
        return String(localized: "No Downloads in This View")
    }

    private var emptyDescription: String {
        if store.tasks.isEmpty {
            return String(localized: "Add a link or open a download file. Restored downloads stay paused until you resume them.")
        }
        return String(localized: "Your other downloads are available in All Downloads.")
    }

    @ViewBuilder private var importActions: some View {
        Button(String(localized: "Paste Link"), action: onPaste).fixedSize()
        Button(String(localized: "Open Torrent or Metalink…"), action: onOpenFile).fixedSize()
    }

    private func clearHiddenSelection() {
        store.selectedTaskIDs.formIntersection(visibleTasks.map(\.id))
    }
}

/// Secondary, read-only status below the task list. Its row spans the
/// entire detail area, while the navigation sidebar keeps its full height.
struct DownloadStatusBar: View {
    @EnvironmentObject private var store: DownloadStore

    private var totalSize: Int64 {
        store.tasks.reduce(0) { total, task in
            let sum = total.addingReportingOverflow(max(0, task.totalLength))
            return sum.overflow ? .max : sum.partialValue
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text(String(localized: "Active: \(store.count(for: .active).formatted())"))
                        .accessibilityIdentifier("download-status-active")
                    Text("·").accessibilityHidden(true)
                    Text(String(localized: "Completed: \(store.count(for: .completed).formatted())"))
                        .accessibilityIdentifier("download-status-completed")
                    Text("·").accessibilityHidden(true)
                    Text(String(localized: "Total Size: \(ByteFormat.size(totalSize))"))
                        .help(String(localized: "\(store.tasks.count) items"))
                        .accessibilityIdentifier("download-status-size")
                }.fixedSize()
                HStack(spacing: 16) {
                    statusValue(String(localized: "Active"), value: store.count(for: .active).formatted(), symbol: "play.circle")
                    statusValue(String(localized: "Completed"), value: store.count(for: .completed).formatted(), symbol: "checkmark.circle")
                    statusValue(String(localized: "Total Size"), value: ByteFormat.size(totalSize), symbol: "externaldrive")
                }.fixedSize()
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 28)
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "All Downloads"))
        .accessibilityIdentifier("download-status-bar")
        .help(String(localized: "Summary of all downloads, including tasks outside the current filter."))
    }

    private func statusValue(_ title: String, value: String, symbol: String) -> some View {
        Label(value, systemImage: symbol)
            .accessibilityLabel(title).accessibilityValue(value)
            .help(title + ": " + value)
    }
}

private struct DownloadTaskRow: View {
    let store: DownloadStore
    let detailsPresentation: TaskDetailsPresentation
    @ObservedObject var row: DownloadRowState
    @Environment(\.colorSchemeContrast) private var contrast
    var isSelected: Bool
    var isExpanded: Bool
    var actionsEnabled: Bool
    var isUpdatingEngine: Bool
    var scheduleArmed: Bool
    var destination: SidebarDestination
    var showDetails: () -> Void
    private var task: DownloadTask { row.task }

    private var commandContext: DownloadActionContext {
        DownloadActionContext(store: store, taskID: task.id, window: DownloadWindowActions(
            hasSelection: true, showDetails: { section in
                selectAndExpand()
                if let section {
                    detailsPresentation.selectedTab = .overview
                    detailsPresentation.sectionRequest = TaskDetailRequest(section: section)
                }
                showDetails()
            }), taskIDs: DownloadSelection.contextIDs(clicked: task.id, selected: store.selectedTaskIDs))
    }

    private var expansion: Binding<Bool> {
        Binding(get: { detailsPresentation.expandedTaskID == task.id }, set: { expanded in
            if expanded {
                store.selectedTaskID = task.id
                detailsPresentation.expandedTaskID = task.id
            } else if detailsPresentation.expandedTaskID == task.id {
                detailsPresentation.expandedTaskID = nil
            }
        })
    }

    private func selectAndExpand() {
        store.selectedTaskID = task.id
        detailsPresentation.selectionChanged(to: task.id)
    }

    var body: some View {
        DisclosureGroup(isExpanded: expansion) {
            TaskSummaryView(task: task, showDetails: showDetails)
        } label: {
            rowLabel
        }
        .listRowInsets(EdgeInsets(top: 11, leading: 8, bottom: 11, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(
            RoundedRectangle(cornerRadius: AppLayout.rowCornerRadius)
                .fill(isSelected ? Color.clear : Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: AppLayout.rowCornerRadius).strokeBorder(
                        Color(nsColor: .separatorColor).opacity(isSelected ? 0 : (contrast == .increased ? 1 : 0.24)), lineWidth: 0.5)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 12)
        )
        .contentShape(Rectangle())
        .contextMenu {
            DownloadActionButton(action: .details, context: commandContext)
            Divider()
            if DownloadAction.reveal.isEnabled(in: commandContext) {
                DownloadActionButton(action: .reveal, context: commandContext)
                Divider()
            }
            if commandContext.tasks.count > 1 {
                DownloadActionButton(action: .pause, context: commandContext)
                DownloadActionButton(action: .resume, context: commandContext)
            } else if let action = task.primaryControlAction {
                DownloadActionButton(action: action == .pause ? .pause : .resume, context: commandContext)
            }
            if task.isAvailableInEngine, task.primaryControlAction != nil, !task.requiresFileSelection {
                DownloadActionButton(action: .speedLimits, context: commandContext)
                DownloadActionButton(action: .schedule, context: commandContext)
            }
            if task.canFinishRecording { DownloadActionButton(action: .finishRecording, context: commandContext) }
            if task.canRetryMedia { DownloadActionButton(action: .retryMedia, context: commandContext) }
            if task.canEditAndAddAgain { DownloadActionButton(action: .editAgain, context: commandContext) }
            if task.queuePosition != nil { DownloadActionButton(action: .moveToTop, context: commandContext) }
            DownloadActionButton(action: .remove, context: commandContext)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-row-\(task.id)")
        .modifier(QueueReordering(store: store, task: task))
    }

    private var rowLabel: some View {
        DownloadTaskRowLabel(store: store, row: row, isSelected: isSelected,
            actionsEnabled: actionsEnabled, scheduleArmed: scheduleArmed)
            .equatable()
    }
}

private struct DownloadTaskRowLabel: View, Equatable {
    let store: DownloadStore
    @ObservedObject var row: DownloadRowState
    let isSelected: Bool
    let actionsEnabled: Bool
    let scheduleArmed: Bool
    private var task: DownloadTask { row.task }
    private var commandContext: DownloadActionContext { DownloadActionContext(store: store, taskID: task.id) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row === rhs.row && lhs.isSelected == rhs.isSelected &&
        lhs.actionsEnabled == rhs.actionsEnabled && lhs.scheduleArmed == rhs.scheduleArmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.controlSpacing) {
            HStack(alignment: .center, spacing: AppLayout.controlSpacing) {
                HStack(alignment: .center, spacing: AppLayout.controlSpacing) {
                    DownloadTaskIcon(task: task, size: AppLayout.taskIconSize)
                    Text(task.name)
                        .font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        .help(task.name)
                        .accessibilityIdentifier("task-\(task.id)-name")
                    Spacer(minLength: 0)
                    Text(task.progressLabel).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize()
                }
                .contentShape(Rectangle())

                primaryAction.frame(width: 20)
            }
            VStack(alignment: .leading, spacing: AppLayout.controlSpacing) {
                TaskProgressIndicator(task: task).controlSize(.small)
                    .accessibilityHidden(true) // The adjacent text exposes phase, progress and bytes once.
                ViewThatFits(in: .horizontal) {
                    transferLine(includingETA: true)
                    transferLine(includingETA: false)
                }
                if let scheduled = task.scheduledStart {
                    Label("\(scheduled.formatted(date: .abbreviated, time: .shortened)) · \(scheduleArmed ? String(localized: "Scheduled") : String(localized: "Schedule disabled"))", systemImage: "calendar")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let error = task.errorMessage, task.status == .failed {
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(error)
                }
            }
            .padding(.leading, AppLayout.taskTextInset)
            .contentShape(Rectangle())

        }
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + AppLayout.taskTextInset }
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
    }

    private func transferLine(includingETA: Bool) -> some View {
        HStack(spacing: 6) {
            Label(task.phaseLabel, systemImage: task.status.symbolName)
                .foregroundStyle(task.status == .failed && !isSelected ? Color.red : .secondary)
                .accessibilityIdentifier("task-\(task.id)-status")
            Text("·").accessibilityHidden(true)
            Text(task.transferSizeLabel).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if task.status == .active {
                if task.isSharing {
                    Label(ByteFormat.speed(task.uploadSpeed), systemImage: "arrow.up")
                } else {
                    Text(ByteFormat.speed(task.downloadSpeed))
                }
                if includingETA, let etaLabel { Text("·"); Text(etaLabel) }
            }
        }
        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let action = task.primaryControlAction {
            Button {
                (action == .pause ? DownloadAction.pause : .resume).perform(in: commandContext)
            } label: {
                Label("\(action.helpTitle) \(task.name)", systemImage: action.symbolName).labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless).controlSize(.small)
            .disabled(!actionsEnabled)
            .help(action.helpTitle)
            .accessibilityLabel("\(action.helpTitle) \(task.name)")
            .accessibilityIdentifier("task-\(task.id)-\(action.accessibilityName)-button")
        } else if task.status == .completed {
            Button(String(localized: "Show in Finder"), systemImage: "magnifyingglass") { store.showInFinder(task) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
                .help(String(localized: "Show in Finder"))
                .disabled(DownloadFileLocation.revealURL(for: task) == nil)
        }
    }

    private var etaLabel: String? {
        guard task.status == .active, task.media == nil, !task.isSharing,
              task.progressState.fraction != nil, task.downloadSpeed > 0 else { return nil }
        let remainingBytes = max(0, task.totalLength - task.completedLength)
        guard remainingBytes > 0 else { return nil }
        let seconds = Int(ceil(Double(remainingBytes) / Double(task.downloadSpeed)))
        return String(localized: "ETA \(ByteFormat.duration(seconds))")
    }


}

private struct BrowserCaptureView: View {
    @EnvironmentObject private var store: DownloadStore

    var body: some View {
        Form {
            Section(String(localized: "Browser Integration")) {
                BrowserIntegrationView(server: store.browserCapture)
            }
        }.formStyle(.grouped)
            .frame(maxWidth: AppLayout.settingsWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}


private struct DownloadWindowIdentity: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowIdentityView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowIdentityView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = NSUserInterfaceItemIdentifier("ChopChop.Downloads")
        }
    }
}
