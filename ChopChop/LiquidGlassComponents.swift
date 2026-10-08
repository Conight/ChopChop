import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

/// Use Finder's file-type artwork without reading the downloaded file or generating thumbnails.
struct DownloadTaskIcon: View {
    let task: DownloadTask
    var size: CGFloat = 28
    @MainActor private static var icons: [UTType: NSImage] = [:]

    private var icon: NSImage {
        let type = task.isTorrentLike ? UTType.folder :
            (UTType(filenameExtension: (task.name as NSString).pathExtension) ?? .data)
        if let icon = Self.icons[type] { return icon }
        let icon = NSWorkspace.shared.icon(for: type)
        Self.icons[type] = icon
        return icon
    }

    var body: some View {
        Image(nsImage: icon).resizable().scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
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
            Text(String(localized: "New"))
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
        .accessibilityLabel(String(localized: "Engine update available"))
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
            let hasActivity = values.contains { $0 > 0 }
            if hasActivity {
                context.fill(fill, with: .linearGradient(Gradient(colors: [.accentColor.opacity(0.16), .accentColor.opacity(0.015)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
            }
        }
        .frame(height: height)
        .accessibilityLabel(String(localized: "Recent download speed"))
        .accessibilityValue(String(localized: "Current \(ByteFormat.speed(samples.last?.downloadBytesPerSecond ?? 0)), peak \(ByteFormat.speed(samples.map(\.downloadBytesPerSecond).max() ?? 0))"))
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

/// GroupBox supplies the platform surface; the group owns its content inset.
private struct ContentPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        GroupBox {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppLayout.groupInset)
        }
    }
}

extension View {
    func contentPanel() -> some View {
        modifier(ContentPanelModifier())
    }
}
