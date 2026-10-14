import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    var network: some View {
        SettingsSection(title: String(localized: "Transfer")) {
            SettingsNumberRow(
                title: String(localized: "Max active downloads"), value: Bindable(store).engineSettings.maxActiveDownloads, range: 1...100,
                subtitle: String(localized: "Tasks that can run together. Default: 6.")
            )
            .settingsAnchor("network.max-active-downloads")
            SettingsNumberRow(
                title: String(localized: "Max connections per server"), value: Bindable(store).engineSettings.maxConnectionsPerTask, range: 1...256,
                subtitle: String(localized: "Upper limit for each server, per task. Default: 64; the server may allow fewer.")
            )
            .settingsAnchor("network.max-connections-per-server")
            SettingsNumberRow(
                title: String(localized: "Split count"), value: Bindable(store).engineSettings.splitCount, range: 1...256,
                subtitle: String(localized: "Maximum parallel parts per task. Small files and servers without range support may use fewer.")
            )
            .settingsAnchor("network.split-count")
            SpeedLimitStepper(
                title: String(localized: "Global download limit"),
                value: Bindable(store).engineSettings.maxOverallDownloadLimitKB
            )
            .settingsAnchor("network.global-download-limit")
            SpeedLimitStepper(
                title: String(localized: "Global upload limit"),
                value: Bindable(store).engineSettings.maxOverallUploadLimitKB
            )
            .settingsAnchor("network.global-upload-limit")
        }

        SettingsSection(title: "HTTP") {
            TextField("User-Agent", text: Bindable(store).engineSettings.userAgent)
                .nativeTextFieldStyle()
                .frame(minWidth: 220, maxWidth: .infinity)
            .settingsAnchor("network.user-agent")
            HStack(spacing: 10) {
                TextField(String(localized: "Proxy URL"), text: Bindable(store).engineSettings.proxyURL)
                    .nativeTextFieldStyle()
                    .frame(minWidth: 220, maxWidth: .infinity)
                    Button {
                    store.applyDetectedSystemProxy()
                } label: {
                    Label(String(localized: "Detect System Proxy"), systemImage: "network")
                }
                .buttonStyle(.bordered)
            }
            .settingsAnchor("network.proxy-url")
            TextField(String(localized: "Proxy bypass list"), text: Bindable(store).engineSettings.proxyBypass)
                .nativeTextFieldStyle()
                .frame(minWidth: 220, maxWidth: .infinity)
            .settingsAnchor("network.proxy-bypass-list")
        }
        networkAdvanced
    }

    @ViewBuilder
    var networkAdvanced: some View {
        SettingsSection(title: String(localized: "Retry and Disk")) {
            SettingsNumberRow(
                title: String(localized: "Maximum attempts"), value: Bindable(store).engineSettings.retryCount, range: 1...99,
                subtitle: String(localized: "Includes the first connection attempt. Default: 3. Repeated failures stop the download and show an error.")
            )
            .settingsAnchor("network.retry-count")
            SettingsNumberRow(
                title: String(localized: "Retry wait"), value: Bindable(store).engineSettings.retryWaitSeconds, range: 1...300,
                subtitle: String(localized: "Delay between retries. Default: 10 seconds."),
                unit: .seconds
            )
            .settingsAnchor("network.retry-wait")
            SettingsNumberRow(
                title: String(localized: "Connect timeout"), value: Bindable(store).engineSettings.connectTimeoutSeconds, range: 1...300,
                subtitle: String(localized: "Time allowed to establish a connection. Default: 10 seconds."),
                unit: .seconds
            )
            .settingsAnchor("network.connect-timeout")
            SettingsNumberRow(
                title: String(localized: "Transfer timeout"), value: Bindable(store).engineSettings.timeoutSeconds, range: 1...300,
                subtitle: String(localized: "Time without receiving data before retrying. Default: 10 seconds."),
                unit: .seconds
            )
            .settingsAnchor("network.transfer-timeout")
            Picker(String(localized: "File allocation"), selection: Bindable(store).engineSettings.fileAllocation) {
                ForEach(FileAllocationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .settingsAnchor("network.file-allocation")
        }

    }
}
