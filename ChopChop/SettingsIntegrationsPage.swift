import AppKit
import SwiftUI

extension SettingsView {
    var protocols: some View {
        SettingsSection(title: String(localized: "Links and Files")) {
            Text(String(localized: "ChopChop supports HTTP, HTTPS, SFTP, Magnet, ED2K, torrent, and metalink downloads from the Add Download window."))
            Toggle(String(localized: "Receive Magnet links"), isOn: $store.preferences.handleMagnetLinks)
            .settingsAnchor("integrations.receive-magnet-links")
            Toggle(String(localized: "Receive ED2K links"), isOn: $store.preferences.handleED2KLinks)
            .settingsAnchor("integrations.receive-ed2k-links")
            Toggle(String(localized: "Open Torrent files"), isOn: $store.preferences.handleTorrentFiles)
            .settingsAnchor("integrations.open-torrent-files")
            Toggle(String(localized: "Open Metalink files"), isOn: $store.preferences.handleMetalinkFiles)
            .settingsAnchor("integrations.open-metalink-files")
            Text(String(localized: "Drop links or files into the download window, or choose File → Open Download File…. Every import opens for review before downloading."))
                .foregroundStyle(.secondary)
            Text(String(localized: "To open a file from Finder, choose Open With → ChopChop. Your macOS default apps remain your choice; these options only control what ChopChop accepts."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    var browserCapture: some View {
        SettingsSection(title: String(localized: "Browser Integration")) {
            BrowserIntegrationView(server: store.browserCapture).settingsAnchor("integrations.browser")
        }
    }
}
