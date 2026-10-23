import AppKit
import CoreText
import SwiftUI

/// Keep menu bar presentation in a system scene, independently of ordinary app
/// windows and their Spaces. No private popover windows or activation switching.
struct ChopChopMenuBarScene: Scene {
    let store: DownloadStore

    var body: some Scene {
        MenuBarExtra(isInserted: AppLaunchConfiguration.isTestAutomation ? .constant(false) : isInserted) {
            MenuBarPanel().environment(store)
        } label: {
            MenuBarStatusLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }

    var isInserted: Binding<Bool> {
        Binding {
            store.preferences.showMenuBar
        } set: { isInserted in
            // SwiftUI can write back the current insertion value during scene
            // updates. Avoid invalidating the graph and saving it again.
            guard store.preferences.showMenuBar != isInserted else { return }
            store.preferences.showMenuBar = isInserted
        }
    }
}

nonisolated struct MenuBarTransferRates: Equatable, Sendable {
    let download: Int64
    let upload: Int64

    init(download: Int64, upload: Int64) {
        self.download = max(0, download)
        self.upload = max(0, upload)
    }
}

nonisolated struct MenuBarStatusSnapshot: Equatable, Sendable {
    let isVisible: Bool
    let mode: MenuBarDisplayMode
    let rates: MenuBarTransferRates?

    @MainActor
    init(store: DownloadStore) {
        isVisible = store.preferences.showMenuBar
        mode = store.preferences.menuBarDisplayMode
        // An icon-only or hidden item doesn't observe continuously changing rates.
        guard isVisible, mode.showsSpeed,
              case .running = store.runtime.phase, store.connectionIssue == nil else {
            rates = nil
            return
        }
        rates = MenuBarTransferRates(download: store.activeSpeed, upload: store.uploadSpeed)
    }

    var accessibilityValue: String? {
        guard mode.showsSpeed else { return nil }
        guard let rates else { return String(localized: "Transfer speeds unavailable") }
        return String(localized: "Download speed: \(ByteFormat.speed(rates.download))") + ", " +
            String(localized: "Upload speed: \(ByteFormat.speed(rates.upload))")
    }

    var toolTip: String {
        [AppIdentity.displayName, accessibilityValue].compactMap { $0 }.joined(separator: "\n")
    }
}

/// SwiftUI observes only the properties read by the snapshot, so hidden and
/// icon-only modes don't subscribe to continuously changing speed samples.
struct MenuBarStatusLabel: View {
    let store: DownloadStore

    var body: some View {
        let snapshot = MenuBarStatusSnapshot(store: store)
        Group {
            if let image = MenuBarStatusAppearance.image(for: snapshot) {
                Image(nsImage: image).renderingMode(.template)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppIdentity.displayName)
        .accessibilityValue(snapshot.accessibilityValue ?? "")
        .accessibilityIdentifier("menu-bar-status")
        .help(snapshot.toolTip)
    }
}

/// One template image centers the icon and both rows as a single system label.
@MainActor
enum MenuBarStatusAppearance {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    private static let unitFont = NSFont.systemFont(ofSize: 8.5, weight: .regular)
    // Use the full system working area so small-font rasterization has a gutter
    // at both 1× and 2× without changing the centered artwork's visual position.
    private static let imageHeight: CGFloat = 22
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.usesSignificantDigits = true
        formatter.minimumSignificantDigits = 1
        formatter.maximumSignificantDigits = 3
        return formatter
    }()
    private static let countWidth = ceil([888, 88.8, 8.88].map {
        (formatter.string(from: NSNumber(value: $0))! as NSString).size(withAttributes: [.font: font]).width
    }.max()!)
    private static let unitWidth = ceil(ByteFormat.displayUnits.map {
        ("\($0)/s" as NSString).size(withAttributes: [.font: unitFont]).width
    }.max()!)

    private static func imageWidth(for mode: MenuBarDisplayMode) -> CGFloat {
        (mode.showsIcon ? 22 : 0) + 8 + countWidth + 2 + unitWidth + 1
    }

    /// Three significant digits keep the visual columns compact. Spoken and
    /// tooltip values retain the app's full localized ByteFormat output.
    static func speedText(_ bytes: Int64?) -> ByteFormat.DisplayParts {
        guard let bytes else { return .init(count: "—", unit: "") }
        var value = Double(max(0, bytes))
        var unit = value == 0 ? 1 : 0
        while value >= 1_000, unit < ByteFormat.displayUnits.count - 1 {
            value /= 1_000
            unit += 1
        }
        // Promote before rounding, avoiding a misleading 1,000 KB/s column.
        if value >= 999.5, unit < ByteFormat.displayUnits.count - 1 {
            value /= 1_000
            unit += 1
        }
        return .init(count: formatter.string(from: NSNumber(value: value)) ?? "—",
                     unit: "\(ByteFormat.displayUnits[unit])/s")
    }

    private struct Row {
        let count: CTLine
        let unit: CTLine
        let countAdvance: CGFloat
        let inkBounds: CGRect

        init(_ bytes: Int64?) {
            let text = speedText(bytes)
            count = CTLineCreateWithAttributedString(NSAttributedString(
                string: text.count, attributes: [.font: font, .foregroundColor: NSColor.black]))
            unit = CTLineCreateWithAttributedString(NSAttributedString(
                string: text.unit, attributes: [.font: unitFont, .foregroundColor: NSColor.black.withAlphaComponent(0.85)]))
            countAdvance = CTLineGetTypographicBounds(count, nil, nil, nil)
            let countBounds = CTLineGetBoundsWithOptions(count, .useGlyphPathBounds)
            inkBounds = text.unit.isEmpty ? countBounds : countBounds.union(CTLineGetBoundsWithOptions(unit, .useGlyphPathBounds))
        }
    }

    static func image(for snapshot: MenuBarStatusSnapshot) -> NSImage? {
        let icon = snapshot.mode.showsIcon ? AppBrand.menuBarImage : nil
        guard snapshot.mode.showsSpeed else { return icon }
        let rows = [Row(snapshot.rates?.download), Row(snapshot.rates?.upload)]
        let speedX: CGFloat = snapshot.mode.showsIcon ? 22 : 0
        let countRight = speedX + 8 + countWidth
        let unitX = countRight + 2
        let size = NSSize(width: imageWidth(for: snapshot.mode), height: imageHeight)
        let image = NSImage(size: size, flipped: false) { _ in
            icon?.draw(in: NSRect(x: 0, y: (size.height - 16) / 2, width: 16, height: 16))
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.textMatrix = .identity
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.8))
            context.setLineWidth(1)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for (index, row) in rows.enumerated() {
                let centerY = size.height / 2 + (index == 0 ? 5 : -5)
                let baseline = centerY - row.inkBounds.midY
                context.textPosition = CGPoint(x: countRight - row.countAdvance, y: baseline)
                CTLineDraw(row.count, context)
                context.textPosition = CGPoint(x: unitX, y: baseline)
                CTLineDraw(row.unit, context)

                // Small direction marks share the visual center of each row.
                let x = speedX + 4
                let tipY = centerY + (index == 0 ? -3 : 3)
                let tailY = centerY + (index == 0 ? 3 : -3)
                let shoulderY = tipY + (index == 0 ? 2 : -2)
                context.move(to: CGPoint(x: x, y: tailY))
                context.addLine(to: CGPoint(x: x, y: tipY))
                context.move(to: CGPoint(x: x - 2, y: shoulderY))
                context.addLine(to: CGPoint(x: x, y: tipY))
                context.addLine(to: CGPoint(x: x + 2, y: shoulderY))
                context.strokePath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

}
