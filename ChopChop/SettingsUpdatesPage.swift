import SwiftUI

extension SettingsView {
    @ViewBuilder
    var updateSettings: some View {
        SettingsSection(title: String(localized: "Update Checks")) {
            Toggle(String(localized: "Check for updates at launch"), isOn: $updates.automaticallyChecks)
                .settingsAnchor("updates.at-launch")
                .accessibilityIdentifier("settings-check-updates-at-launch")
            Text(String(localized: "Check ChopChop and Engine versions when the app opens. You choose when to download and install updates."))
                .font(.callout).foregroundStyle(.secondary)
            UpdateCheckRow(status: String(localized: "ChopChop and Engine"),
                           title: String(localized: "Check All Updates"),
                           isChecking: updates.isCheckingAll,
                           canCheck: updates.canCheckForUpdates && store.canCheckEngineUpdates,
                           identifier: "settings-check-updates-button") {
                Task { await updates.checkAll(using: store) }
            }
            .settingsAnchor("updates.check")
        }
        AppUpdateSettingsView(updates: updates, openUpdates: showAppUpdates)
            .settingsAnchor("updates.chopchop")
        engineUpdates
    }
}

/// All scopes use the same native control and reserve the icon slot while checking.
struct UpdateCheckRow: View {
    let status: String
    var title = String(localized: "Check for Updates")
    let isChecking: Bool
    let canCheck: Bool
    var accessibilityTitle: String? = nil
    let identifier: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(status)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(action: action) {
                ActionFeedbackLabel(title: title, systemImage: "arrow.clockwise",
                                    feedback: isChecking ? .working : .idle)
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(isChecking || !canCheck)
            .accessibilityLabel(accessibilityTitle ?? title)
            .accessibilityValue(isChecking ? String(localized: "Checking for updates…") : "")
            .accessibilityIdentifier(identifier)
        }
        .frame(minHeight: 28)
    }
}
