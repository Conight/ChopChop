import AppKit
import SwiftUI

struct EmptyContentState: View {
    var title: String
    var message: String
    var systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
                .accessibilityIdentifier("empty-state-title")
        } description: {
            Text(message)
                .accessibilityIdentifier("empty-state-message")
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct StatusBadge: View {
    var status: DownloadStatus
    var isSelected = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Label {
            Text(status.rawValue)
        } icon: {
            Image(systemName: status.symbolName)
                .foregroundStyle(isSelected ? Color.primary : status.tint)
        }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background((isSelected ? Color.primary : status.tint).opacity(0.10), in: Capsule())
            .overlay {
                if contrast == .increased {
                    Capsule().strokeBorder(.primary.opacity(0.55), lineWidth: 1)
                }
            }
    }
}

/// A status label inside the Engine settings button, not a second click target.
struct EngineUpdateBadge: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.up")
                .foregroundStyle(Color.accentColor)
            Text("New")
                .foregroundStyle(.primary)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
                .opacity(reduceTransparency ? 1 : 0)
            Capsule()
                .fill(Color.accentColor.opacity(contrast == .increased ? 0.20 : 0.12))
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    contrast == .increased ? Color.primary.opacity(0.55) : Color.accentColor.opacity(0.24),
                    lineWidth: contrast == .increased ? 1 : 0.5
                )
        }
        .fixedSize()
        .accessibilityLabel("Engine update available")
        .accessibilityIdentifier("sidebar-engine-update-badge")
    }
}

struct SpeedSparkline: View {
    var samples: [SpeedSample]
    var height: CGFloat = 56

    var body: some View {
        Canvas { context, size in
            let values = normalizedValues
            guard values.count > 1 else { return }
            let maximum = max(values.max() ?? 1, 1)
            let step = size.width / CGFloat(max(values.count - 1, 1))
            let baseline = size.height - 1

            for index in values.indices {
                let x = CGFloat(index) * step
                var guide = Path()
                guide.move(to: CGPoint(x: x, y: baseline))
                guide.addLine(to: CGPoint(x: x, y: size.height * 0.58))
                context.stroke(guide, with: .color(.accentColor.opacity(0.10)), lineWidth: 1)
            }

            var path = Path()
            for index in values.indices {
                let x = CGFloat(index) * step
                let y = baseline - (values[index] / maximum * (size.height - 6))
                if index == values.startIndex {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: baseline))
            fill.addLine(to: CGPoint(x: 0, y: baseline))
            fill.closeSubpath()
            context.fill(fill, with: .color(.accentColor.opacity(0.16)))
            context.stroke(path, with: .color(.accentColor), lineWidth: 2.5)
        }
        .frame(height: height)
        .accessibilityLabel("Recent download speed")
    }

    private var normalizedValues: [CGFloat] {
        let values = samples.map { CGFloat(max(0, $0.downloadBytesPerSecond)) }
        if values.isEmpty {
            return [0, 0]
        }
        if values.count == 1 {
            return [values[0], values[0]]
        }
        return values
    }
}

struct MetricColumn: View {
    var title: String
    var value: String
    var symbol: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .contentPanel()
    }
}

/// Content surfaces stay opaque; system navigation and toolbars supply their own material.
private struct ContentPanelModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : Color(nsColor: .separatorColor),
                                  lineWidth: contrast == .increased ? 1 : 0.5)
            }
    }
}

extension View {
    func contentPanel(cornerRadius: CGFloat = 10) -> some View {
        modifier(ContentPanelModifier(cornerRadius: cornerRadius))
    }
}
