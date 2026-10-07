import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
    case general = "General"
    case downloads = "Downloads"
    case network = "Network"
    case bitTorrent = "BitTorrent"
    case ed2k = "ED2K"
    case protocols = "Protocols"
    case browserCapture = "Browser Capture"
    case engine = "Engine"
    case advanced = "Advanced"

    var id: String { rawValue }

    var accessibilityIdentifier: String {
        "settings-pane-\(rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))"
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .downloads: "arrow.down.circle"
        case .network: "network"
        case .bitTorrent: "point.3.connected.trianglepath.dotted"
        case .ed2k: "shared.with.you"
        case .protocols: "link.badge.plus"
        case .browserCapture: "globe.badge.chevron.backward"
        case .engine: "cpu"
        case .advanced: "slider.horizontal.3"
        }
    }
}

private struct PeerLimitConfirmation {
    var value: Int
}

struct SettingsView: View {
    @EnvironmentObject private var store: DownloadStore
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var selectedPane: SettingsPane? = .general
    @State private var sidebarSearchText = ""
    @State private var presentedAlert: UserFacingAlert?
    @State private var peerLimitConfirmation: PeerLimitConfirmation?
    @State private var sharingModeSelection: BitTorrentSharingMode = .stopByCondition
    @State private var ed2kSearchFileTypeSelection: ED2KSearchFileType = .any

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
        .onAppear {
            syncSharingModeSelectionFromStore()
            syncED2KSearchFileTypeSelectionFromStore()
            store.publishStartupAlerts()
            navigateToRequestedEngineSettings()
        }
        .onChange(of: store.engineSettingsRequested) { _, _ in
            navigateToRequestedEngineSettings()
        }
        .onChange(of: store.engineSettings.keepSharing) { _, _ in
            syncSharingModeSelectionFromStore()
        }
        .onChange(of: sharingModeSelection) { _, newValue in
            commitSharingModeSelection(newValue)
        }
        .onChange(of: ed2kSearchFileTypeSelection) { _, newValue in
            commitED2KSearchFileTypeSelection(newValue)
        }
        .onReceive(store.userAlerts) { alert in
            guard controlActiveState == .key else { return }
            guard store.claimAlert(alert) else { return }
            presentedAlert = alert
        }
        .alert(item: $presentedAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(
            "High Peer Limit",
            isPresented: peerLimitConfirmationIsPresented,
            presenting: peerLimitConfirmation
        ) { confirmation in
            Button("Continue") {
                store.engineSettings.btMaxPeers = confirmation.value
                peerLimitConfirmation = nil
            }
            Button("Cancel", role: .cancel) {
                peerLimitConfirmation = nil
            }
        } message: { confirmation in
            Text("Max peers is set to \(confirmation.value). The recommended limit is 128 because higher values can increase memory and connection pressure.")
        }
    }

    private func navigateToRequestedEngineSettings() {
        guard store.consumeEngineSettingsRequest() else { return }
        sidebarSearchText = ""
        selectedPane = .engine
    }

    private var sidebar: some View {
        List(selection: $selectedPane) {
            ForEach(filteredPanes) { pane in
                NavigationLink(value: pane) {
                    Label(pane.rawValue, systemImage: pane.symbol)
                }
                .tag(Optional(pane))
                .accessibilityIdentifier(pane.accessibilityIdentifier)
            }

            if filteredPanes.isEmpty {
                Text("No Results")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $sidebarSearchText, placement: .sidebar, prompt: "Search")
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
        .frame(minWidth: 210)
    }

    private var filteredPanes: [SettingsPane] {
        let query = sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SettingsPane.allCases }
        return SettingsPane.allCases.filter { pane in
            pane.rawValue.localizedCaseInsensitiveContains(query) ||
                headerSubtitle(for: pane).localizedCaseInsensitiveContains(query)
        }
    }

