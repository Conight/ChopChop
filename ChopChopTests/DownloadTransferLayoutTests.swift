import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ChopChop

final class DownloadTransferLayoutTests: XCTestCase {
    /// Verify native row geometry and export actual offscreen renders without
    /// activating a window, sending input events or connecting to the engine.
    @MainActor
    func testTorrentTransferLayoutKeepsRowGeometryStableDuringPolling() async throws {
        let store = DownloadStore(settingsStore: try PersistentSettingsStore(inMemory: true))
        defer { store.shutdown() }
        store.runtime.phase = .running(pid: 1)
        let presentation = TaskDetailsPresentation()
        let output = try Aria2NextPaths.supportDirectory().appendingPathComponent("Design Previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for width: CGFloat in [579, 719, 720, 840] {
            var task = fixture()
            store.tasks = [task]
            let host = NSHostingController(rootView:
                DownloadCanvas(destination: .all, onPaste: {}, onOpenFile: {}, showDetails: {}, toggleDetails: {})
                    .environmentObject(store).environmentObject(presentation))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 160),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.setContentSize(NSSize(width: width, height: 160))
            defer { window.close() }
            var geometry: RowGeometry?

            // A poll may change zero upload to a nonzero value and back. The
            // native row must not grow/shrink and move the following tasks.
            for speed: Int64 in [0, 987_654_321, 0] {
                task.uploadSpeed = speed
                store.tasks = [task]
                try await settle(host.view)
                geometry = try verifyLayout(in: host.view, width: width, expected: geometry)
                if speed > 0 {
                    let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                    host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent("transfer-list-\(Int(width)).png"))
                }
            }

            task.isSharing = true
            task.completedLength = task.totalLength
            task.downloadSpeed = 0
            store.tasks = [task]
            try await settle(host.view)
            try verifyLayout(in: host.view, width: width, expected: geometry)

            task = fixture()
            task.protocolKind = .http
            store.tasks = [task]
            try await settle(host.view)
            try verifyLayout(in: host.view, width: width, expected: geometry)

            for name in ["a.zip", String(repeating: "这是很长的下载文件名称 — ", count: 25) + ".zip"] {
                task.name = name
                store.tasks = [task]
                try await settle(host.view)
                try verifyLayout(in: host.view, width: width, expected: geometry)
            }

            for status in [DownloadStatus.completed, .paused, .waiting, .failed] {
                task = fixture()
                task.status = status
                if status == .completed { task.completedLength = task.totalLength }
                store.tasks = [task]
                try await settle(host.view)
                try verifyLayout(in: host.view, width: width, expected: geometry)
            }

