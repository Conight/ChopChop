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
    static let taskIconSize: CGFloat = 20
    static let taskTextInset: CGFloat = taskIconSize + controlSpacing
}

extension View {
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
