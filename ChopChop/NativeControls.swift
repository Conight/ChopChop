import AppKit
import SwiftUI

/// Layout is determined by a stable envelope, never by the current value.
/// Unlike a minimum width, the overlay cannot grow the envelope on a live tick.
struct StableMetricText: View {
    let value: String
    let reference: String
    var alignment: Alignment = .trailing

    var body: some View {
        Text(verbatim: reference).hidden().accessibilityHidden(true)
            .overlay(alignment: alignment) {
                Text(verbatim: value).lineLimit(1).minimumScaleFactor(0.75)
            }
            .monospacedDigit().fixedSize()
            .accessibilityElement(children: .ignore).accessibilityLabel(value)
    }
}

/// Keep the number's trailing edge and the unit's leading edge stationary.
/// A rate changing between B/s, KB/s and MB/s must not move its arrow or neighbor.
struct TransferByteValue: View {
    let bytes: Int64
    var perSecond = false

    var body: some View {
        let parts = ByteFormat.displayParts(bytes)
        HStack(spacing: 3) {
            StableMetricText(value: parts.count,
                reference: 999.99.formatted(.number.precision(.fractionLength(2)).grouping(.never)))
            ZStack(alignment: .leading) {
                ForEach(ByteFormat.displayUnits, id: \.self) { unit in
                    Text(verbatim: unit + (perSecond ? "/s" : "")).hidden().accessibilityHidden(true)
                }
            }
            .overlay(alignment: .leading) {
                Text(verbatim: parts.unit + (perSecond ? "/s" : "")).lineLimit(1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(perSecond ? ByteFormat.speed(bytes) : ByteFormat.size(bytes))
    }
}

struct TransferSpeedLabel: View {
    let speed: Int64
    let uploading: Bool
    var circled = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: (uploading ? "arrow.up" : "arrow.down") + (circled ? ".circle" : ""))
                .frame(width: circled ? 16 : 12)
            TransferByteValue(bytes: speed, perSecond: true)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(uploading ? String(localized: "Upload speed") : String(localized: "Download speed"))
        .accessibilityValue(ByteFormat.speed(speed))
    }
}

struct TransferSizeValue: View {
    let completed: Int64
    let total: Int64

    var body: some View {
        HStack(spacing: 3) {
            TransferByteValue(bytes: completed)
            Text(verbatim: "/")
            TransferByteValue(bytes: total)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ByteFormat.size(completed)) / \(ByteFormat.size(total))")
    }
}

struct TaskProgressValue: View {
    let task: DownloadTask
    var body: some View {
        StableMetricText(value: task.progressLabel,
            reference: task.media != nil && task.progressState.fraction == nil
                ? ByteFormat.duration(999 * 3_600 + 59 * 60) : "100%")
    }
}

/// Animate semantic changes, never an entire polling snapshot or a search query.
nonisolated enum AppMotion {
    static let duration = 0.18
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: duration)
    }
}

private struct StateChangeMotion<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value
    var enabled = true
    func body(content: Content) -> some View {
        content.animation(AppMotion.animation(reduceMotion: reduceMotion || !enabled), value: value)
    }
}

extension View {
    func stateChangeMotion<Value: Equatable>(_ value: Value, enabled: Bool = true) -> some View {
        modifier(StateChangeMotion(value: value, enabled: enabled))
    }
}

nonisolated enum ActionFeedback: Equatable {
    case idle, working, succeeded
}

private struct FeedbackRevision: Equatable {
    var feedback: ActionFeedback
    var revision: Int
}

/// The same icon slot and title envelope survive every operation state.
/// A successful operation gets one brief checkmark; failure never implies success.
struct ActionFeedbackLabel: View {
    let title: String
    let systemImage: String
    var feedback: ActionFeedback = .idle
    var successTitle: String? = nil
    var revision = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var successExpired = false

    private var showsSuccess: Bool { feedback == .succeeded && !successExpired }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: showsSuccess ? "checkmark" : systemImage)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .opacity(feedback == .working ? 0 : 1)
                .frame(width: 16, height: 16)
                .overlay {
                    if feedback == .working {
                        ProgressView().controlSize(.mini).accessibilityHidden(true)
                    }
                }
            ZStack {
                Text(title).hidden()
                if let successTitle { Text(successTitle).hidden() }
                Text(showsSuccess ? (successTitle ?? title) : title)
                    .contentTransition(.opacity)
            }
        }
        .stateChangeMotion(feedback)
        .stateChangeMotion(showsSuccess)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsSuccess ? (successTitle ?? title) : title)
        .accessibilityValue(feedback == .working ? String(localized: "In progress") : showsSuccess ? String(localized: "Completed") : "")
        .task(id: FeedbackRevision(feedback: feedback, revision: revision)) {
            successExpired = false
            guard feedback == .succeeded else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            successExpired = true
        }
    }
}

