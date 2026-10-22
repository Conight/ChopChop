import AppKit
import SwiftUI
import XCTest

final class LayoutSynchronizationTests: XCTestCase {
    @MainActor
    func testLayoutReadsTheChangedModelRatherThanThePreviousFrame() async throws {
        let model = WidthModel()
        let fixture = NativeLayoutFixture(
            WidthFixture(model: model), size: NSSize(width: 400, height: 100),
            appearance: .aqua, windowChrome: false)
        defer { fixture.close() }
        func anchor(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "width-probe" { return view }
            return view.subviews.lazy.compactMap(anchor).first
        }
        await NativeLayout.flush(fixture.controller.view)
        let probe = try XCTUnwrap(anchor(fixture.controller.view))
        XCTAssertEqual(probe.bounds.width, 80, accuracy: 0.5)
        model.width = 220
        await NativeLayout.flush(fixture.controller.view)
        XCTAssertEqual(probe.bounds.width, 220, accuracy: 0.5,
                       "Layout checks must observe a model change before asserting its geometry")
    }

    @MainActor
    func testFrameObserverDetectsAnExcursionEvenWhenTheFinalFrameIsUnchanged() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let initial = window.frame
        let observation = WindowFrameObservation(window)
        window.setFrameOrigin(NSPoint(x: initial.minX + 40, y: initial.minY))
        window.setFrame(initial, display: false)
        XCTAssertEqual(window.frame, initial)
        XCTAssertTrue(observation.changes.contains { $0 != initial },
                      "A transient frame change must be caught even if it happens between display frames")
    }
}

@MainActor @Observable
private final class WidthModel { var width: CGFloat = 80 }

private struct WidthFixture: View {
    let model: WidthModel
    var body: some View { WidthProbe().frame(width: model.width, height: 24) }
}

private struct WidthProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("width-probe")
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
