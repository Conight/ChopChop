import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    var engine: some View {
        SettingsSection(title: "Aria2 Next") {
            EngineStatusView()
            KeyValueLine(title: String(localized: "Installed version"), value: store.engineVersionDescription).settingsAnchor("engine.version")
            if let capabilities = store.engineCapabilities {
                KeyValueLine(title: String(localized: "Running version"), value: capabilities.version)
                if !capabilities.enabledFeatures.isEmpty {
                    KeyValueLine(title: String(localized: "Available features"), value: capabilities.enabledFeatures.joined(separator: ", "))
                }
            }
            Text(String(localized: "Aria2 Next starts automatically when ChopChop opens. Restored downloads stay paused until you resume them."))
                .font(.callout).foregroundStyle(.secondary)
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
                        if let release = store.selectedEngineRelease {
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
        if release.version == store.installedEngine?.version { return String(localized: "Installed") }
        if store.engineUpgradeError != nil { return String(localized: "Retry Installation") }
        if let installed = store.installedEngine, release.version < installed.version {
            return String(localized: "Switch to \(release.version.description)")
        }
        return String(localized: "Update to \(release.version.description)")
    }

    @ViewBuilder
    var engineAdvanced: some View {
        SettingsSection(title: "RPC") {
            SecureField(String(localized: "RPC token"), text: Bindable(store).engineSettings.rpcToken)
                .settingsAnchor("engine.rpc-token")
                .nativeTextFieldStyle()
                .frame(minWidth: 220, maxWidth: .infinity)
            HStack {
                Button {
                    store.generateRPCToken()
                } label: {
                    Label(String(localized: "Generate Token"), systemImage: "key")
                }
                .buttonStyle(.bordered)

                TextField(String(localized: "Port"), value: Bindable(store).engineSettings.rpcPort, format: .number.grouping(.never))
                    .nativeTextFieldStyle()
                    .frame(width: 112)
                }
            .settingsAnchor("engine.rpc-port")
            Text(String(localized: "Changing the RPC port or token requires restarting the engine."))
                .font(.caption).foregroundStyle(.secondary)
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
                    ActionFeedbackLabel(title: String(localized: "Apply Settings"), systemImage: "slider.horizontal.3", feedback: store.runtimeSettingsFeedback)
                }
                .buttonStyle(.bordered)
                .disabled(!runtimeCanApplySettings || store.runtimeSettingsFeedback == .working)
            }
            .settingsAnchor("engine.start-engine")
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

    var launchArguments: some View {
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

    var runtimeDescription: String {
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

    var runtimeCanApplySettings: Bool {
        guard !store.isUpdatingEngine else { return false }
        return switch store.runtime.phase {
        case .running:
            true
        case .stopped, .starting, .stopping, .failed:
            false
        }
    }
}
