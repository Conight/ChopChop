import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    var downloads: some View {
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
            .settingsAnchor("downloads.default-save-location")
            Toggle(String(localized: "Auto organize files"), isOn: $store.preferences.autoOrganizeFiles)
            .settingsAnchor("downloads.auto-organize-files")
        }

        SettingsSection(title: String(localized: "Removal")) {
            Toggle(String(localized: "Confirm before removing downloads"), isOn: confirmBeforeRemoveBinding)
            .settingsAnchor("downloads.confirm-before-removing-downloads")
            Toggle(
                String(localized: "Move files to Trash when confirmation is skipped"),
                isOn: $store.preferences.deleteFilesWhenSkippingRemoveConfirmation
            )
            .disabled(!store.preferences.suppressRemoveConfirmation)
            .settingsAnchor("downloads.move-files-to-trash-when-confirmation-is-skipped")
        }
        BandwidthScheduleView()
            .settingsAnchor("downloads.bandwidth-schedule")
    }

    var confirmBeforeRemoveBinding: Binding<Bool> {
        Binding(
            get: { !store.preferences.suppressRemoveConfirmation },
            set: { store.preferences.suppressRemoveConfirmation = !$0 }
        )
    }

    func chooseDownloadFolder() {
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
}
