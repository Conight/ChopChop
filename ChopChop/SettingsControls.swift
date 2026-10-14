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
    @Environment(DownloadStore.self) private var store

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
