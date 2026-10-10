import SwiftUI

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
    static let sheetBodyHeight: CGFloat = 360
    static let artworkWidth: CGFloat = 180
    static let compactArtworkWidth: CGFloat = 72
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
