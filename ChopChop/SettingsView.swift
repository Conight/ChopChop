import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
    case general = "General"
    case downloads = "Downloads"
    case network = "Network"
    case bitTorrent = "BitTorrent"
    case ed2k = "ED2K"
    case integrations = "Integrations"
    case engine = "Engine"

    var localizedTitle: String { L10n.key(rawValue) }
    var id: String { rawValue }
    var accessibilityIdentifier: String { "settings-pane-\(rawValue.lowercased())" }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .downloads: "arrow.down.circle"
        case .network: "network"
        case .bitTorrent: "point.3.connected.trianglepath.dotted"
        case .ed2k: "server.rack"
        case .integrations: "puzzlepiece.extension"
        case .engine: "cpu"
        }
    }
}

private struct PeerLimitConfirmation {
    var value: Int
}

struct SettingsView: View {
    @EnvironmentObject private var store: DownloadStore
    @EnvironmentObject private var updates: AppUpdateCoordinator
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var selectedPane: SettingsPane
    @State private var presentedAlert: UserFacingAlert?
    @State private var peerLimitConfirmation: PeerLimitConfirmation?
    @State private var sharingModeSelection: BitTorrentSharingMode = .stopByCondition
    @State private var ed2kSearchFileTypeSelection: ED2KSearchFileType = .any

    init(initialPane: SettingsPane? = nil) {
        let saved = AppLaunchConfiguration.isTestAutomation ? nil : UserDefaults.standard.string(forKey: "settings.lastPane")
        _selectedPane = State(initialValue: initialPane ?? saved.flatMap(SettingsPane.init(rawValue:)) ?? .general)
    }

