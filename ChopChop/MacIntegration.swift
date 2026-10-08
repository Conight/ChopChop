import AppIntents
import AppKit
import QuickLook
import Combine
import Darwin
import SwiftUI

nonisolated struct DockDownloadProgress: Equatable, Sendable {
    var count: Int
    var fraction: Double?

    init(tasks: [DownloadTask]) {
        let transferring = tasks.filter { $0.isAvailableInEngine && !$0.isSharing && ($0.status == .active || $0.status == .waiting) }
        count = transferring.count
        guard !transferring.isEmpty, transferring.allSatisfy({ $0.progressState.fraction != nil }) else {
            fraction = nil; return
        }
        if transferring.allSatisfy({ $0.media == nil && $0.totalLength > 0 }) {
            let total = transferring.reduce(0.0) { $0 + Double($1.totalLength) }
            fraction = transferring.reduce(0.0) { $0 + Double(min($1.totalLength, max(0, $1.completedLength))) } / total
        } else {
            fraction = transferring.compactMap { $0.progressState.fraction }.reduce(0, +) / Double(count)
        }
    }
}

@MainActor
final class DockDownloadProgressController {
    private var subscription: AnyCancellable?
    private weak var store: DownloadStore?
    func configure(store: DownloadStore) {
        guard !AppLaunchConfiguration.isTestAutomation, self.store !== store else { return }
        self.store = store
        subscription = store.$tasks.map { DockDownloadProgress(tasks: $0) }.removeDuplicates()
            .sink { [weak self] in self?.update($0) }
    }
    private func update(_ summary: DockDownloadProgress) {
        let tile = NSApp.dockTile
        guard summary.count > 0 else { tile.badgeLabel = nil; tile.contentView = nil; tile.display(); return }
        tile.badgeLabel = summary.count > 99 ? "99+" : String(summary.count)
        let view = NSView(frame: NSRect(origin: .zero, size: tile.size))
        let icon = NSImageView(frame: view.bounds)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(icon)
        if let fraction = summary.fraction {
            let bar = NSProgressIndicator(frame: NSRect(x: tile.size.width * 0.12, y: tile.size.height * 0.10,
                                                        width: tile.size.width * 0.76, height: 12))
            bar.style = .bar; bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1
            bar.doubleValue = fraction; view.addSubview(bar)
        }
        tile.contentView = view; tile.display()
    }
}

@MainActor
final class DownloadIntentRouter {
    static let shared = DownloadIntentRouter()
    weak var store: DownloadStore?

    static func links(from text: String) throws -> [String] {
        guard text.utf8.count <= 131_072 else { throw DownloadOperationError(String(localized: "Send no more than 128 KiB of download links at once.")) }
        let resources = try AddDownloadDraft(rawInput: text).normalizedResources()
        guard !resources.isEmpty, resources.count <= 100 else { throw DownloadOperationError(String(localized: "Send between 1 and 100 download links.")) }
        return resources
    }

    func add(_ text: String) throws {
        let resources = try Self.links(from: text)
        guard let store else { throw DownloadOperationError(String(localized: "Open ChopChop before running this shortcut.")) }
        store.importDownloads([.text(resources.joined(separator: "\n"))])
        store.downloadWindowRequests.send()
    }
}

struct AddDownloadLinksIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Download Links"
    static let description = IntentDescription("Review download links in ChopChop before starting them. Accepts text or URLs from earlier shortcut actions.")
    static let openAppWhenRun = true
    @Parameter(title: "Links", description: "One HTTP, HTTPS, SFTP, Magnet, or ED2K link per line.")
    var links: String
    static var parameterSummary: some ParameterSummary { Summary("Review \(\.$links) in ChopChop") }

    @MainActor
    func perform() async throws -> some IntentResult {
        try DownloadIntentRouter.shared.add(links)
        return .result()
    }
}

struct PauseDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Downloads"
    static let description = IntentDescription("Pause downloads and cancel enabled scheduled starts in ChopChop.")
    static let openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let store = DownloadIntentRouter.shared.store else { throw DownloadOperationError(String(localized: "Open ChopChop before running this shortcut.")) }
        try await store.pauseForShortcut()
        return .result()
    }
}

struct DownloadSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Download Summary"
    static let description = IntentDescription("Return download counts without including source links or authentication.")
    static let openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let store = DownloadIntentRouter.shared.store else { throw DownloadOperationError(String(localized: "Open ChopChop before running this shortcut.")) }
        let active = store.tasks.filter { $0.status == .active }.count
        let paused = store.tasks.filter { $0.status == .paused }.count
        let completed = store.tasks.filter { $0.status == .completed }.count
        let failed = store.tasks.filter { $0.status == .failed }.count
        return .result(value: String(localized: "\(active) active, \(paused) paused, \(completed) completed, \(failed) failed"))
    }
}

struct ChopChopShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddDownloadLinksIntent(), phrases: ["Add downloads with \(.applicationName)"],
                    shortTitle: "Add Downloads", systemImageName: "arrow.down.circle")
        AppShortcut(intent: PauseDownloadsIntent(), phrases: ["Pause downloads in \(.applicationName)"],
                    shortTitle: "Pause Downloads", systemImageName: "pause.circle")
        AppShortcut(intent: DownloadSummaryIntent(), phrases: ["Download summary in \(.applicationName)"],
                    shortTitle: "Download Summary", systemImageName: "list.bullet")
    }
}

