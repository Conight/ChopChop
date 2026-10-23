import AppKit
import XCTest
@testable import ChopChop

final class MacIntegrationTests: XCTestCase {
    @MainActor
    func testLastWindowCloseRespectsBackgroundDownloadPreference() throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        let delegate = ChopChopAppDelegate()
        delegate.configureApplicationServices(store: store)
        store.preferences.keepRunningAfterClose = true
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        store.preferences.keepRunningAfterClose = false
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }

    @MainActor
    func testDockKeepsNativeIconAndProgressViewsAcrossUpdates() {
        let view = DockDownloadProgressView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        let icon = view.iconView, bar = view.progressIndicator
        for fraction in [0.1, 0.5, 1.0] {
            var summary = DockDownloadProgress(tasks: [])
            summary.count = 1; summary.fraction = fraction
            view.update(summary); view.layoutSubtreeIfNeeded()
            XCTAssertTrue(view.iconView === icon)
            XCTAssertTrue(view.progressIndicator === bar)
            XCTAssertEqual(view.subviews.count, 2)
            XCTAssertEqual(bar.doubleValue, fraction)
            XCTAssertFalse(bar.isHidden)
        }
        view.update(DockDownloadProgress(tasks: []))
        XCTAssertTrue(bar.isHidden)
        XCTAssertTrue(bar.superview === view, "Unknown/idle progress hides rather than replaces the indicator")
    }
    func testDockUsesByteWeightedProgressAndExcludesPausedAndSeeding() throws {
        let values = #"[{"gid":"a","status":"active","totalLength":"100","completedLength":"100"},{"gid":"b","status":"waiting","totalLength":"900","completedLength":"0"},{"gid":"c","status":"paused","totalLength":"100","completedLength":"0"},{"gid":"d","status":"active","seeder":"true","totalLength":"100","completedLength":"100"}]"#
        var tasks = try JSONDecoder().decode([Aria2TaskDTO].self, from: Data(values.utf8)).map { $0.toTask() }
        let result = DockDownloadProgress(tasks: tasks)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.fraction, 0.1)
        tasks[0].totalLength = 0
        XCTAssertNil(DockDownloadProgress(tasks: tasks).fraction)
        XCTAssertEqual(DockDownloadProgress(tasks: tasks.map(\.disconnectedSnapshot)).count, 0)
    }

    @MainActor
    func testShortcutInputHasBoundsAndRejectsUnsupportedProtocols() throws {
        XCTAssertEqual(try DownloadIntentRouter.links(from: "https://example.com/a\nsftp://example.com/b").count, 2)
        XCTAssertThrowsError(try DownloadIntentRouter.links(from: "ftp://example.com/removed"))
        XCTAssertThrowsError(try DownloadIntentRouter.links(from: String(repeating: "x", count: 131_073)))
        XCTAssertThrowsError(try DownloadIntentRouter.links(from: (0...100).map { "https://example.com/\($0)" }.joined(separator: "\n")))
    }
}
