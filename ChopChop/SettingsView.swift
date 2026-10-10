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

struct PeerLimitConfirmation {
    var value: Int
}

struct SettingsView: View {
    private static let lastPaneKey = "settings.lastPane"
    @EnvironmentObject var store: DownloadStore
    @EnvironmentObject var updates: AppUpdateCoordinator
    @Environment(\.controlActiveState) var controlActiveState
    @Environment(\.openWindow) private var openWindow
    @StateObject var settingsSearch = SettingsSearchModel()
    @State var selectedPane: SettingsPane
    @State var presentedAlert: UserFacingAlert?
    @State var peerLimitConfirmation: PeerLimitConfirmation?
    @State var sharingModeSelection: BitTorrentSharingMode = .stopByCondition
    @State var ed2kSearchFileTypeSelection: ED2KSearchFileType = .any

    init(initialPane: SettingsPane? = nil, search: SettingsSearchModel? = nil) {
        _settingsSearch = StateObject(wrappedValue: search ?? SettingsSearchModel())
        let saved = AppLaunchConfiguration.isTestAutomation ? nil : UserDefaults.standard.string(forKey: Self.lastPaneKey)
        _selectedPane = State(initialValue: initialPane ?? saved.flatMap(SettingsPane.init(rawValue:)) ?? .general)
    }

    var body: some View {
        settingsNavigation
            .frame(minWidth: 860, idealWidth: 940, minHeight: 560, idealHeight: 640)
        .onChange(of: settingsSearch.navigationRequest) { _, request in
            if let request { selectedPane = request.entry.pane }
        }
        .onChange(of: selectedPane) { _, pane in
            if !AppLaunchConfiguration.isTestAutomation { UserDefaults.standard.set(pane.rawValue, forKey: Self.lastPaneKey) }
        }
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

    private var settingsNavigation: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            VStack(spacing: 0) {
                SettingsSearchField(model: settingsSearch)
                    .frame(height: 28)
                    .padding(12)
                List(SettingsPane.allCases, selection: sidebarSelection) { pane in
                    Label(pane.localizedTitle, systemImage: pane.symbol)
                        .tag(pane)
                        .accessibilityIdentifier(pane.accessibilityIdentifier)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 210, ideal: 210, max: 210)
            .accessibilityIdentifier("settings-sidebar")
        } detail: {
            SettingsPaneHost(content: settingsPage
                .environmentObject(store)
                .environmentObject(updates))
                .navigationTitle(selectedPane.localizedTitle)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var settingsPage: some View {
        ScrollViewReader { proxy in
            Form { paneContent(selectedPane) }
                .formStyle(.grouped)
                .frame(maxWidth: AppLayout.settingsWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if selectedPane == .network || selectedPane == .bitTorrent || selectedPane == .ed2k { engineSettingsFooter }
                }
                .task(id: settingsSearch.navigationRequest?.id) {
                    guard let request = settingsSearch.navigationRequest,
                          request.entry.pane == selectedPane else { return }
                    // The destination Form must be installed before resolving its anchor.
                    await Task.yield()
                    guard !Task.isCancelled, settingsSearch.navigationRequest == request else { return }
                    proxy.scrollTo(request.entry.id, anchor: .center)
                    settingsSearch.finishNavigation(request)
                }
        }
        .id(selectedPane)
        .desktopControls()
        .accessibilityIdentifier("settings-current-pane-title")
    }

    private func navigateToRequestedEngineSettings() {
        guard store.consumeEngineSettingsRequest() else { return }
        settingsSearch.cancel()
        selectedPane = .engine
    }

    func showAppUpdates() { openWindow(id: AppWindowID.updates) }

    private var sidebarSelection: Binding<SettingsPane?> {
        Binding(get: { selectedPane }, set: { pane in
            guard let pane else { return }
            settingsSearch.cancel()
            selectedPane = pane
        })
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

    var engineSettingsFooter: some View {
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

    func runStoreTask(_ operation: @escaping @MainActor () async -> Void) {
        DispatchQueue.main.async {
            Task { @MainActor in
                await operation()
            }
        }
    }


}

/// The native split owns the viewport. A long Form must not become its minimum height.
private struct SettingsPaneHost<Content: View>: NSViewControllerRepresentable {
    var content: Content

    func makeNSViewController(context: Context) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        return controller
    }

    func updateNSViewController(_ controller: NSHostingController<Content>, context: Context) {
        controller.rootView = content
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NSHostingController<Content>, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}