/// Operations continue if a settings page closes. Only the transient visual
/// confirmation is tied to the label's lifetime.
struct FeedbackButton: View {
    let title: String
    let systemImage: String
    var successTitle: String? = nil
    let action: @MainActor () async -> Bool
    @State private var feedback = ActionFeedback.idle
    @State private var revision = 0

    var body: some View {
        Button {
            guard feedback != .working else { return }
            revision += 1
            feedback = .working
            Task { feedback = await action() ? .succeeded : .idle }
        } label: {
            ActionFeedbackLabel(title: title, systemImage: systemImage, feedback: feedback, successTitle: successTitle, revision: revision)
        }
        .disabled(feedback == .working)
    }
}

/// AppKit owns ordering animations and cancellation when a panel reopens quickly.
@MainActor enum NativePanelMotion {
    static func prepare(_ panel: NSPanel) {
        panel.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
    }
}

/// App-owned spacing. Native List/Form chrome keeps its system metrics; only the
/// content inside each container uses these values. Each boundary owns its inset once.
nonisolated enum AppLayout {
    static let pageInset: CGFloat = 20
    static let sectionSpacing: CGFloat = 20
    static let groupInset: CGFloat = 12
    static let rowSpacing: CGFloat = 12
    static let controlSpacing: CGFloat = 8
    static let focusClearance: CGFloat = 4
    static let settingsWidth: CGFloat = 760
    static let settingsInset: CGFloat = 28
    static let detailInset: CGFloat = 24
    static let detailSectionSpacing: CGFloat = 20
    static let detailTabSpacing: CGFloat = 16
    static let formLabelWidth: CGFloat = 106
    static let detailLabelWidth: CGFloat = 112
    static let sheetWidth: CGFloat = 740
    static let sheetMinimumWidth: CGFloat = 660
    static let sheetHeight: CGFloat = 520
    static let sheetMinimumHeight: CGFloat = 400
    static let sheetBodyHeight: CGFloat = 360
    static let artworkWidth: CGFloat = 180
}

enum AppTypography {
    static let windowTitle = Font.title2.weight(.semibold)
    static let sectionTitle = Font.callout.weight(.semibold)
    static let fieldLabel = Font.callout.weight(.medium)
}

extension View {
    /// Content controls only. Apply inside the content container, never to a scene,
    /// NavigationSplitView or TabView: toolbars need their context-specific system
    /// sizing, shape and interaction rather than these inherited content overrides.
    func desktopControls() -> some View {
        buttonBorderShape(.capsule).controlSize(.regular)
    }

    @ViewBuilder
    func nativeTextFieldStyle() -> some View {
        if #available(macOS 27.0, *) {
            self.textFieldStyle(.bordered)
        } else {
            self.textFieldStyle(.roundedBorder)
        }
    }
}

nonisolated enum L10n {
    /// Only use for fixed display keys (e.g. persisted enum raw values), never user content.
    static func key(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// Interpolate only newly reported forward progress. The engine remains the source
/// of truth; no timer estimates additional bytes between updates.
nonisolated struct DownloadProgressAnimation: Equatable {
    static let duration = 0.25
    var value: Double
    var isActive: Bool

    func shouldAnimate(from previous: Self, reduceMotion: Bool) -> Bool {
        !reduceMotion && isActive && previous.isActive &&
            previous.value.isFinite && value.isFinite &&
            previous.value >= 0 && value > previous.value && value < 1
    }
}

struct AnimatedDownloadProgressView: View {
    let value: Double
    let isActive: Bool
    let reduceMotion: Bool
    @State private var displayedValue: Double

    init(value: Double, isActive: Bool, reduceMotion: Bool) {
        self.value = value
        self.isActive = isActive
        self.reduceMotion = reduceMotion
        _displayedValue = State(initialValue: value)
    }

    private var sample: DownloadProgressAnimation {
        DownloadProgressAnimation(value: value, isActive: isActive)
    }

    var body: some View {
        InterpolatedNativeProgress(value: displayedValue, reportedValue: value,
                                   interpolates: isActive && !reduceMotion)
            .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
            .onChange(of: sample) { previous, current in
                let animation: Animation? = current.shouldAnimate(from: previous, reduceMotion: reduceMotion)
                    ? .easeOut(duration: DownloadProgressAnimation.duration) : nil
                withAnimation(animation) { displayedValue = current.value }
            }
    }
}

/// Keep the platform's real ProgressView (NSProgressIndicator on macOS). Explicit
/// animatable data also interpolates native controls, not just SwiftUI geometry.
private struct InterpolatedNativeProgress: View, Animatable {
    var value: Double
    var reportedValue: Double
    var interpolates: Bool
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        ProgressView(value: interpolates ? min(value, reportedValue) : reportedValue)
            .progressViewStyle(.linear)
    }
}
