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

struct SettingsNumberRow: View {
    var title: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1
    var subtitle: String? = nil
    var unit: SettingsIntegerFormat.Unit? = nil
    var zeroLabel: String? = nil
    var disabledLabel: String? = nil

    var body: some View {
        SettingsControlRow(title: title, subtitle: subtitle) {
            HStack(alignment: .center, spacing: 6) {
                TextField(
                    title, value: boundedValue,
                    format: SettingsIntegerFormat(range: range, unit: unit, zeroLabel: zeroLabel, disabledLabel: disabledLabel)
                )
                    .nativeTextFieldStyle()
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 112)
                Stepper(title, value: boundedValue, in: range, step: step)
                    .labelsHidden()
                    .fixedSize()
            }
            .controlSize(.small)
            .disabled(disabledLabel != nil)
        }
    }

    private var boundedValue: Binding<Int> {
        Binding(
            get: { value },
            set: { proposed in
                guard disabledLabel == nil else { return }
                let bounded = min(range.upperBound, max(range.lowerBound, proposed))
                if bounded != value { value = bounded }
            }
        )
    }
}

struct SettingsIntegerFormat: ParseableFormatStyle {
    enum Unit: String, Codable { case seconds, minutes, kibibytesPerSecond }

    var range: ClosedRange<Int>
    var unit: Unit? = nil
    var zeroLabel: String? = nil
    var disabledLabel: String? = nil

    func format(_ value: Int) -> String {
        if let disabledLabel { return disabledLabel }
        if value == 0, let zeroLabel { return zeroLabel }
        switch unit {
        case .seconds: return String(localized: "\(value) s")
        case .minutes: return String(localized: "\(value) min")
        case .kibibytesPerSecond: return String(localized: "\(String(value)) KiB/s")
        case nil: return String(value)
        }
    }

    var parseStrategy: Strategy { Strategy(format: self) }

    struct Strategy: ParseStrategy {
        var format: SettingsIntegerFormat

        func parse(_ value: String) throws -> Int {
            guard format.disabledLabel == nil else { throw CocoaError(.formatting) }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == format.zeroLabel, format.range.contains(0) { return 0 }
            let plainInteger = Int(text)
            let integer = plainInteger ?? (try? IntegerFormatStyle<Int>.number.parseStrategy.parse(text))
            guard let integer, format.range.contains(integer),
                  plainInteger != nil || text == format.format(integer) || text == integer.formatted() else {
                throw CocoaError(.formatting)
            }
            return integer
        }
    }
}

struct SpeedLimitStepper: View {
    var title: String
    @Binding var value: Int

    var body: some View {
        SettingsNumberRow(
            title: title, value: $value, range: 0...1_048_576, step: 128,
            subtitle: String(localized: "Across all tasks. Default: unlimited. Scheduled bandwidth can override this limit."),
            unit: .kibibytesPerSecond, zeroLabel: String(localized: "Unlimited")
        )
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

struct EngineStatusView: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "cpu")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text("Aria2 Next").font(.headline)
                HStack(spacing: 6) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: hasIssue ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(hasIssue ? Color.orange : Color.green)
                    }
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("settings-engine-status")
    }

    private var isBusy: Bool {
        if store.isUpdatingEngine || store.engineSetupState == .checking || store.engineSetupState.isInstalling { return true }
        switch store.runtime.phase {
        case .starting, .stopping: return true
        default: return false
        }
    }

    private var hasIssue: Bool {
        if store.engineSetupState.requiresInstallation || store.connectionIssue != nil { return true }
        switch store.runtime.phase {
        case .stopped, .failed: return true
        default: return false
        }
    }

    private var status: String {
        if let progress = store.engineUpgradeProgress { return progress.title }
        if let status = store.engineSetupState.statusLabel { return status }
        switch store.runtime.phase {
        case .running:
            return store.connectionIssue == nil ? String(localized: "Running") : String(localized: "Reconnecting…")
        case .starting: return String(localized: "Starting the download engine…")
        case .stopping: return String(localized: "Stopping…")
        case .failed: return String(localized: "Connection Needs Attention")
        case .stopped: return String(localized: "Not Running")
        }
    }
}

struct CompletionNotificationSetting: View {
    @Environment(DownloadStore.self) private var store
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