    var body: some View {
        TabView(selection: $selectedPane) {
            ForEach(SettingsPane.allCases) { pane in
                Form {
                    paneContent(pane)
                }
                .formStyle(.grouped)
                .controlSize(.regular)
                .frame(maxWidth: AppLayout.settingsWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle(pane.localizedTitle)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if pane == .network || pane == .bitTorrent || pane == .ed2k { engineSettingsFooter }
                }
                .tabItem { Label(pane.localizedTitle, systemImage: pane.symbol).accessibilityIdentifier(pane.accessibilityIdentifier) }
                .tag(pane)
                .accessibilityIdentifier("settings-current-pane-title")
            }
        }
        .frame(minWidth: 760, idealWidth: 800, minHeight: 560, idealHeight: 620)
        .onChange(of: selectedPane) { _, pane in
            if !AppLaunchConfiguration.isTestAutomation { UserDefaults.standard.set(pane.rawValue, forKey: "settings.lastPane") }
        }
        .onAppear {
            syncSharingModeSelectionFromStore()
            syncED2KSearchFileTypeSelectionFromStore()
            store.publishStartupAlerts()
            navigateToRequestedEngineSettings()
            navigateToRequestedAppUpdates()
        }
        .onChange(of: updates.settingsRequested) { _, _ in navigateToRequestedAppUpdates() }
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
            String(localized: "High Peer Limit"),
            isPresented: peerLimitConfirmationIsPresented,
            presenting: peerLimitConfirmation
        ) { confirmation in
            Button(String(localized: "Continue")) {
                store.engineSettings.btMaxPeers = confirmation.value
                peerLimitConfirmation = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                peerLimitConfirmation = nil
            }
        } message: { confirmation in
            Text(String(localized: "Max peers is set to \(confirmation.value). The recommended limit is 128 because higher values can increase memory and connection pressure."))
        }
    }

    private func navigateToRequestedAppUpdates() {
        guard updates.settingsRequested else { return }
        selectedPane = .general; updates.settingsRequested = false
    }

    private func navigateToRequestedEngineSettings() {
        guard store.consumeEngineSettingsRequest() else { return }
        selectedPane = .engine
    }

    @ViewBuilder
    private func paneContent(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: general
        case .downloads: downloads
        case .network: network
        case .bitTorrent: bitTorrent
        case .ed2k: ed2k
        case .integrations:
            protocols
            browserCapture
        case .engine: engine
        }
    }

    private var engineSettingsFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                Text(String(localized: "Saved automatically. Apply changes to the running engine; port changes require a restart."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(String(localized: "Apply Settings")) {
                    runStoreTask { await store.applyRuntimeEngineOptions() }
                }.disabled(!runtimeCanApplySettings)
            }
            .padding(.horizontal, AppLayout.settingsInset).padding(.vertical, AppLayout.groupInset)
            .frame(maxWidth: AppLayout.settingsWidth)
            .frame(maxWidth: .infinity)
        }.background(.background)
    }

    @ViewBuilder
    private var general: some View {
        SettingsSection(title: String(localized: "App Behavior")) {
            Toggle(String(localized: "Show in menu bar"), isOn: $store.preferences.showMenuBar)
            Toggle(String(localized: "Keep running after window closes"), isOn: $store.preferences.keepRunningAfterClose)
            Toggle(String(localized: "Prevent sleep while downloads are active"), isOn: $store.preferences.preventSleepDuringActiveDownloads)
            CompletionNotificationSetting(coordinator: store.notifications)
        }
        AppUpdateSettingsView(updates: updates)
    }

    @ViewBuilder
    private var downloads: some View {
        SettingsSection(title: String(localized: "Location")) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Default save location"))
                    Text(store.engineSettings.downloadDirectoryPath.map { DownloadLocationDisplay.path($0) } ?? String(localized: "No folder selected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(String(localized: "Choose Folder")) {
                    chooseDownloadFolder()
                }
            }
            Toggle(String(localized: "Auto organize files"), isOn: $store.preferences.autoOrganizeFiles)
        }

        SettingsSection(title: String(localized: "Removal")) {
            Toggle(String(localized: "Confirm before removing downloads"), isOn: confirmBeforeRemoveBinding)
            Toggle(
                String(localized: "Move files to Trash when confirmation is skipped"),
                isOn: $store.preferences.deleteFilesWhenSkippingRemoveConfirmation
            )
            .disabled(!store.preferences.suppressRemoveConfirmation)
        }
        BandwidthScheduleView()
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
        SettingsSection(title: String(localized: "Transfer")) {
            Stepper(value: $store.engineSettings.maxActiveDownloads, in: 1...100) {
                SettingValueRow(title: String(localized: "Max active downloads"), value: "\(store.engineSettings.maxActiveDownloads)")
            }
            Stepper(value: $store.engineSettings.maxConnectionsPerTask, in: 1...256) {
                SettingValueRow(title: String(localized: "Max connections per server"), value: "\(store.engineSettings.maxConnectionsPerTask)")
            }
            Stepper(value: $store.engineSettings.splitCount, in: 1...256) {
                SettingValueRow(title: String(localized: "Split count"), value: "\(store.engineSettings.splitCount)")
            }
            SpeedLimitStepper(
                title: String(localized: "Global download limit"),
                value: $store.engineSettings.maxOverallDownloadLimitKB
            )
            SpeedLimitStepper(
                title: String(localized: "Global upload limit"),
                value: $store.engineSettings.maxOverallUploadLimitKB
            )
        }

        SettingsSection(title: "HTTP") {
            TextField("User-Agent", text: $store.engineSettings.userAgent)
                .nativeTextFieldStyle()
                .frame(minWidth: 220, maxWidth: .infinity)
            HStack(spacing: 10) {
                TextField(String(localized: "Proxy URL"), text: $store.engineSettings.proxyURL)
                    .nativeTextFieldStyle()
                    .frame(minWidth: 220, maxWidth: .infinity)
                    Button {
                    store.applyDetectedSystemProxy()
                } label: {
                    Label(String(localized: "Detect System Proxy"), systemImage: "network")
                }
                .buttonStyle(.bordered)
            }
            TextField(String(localized: "Proxy bypass list"), text: $store.engineSettings.proxyBypass)
                .nativeTextFieldStyle()
                .frame(minWidth: 220, maxWidth: .infinity)
        }
        networkAdvanced
    }

    @ViewBuilder
    private var networkAdvanced: some View {
        SettingsSection(title: String(localized: "Retry and Disk")) {
            Stepper(value: $store.engineSettings.retryCount, in: 0...99) {
                SettingValueRow(title: String(localized: "Retry count"), value: store.engineSettings.retryCount == 0 ? String(localized: "Unlimited") : "\(store.engineSettings.retryCount)")
            }
            Stepper(value: $store.engineSettings.retryWaitSeconds, in: 1...300) {
                SettingValueRow(title: String(localized: "Retry wait"), value: String(localized: "\(store.engineSettings.retryWaitSeconds) s"))
            }
            Stepper(value: $store.engineSettings.connectTimeoutSeconds, in: 1...300) {
                SettingValueRow(title: String(localized: "Connect timeout"), value: String(localized: "\(store.engineSettings.connectTimeoutSeconds) s"))
            }
            Stepper(value: $store.engineSettings.timeoutSeconds, in: 1...300) {
                SettingValueRow(title: String(localized: "Transfer timeout"), value: String(localized: "\(store.engineSettings.timeoutSeconds) s"))
            }
            Picker(String(localized: "File allocation"), selection: $store.engineSettings.fileAllocation) {
                ForEach(FileAllocationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Toggle(String(localized: "Async DNS"), isOn: $store.engineSettings.asyncDNS)
        }

    }

    @ViewBuilder
    private var bitTorrent: some View {
        SettingsSection(title: String(localized: "Content")) {
            Text(String(localized: "ChopChop asks you to choose files before starting a torrent download."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-bt-file-selection-note")
            Toggle(String(localized: "Force BitTorrent encryption"), isOn: $store.engineSettings.btForceEncryption)
                .accessibilityIdentifier("settings-bt-force-encryption-toggle")
            Stepper(value: btMaxPeersBinding, in: 1...500) {
                SettingValueRow(title: String(localized: "Max peers"), value: "\(store.engineSettings.btMaxPeers)")
            }
            .accessibilityIdentifier("settings-bt-max-peers-stepper")
        }

        SettingsSection(title: String(localized: "Peer Discovery")) {
            Toggle("DHT", isOn: $store.engineSettings.btDHTEnabled)
                .accessibilityIdentifier("settings-bt-dht-toggle")
            Toggle(String(localized: "Peer exchange"), isOn: $store.engineSettings.btPeerExchangeEnabled)
                .accessibilityIdentifier("settings-bt-peer-exchange-toggle")
            Toggle(String(localized: "Local peer discovery"), isOn: $store.engineSettings.btLocalPeerDiscoveryEnabled)
                .accessibilityIdentifier("settings-bt-local-peer-discovery-toggle")
        }

        SettingsSection(title: String(localized: "Seeding")) {
            Picker(String(localized: "Seeding"), selection: $sharingModeSelection) {
                ForEach(BitTorrentSharingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings-bt-sharing-mode-picker")

            Stepper(value: $store.engineSettings.shareRatio, in: 1...100) {
                SettingValueRow(title: String(localized: "Stop at ratio"), value: store.engineSettings.keepSharing ? String(localized: "Disabled") : "\(store.engineSettings.shareRatio)")
            }
            .disabled(store.engineSettings.keepSharing)

            Stepper(value: $store.engineSettings.shareTimeMinutes, in: 1...20_160, step: 60) {
                SettingValueRow(title: String(localized: "Stop after"), value: store.engineSettings.keepSharing ? String(localized: "Disabled") : String(localized: "\(store.engineSettings.shareTimeMinutes) min"))
            }
            .disabled(store.engineSettings.keepSharing)
        }

        bitTorrentAdvanced
    }

    @ViewBuilder
    private var bitTorrentAdvanced: some View {
        SettingsSection(title: String(localized: "Ports")) {
            SettingsControlRow(title: String(localized: "BT listen port")) {
                TextField(String(localized: "BT listen port"), value: $store.engineSettings.listenPort, format: .number.grouping(.never))
                    .nativeTextFieldStyle()
                    .labelsHidden()
                    .frame(width: 112)
                    .accessibilityIdentifier("settings-bt-listen-port-field")
            }
            SettingsControlRow(title: String(localized: "DHT listen port")) {
                TextField(String(localized: "DHT listen port"), value: $store.engineSettings.dhtListenPort, format: .number.grouping(.never))
                    .nativeTextFieldStyle()
                    .labelsHidden()
                    .frame(width: 112)
                    .accessibilityIdentifier("settings-bt-dht-listen-port-field")
            }
        }

        SettingsSection(title: String(localized: "Tracker Sources")) {
            TrackerSourcesEditor(
                selectedSourceURLs: $store.engineSettings.trackerSourceURLs,
                customSourceURLs: $store.engineSettings.customTrackerSourceURLs
            )

            HStack {
                Button {
                    runStoreTask { await store.syncBitTorrentTrackersManually() }
                } label: {
                    Label(store.isSyncingTrackers ? String(localized: "Syncing") : String(localized: "Sync Trackers"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.isSyncingTrackers)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings-bt-sync-trackers-button")

                Spacer()

                Text(String(localized: "Last sync: \(lastTrackerSyncDescription)"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }

        SettingsSection(title: String(localized: "Tracker List")) {
            TrackerListEditor(trackerText: btTrackerTextBinding)

            Toggle(String(localized: "Sync tracker sources automatically"), isOn: $store.engineSettings.btTrackerAutoSync)
                .accessibilityIdentifier("settings-bt-tracker-auto-sync-toggle")

            Picker(String(localized: "Sync frequency:"), selection: $store.engineSettings.btTrackerSyncIntervalHours) {
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
            return String(localized: "Never")
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
        SettingsSection(title: String(localized: "Ports")) {
            SettingsControlRow(title: String(localized: "ED2K listen port")) {
                TextField(String(localized: "ED2K listen port"), value: $store.engineSettings.ed2kListenPort, format: .number.grouping(.never))
                    .nativeTextFieldStyle()
                    .labelsHidden()
                    .frame(width: 112)
                    .accessibilityIdentifier("settings-ed2k-listen-port-field")
            }
            SettingsControlRow(title: String(localized: "ED2K UDP listen port")) {
                TextField(String(localized: "ED2K UDP listen port"), value: $store.engineSettings.ed2kUDPListenPort, format: .number.grouping(.never))
                    .nativeTextFieldStyle()
                    .labelsHidden()
                    .frame(width: 112)
                    .accessibilityIdentifier("settings-ed2k-udp-listen-port-field")
            }
            Stepper(value: $store.engineSettings.ed2kUploadSlots, in: 1...100) {
                SettingValueRow(title: String(localized: "Upload slots"), value: "\(store.engineSettings.ed2kUploadSlots)")
            }
            .accessibilityIdentifier("settings-ed2k-upload-slots-stepper")
        }

        SettingsSection(title: String(localized: "Bootstrap")) {
            TextField(String(localized: "server.met URL"), text: $store.engineSettings.ed2kServerMetURL)
                .nativeTextFieldStyle()
                .frame(minWidth: 220, maxWidth: .infinity)
                .accessibilityIdentifier("settings-ed2k-server-met-url-field")
            TextField(String(localized: "nodes.dat URL"), text: $store.engineSettings.ed2kNodesDatURL)
                .nativeTextFieldStyle()
                .frame(minWidth: 220, maxWidth: .infinity)
                .accessibilityIdentifier("settings-ed2k-nodes-dat-url-field")

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "ED2K servers"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(String(localized: "One server per line, for example server.example:4661"), text: $store.engineSettings.ed2kServer, axis: .vertical)
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
                    Text(String(localized: "Use host:port format, one server per line."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(String(localized: "Sync bootstrap files automatically"), isOn: $store.engineSettings.ed2kBootstrapAutoSync)
                .accessibilityIdentifier("settings-ed2k-bootstrap-auto-sync-toggle")

            Picker(String(localized: "Sync frequency:"), selection: $store.engineSettings.ed2kBootstrapSyncIntervalHours) {
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
                    Label(store.isSyncingED2KBootstrap ? String(localized: "Syncing") : String(localized: "Sync Bootstrap Files"), systemImage: "arrow.triangle.2.circlepath")
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

        SettingsSection(title: String(localized: "Search")) {
            TextField(String(localized: "Keyword"), text: $store.ed2kSearchKeyword)
                .nativeTextFieldStyle()
                .frame(minWidth: 220, maxWidth: .infinity)
                .accessibilityIdentifier("settings-ed2k-search-keyword-field")

            Picker(String(localized: "File type:"), selection: $ed2kSearchFileTypeSelection) {
                ForEach(ED2KSearchFileType.allCases) { fileType in
                    Text(fileType.title).tag(fileType)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings-ed2k-search-file-type-picker")

            Stepper(value: $store.ed2kSearchMinSources, in: 1...9_999) {
                SettingValueRow(title: String(localized: "Minimum sources"), value: "\(store.ed2kSearchMinSources)")
            }

            Stepper(value: $store.engineSettings.ed2kSearchTimeoutSeconds, in: 10...600, step: 10) {
                SettingValueRow(title: String(localized: "Search timeout"), value: String(localized: "\(store.engineSettings.ed2kSearchTimeoutSeconds) s"))
            }
            .accessibilityIdentifier("settings-ed2k-search-timeout-stepper")

            HStack {
                Button {
                    runStoreTask { await store.startOrCancelED2KSearch() }
                } label: {
                    Label(store.isSearchingED2K ? String(localized: "Cancel Search") : String(localized: "Search"), systemImage: store.isSearchingED2K ? "xmark.circle" : "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings-ed2k-search-button")

                Text(ed2kSearchStatusDescription)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()
            }

            if store.ed2kSearchResults.isEmpty {
                Text(String(localized: "No ED2K search results."))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-ed2k-search-empty")
            } else {
                Table(store.ed2kSearchResults) {
                    TableColumn(String(localized: "Name")) { result in
                        Text(result.displayName)
                            .lineLimit(1)
                    }
                    TableColumn(String(localized: "Size")) { result in
                        Text(ByteFormat.size(result.lengthBytes))
                            .monospacedDigit()
                    }
                    TableColumn(String(localized: "Sources")) { result in
                        Text(result.sourceCount ?? "0")
                            .monospacedDigit()
                    }
                    TableColumn(String(localized: "Complete")) { result in
                        Text(result.completeSourceCount ?? "0")
                            .monospacedDigit()
                    }
                    TableColumn("") { result in
                        Button {
                            runStoreTask { await store.downloadED2KSearchResult(result) }
                        } label: {
                            Label(String(localized: "Download \(result.displayName)"), systemImage: "arrow.down.circle")
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
        let serverSize = store.ed2kBootstrapStatus.serverMetSize.map(ByteFormat.size) ?? String(localized: "Missing")
        let nodesSize = store.ed2kBootstrapStatus.nodesDatSize.map(ByteFormat.size) ?? String(localized: "Missing")
        let syncText = store.engineSettings.lastED2KBootstrapSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Never")
        return String(localized: "server.met \(serverSize), nodes.dat \(nodesSize) · Last sync \(syncText)")
    }

    private var ed2kSearchStatusDescription: String {
        if store.isSearchingED2K {
            return String(localized: "\(store.ed2kSearchElapsedSeconds)/\(store.engineSettings.ed2kSearchTimeoutSeconds) s · \(store.ed2kSearchResults.count) results")
        }
        return String(localized: "\(store.ed2kSearchResults.count) results")
    }

    private var protocols: some View {
        SettingsSection(title: String(localized: "Links and Files")) {
            Text(String(localized: "ChopChop supports HTTP, HTTPS, SFTP, Magnet, ED2K, torrent, and metalink downloads from the Add Download window."))
            Toggle(String(localized: "Receive Magnet links"), isOn: $store.preferences.handleMagnetLinks)
            Toggle(String(localized: "Receive ED2K links"), isOn: $store.preferences.handleED2KLinks)
            Toggle(String(localized: "Open Torrent files"), isOn: $store.preferences.handleTorrentFiles)
            Toggle(String(localized: "Open Metalink files"), isOn: $store.preferences.handleMetalinkFiles)
            Text(String(localized: "Drop links or files into the download window, or choose File → Open Download File…. Every import opens for review before downloading."))
                .foregroundStyle(.secondary)
            Text(String(localized: "To open a file from Finder, choose Open With → ChopChop. Your macOS default apps remain your choice; these options only control what ChopChop accepts."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var browserCapture: some View {
        SettingsSection(title: String(localized: "Browser Integration")) {
            BrowserIntegrationView(server: store.browserCapture)
        }
    }

    @ViewBuilder
    private var engine: some View {
        SettingsSection(title: "Aria2 Next") {
            EngineStatusView()
            KeyValueLine(title: String(localized: "Installed version"), value: store.engineVersionDescription)
            if let capabilities = store.engineCapabilities {
                KeyValueLine(title: String(localized: "Running version"), value: capabilities.version)
                if let features = capabilities.enabledFeatures {
                    KeyValueLine(title: String(localized: "Available features"), value: features.joined(separator: ", "))
                }
            }
            Text(String(localized: "Aria2 Next starts automatically when ChopChop opens. Restored downloads stay paused until you resume them."))
                .font(.callout).foregroundStyle(.secondary)
        }

        SettingsSection(title: String(localized: "Engine Update")) {
            VStack(alignment: .leading, spacing: 16) {
                if let progress = store.engineUpgradeProgress {
                    EngineInstallationProgressView(progress: progress, onCancel: store.cancelEngineUpdate)
                        .accessibilityIdentifier("settings-engine-update-progress")
                    Text(progress.canCancel
                         ? String(localized: "Your current engine stays available while the update downloads and is verified.")
                         : String(localized: "Downloads briefly pause while ChopChop finishes the update."))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    if let error = store.engineUpgradeError {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(String(localized: "The update couldn’t be completed"), systemImage: "exclamationmark.triangle.fill")
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
                        Text(String(localized: "ChopChop downloads and verifies the update before restarting the engine. Downloads briefly pause during the restart."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        if let release = store.availableEngineUpdate {
                            Button(store.engineUpgradeError == nil ? String(localized: "Update to \(release.version.description)") : String(localized: "Retry Update to \(release.version.description)")) {
                                store.updateEngine()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!store.canUpdateEngine)
                            .accessibilityIdentifier("settings-update-engine-button")
                        }
                        Button(String(localized: "Check for Updates")) { store.startEngineUpdateCheck() }
                            .disabled(store.installedEngine == nil || store.isCheckingEngineUpdate)
                        if store.isCheckingEngineUpdate { ProgressView().controlSize(.small) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        engineAdvanced
    }

    @ViewBuilder
    private var engineAdvanced: some View {
        SettingsSection(title: "RPC") {
            SecureField(String(localized: "RPC token"), text: $store.engineSettings.rpcToken)
                .nativeTextFieldStyle()
                .frame(minWidth: 220, maxWidth: .infinity)
            HStack {
                Button {
                    store.generateRPCToken()
                } label: {
                    Label(String(localized: "Generate Token"), systemImage: "key")
                }
                .buttonStyle(.bordered)

                TextField(String(localized: "Port"), value: $store.engineSettings.rpcPort, format: .number.grouping(.never))
                    .nativeTextFieldStyle()
                    .frame(width: 112)
                }
        }

        SettingsSection(title: String(localized: "Runtime")) {
            HStack(spacing: 10) {
                Button {
                    runStoreTask { await store.startEngine() }
                } label: {
                    Label(String(localized: "Start Engine"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canStartEngine)

                Button {
                    runStoreTask { await store.restartEngine() }
                } label: {
                    Label(String(localized: "Restart"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!store.canRestartEngine)

                Button {
                    runStoreTask { await store.stopEngine() }
                } label: {
                    Label(String(localized: "Stop"), systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!store.canStopEngine)

                Button {
                    runStoreTask { await store.applyRuntimeEngineOptions() }
                } label: {
                    Label(String(localized: "Apply Settings"), systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .disabled(!runtimeCanApplySettings)
            }
            RuntimeRequirementsView(missingRequirements: store.engineSettings.missingLaunchRequirements)
            KeyValueLine(title: String(localized: "State"), value: runtimeDescription)
            if let error = store.runtime.lastError {
                VStack(alignment: .leading, spacing: AppLayout.controlSpacing) {
                    Label(String(localized: "Last error"), systemImage: "exclamationmark.triangle")
                    Text(error)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        launchArguments
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Download Folder")
        panel.prompt = String(localized: "Choose")
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

    private var launchArguments: some View {
        SettingsSection(title: String(localized: "Launch Arguments")) {
            if store.runtime.lastLaunchArguments.isEmpty {
                Text(String(localized: "No engine launch arguments yet."))
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
            String(localized: "Stopped")
        case .starting:
            String(localized: "Starting")
        case .running(let pid):
            String(localized: "Running, PID \(String(pid))")
        case .stopping:
            String(localized: "Stopping")
        case .failed(let message):
            String(localized: "Failed: \(message)")
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
            Text(title).fixedSize(horizontal: false, vertical: true)
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
            SettingValueRow(title: title, value: value == 0 ? String(localized: "Unlimited") : "\(value) KB/s")
        }
    }
}

private struct TrackerSourcesEditor: View {
    @Binding var selectedSourceURLs: [String]
    @Binding var customSourceURLs: [String]
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
                    subtitle: String(localized: "Custom"),
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
                    subtitle: String(localized: "Selected source"),
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
        selectedCount == 1 ? String(localized: "1 source") : String(localized: "\(selectedCount) sources")
    }

    private var focusedCustomSource: TrackerSourceRowModel? {
        guard let focusedSourceID else { return nil }
        return sourceRows.first { $0.id == focusedSourceID && $0.isCustom }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                filterField
                Text(summary).font(.callout).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
            .padding(.bottom, 12)

            Divider()

            sourceList
                .frame(height: 260)

            Divider()

            addCustomSourceControls
                .padding(12)

            Divider()

            TrackerCommandRow(
                title: String(localized: "Remove Custom Source"),
                systemImage: "minus.circle",
                isEnabled: focusedCustomSource != nil,
                accessibilityIdentifier: "settings-bt-remove-custom-tracker-source-button",
                action: removeFocusedCustomSource
            )
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("settings-bt-tracker-sources-editor")
        .onChange(of: customSourceURLs) { _, _ in
            reconcileFocusedSource()
        }
        .onChange(of: selectedSourceURLs) { _, _ in
            reconcileFocusedSource()
        }
    }

    private var filterField: some View {
        TextField(String(localized: "Filter"), text: $filter)
            .nativeTextFieldStyle()
            .accessibilityIdentifier("settings-bt-tracker-source-filter-field")
    }

    private var sourceList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if filteredRows.isEmpty {
                    Text(String(localized: "No tracker sources match this filter."))
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
                TextField(String(localized: "Custom tracker source URL"), text: $newSourceURL)
                    .nativeTextFieldStyle()
                    .accessibilityIdentifier("settings-bt-custom-tracker-source-field")
                    .onSubmit(addCustomSource)

                Button(action: addCustomSource) {
                    Label(String(localized: "Add"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
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
            validationMessage = String(localized: "Enter a tracker source URL.")
            return
        }
        guard TrackerSourceURLValidator.isValid(url) else {
            validationMessage = String(localized: "Use an HTTP or HTTPS tracker source URL.")
            return
        }
        guard !sourceRows.contains(where: { $0.url == url }) else {
            focusedSourceID = sourceRows.first { $0.url == url }?.id
            validationMessage = String(localized: "Tracker source already exists.")
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

private struct TrackerListEditor: View {
    @Binding var trackerText: String
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
        return count == 1 ? String(localized: "1 tracker") : String(localized: "\(count) trackers")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                filterField
                Text(summary).font(.callout).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
            .padding(.bottom, 12)

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
        .accessibilityIdentifier("settings-bt-tracker-list-editor")
        .onAppear(perform: selectInitialTrackerIfNeeded)
        .onChange(of: trackerText) { _, _ in
            reconcileSelection()
        }
    }

    private var filterField: some View {
        TextField(String(localized: "Filter"), text: $filter)
            .nativeTextFieldStyle()
            .accessibilityIdentifier("settings-bt-tracker-filter-field")
    }

    private var trackerRows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if trackers.isEmpty {
                    Text(String(localized: "No trackers. Sync sources or add a tracker."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .accessibilityIdentifier("settings-bt-tracker-list-empty")
                } else if filteredTrackers.isEmpty {
                    Text(String(localized: "No trackers match this filter."))
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
                TextField(String(localized: "Add tracker URL"), text: $newTracker)
                    .nativeTextFieldStyle()
                    .accessibilityIdentifier("settings-bt-tracker-add-field")
                    .onSubmit(addTracker)

                Button(action: addTracker) {
                    Label(String(localized: "Add"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
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
        HStack(spacing: 12) {
            TrackerCommandRow(
                title: String(localized: "Remove Selected Tracker"),
                systemImage: "minus.circle",
                isEnabled: selectedTracker != nil,
                accessibilityIdentifier: "settings-bt-tracker-remove-button",
                action: removeSelectedTracker
            )

            TrackerCommandRow(
                title: showsRawEditor ? String(localized: "Hide Raw List") : String(localized: "Edit Raw List..."),
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
            Text(String(localized: "Raw tracker list"))
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
            validationMessage = String(localized: "Enter a tracker URL.")
            return
        }
        guard TrackerURLValidator.isValid(trimmed) else {
            validationMessage = String(localized: "Use an HTTP, HTTPS, or UDP tracker URL.")
            return
        }
        guard !trackers.contains(trimmed) else {
            selectedTracker = trimmed
            validationMessage = String(localized: "Tracker already exists.")
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
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct KeyValueLine: View {
    var title: String
    var value: String

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
        }
    }
}

private struct RuntimeRequirementsView: View {
    var missingRequirements: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if missingRequirements.isEmpty {
                RuntimeRequirementLine(
                    symbol: "checkmark.circle.fill",
                    title: String(localized: "Runtime requirements complete"),
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
            return String(localized: "Aria2 Next running")
        case .failed:
            return String(localized: "Aria2 Next failed")
        default:
            return store.engineSettings.canLaunch ? String(localized: "Aria2 Next ready") : String(localized: "Runtime setup incomplete")
        }
    }

    private var subtitle: String {
        let missingRequirements = store.engineSettings.missingLaunchRequirements
        if !missingRequirements.isEmpty {
            return String(localized: "Missing: \(missingRequirements.joined(separator: ", ")).")
        }
        switch store.runtime.phase {
        case .running: return String(localized: "The engine is ready to download files.")
        case .starting: return String(localized: "Starting the download engine…")
        default: return String(localized: "Aria2 Next starts automatically when ChopChop opens. Restored downloads stay paused until you resume them.")
        }
    }
}


private struct CompletionNotificationSetting: View {
    @EnvironmentObject private var store: DownloadStore
    @ObservedObject var coordinator: DownloadNotificationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(String(localized: "Notify when downloads complete"), isOn: Binding(
                get: { store.preferences.notifyOnDownloadCompletion },
                set: { enabled in Task { await store.setCompletionNotificationsEnabled(enabled) } }
            ))
            .disabled(coordinator.isRequestingPermission)
            Text(coordinator.status ?? String(localized: "Show a notification when a background download finishes. Notifications are quiet while ChopChop is active."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