struct DownloadedFileActions: View {
    let file: DownloadFile
    @State private var previewURL: URL?
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { actions }
            VStack(alignment: .leading, spacing: 8) { actions }
        }
        .controlSize(.small)
        .quickLookPreview($previewURL)
    }

    @ViewBuilder
    private var actions: some View {
        Button(String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
        Button(String(localized: "Quick Look"), systemImage: "eye") {
            previewURL = DownloadFileLocation.existingFile(file.path)
        }
        ShareLink(item: URL(fileURLWithPath: file.path)) { Label(String(localized: "Share"), systemImage: "square.and.arrow.up") }
    }
}

/// Presentation only: never write resolved or abbreviated paths back to the engine/history.
nonisolated enum DownloadLocationDisplay {
    // Foundation's current-user home is redirected to the app container under App Sandbox.
    // The account record provides the actual home; use its reentrant API once for display only.
    static let userHome: URL = {
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        return buffer.withUnsafeMutableBufferPointer { buffer in
            guard getpwuid_r(getuid(), &account, buffer.baseAddress, buffer.count, &result) == 0,
                  result != nil, let path = account.pw_dir else {
                return FileManager.default.homeDirectoryForCurrentUser
            }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
    }()

    static func resolvedURL(_ path: String, home: URL = userHome) -> URL? {
        let url: URL
        if path == "~" { url = home }
        else if path.hasPrefix("~/") { url = home.appendingPathComponent(String(path.dropFirst(2))) }
        else if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
        else { return nil }
        // Foundation leaves the entire path unresolved when a trailing component is missing.
        // Resolve the existing parent, then restore the untouched, not-yet-downloaded suffix.
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return suffix.reversed().reduce(ancestor.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL
    }

    static func path(_ path: String, home: URL = userHome) -> String {
        guard let url = resolvedURL(path, home: home) else { return path }
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        if url.path == homePath { return "~" }
        if homePath != "/", url.path.hasPrefix(homePath + "/") {
            return "~" + url.path.dropFirst(homePath.count)
        }
        return url.path
    }

    /// Prefer the torrent's content folder or an ordinary task's single file.
    /// Use reported paths even when a volume is offline or a file has not been created yet.
    static func taskURL(_ task: DownloadTask) -> URL? {
        let destination = resolvedURL(task.destination)
        if task.isTorrentLike, let folder = task.torrentDirectory.flatMap({ resolvedURL($0) }),
           folder == destination { return folder }
        let files = task.files.compactMap { file -> URL? in
            guard DownloadTaskTrashPath.isReportedUserContentPath(file.path) else { return nil }
            return URL(fileURLWithPath: file.path).standardizedFileURL
        }
        if !task.isTorrentLike, files.count == 1 { return resolvedURL(files[0].path) }
        if task.isTorrentLike, let first = files.first, let destination {
            var common = first.deletingLastPathComponent()
            for file in files.dropFirst() {
                while common.path != "/", !file.path.hasPrefix(common.path + "/") {
                    common.deleteLastPathComponent()
                }
            }
            if let folder = resolvedURL(common.path), folder.path != "/",
               folder.path == destination.path || folder.path.hasPrefix(destination.path + "/") {
                return folder
            }
        }
        return destination
    }

    static func taskPath(_ task: DownloadTask) -> String {
        path(taskURL(task)?.path ?? task.destination)
    }
}

nonisolated enum DownloadFileLocation {
    static func existingFile(_ path: String, fileManager: FileManager = .default) -> URL? {
        guard path.hasPrefix("/"), DownloadTaskTrashPath.isReportedUserContentPath(path) else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var directory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { return nil }
        return url
    }

    static func revealURL(for task: DownloadTask, fileManager: FileManager = .default) -> URL? {
        let files = task.files.compactMap { file -> URL? in
            guard file.path.hasPrefix("/"), DownloadTaskTrashPath.isReportedUserContentPath(file.path) else { return nil }
            return URL(fileURLWithPath: file.path).standardizedFileURL
        }
        let destination = task.destination.hasPrefix("/") ? URL(fileURLWithPath: task.destination).standardizedFileURL : nil
        if !task.isTorrentLike, files.count == 1,
           let file = existingFile(files[0].path, fileManager: fileManager) { return file }
        if task.isTorrentLike {
            if let path = task.torrentDirectory, let destination, path == destination.path,
               fileManager.fileExists(atPath: path) { return destination }
            // Old tasks retain their original layout. Reveal their common content folder.
            if let first = files.first {
                var common = first.deletingLastPathComponent()
                while common.path != "/", !files.allSatisfy({ $0.path.hasPrefix(common.path + "/") }) {
                    common.deleteLastPathComponent()
                }
                if common.path != "/", let destination,
                   (common.path == destination.path || common.path.hasPrefix(destination.path + "/")),
                   fileManager.fileExists(atPath: common.path) { return common }
            }
        }
        if let destination, destination.path != "/", fileManager.fileExists(atPath: destination.path) { return destination }
        return nil
    }
}

nonisolated extension DownloadFile {
    var isCompleteOnDisk: Bool {
        isSelected && completedLength >= length && DownloadFileLocation.existingFile(path) != nil
    }
    var displayedProgress: Double? { isSelected && length > 0 ? progress : nil }
}

struct DownloadFileProgressView: View {
    let file: DownloadFile
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if file.isSelected {
                Text("\(ByteFormat.size(file.completedLength)) / \(ByteFormat.size(file.length))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let progress = file.displayedProgress {
                    ProgressView(value: progress).accessibilityLabel(String(localized: "File progress"))
                }
            } else {
                Label(String(localized: "Skipped"), systemImage: "minus.circle")
                    .font(.caption).foregroundStyle(.secondary)
                if DownloadFileLocation.existingFile(file.path) != nil {
                    Text(String(localized: "An existing copy remains on disk."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if file.completedLength > 0 {
                    Text(String(localized: "Shared torrent pieces are cached for selected files. This file has not been saved."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
