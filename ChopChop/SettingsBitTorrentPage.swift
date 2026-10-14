import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    var bitTorrent: some View {
        SettingsSection(title: String(localized: "Content")) {
            Text(String(localized: "ChopChop asks you to choose files before starting a torrent download."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-bt-file-selection-note")
            Toggle(String(localized: "Force BitTorrent encryption"), isOn: Bindable(store).engineSettings.btForceEncryption)
                .accessibilityIdentifier("settings-bt-force-encryption-toggle")
            .settingsAnchor("bitTorrent.force-bittorrent-encryption")
            SettingsNumberRow(
                title: String(localized: "Max peers"), value: btMaxPeersBinding, range: 1...500,
                subtitle: String(localized: "Per torrent. Default: 128. Higher limits use more memory and connections.")
            )
            .accessibilityIdentifier("settings-bt-max-peers-stepper")
            .settingsAnchor("bitTorrent.max-peers")
        }

        SettingsSection(title: String(localized: "Client Identity")) {
            LabeledContent("User-Agent", value: BitTorrentClientIdentity.current.userAgent)
                .textSelection(.enabled)
            LabeledContent(String(localized: "Peer ID prefix"), value: BitTorrentClientIdentity.current.peerIDPrefix)
                .textSelection(.enabled)
            Text(String(localized: "ChopChop identifies itself to trackers and peers. The version follows the installed app."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .settingsAnchor("bitTorrent.client-identity")

        SettingsSection(title: String(localized: "Peer Discovery")) {
            Toggle("DHT", isOn: Bindable(store).engineSettings.btDHTEnabled)
                .accessibilityIdentifier("settings-bt-dht-toggle")
            .settingsAnchor("bitTorrent.dht")
            Toggle(String(localized: "Peer exchange"), isOn: Bindable(store).engineSettings.btPeerExchangeEnabled)
                .accessibilityIdentifier("settings-bt-peer-exchange-toggle")
            .settingsAnchor("bitTorrent.peer-exchange")
            Toggle(String(localized: "Local peer discovery"), isOn: Bindable(store).engineSettings.btLocalPeerDiscoveryEnabled)
                .accessibilityIdentifier("settings-bt-local-peer-discovery-toggle")
            .settingsAnchor("bitTorrent.local-peer-discovery")
        }

        SettingsSection(title: String(localized: "Seeding")) {
            Picker(String(localized: "Seeding"), selection: $sharingModeSelection) {
                ForEach(BitTorrentSharingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings-bt-sharing-mode-picker")
            .settingsAnchor("bitTorrent.seeding")

            Text(String(localized: "Seeding continues after the download finishes. Configure global upload bandwidth in Network and individual torrent limits in Details → Network."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.engineSettings.keepSharing {
                Text(String(localized: "Continuous seeding removes the default ratio and time limits. Tasks with individual limits keep them. Restored tasks remain paused until you resume them."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            SettingsNumberRow(
                title: String(localized: "Stop at ratio"), value: Bindable(store).engineSettings.shareRatio, range: 1...100,
                subtitle: String(localized: "Uploaded bytes divided by downloaded bytes. Default: 2."),
                disabledLabel: store.engineSettings.keepSharing ? String(localized: "Disabled") : nil
            )
            .disabled(store.engineSettings.keepSharing)
            .settingsAnchor("bitTorrent.stop-at-ratio")

            SettingsNumberRow(
                title: String(localized: "Stop after"), value: Bindable(store).engineSettings.shareTimeMinutes, range: 1...20_160, step: 60,
                subtitle: String(localized: "Maximum time spent seeding after completion. Default: 2,880 minutes."),
                unit: .minutes,
                disabledLabel: store.engineSettings.keepSharing ? String(localized: "Disabled") : nil
            )
            .disabled(store.engineSettings.keepSharing)
            .settingsAnchor("bitTorrent.stop-after")
        }

        bitTorrentAdvanced
    }

    @ViewBuilder
    var bitTorrentAdvanced: some View {
        SettingsSection(title: String(localized: "Ports")) {
            SettingsControlRow(title: String(localized: "BT listen port")) {
                TextField(String(localized: "BT listen port"), value: Bindable(store).engineSettings.listenPort, format: .number.grouping(.never))
                    .nativeTextFieldStyle()
                    .labelsHidden()
                    .frame(width: 112)
                    .accessibilityIdentifier("settings-bt-listen-port-field")
            }
            .settingsAnchor("bitTorrent.bt-listen-port")
            Text(String(localized: "DHT uses the BT listen port."))
                .font(.callout).foregroundStyle(.secondary)
        }

        SettingsSection(title: String(localized: "Tracker Sources")) {
            TrackerSourcesEditor(
                selectedSourceURLs: Bindable(store).engineSettings.trackerSourceURLs,
                customSourceURLs: Bindable(store).engineSettings.customTrackerSourceURLs
            ).settingsAnchor("bitTorrent.tracker-sources")

            HStack {
                Button {
                    runStoreTask { await store.syncBitTorrentTrackersManually() }
                } label: {
                    ActionFeedbackLabel(title: String(localized: "Sync Trackers"), systemImage: "arrow.triangle.2.circlepath", feedback: store.trackerSyncFeedback)
                }
                .disabled(store.isSyncingTrackers)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings-bt-sync-trackers-button")

                Spacer()

                Text(String(localized: "Last sync: \(lastTrackerSyncDescription)"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .settingsAnchor("bitTorrent.syncing")
            if let issue = store.trackerSyncIssue {
                Text(issue).font(.callout).foregroundStyle(.red)
            }
        }

        SettingsSection(title: String(localized: "Tracker List")) {
            TrackerListEditor(trackerText: btTrackerTextBinding).settingsAnchor("bitTorrent.tracker-list")

            Toggle(String(localized: "Sync tracker sources automatically"), isOn: Bindable(store).engineSettings.btTrackerAutoSync)
                .accessibilityIdentifier("settings-bt-tracker-auto-sync-toggle")
            .settingsAnchor("bitTorrent.sync-tracker-sources-automatically")

            Picker(String(localized: "Sync frequency:"), selection: Bindable(store).engineSettings.btTrackerSyncIntervalHours) {
                ForEach(TrackerSyncInterval.allCases) { interval in
                    Text(interval.title).tag(interval.rawValue)
                }
            }
            .disabled(!store.engineSettings.btTrackerAutoSync)
            .accessibilityIdentifier("settings-bt-tracker-sync-frequency-picker")
            .settingsAnchor("bitTorrent.sync-frequency")
        }
    }

    var peerLimitConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { peerLimitConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    peerLimitConfirmation = nil
                }
            }
        )
    }

    var btMaxPeersBinding: Binding<Int> {
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

    var btTrackerTextBinding: Binding<String> {
        Binding(
            get: { store.engineSettings.btTracker },
            set: { store.engineSettings.btTracker = $0 }
        )
    }

    var lastTrackerSyncDescription: String {
        guard let lastTrackerSyncAt = store.engineSettings.lastTrackerSyncAt else {
            return String(localized: "Never")
        }
        return lastTrackerSyncAt.formatted(date: .abbreviated, time: .shortened)
    }

    func syncSharingModeSelectionFromStore() {
        let mode = store.engineSettings.sharingMode
        guard sharingModeSelection != mode else { return }
        sharingModeSelection = mode
    }

    func commitSharingModeSelection(_ mode: BitTorrentSharingMode) {
        let keepSharing = mode == .manualStop
        guard store.engineSettings.keepSharing != keepSharing else { return }
        Task { @MainActor in
            await Task.yield()
            guard store.engineSettings.keepSharing != keepSharing else { return }
            store.engineSettings.keepSharing = keepSharing
        }
    }
}