            for phase in ["checking", "finalizing", "offline"] {
                task = fixture()
                task.isChecking = phase == "checking"
                task.isAvailableInEngine = phase != "offline"
                if phase == "finalizing" { task.media = MediaTaskProgress(state: "finalizing") }
                store.tasks = [task]
                try await settle(host.view)
                try verifyLayout(in: host.view, width: width, expected: geometry)
            }
        }
        print("TRANSFER_LIST_PREVIEW_OUTPUT=\(output.path)")
    }

    @MainActor
    func testNativeProgressInterpolatesOnlyReportedForwardAdvancement() async throws {
        let model = ProgressFixture(task: fixture())
        model.task.totalLength = 100
        model.task.completedLength = 20
        let host = NSHostingController(rootView: ProgressFixtureView(model: model))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 48),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentViewController = host
        window.setContentSize(NSSize(width: 220, height: 48))
        window.orderBack(nil)
        defer { window.close() }
        try await settle(host.view)

        func read() throws -> (Double, Bool) {
            host.view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
            let bar = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSProgressIndicator }.first)
            return ((bar.doubleValue - bar.minValue) / (bar.maxValue - bar.minValue), bar.isIndeterminate)
        }
        XCTAssertEqual(try read().0, 0.2, accuracy: 0.001, "Initial progress must not animate from zero")
        model.task.completedLength = 80
        var samples: [Double] = []
        for _ in 0..<16 {
            try await Task.sleep(for: .milliseconds(25))
            samples.append(try read().0)
        }
        XCTAssertTrue(samples.contains { $0 > 0.2 && $0 < 0.79 },
                      "The native indicator must actually show intermediate values, not merely carry an animation modifier")
        XCTAssertTrue(samples.allSatisfy { $0 >= 0.2 && $0 <= 0.8 + 0.000001 }, "Never overshoot reported progress")
        for (old, new) in zip(samples, samples.dropFirst()) { XCTAssertGreaterThanOrEqual(new + 0.000001, old) }
        XCTAssertEqual(try read().0, 0.8, accuracy: 0.001)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try read().0, 0.8, accuracy: 0.001, "No synthetic advancement between engine polls")

        model.task.completedLength = 30
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(try read().0, 0.3, accuracy: 0.001, "Corrections apply immediately")
        model.task.completedLength = 90
        try await Task.sleep(for: .milliseconds(40))
        model.reduceMotion = true
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(try read().0, 0.9, accuracy: 0.001, "Reduce Motion also interrupts an in-flight interpolation")
        model.task.completedLength = 95
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(try read().0, 0.95, accuracy: 0.001)

        model.reduceMotion = false
        model.task.status = .paused
        model.task.completedLength = 96
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(try read().0, 0.96, accuracy: 0.001, "Paused state must not keep animating")
        model.task.id = "another-task"
        model.task.status = .active
        model.task.completedLength = 45
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(try read().0, 0.45, accuracy: 0.001, "Switching tasks must not animate from the previous task")
        model.task.isChecking = true
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(try read().1)
        model.task.isChecking = false
        model.task.completedLength = 60
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(try read().0, 0.6, accuracy: 0.001, "Known progress starts at the reported value after checking")
        model.task.status = .completed
        model.task.completedLength = 100
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(try read().0, 1, accuracy: 0.001, "Completion must not wait for a cosmetic animation")
        print("NATIVE_PROGRESS_ANIMATION_SAMPLES=\(samples)")
    }

    @MainActor
    private func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
    }

    @MainActor
    @discardableResult
    private func verifyLayout(in view: NSView, width: CGFloat, expected: RowGeometry?,
                              file: StaticString = #filePath, line: UInt = #line) throws -> RowGeometry {
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let table = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTableView }.first, file: file, line: line)
        let scroll = try XCTUnwrap(table.enclosingScrollView, file: file, line: line)
        XCTAssertEqual(view.bounds.width, width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(table.numberOfRows, 1, file: file, line: line)
        XCTAssertLessThanOrEqual(table.bounds.width, scroll.contentView.bounds.width + 1, file: file, line: line)
        let height = table.rect(ofRow: 0).height
        XCTAssertGreaterThanOrEqual(height, 56, file: file, line: line)
        XCTAssertLessThanOrEqual(height, 70, file: file, line: line)
        let bar = try XCTUnwrap(descendants(table).compactMap { $0 as? NSProgressIndicator }.first, file: file, line: line)
        let progress = bar.convert(bar.bounds, to: table)
        if let expected {
            XCTAssertEqual(height, expected.height, accuracy: 1,
                           "Polling must not move subsequent rows when rates, ETA or phase change", file: file, line: line)
            XCTAssertEqual(progress.minX, expected.progress.minX, accuracy: 1,
                           "Changing the name or phase must not move the progress column", file: file, line: line)
            XCTAssertEqual(progress.width, expected.progress.width, accuracy: 1,
                           "Changing the name or phase must not resize the progress track", file: file, line: line)
        }
        return RowGeometry(height: height, progress: progress)
    }

    private struct RowGeometry {
        var height: CGFloat
        var progress: NSRect
    }

    private func fixture() -> DownloadTask {
        DownloadTask(id: "transfer-layout", name: "Sample footage collection with a long name",
            protocolKind: .bitTorrent, status: .active,
            totalLength: 900_000_000_000_000, completedLength: 450_000_000_000_000,
            downloadSpeed: 123_456_789, uploadSpeed: 0, connections: 24,
            destination: "~/Downloads", addedAt: Date(), errorMessage: nil,
            files: [], peers: [], trackers: [], recentLogs: [])
    }
}

@MainActor
private final class ProgressFixture: ObservableObject {
    @Published var task: DownloadTask
    @Published var reduceMotion = false
    init(task: DownloadTask) { self.task = task }
}

private struct ProgressFixtureView: View {
    @ObservedObject var model: ProgressFixture
    var body: some View {
        Group {
            if let fraction = model.task.progressState.fraction {
                AnimatedDownloadProgressView(value: fraction,
                    isActive: model.task.status == .active && model.task.isAvailableInEngine && !model.task.isSharing,
                    reduceMotion: model.reduceMotion)
                    .id(model.task.id)
            } else {
                TaskProgressIndicator(task: model.task)
            }
        }.padding(20)
    }
}
