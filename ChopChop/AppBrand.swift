import AppKit
import SwiftUI

enum AppBrand {
    @MainActor
    static var menuBarImage: NSImage? {
        guard let image = NSImage(named: "MenuBarIcon")?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        image.accessibilityDescription = AppIdentity.displayName
        return image
    }
}

/// Native Icon Composer renders, with appearance selected by the asset catalog.
struct AppBrandIcon: View {
    var size: CGFloat

    var body: some View {
        Image("BrandIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
