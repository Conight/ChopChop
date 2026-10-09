import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    var network: some View {
        SettingsSection(title: String(localized: "Transfer")) {
            Stepper(value: $store.engineSettings.maxActiveDownloads, in: 1...100) {
                SettingValueRow(title: String(localized: "Max active downloads"), value: "\(store.engineSettings.maxActiveDownloads)", subtitle: String(localized: "Tasks that can run together. Default: 6."))
            }
            .settingsAnchor("network.max-active-downloads")
            Stepper(value: $store.engineSettings.maxConnectionsPerTask, in: 1...256) {
                SettingValueRow(title: String(localized: "Max connections per server"), value: "\(store.engineSettings.maxConnectionsPerTask)", subtitle: String(localized: "Upper limit for each server, per task. Default: 64; the server may allow fewer."))
            }
            .settingsAnchor("network.max-connections-per-server")
            Stepper(value: $store.engineSettings.splitCount, in: 1...256) {
                SettingValueRow(title: String(localized: "Split count"), value: "\(store.engineSettings.splitCount)", subtitle: String(localized: "Maximum parallel parts per task. Small files and servers without range support may use fewer."))
            }
            .settingsAnchor("network.split-count")
            SpeedLimitStepper(
                title: String(localized: "Global download limit"),
                value: $store.engineSettings.maxOverallDownloadLimitKB
            )
            .settingsAnchor("network.global-download-limit")
            SpeedLimitStepper(
                title: String(localized: "Global upload limit"),
                value: $store.engineSettings.maxOverallUploadLimitKB
            )
            .settingsAnchor("network.global-upload-limit")
        }

        SettingsSection(title: "HTTP") {
            TextField("User-Agent", text: $store.engineSettings.userAgent)
                .nativeTextFieldStyle()
                .frame(minWidth: 220, maxWidth: .infinity)
            .settingsAnchor("network.user-agent")
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
            .settingsAnchor("network.proxy-url")
            TextField(String(localized: "Proxy bypass list"), text: $store.engineSettings.proxyBypass)
                .nativeTextFieldStyle()
                .frame(minWidth: 220, maxWidth: .infinity)
            .settingsAnchor("network.proxy-bypass-list")
        }
        networkAdvanced
    }

    @ViewBuilder
    var networkAdvanced: some View {
        SettingsSection(title: String(localized: "Retry and Disk")) {
            Stepper(value: $store.engineSettings.retryCount, in: 0...99) {
                SettingValueRow(title: String(localized: "Retry count"), value: store.engineSettings.retryCount == 0 ? String(localized: "Unlimited") : "\(store.engineSettings.retryCount)", subtitle: String(localized: "0 retries indefinitely. Default: unlimited."))
            }
            .settingsAnchor("network.retry-count")
            Stepper(value: $store.engineSettings.retryWaitSeconds, in: 1...300) {
                SettingValueRow(title: String(localized: "Retry wait"), value: String(localized: "\(store.engineSettings.retryWaitSeconds) s"), subtitle: String(localized: "Delay between retries. Default: 10 seconds."))
            }
            .settingsAnchor("network.retry-wait")
            Stepper(value: $store.engineSettings.connectTimeoutSeconds, in: 1...300) {
                SettingValueRow(title: String(localized: "Connect timeout"), value: String(localized: "\(store.engineSettings.connectTimeoutSeconds) s"), subtitle: String(localized: "Time allowed to establish a connection. Default: 10 seconds."))
            }
            .settingsAnchor("network.connect-timeout")
            Stepper(value: $store.engineSettings.timeoutSeconds, in: 1...300) {
                SettingValueRow(title: String(localized: "Transfer timeout"), value: String(localized: "\(store.engineSettings.timeoutSeconds) s"), subtitle: String(localized: "Time without receiving data before retrying. Default: 10 seconds."))
            }
            .settingsAnchor("network.transfer-timeout")
            Picker(String(localized: "File allocation"), selection: $store.engineSettings.fileAllocation) {
                ForEach(FileAllocationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .settingsAnchor("network.file-allocation")
            Toggle(String(localized: "Async DNS"), isOn: $store.engineSettings.asyncDNS)
            .settingsAnchor("network.async-dns")
        }

    }
}
