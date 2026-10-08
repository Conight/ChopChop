import AppKit
import SwiftUI
import XCTest
@testable import ChopChop

final class DownloadArtworkTests: XCTestCase {
    func testPausedClockDoesNotAdvanceOrJumpOnResume() {
        var clock = ArtworkClock()
        XCTAssertEqual(clock.elapsed(at: 100), 0)
        clock.setRunning(true, at: 100)
        XCTAssertEqual(clock.elapsed(at: 106), 6)
        clock.setRunning(true, at: 106) // Repeated visibility signals must not reset the phase.
        clock.setRunning(false, at: 110)
        XCTAssertEqual(clock.elapsed(at: 500), 10)
        clock.setRunning(false, at: 600)
        clock.setRunning(true, at: 1_000)
        XCTAssertEqual(clock.elapsed(at: 1_004), 14)
    }

    @MainActor
    func testHiddenWindowAndDetachStopActivityAndPaletteObservation() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let activity = ArtworkActivity()
        activity.attach(to: window)
        XCTAssertFalse(activity.canAnimate)
        XCTAssertTrue(activity.window === window)
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        XCTAssertEqual(activity.paletteRevision, 1)
        activity.attach(to: nil)
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        XCTAssertEqual(activity.paletteRevision, 1, "Detached art has no palette observers")
        XCTAssertFalse(activity.canAnimate)
        XCTAssertNil(activity.window)
        activity.attach(to: window)
        window.close()
        XCTAssertNil(activity.window)
        XCTAssertFalse(activity.canAnimate)
    }

    @MainActor
    func testWindowObserversDoNotRetainArtwork() {
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        weak var reference: ArtworkActivity?
        autoreleasepool {
            let activity = ArtworkActivity()
            reference = activity
            activity.attach(to: window)
        }
        XCTAssertNil(reference)
    }

    @MainActor
    func testFlowRendersOpaqueDistinctPalettesAndMotion() throws {
        let output = try Aria2NextPaths.supportDirectory().appendingPathComponent("Artwork Previews")
        let exporting = ProcessInfo.processInfo.environment["CHOPCHOP_DESIGN_RENDER"] == "1"
        if exporting { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        var rendered = Set<Data>()
        for (name, accent) in [("blue", Color.blue), ("purple", .purple), ("orange", .orange), ("graphite", .gray)] {
            for dark in [false, true] {
                for contrast in [false, true] {
                    let flow = DownloadFlowScene(elapsed: 0, accent: accent, dark: dark, increasedContrast: contrast)
                    let image = try bitmap(flow)
                    // Sample the full canvas, including its corners. Every pixel is opaque,
                    // so the same drawing also works when Reduce Transparency is enabled.
                    for x in stride(from: 0, to: image.pixelsWide, by: 29) {
                        for y in stride(from: 0, to: image.pixelsHigh, by: 37) {
                            XCTAssertEqual(try XCTUnwrap(image.colorAt(x: x, y: y)).alphaComponent, 1, accuracy: 0.001)
                        }
                    }
                    let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    XCTAssertTrue(rendered.insert(png).inserted, "Every palette/appearance should resolve independently")
                    if exporting {
                        try png.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light")\(contrast ? "-contrast" : "").png"))
                    }
                }
            }
        }
        let first = try bitmap(DownloadFlowScene(elapsed: 0, accent: .blue, dark: false))
        let later = try bitmap(DownloadFlowScene(elapsed: 7, accent: .blue, dark: false))
        XCTAssertNotEqual(first.representation(using: .png, properties: [:]), later.representation(using: .png, properties: [:]))
        if exporting { print("ARTWORK_PREVIEW_OUTPUT=\(output.path)") }
    }

    @MainActor
    private func bitmap(_ view: DownloadFlowScene) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: 180, height: 480))
        renderer.scale = 1
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }
}
