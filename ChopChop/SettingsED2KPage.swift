import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    var ed2k: some View {
        SettingsSection(title: String(localized: "Ports")) {
            SettingsControlRow(title: String(localized: "ED2K listen port")) {
                TextField(String(localized: "ED2K listen port"), value: $store.engineSettings.ed2kListenPort, format: .number.grouping(.never))
                    .nativeTextFieldStyle()
                    .labelsHidden()
                    .frame(width: 112)
                    .accessibilityIdentifier("settings-ed2k-listen-port-field")
            }
            .settingsAnchor("ed2k.ed2k-listen-port")
            SettingsControlRow(title: String(localized: "ED2K UDP listen port")) {
                TextField(String(localized: "ED2K UDP listen port"), value: $store.engineSettings.ed2kUDPListenPort, format: .number.grouping(.never))
                    .nativeTextFieldStyle()
                    .labelsHidden()
                    .frame(width: 112)
                    .accessibilityIdentifier("settings-ed2k-udp-listen-port-field")
            }
            .settingsAnchor("ed2k.ed2k-udp-listen-port")
            Stepper(value: $store.engineSettings.ed2kUploadSlots, in: 1...100) {
                SettingValueRow(title: String(localized: "Upload slots"), value: "\(store.engineSettings.ed2kUploadSlots)")
            }
            .accessibilityIdentifier("settings-ed2k-upload-slots-stepper")
            .settingsAnchor("ed2k.upload-slots")
        }

        SettingsSection(title: String(localized: "Bootstrap")) {
            TextField(String(localized: "server.met URL"), text: $store.engineSettings.ed2kServerMetURL)
                .nativeTextFieldStyle()
                .frame(minWidth: 220, maxWidth: .infinity)
                .accessibilityIdentifier("settings-ed2k-server-met-url-field")
            .settingsAnchor("ed2k.server-met-url")
            TextField(String(localized: "nodes.dat URL"), text: $store.engineSettings.ed2kNodesDatURL)
                .nativeTextFieldStyle()
                .frame(minWidth: 220, maxWidth: .infinity)
                .accessibilityIdentifier("settings-ed2k-nodes-dat-url-field")
            .settingsAnchor("ed2k.nodes-dat-url")

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
                    .settingsAnchor("ed2k.servers")
                if ED2KServerText.containsInvalidServer(in: store.engineSettings.ed2kServer) {
                    Text(String(localized: "Use host:port format, one server per line."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(String(localized: "Sync bootstrap files automatically"), isOn: $store.engineSettings.ed2kBootstrapAutoSync)
                .accessibilityIdentifier("settings-ed2k-bootstrap-auto-sync-toggle")
            .settingsAnchor("ed2k.sync-bootstrap-files-automatically")

            Picker(String(localized: "Sync frequency:"), selection: $store.engineSettings.ed2kBootstrapSyncIntervalHours) {
                ForEach(TrackerSyncInterval.allCases) { interval in
                    Text(interval.title).tag(interval.rawValue)
                }
            }
            .disabled(!store.engineSettings.ed2kBootstrapAutoSync)
            .accessibilityIdentifier("settings-ed2k-bootstrap-sync-frequency-picker")
            .settingsAnchor("ed2k.sync-frequency")

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
            .settingsAnchor("ed2k.syncing")
        }

        SettingsSection(title: String(localized: "Search")) {
            TextField(String(localized: "Keyword"), text: $store.ed2kSearchKeyword)
                .nativeTextFieldStyle()
                .frame(minWidth: 220, maxWidth: .infinity)
                .accessibilityIdentifier("settings-ed2k-search-keyword-field")
            .settingsAnchor("ed2k.keyword")

            Picker(String(localized: "File type:"), selection: $ed2kSearchFileTypeSelection) {
                ForEach(ED2KSearchFileType.allCases) { fileType in
                    Text(fileType.title).tag(fileType)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings-ed2k-search-file-type-picker")
            .settingsAnchor("ed2k.file-type")

            Stepper(value: $store.ed2kSearchMinSources, in: 1...9_999) {
                SettingValueRow(title: String(localized: "Minimum sources"), value: "\(store.ed2kSearchMinSources)")
            }
            .settingsAnchor("ed2k.minimum-sources")

            Stepper(value: $store.engineSettings.ed2kSearchTimeoutSeconds, in: 10...600, step: 10) {
                SettingValueRow(title: String(localized: "Search timeout"), value: String(localized: "\(store.engineSettings.ed2kSearchTimeoutSeconds) s"))
            }
            .accessibilityIdentifier("settings-ed2k-search-timeout-stepper")
            .settingsAnchor("ed2k.search-timeout")

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
            .settingsAnchor("ed2k.cancel-search")

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

    var ed2kBootstrapStatusDescription: String {
        let serverSize = store.ed2kBootstrapStatus.serverMetSize.map(ByteFormat.size) ?? String(localized: "Missing")
        let nodesSize = store.ed2kBootstrapStatus.nodesDatSize.map(ByteFormat.size) ?? String(localized: "Missing")
        let syncText = store.engineSettings.lastED2KBootstrapSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Never")
        return String(localized: "server.met \(serverSize), nodes.dat \(nodesSize) · Last sync \(syncText)")
    }

    var ed2kSearchStatusDescription: String {
        if store.isSearchingED2K {
            return String(localized: "\(store.ed2kSearchElapsedSeconds)/\(store.engineSettings.ed2kSearchTimeoutSeconds) s · \(store.ed2kSearchResults.count) results")
        }
        return String(localized: "\(store.ed2kSearchResults.count) results")
    }

    func syncED2KSearchFileTypeSelectionFromStore() {
        let fileType = store.ed2kSearchFileType
        guard ed2kSearchFileTypeSelection != fileType else { return }
        ed2kSearchFileTypeSelection = fileType
    }

    func commitED2KSearchFileTypeSelection(_ fileType: ED2KSearchFileType) {
        guard store.ed2kSearchFileType != fileType else { return }
        Task { @MainActor in
            await Task.yield()
            guard store.ed2kSearchFileType != fileType else { return }
            store.ed2kSearchFileType = fileType
        }
    }
}