    private var detail: some View {
        NavigationStack {
            Form {
                paneContent
            }
            .formStyle(.grouped)
            .controlSize(.regular)
            .navigationTitle(selectedPane?.rawValue ?? "Settings")
            .toolbarTitleDisplayMode(.inline)
            .accessibilityIdentifier("settings-current-pane-title")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func headerSubtitle(for pane: SettingsPane) -> String {
        switch pane {
        case .general:
            "Window, launch, and appearance behavior."
        case .downloads:
            "Default save location and completed-file behavior."
        case .network:
            "Queue size, connection count, retry, timeout, speed, and proxy settings."
        case .bitTorrent:
            "Peer discovery, listen ports, encryption, and sharing behavior."
        case .ed2k:
            "ED2K ports, bootstrap files, server discovery, and search."
        case .protocols:
            "System protocol and file association preferences."
        case .browserCapture:
            "Download interception rules for browser integrations."
        case .engine:
            "Managed Aria2 Next download, update check, and RPC launch settings."
        case .advanced:
            "Runtime diagnostics and explicit launch arguments."
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane ?? .general {
        case .general:
            general
        case .downloads:
            downloads
        case .network:
            network
        case .bitTorrent:
            bitTorrent
        case .ed2k:
            ed2k
        case .protocols:
            protocols
        case .browserCapture:
            browserCapture
        case .engine:
            engine
        case .advanced:
            advanced
        }
    }

    private var headerSubtitle: String {
        headerSubtitle(for: selectedPane ?? .general)
    }

    private var general: some View {
        SettingsSection {
            Toggle("Show in menu bar", isOn: $store.preferences.showMenuBar)
            Toggle("Keep running after window closes", isOn: $store.preferences.keepRunningAfterClose)
            Toggle("Prevent sleep while downloads are active", isOn: $store.preferences.preventSleepDuringActiveDownloads)
        }
    }

    @ViewBuilder
    private var downloads: some View {
        SettingsSection(title: "Location") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default save location")
                    Text(store.engineSettings.downloadDirectoryPath ?? "No folder selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Choose Folder") {
                    chooseDownloadFolder()
                }
            }
            Toggle("Auto organize files", isOn: $store.preferences.autoOrganizeFiles)
        }

        SettingsSection(title: "Removal") {
            Toggle("Confirm before removing downloads", isOn: confirmBeforeRemoveBinding)
            Toggle(
                "Move files to Trash when confirmation is skipped",
                isOn: $store.preferences.deleteFilesWhenSkippingRemoveConfirmation
            )
            .disabled(!store.preferences.suppressRemoveConfirmation)
        }
    }

    private var confirmBeforeRemoveBinding: Binding<Bool> {
        Binding(
            get: { !store.preferences.suppressRemoveConfirmation },
            set: { store.preferences.suppressRemoveConfirmation = !$0 }
        )
    }

    private var peerLimitConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { peerLimitConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    peerLimitConfirmation = nil
                }
            }
        )
    }

    private var autoDownloadBitTorrentContentBinding: Binding<Bool> {
        Binding(
            get: { !store.engineSettings.pauseMetadata },
            set: { store.engineSettings.pauseMetadata = !$0 }
        )
    }

    private var btMaxPeersBinding: Binding<Int> {
        Binding(
            get: { store.engineSettings.btMaxPeers },
            set: { value in
                let clampedValue = min(500, max(1, value))
                guard clampedValue > 128,
                      clampedValue > store.engineSettings.btMaxPeers else {
                    store.engineSettings.btMaxPeers = clampedValue
                    return
                }
                peerLimitConfirmation = PeerLimitConfirmation(value: clampedValue)
            }
        )
    }

    private var btTrackerTextBinding: Binding<String> {
        Binding(
            get: { store.engineSettings.btTracker },
            set: { store.engineSettings.btTracker = $0 }
        )
    }

    @ViewBuilder
    private var network: some View {
        SettingsSection(title: "Transfer") {
            Stepper(value: $store.engineSettings.maxActiveDownloads, in: 1...100) {
                SettingValueRow(title: "Max active downloads", value: "\(store.engineSettings.maxActiveDownloads)")
            }
            Stepper(value: $store.engineSettings.maxConnectionsPerTask, in: 1...256) {
                SettingValueRow(title: "Max connections per server", value: "\(store.engineSettings.maxConnectionsPerTask)")
            }
            Stepper(value: $store.engineSettings.splitCount, in: 1...256) {
                SettingValueRow(title: "Split count", value: "\(store.engineSettings.splitCount)")
            }
            SpeedLimitStepper(
                title: "Global download limit",
                value: $store.engineSettings.maxOverallDownloadLimitKB
            )
            SpeedLimitStepper(
                title: "Global upload limit",
                value: $store.engineSettings.maxOverallUploadLimitKB
            )
        }

        SettingsSection(title: "Retry and Disk") {
            Stepper(value: $store.engineSettings.retryCount, in: 0...99) {
                SettingValueRow(title: "Retry count", value: store.engineSettings.retryCount == 0 ? "Unlimited" : "\(store.engineSettings.retryCount)")
            }
            Stepper(value: $store.engineSettings.retryWaitSeconds, in: 1...300) {
                SettingValueRow(title: "Retry wait", value: "\(store.engineSettings.retryWaitSeconds) s")
            }
            Stepper(value: $store.engineSettings.connectTimeoutSeconds, in: 1...300) {
                SettingValueRow(title: "Connect timeout", value: "\(store.engineSettings.connectTimeoutSeconds) s")
            }
            Stepper(value: $store.engineSettings.timeoutSeconds, in: 1...300) {
                SettingValueRow(title: "Transfer timeout", value: "\(store.engineSettings.timeoutSeconds) s")
            }
            Picker("File allocation", selection: $store.engineSettings.fileAllocation) {
                ForEach(FileAllocationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Toggle("Async DNS", isOn: $store.engineSettings.asyncDNS)
        }

        SettingsSection(title: "HTTP") {
            TextField("User-Agent", text: $store.engineSettings.userAgent)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, maxWidth: .infinity)
                .frame(height: 28)
            HStack(spacing: 10) {
                TextField("Proxy URL", text: $store.engineSettings.proxyURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220, maxWidth: .infinity)
                    .frame(height: 28)
                Button {
                    store.applyDetectedSystemProxy()
                } label: {
                    Label("Detect System Proxy", systemImage: "network")
                }
                .buttonStyle(.bordered)
            }
            TextField("Proxy bypass list", text: $store.engineSettings.proxyBypass)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, maxWidth: .infinity)
                .frame(height: 28)
        }
    }

    @ViewBuilder
    private var bitTorrent: some View {
        SettingsSection(title: "Content") {
            Toggle("Download magnet and torrent content automatically", isOn: autoDownloadBitTorrentContentBinding)
                .accessibilityIdentifier("settings-bt-auto-download-content-toggle")
            Toggle("Force BitTorrent encryption", isOn: $store.engineSettings.btForceEncryption)
                .accessibilityIdentifier("settings-bt-force-encryption-toggle")
            Stepper(value: btMaxPeersBinding, in: 1...500) {
                SettingValueRow(title: "Max peers", value: "\(store.engineSettings.btMaxPeers)")
            }
            .accessibilityIdentifier("settings-bt-max-peers-stepper")
        }

        SettingsSection(title: "Peer Discovery") {
            Toggle("DHT", isOn: $store.engineSettings.btDHTEnabled)
                .accessibilityIdentifier("settings-bt-dht-toggle")
            Toggle("Peer exchange", isOn: $store.engineSettings.btPeerExchangeEnabled)
                .accessibilityIdentifier("settings-bt-peer-exchange-toggle")
            Toggle("Local peer discovery", isOn: $store.engineSettings.btLocalPeerDiscoveryEnabled)
                .accessibilityIdentifier("settings-bt-local-peer-discovery-toggle")
        }

        SettingsSection(title: "Ports") {
            SettingsControlRow(title: "BT listen port") {
                TextField("BT listen port", value: $store.engineSettings.listenPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 112)
                    .accessibilityIdentifier("settings-bt-listen-port-field")
            }
            SettingsControlRow(title: "DHT listen port") {
                TextField("DHT listen port", value: $store.engineSettings.dhtListenPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 112)
                    .accessibilityIdentifier("settings-bt-dht-listen-port-field")
            }
        }

        SettingsSection(title: "Seeding") {
            Picker("Mode:", selection: $sharingModeSelection) {
                ForEach(BitTorrentSharingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings-bt-sharing-mode-picker")

            Stepper(value: $store.engineSettings.shareRatio, in: 1...100) {
                SettingValueRow(title: "Stop at ratio", value: store.engineSettings.keepSharing ? "Disabled" : "\(store.engineSettings.shareRatio)")
            }
            .disabled(store.engineSettings.keepSharing)

            Stepper(value: $store.engineSettings.shareTimeMinutes, in: 1...20_160, step: 60) {
                SettingValueRow(title: "Stop after", value: store.engineSettings.keepSharing ? "Disabled" : "\(store.engineSettings.shareTimeMinutes) min")
            }
            .disabled(store.engineSettings.keepSharing)
        }

        SettingsSection(title: "Tracker Sources") {
            TrackerSourcesPopoverButton(
                selectedSourceURLs: $store.engineSettings.trackerSourceURLs,
                customSourceURLs: $store.engineSettings.customTrackerSourceURLs
            )

            HStack {
                Button {
                    runStoreTask { await store.syncBitTorrentTrackersManually() }
                } label: {
                    Label(store.isSyncingTrackers ? "Syncing" : "Sync Trackers", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.isSyncingTrackers)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings-bt-sync-trackers-button")

                Spacer()

                Text("Last sync: \(lastTrackerSyncDescription)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }

        SettingsSection(title: "Tracker List") {
            TrackerListPopoverButton(trackerText: btTrackerTextBinding)

            Toggle("Sync tracker sources automatically", isOn: $store.engineSettings.btTrackerAutoSync)
                .accessibilityIdentifier("settings-bt-tracker-auto-sync-toggle")

            Picker("Sync frequency:", selection: $store.engineSettings.btTrackerSyncIntervalHours) {
                ForEach(TrackerSyncInterval.allCases) { interval in
                    Text(interval.title).tag(interval.rawValue)
                }
            }
            .disabled(!store.engineSettings.btTrackerAutoSync)
            .accessibilityIdentifier("settings-bt-tracker-sync-frequency-picker")
        }
    }

    private var lastTrackerSyncDescription: String {
        guard let lastTrackerSyncAt = store.engineSettings.lastTrackerSyncAt else {
            return "Never"
        }
        return lastTrackerSyncAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func syncSharingModeSelectionFromStore() {
        let mode = store.engineSettings.sharingMode
        guard sharingModeSelection != mode else { return }
        sharingModeSelection = mode
    }

    private func commitSharingModeSelection(_ mode: BitTorrentSharingMode) {
        let keepSharing = mode == .manualStop
        guard store.engineSettings.keepSharing != keepSharing else { return }
        Task { @MainActor in
            await Task.yield()
            guard store.engineSettings.keepSharing != keepSharing else { return }
            store.engineSettings.keepSharing = keepSharing
        }
    }

    private func syncED2KSearchFileTypeSelectionFromStore() {
        let fileType = store.ed2kSearchFileType
        guard ed2kSearchFileTypeSelection != fileType else { return }
        ed2kSearchFileTypeSelection = fileType
    }

    private func commitED2KSearchFileTypeSelection(_ fileType: ED2KSearchFileType) {
        guard store.ed2kSearchFileType != fileType else { return }
        Task { @MainActor in
            await Task.yield()
            guard store.ed2kSearchFileType != fileType else { return }
            store.ed2kSearchFileType = fileType
        }
    }

    @ViewBuilder
    private var ed2k: some View {
        SettingsSection(title: "Ports") {
            SettingsControlRow(title: "ED2K listen port") {
                TextField("ED2K listen port", value: $store.engineSettings.ed2kListenPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 112)
                    .accessibilityIdentifier("settings-ed2k-listen-port-field")
            }
            SettingsControlRow(title: "ED2K UDP listen port") {
                TextField("ED2K UDP listen port", value: $store.engineSettings.ed2kUDPListenPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 112)
                    .accessibilityIdentifier("settings-ed2k-udp-listen-port-field")
            }
            Stepper(value: $store.engineSettings.ed2kUploadSlots, in: 1...100) {
                SettingValueRow(title: "Upload slots", value: "\(store.engineSettings.ed2kUploadSlots)")
            }
            .accessibilityIdentifier("settings-ed2k-upload-slots-stepper")
        }

        SettingsSection(title: "Bootstrap") {
            TextField("server.met URL", text: $store.engineSettings.ed2kServerMetURL)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, maxWidth: .infinity)
                .frame(height: 28)
                .accessibilityIdentifier("settings-ed2k-server-met-url-field")
            TextField("nodes.dat URL", text: $store.engineSettings.ed2kNodesDatURL)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, maxWidth: .infinity)
                .frame(height: 28)
                .accessibilityIdentifier("settings-ed2k-nodes-dat-url-field")

            VStack(alignment: .leading, spacing: 6) {
                Text("ED2K servers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("One server per line, for example server.example:4661", text: $store.engineSettings.ed2kServer, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(3...6)
                    .frame(minHeight: 84)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.separator.opacity(0.45), lineWidth: 0.5)
                    }
                    .accessibilityIdentifier("settings-ed2k-server-list-field")
                if ED2KServerText.containsInvalidServer(in: store.engineSettings.ed2kServer) {
                    Text("Use host:port format, one server per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Sync bootstrap files automatically", isOn: $store.engineSettings.ed2kBootstrapAutoSync)
                .accessibilityIdentifier("settings-ed2k-bootstrap-auto-sync-toggle")

            Picker("Sync frequency:", selection: $store.engineSettings.ed2kBootstrapSyncIntervalHours) {
                ForEach(TrackerSyncInterval.allCases) { interval in
                    Text(interval.title).tag(interval.rawValue)
                }
            }
            .disabled(!store.engineSettings.ed2kBootstrapAutoSync)
            .accessibilityIdentifier("settings-ed2k-bootstrap-sync-frequency-picker")

            HStack {
                Button {
                    runStoreTask { await store.syncED2KBootstrapManually() }
                } label: {
                    Label(store.isSyncingED2KBootstrap ? "Syncing" : "Sync Bootstrap Files", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(store.isSyncingED2KBootstrap)
                .accessibilityIdentifier("settings-ed2k-sync-bootstrap-button")

                Spacer()

                Text(ed2kBootstrapStatusDescription)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }

        SettingsSection(title: "Search") {
            TextField("Keyword", text: $store.ed2kSearchKeyword)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, maxWidth: .infinity)
                .frame(height: 28)
                .accessibilityIdentifier("settings-ed2k-search-keyword-field")

            Picker("File type:", selection: $ed2kSearchFileTypeSelection) {
                ForEach(ED2KSearchFileType.allCases) { fileType in
                    Text(fileType.title).tag(fileType)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings-ed2k-search-file-type-picker")

            Stepper(value: $store.ed2kSearchMinSources, in: 1...9_999) {
                SettingValueRow(title: "Minimum sources", value: "\(store.ed2kSearchMinSources)")
            }

            Stepper(value: $store.engineSettings.ed2kSearchTimeoutSeconds, in: 10...600, step: 10) {
                SettingValueRow(title: "Search timeout", value: "\(store.engineSettings.ed2kSearchTimeoutSeconds) s")
            }
            .accessibilityIdentifier("settings-ed2k-search-timeout-stepper")

            HStack {
                Button {
                    runStoreTask { await store.startOrCancelED2KSearch() }
                } label: {
                    Label(store.isSearchingED2K ? "Cancel Search" : "Search", systemImage: store.isSearchingED2K ? "xmark.circle" : "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings-ed2k-search-button")

                Text(ed2kSearchStatusDescription)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()
            }

            if store.ed2kSearchResults.isEmpty {
                Text("No ED2K search results.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-ed2k-search-empty")
            } else {
                Table(store.ed2kSearchResults) {
                    TableColumn("Name") { result in
                        Text(result.displayName)
                            .lineLimit(1)
                    }
                    TableColumn("Size") { result in
                        Text(ByteFormat.size(result.lengthBytes))
                            .monospacedDigit()
                    }
                    TableColumn("Sources") { result in
                        Text(result.sourceCount ?? "0")
                            .monospacedDigit()
                    }
                    TableColumn("Complete") { result in
                        Text(result.completeSourceCount ?? "0")
                            .monospacedDigit()
                    }
                    TableColumn("") { result in
                        Button {
                            runStoreTask { await store.downloadED2KSearchResult(result) }
                        } label: {
                            Label("Download \(result.displayName)", systemImage: "arrow.down.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(minHeight: 180)
                .accessibilityIdentifier("settings-ed2k-search-results-table")
            }
        }
    }

    private var ed2kBootstrapStatusDescription: String {
        let serverSize = store.ed2kBootstrapStatus.serverMetSize.map(ByteFormat.size) ?? "Missing"
        let nodesSize = store.ed2kBootstrapStatus.nodesDatSize.map(ByteFormat.size) ?? "Missing"
        let syncText = store.engineSettings.lastED2KBootstrapSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
        return "server.met \(serverSize), nodes.dat \(nodesSize) · Last sync \(syncText)"
    }

    private var ed2kSearchStatusDescription: String {
        if store.isSearchingED2K {
            return "\(store.ed2kSearchElapsedSeconds)/\(store.engineSettings.ed2kSearchTimeoutSeconds) s · \(store.ed2kSearchResults.count) results"
        }
        return "\(store.ed2kSearchResults.count) results"
    }

    private var protocols: some View {
        SettingsSection(title: "Links and Files") {
            Text("ChopChop supports HTTP, HTTPS, Magnet, ED2K, torrent, and metalink downloads from the Add Download window.")
            Text("Opening links or files directly from other apps isn't available in this version.")
                .foregroundStyle(.secondary)
        }
    }

    private var browserCapture: some View {
        SettingsSection(title: "Browser Integration") {
            Text("Browser capture isn't available in this version.")
            Text("Copy a download link from your browser, then choose File → Paste Download Link… in the main window.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var engine: some View {
        SettingsSection(title: "Aria2 Next") {
            EngineStatusView()
            KeyValueLine(title: "Installed version", value: store.engineVersionDescription)
            Text("Aria2 Next starts automatically when ChopChop opens.")
                .font(.callout).foregroundStyle(.secondary)
        }

        SettingsSection(title: "Engine Update") {
            VStack(alignment: .leading, spacing: 16) {
                if let progress = store.engineUpgradeProgress {
                    EngineInstallationProgressView(progress: progress, onCancel: store.cancelEngineUpdate)
                        .accessibilityIdentifier("settings-engine-update-progress")
                    Text(progress.canCancel
                         ? "Your current engine stays available while the update downloads and is verified."
                         : "Downloads briefly pause while ChopChop finishes the update.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    if let error = store.engineUpgradeError {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("The update couldn’t be completed", systemImage: "exclamationmark.triangle.fill")
                                .fontWeight(.medium)
                                .symbolRenderingMode(.multicolor)
                            Text(error).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .accessibilityIdentifier("settings-engine-update-error")
                    } else if let result = store.engineUpgradeResult {
                        Label(result, systemImage: store.availableEngineUpdate == nil ? "checkmark.circle" : "info.circle")
                    } else {
                        Text(store.engineUpdateStatus).fontWeight(.medium)
                    }

                    if store.availableEngineUpdate != nil {
                        Text("ChopChop downloads and verifies the update before restarting the engine. Downloads briefly pause during the restart.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        if let release = store.availableEngineUpdate {
                            Button(store.engineUpgradeError == nil ? "Update to \(release.version.description)" : "Retry Update to \(release.version.description)") {
                                store.updateEngine()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!store.canUpdateEngine)
                            .accessibilityIdentifier("settings-update-engine-button")
                        }
                        Button("Check for Updates") { store.startEngineUpdateCheck() }
                            .disabled(store.installedEngine == nil || store.isCheckingEngineUpdate)
                        if store.isCheckingEngineUpdate { ProgressView().controlSize(.small) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        SettingsSection(title: "RPC") {
            SecureField("RPC token", text: $store.engineSettings.rpcToken)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, maxWidth: .infinity)
                .frame(height: 28)
            HStack {
                Button {
                    store.generateRPCToken()
                } label: {
                    Label("Generate Token", systemImage: "key")
                }
                .buttonStyle(.bordered)

                TextField("Port", value: $store.engineSettings.rpcPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 112)
                    .frame(height: 28)
            }
        }

        SettingsSection(title: "Runtime") {
            HStack(spacing: 10) {
                Button {
                    runStoreTask { await store.startEngine() }
                } label: {
                    Label("Start Engine", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canStartEngine)

                Button {
                    runStoreTask { await store.restartEngine() }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!store.canRestartEngine)

                Button {
                    runStoreTask { await store.stopEngine() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!store.canStopEngine)

                Button {
                    runStoreTask { await store.applyRuntimeEngineOptions() }
                } label: {
                    Label("Apply Settings", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .disabled(!runtimeCanApplySettings)
            }
            RuntimeRequirementsView(missingRequirements: store.engineSettings.missingLaunchRequirements)
            KeyValueLine(title: "State", value: runtimeDescription)
            if let error = store.runtime.lastError {
                KeyValueLine(title: "Last error", value: error)
            }
        }
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.adoptDownloadDirectory(url)
    }

    private func runStoreTask(_ operation: @escaping @MainActor () async -> Void) {
        DispatchQueue.main.async {
            Task { @MainActor in
                await operation()
            }
        }
    }

    private var advanced: some View {
        SettingsSection {
            if store.runtime.lastLaunchArguments.isEmpty {
                Text("No engine launch arguments yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.runtime.lastLaunchArguments, id: \.self) { argument in
                    Text(argument)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var runtimeDescription: String {
        switch store.runtime.phase {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .running(let pid):
            "Running, PID \(pid)"
        case .stopping:
            "Stopping"
        case .failed(let message):
            "Failed: \(message)"
        }
    }

    private var runtimeCanApplySettings: Bool {
        guard !store.isUpdatingEngine else { return false }
        return switch store.runtime.phase {
        case .running:
            true
        case .stopped, .starting, .stopping, .failed:
            false
        }
    }
}

private struct SettingsSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if let title {
            Section(title) {
                content
            }
        } else {
            Section {
                content
            }
        }
    }
}

private struct SettingsControlRow<Control: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var control: Control

    init(title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 24)
            control
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    }
}

private struct SettingValueRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct SpeedLimitStepper: View {
    var title: String
    @Binding var value: Int

    var body: some View {
        Stepper(value: $value, in: 0...1_048_576, step: 128) {
            SettingValueRow(title: title, value: value == 0 ? "Unlimited" : "\(value) KB/s")
        }
    }
}

private struct TrackerSourcesPopoverButton: View {
    @Binding var selectedSourceURLs: [String]
    @Binding var customSourceURLs: [String]
    @State private var isPresented = false
    @State private var filter = ""
    @State private var newSourceURL = ""
    @State private var focusedSourceID: String?
    @State private var validationMessage: String?

    private var sourceRows: [TrackerSourceRowModel] {
        var rows = TrackerSourceCatalog.all.map { option in
            TrackerSourceRowModel(
                id: "preset:\(option.url)",
                title: option.displayName,
                subtitle: option.provider,
                url: option.url,
                isCustom: false
            )
        }
        var knownURLs = Set(rows.map(\.url))

        var emittedCustomURLs = Set<String>()
        for url in customSourceURLs where emittedCustomURLs.insert(url).inserted {
            rows.append(
                TrackerSourceRowModel(
                    id: "custom:\(url)",
                    title: url,
                    subtitle: "Custom",
                    url: url,
                    isCustom: true
                )
            )
            knownURLs.insert(url)
        }

        for url in selectedSourceURLs where !knownURLs.contains(url) {
            rows.append(
                TrackerSourceRowModel(
                    id: "selected:\(url)",
                    title: url,
                    subtitle: "Selected source",
                    url: url,
                    isCustom: true
                )
            )
        }

        return rows
    }

    private var filteredRows: [TrackerSourceRowModel] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sourceRows }
        return sourceRows.filter { row in
            row.title.localizedCaseInsensitiveContains(query) ||
                row.subtitle.localizedCaseInsensitiveContains(query) ||
                row.url.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedCount: Int {
        Set(selectedSourceURLs).count
    }

    private var summary: String {
        selectedCount == 1 ? "1 source" : "\(selectedCount) sources"
    }

    private var focusedCustomSource: TrackerSourceRowModel? {
        guard let focusedSourceID else { return nil }
        return sourceRows.first { $0.id == focusedSourceID && $0.isCustom }
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 10) {
                Label("Tracker Sources", systemImage: "list.bullet")
                Spacer(minLength: 12)
                Text(summary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("settings-bt-tracker-sources-button")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            popoverContent
                .frame(width: 460)
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterField
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 10)

            Divider()

            sourceList
                .frame(height: 260)

            Divider()

            addCustomSourceControls
                .padding(12)

            Divider()

            TrackerCommandRow(
                title: "Remove Custom Source",
                systemImage: "minus.circle",
                isEnabled: focusedCustomSource != nil,
                accessibilityIdentifier: "settings-bt-remove-custom-tracker-source-button",
                action: removeFocusedCustomSource
            )
            .padding(.vertical, 6)
        }
        .onChange(of: customSourceURLs) { _, _ in
            reconcileFocusedSource()
        }
        .onChange(of: selectedSourceURLs) { _, _ in
            reconcileFocusedSource()
        }
    }

    private var filterField: some View {
        HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("settings-bt-tracker-source-filter-field")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }

    private var sourceList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if filteredRows.isEmpty {
                    Text("No tracker sources match this filter.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .accessibilityIdentifier("settings-bt-tracker-source-list-empty")
                } else {
                    ForEach(filteredRows) { row in
                        Button {
                            toggleSource(row)
                        } label: {
                            TrackerSourceSelectionRow(
                                title: row.title,
                                subtitle: row.subtitle,
                                url: row.url,
                                isSelected: selectedSourceURLs.contains(row.url),
                                isFocused: focusedSourceID == row.id,
                                isCustom: row.isCustom
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-bt-tracker-source-row")
                    }
                }
            }
            .padding(8)
        }
    }

    private var addCustomSourceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Custom tracker source URL", text: $newSourceURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings-bt-custom-tracker-source-field")
                    .onSubmit(addCustomSource)

                Button(action: addCustomSource) {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("settings-bt-add-custom-tracker-source-button")
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-bt-custom-tracker-source-validation-message")
            }
        }
    }

    private func toggleSource(_ row: TrackerSourceRowModel) {
        focusedSourceID = row.id
        validationMessage = nil
        if selectedSourceURLs.contains(row.url) {
            selectedSourceURLs.removeAll { $0 == row.url }
        } else {
            selectedSourceURLs.append(row.url)
        }
    }

    private func addCustomSource() {
        let url = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            validationMessage = "Enter a tracker source URL."
            return
        }
        guard TrackerSourceURLValidator.isValid(url) else {
            validationMessage = "Use an HTTP or HTTPS tracker source URL."
            return
        }
        guard !sourceRows.contains(where: { $0.url == url }) else {
            focusedSourceID = sourceRows.first { $0.url == url }?.id
            validationMessage = "Tracker source already exists."
            return
        }

        customSourceURLs.append(url)
        selectedSourceURLs.append(url)
        focusedSourceID = "custom:\(url)"
        newSourceURL = ""
        validationMessage = nil
    }

    private func removeFocusedCustomSource() {
        guard let focusedCustomSource else { return }
        customSourceURLs.removeAll { $0 == focusedCustomSource.url }
        selectedSourceURLs.removeAll { $0 == focusedCustomSource.url }
        focusedSourceID = nil
        validationMessage = nil
    }

    private func reconcileFocusedSource() {
        guard let focusedSourceID else { return }
        if !sourceRows.contains(where: { $0.id == focusedSourceID }) {
            self.focusedSourceID = nil
        }
    }
}

private struct TrackerSourceRowModel: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String
    var url: String
    var isCustom: Bool
}

private struct TrackerSourceSelectionRow: View {
    var title: String
    var subtitle: String
    var url: String
    var isSelected: Bool
    var isFocused: Bool
    var isCustom: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .opacity(isSelected ? 1 : 0)
                .frame(width: 18)
            Image(systemName: isCustom ? "link" : "doc.text")
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(subtitle) · \(url)")
                    .font(.caption)
                    .foregroundStyle(isFocused ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isFocused ? Color.white : Color.primary)
        .background(
            isFocused ? Color.accentColor : selectedBackground,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    private var selectedBackground: Color {
        isSelected ? Color.accentColor.opacity(0.12) : Color.clear
    }
}

private struct TrackerListPopoverButton: View {
    @Binding var trackerText: String
    @State private var isPresented = false
    @State private var filter = ""
    @State private var newTracker = ""
    @State private var selectedTracker: String?
    @State private var showsRawEditor = false
    @State private var validationMessage: String?

    private var trackers: [String] {
        TrackerText.trackers(from: trackerText)
    }

    private var filteredTrackers: [String] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return trackers }
        return trackers.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var summary: String {
        let count = trackers.count
        return count == 1 ? "1 tracker" : "\(count) trackers"
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 10) {
                Label("Tracker List", systemImage: "point.3.connected.trianglepath.dotted")
                Spacer(minLength: 12)
                Text(summary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("settings-bt-tracker-list-button")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            popoverContent
                .frame(width: 430)
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterField
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 10)

            Divider()

            Group {
                if showsRawEditor {
                    rawEditor
                        .padding(12)
                } else {
                    trackerRows
                }
            }
            .frame(height: 190)

            Divider()

            addTrackerControls
                .padding(12)

            Divider()

            commandRows
        }
        .onAppear(perform: selectInitialTrackerIfNeeded)
        .onChange(of: trackerText) { _, _ in
            reconcileSelection()
        }
    }

    private var filterField: some View {
        HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("settings-bt-tracker-filter-field")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }

    private var trackerRows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if trackers.isEmpty {
                    Text("No trackers. Sync sources or add a tracker.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .accessibilityIdentifier("settings-bt-tracker-list-empty")
                } else if filteredTrackers.isEmpty {
                    Text("No trackers match this filter.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .accessibilityIdentifier("settings-bt-tracker-list-empty-filtered")
                } else {
                    ForEach(filteredTrackers, id: \.self) { tracker in
                        Button {
                            selectedTracker = tracker
                            validationMessage = nil
                        } label: {
                            TrackerListRow(
                                tracker: tracker,
                                isSelected: selectedTracker == tracker
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-bt-tracker-row")
                    }
                }
            }
            .padding(8)
        }
    }

    private var addTrackerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Add tracker URL", text: $newTracker)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings-bt-tracker-add-field")
                    .onSubmit(addTracker)

                Button(action: addTracker) {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("settings-bt-tracker-add-button")
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-bt-tracker-validation-message")
            }
        }
    }

    private var commandRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrackerCommandRow(
                title: "Remove Selected Tracker",
                systemImage: "minus.circle",
                isEnabled: selectedTracker != nil,
                accessibilityIdentifier: "settings-bt-tracker-remove-button",
                action: removeSelectedTracker
            )

            TrackerCommandRow(
                title: showsRawEditor ? "Hide Raw List" : "Edit Raw List...",
                systemImage: "text.alignleft",
                isEnabled: true,
                accessibilityIdentifier: "settings-bt-tracker-raw-toggle"
            ) {
                showsRawEditor.toggle()
                validationMessage = nil
            }
        }
        .padding(.vertical, 6)
    }

    private var rawEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Raw tracker list")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-bt-tracker-raw-editor-label")
            TextEditor(text: $trackerText)
                .font(.system(.body, design: .monospaced))
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("settings-bt-tracker-text-editor")
        }
    }

    private func selectInitialTrackerIfNeeded() {
        guard selectedTracker == nil else { return }
        selectedTracker = trackers.first
    }

    private func reconcileSelection() {
        let currentTrackers = trackers
        guard let selectedTracker else {
            self.selectedTracker = currentTrackers.first
            return
        }
        if !currentTrackers.contains(selectedTracker) {
            self.selectedTracker = currentTrackers.first
        }
    }

    private func addTracker() {
        let trimmed = newTracker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationMessage = "Enter a tracker URL."
            return
        }
        guard TrackerURLValidator.isValid(trimmed) else {
            validationMessage = "Use an HTTP, HTTPS, or UDP tracker URL."
            return
        }
        guard !trackers.contains(trimmed) else {
            selectedTracker = trimmed
            validationMessage = "Tracker already exists."
            return
        }

        trackerText = (trackers + [trimmed]).joined(separator: "\n")
        selectedTracker = trimmed
        newTracker = ""
        validationMessage = nil
    }

    private func removeSelectedTracker() {
        guard let selectedTracker else { return }
        let remainingTrackers = trackers.filter { $0 != selectedTracker }
        trackerText = remainingTrackers.joined(separator: "\n")
        self.selectedTracker = remainingTrackers.first
        validationMessage = nil
    }
}

private struct TrackerListRow: View {
    var tracker: String
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .opacity(isSelected ? 1 : 0)
                .frame(width: 18)
            Image(systemName: "link")
                .font(.body)
            Text(tracker)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            isSelected ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
    }
}

private struct TrackerCommandRow: View {
    var title: String
    var systemImage: String
    var isEnabled: Bool
    var accessibilityIdentifier: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.7))
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct KeyValueLine: View {
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct RuntimeRequirementsView: View {
    var missingRequirements: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if missingRequirements.isEmpty {
                RuntimeRequirementLine(
                    symbol: "checkmark.circle.fill",
                    title: "Runtime requirements complete",
                    tint: .green
                )
            } else {
                ForEach(missingRequirements, id: \.self) { requirement in
                    RuntimeRequirementLine(
                        symbol: "exclamationmark.circle",
                        title: requirement,
                        tint: .orange
                    )
                }
            }
        }
    }
}

private struct RuntimeRequirementLine: View {
    var symbol: String
    var title: String
    var tint: Color

    var body: some View {
        Label {
            Text(title)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
    }
}

private struct EngineStatusView: View {
    @EnvironmentObject private var store: DownloadStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var symbol: String {
        switch store.runtime.phase {
        case .running:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        default:
            store.engineSettings.canLaunch ? "cpu" : "exclamationmark.circle"
        }
    }

    private var tint: Color {
        switch store.runtime.phase {
        case .running:
            .green
        case .failed:
            .red
        default:
            store.engineSettings.canLaunch ? .cyan : .orange
        }
    }

    private var title: String {
        if let status = store.engineSetupState.statusLabel { return status }
        switch store.runtime.phase {
        case .running:
            return "Aria2 Next running"
        case .failed:
            return "Aria2 Next failed"
        default:
            return store.engineSettings.canLaunch ? "Aria2 Next ready" : "Runtime setup incomplete"
        }
    }

    private var subtitle: String {
        let missingRequirements = store.engineSettings.missingLaunchRequirements
        if !missingRequirements.isEmpty {
            return "Missing: \(missingRequirements.joined(separator: ", "))."
        }
        switch store.runtime.phase {
        case .running: return "The engine is ready to download files."
        case .starting: return "Starting the download engine…"
        default: return "Aria2 Next starts automatically when ChopChop opens."
        }
    }
}
