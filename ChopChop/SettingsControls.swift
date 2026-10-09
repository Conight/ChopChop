import AppKit
import SwiftUI

struct SettingsSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if let title {
            Section(title) {
                content
            }
        } else {
            Section {
                content
            }
        }
    }
}

struct SettingsControlRow<Control: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var control: Control

    init(title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 24)
            control
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    }
}

struct SettingValueRow: View {
    var title: String
    var value: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

struct SpeedLimitStepper: View {
    var title: String
    @Binding var value: Int

    var body: some View {
        Stepper(value: $value, in: 0...1_048_576, step: 128) {
            SettingValueRow(title: title, value: value == 0 ? String(localized: "Unlimited") : String(localized: "\(value.formatted()) KiB/s"),
                subtitle: String(localized: "Across all tasks. Default: unlimited. Scheduled bandwidth can override this limit."))
        }
    }
}

struct KeyValueLine: View {
    var title: String
    var value: String

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
        }
    }
}

struct RuntimeRequirementsView: View {
    var missingRequirements: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if missingRequirements.isEmpty {
                RuntimeRequirementLine(
                    symbol: "checkmark.circle.fill",
                    title: String(localized: "Runtime requirements complete"),
                    tint: .green
                )
            } else {
                ForEach(missingRequirements, id: \.self) { requirement in
                    RuntimeRequirementLine(
                        symbol: "exclamationmark.circle",
                        title: requirement,
                        tint: .orange
                    )
                }
            }
        }
    }
}

struct RuntimeRequirementLine: View {
    var symbol: String
    var title: String
    var tint: Color

    var body: some View {
        Label {
            Text(title)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
    }
}

struct EngineStatusView: View {
    @EnvironmentObject private var store: DownloadStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var symbol: String {
        switch store.runtime.phase {
        case .running:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        default:
            store.engineSettings.canLaunch ? "cpu" : "exclamationmark.circle"
        }
    }

    private var tint: Color {
        switch store.runtime.phase {
        case .running:
            .green
        case .failed:
            .red
        default:
            store.engineSettings.canLaunch ? .cyan : .orange
        }
    }

    private var title: String {
        if let status = store.engineSetupState.statusLabel { return status }
        switch store.runtime.phase {
        case .running:
            return String(localized: "Aria2 Next running")
        case .failed:
            return String(localized: "Aria2 Next failed")
        default:
            return store.engineSettings.canLaunch ? String(localized: "Aria2 Next ready") : String(localized: "Runtime setup incomplete")
        }
    }

    private var subtitle: String {
        let missingRequirements = store.engineSettings.missingLaunchRequirements
        if !missingRequirements.isEmpty {
            return String(localized: "Missing: \(missingRequirements.joined(separator: ", ")).")
        }
        switch store.runtime.phase {
        case .running: return String(localized: "The engine is ready to download files.")
        case .starting: return String(localized: "Starting the download engine…")
        default: return String(localized: "Aria2 Next starts automatically when ChopChop opens. Restored downloads stay paused until you resume them.")
        }
    }
}


struct CompletionNotificationSetting: View {
    @EnvironmentObject private var store: DownloadStore
    @ObservedObject var coordinator: DownloadNotificationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(String(localized: "Notify when downloads complete"), isOn: Binding(
                get: { store.preferences.notifyOnDownloadCompletion },
                set: { enabled in Task { await store.setCompletionNotificationsEnabled(enabled) } }
            ))
            .disabled(coordinator.isRequestingPermission)
            Text(coordinator.status ?? String(localized: "Show a notification when a background download finishes. Notifications are quiet while ChopChop is active."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
