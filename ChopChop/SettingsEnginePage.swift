import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    var engine: some View {
        SettingsSection {
            EngineStatusView()
            KeyValueLine(title: String(localized: "Installed version"), value: store.engineVersionDescription)
                .settingsAnchor("engine.version")
            Text(String(localized: "ChopChop manages the engine automatically. Restored downloads stay paused until you resume them."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(String(localized: "Engine Updates…")) { selectedPane = .updates }
                Spacer()
                Link(String(localized: "Engine on GitHub"), destination: EngineDistribution.repositoryURL)
            }
        }

        if let issue = engineConnectionIssue {
            SettingsSection(title: String(localized: "Connection Needs Attention")) {
                Text(issue).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Retry Connection")) {
                    if case .running = store.runtime.phase { engineRestartConfirmation = true }
                    else { runStoreTask { await store.restartEngine() } }
                }
                    .disabled(!store.canRestartEngine)
                    .accessibilityIdentifier("settings-engine-retry-button")
            }
        }
        engineAdvanced
    }

    var engineUpdates: some View {
        SettingsSection(title: String(localized: "Engine")) {
            KeyValueLine(title: String(localized: "Installed version"), value: store.engineVersionDescription)
            EngineVersionPicker(showsRefreshButton: false, loadsAutomatically: false)
            UpdateCheckRow(status: store.engineUpdateStatus,
                           isChecking: store.isCheckingEngineUpdate,
                           canCheck: store.canCheckEngineUpdates,
                           accessibilityTitle: String(localized: "Check Engine Updates"),
                           identifier: "settings-check-engine-updates-button") {
                store.startEngineUpdateCheck()
            }
            .settingsAnchor("updates.check-engine")
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
                    }

                    if store.hasEngineVersionChange {
                        Text(String(localized: "ChopChop downloads and verifies the update before restarting the engine. Downloads briefly pause during the restart."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        if let release = store.selectedEngineRelease,
                           store.engineSetupState.requiresInstallation || store.hasEngineVersionChange {
                            Button(engineVersionActionTitle(release)) {
                                if store.engineSetupState.requiresInstallation { store.installRequiredEngine() }
                                else { store.updateEngine() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.engineSetupState.requiresInstallation ? !store.canInstallRequiredEngine : !store.canUpdateEngine)
                            .accessibilityIdentifier("settings-update-engine-button")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .stateChangeMotion(store.engineUpgradeProgress != nil)
            .stateChangeMotion(store.engineUpgradeError != nil)
            .stateChangeMotion(store.engineUpgradeResult != nil)
            .settingsAnchor("engine.update")
        }

    }

    private func engineVersionActionTitle(_ release: EngineRelease) -> String {
        if store.installedEngine == nil { return String(localized: "Download and Start") }
        if store.engineUpgradeError != nil { return String(localized: "Retry Installation") }
        if let installed = store.installedEngine, release.version < installed.version {
            return String(localized: "Switch to \(release.version.description)")
        }
        return String(localized: "Update to \(release.version.description)")
    }

    var engineAdvanced: some View {
        SettingsSection {
            DisclosureGroup(String(localized: "Advanced"), isExpanded: $engineAdvancedExpanded) {
                SettingsControlRow(title: String(localized: "RPC port"),
                                   subtitle: String(localized: "Local connection between ChopChop and its engine. Change only if the port is in use.")) {
                    TextField(String(localized: "RPC port"), value: Bindable(store).engineSettings.rpcPort, format: .number.grouping(.never))
                        .nativeTextFieldStyle().labelsHidden().frame(width: 112)
                }
                .settingsAnchor("engine.rpc-port")
                Text(String(localized: "Connection authentication is generated and managed by ChopChop."))
                    .font(.caption).foregroundStyle(.secondary)
                if !store.engineSettings.missingLaunchRequirements.isEmpty {
                    Text(store.engineSettings.missingLaunchRequirements.joined(separator: "\n"))
                        .font(.callout).foregroundStyle(.orange)
                }
                if let capabilities = store.engineCapabilities {
                    KeyValueLine(title: String(localized: "Running version"), value: capabilities.version)
                    if !capabilities.enabledFeatures.isEmpty {
                        KeyValueLine(title: String(localized: "Available features"), value: capabilities.enabledFeatures.joined(separator: ", "))
                    }
                }
                if case .running(let pid) = store.runtime.phase {
                    KeyValueLine(title: "PID", value: String(pid))
                    Button(String(localized: "Restart Engine…")) { engineRestartConfirmation = true }
                        .disabled(!store.canRestartEngine)
                        .accessibilityIdentifier("settings-engine-restart-button")
                }
                if !store.runtime.lastLaunchArguments.isEmpty {
                    DisclosureGroup(String(localized: "Launch Arguments")) {
                        Text(store.runtime.lastLaunchArguments.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .settingsAnchor("engine.advanced")
        }
    }

    private var engineConnectionIssue: String? {
        guard !store.engineSetupState.requiresInstallation,
              store.engineSetupState != .checking, !store.isUpdatingEngine else { return nil }
        switch store.runtime.phase {
        case .failed(let message): return message
        case .stopped: return String(localized: "The engine is unavailable. Retry the connection to restore access to your downloads.")
        case .running: return store.connectionIssue
        case .starting, .stopping: return nil
        }
    }
}
