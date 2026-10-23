import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    var general: some View {
        SettingsSection(title: String(localized: "App Behavior")) {
            Toggle(String(localized: "Show in menu bar"), isOn: Bindable(store).preferences.showMenuBar)
                .settingsAnchor("general.show-in-menu-bar")
                .accessibilityIdentifier("settings-show-menu-bar")
            Picker(String(localized: "Menu bar display"), selection: Bindable(store).preferences.menuBarDisplayMode) {
                ForEach(MenuBarDisplayMode.allCases) { mode in
                    Text(mode.localizedTitle).tag(mode)
                }
            }
            .disabled(!store.preferences.showMenuBar)
            .settingsAnchor("general.menu-bar-display")
            .accessibilityIdentifier("settings-menu-bar-display")
            Text(String(localized: "Shows ChopChop’s download and upload speeds."))
                .font(.callout).foregroundStyle(.secondary)
            Toggle(String(localized: "Keep running after window closes"), isOn: Bindable(store).preferences.keepRunningAfterClose)
            .settingsAnchor("general.keep-running-after-window-closes")
            Toggle(String(localized: "Prevent sleep while downloads are active"), isOn: Bindable(store).preferences.preventSleepDuringActiveDownloads)
            .settingsAnchor("general.prevent-sleep-while-downloads-are-active")
            CompletionNotificationSetting(coordinator: store.notifications).settingsAnchor("general.notifications")
        }
    }
}
