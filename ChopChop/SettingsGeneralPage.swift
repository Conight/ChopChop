import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    var general: some View {
        SettingsSection(title: String(localized: "App Behavior")) {
            Toggle(String(localized: "Show in menu bar"), isOn: $store.preferences.showMenuBar)
            .settingsAnchor("general.show-in-menu-bar")
            Toggle(String(localized: "Keep running after window closes"), isOn: $store.preferences.keepRunningAfterClose)
            .settingsAnchor("general.keep-running-after-window-closes")
            Toggle(String(localized: "Prevent sleep while downloads are active"), isOn: $store.preferences.preventSleepDuringActiveDownloads)
            .settingsAnchor("general.prevent-sleep-while-downloads-are-active")
            CompletionNotificationSetting(coordinator: store.notifications).settingsAnchor("general.notifications")
        }
        AppUpdateSettingsView(updates: updates, openUpdates: showAppUpdates)
            .settingsAnchor("general.chopchop-updates")
    }
}
