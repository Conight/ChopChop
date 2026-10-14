import Observation
import Foundation

/// Stable, in-memory row identity. A poll only publishes rows whose visible task changed.
@MainActor
@Observable
final class DownloadRowState: Identifiable {
    let id: String
    private(set) var task: DownloadTask
    private(set) var presentation: DownloadRowPresentation
    init(_ task: DownloadTask) {
        id = task.id; self.task = task
        presentation = DownloadRowPresentation(task)
    }
    func update(_ task: DownloadTask) {
        guard self.task != task else { return }
        self.task = task
        let presentation = DownloadRowPresentation(task)
        if self.presentation != presentation { self.presentation = presentation }
    }
}

/// Row structure, identity and controls change independently of live counters.
/// In particular, progress must not replace native tooltip/selection content.
nonisolated struct DownloadRowPresentation: Equatable {
    var id: String
    var name: String
    var protocolKind: TaskProtocol
    var status: DownloadStatus
    var phaseLabel: String
    var statusSymbol: String
    var errorMessage: String?
    var torrentFileIssue: TorrentFileIssue?
    var scheduledStart: Date?
    var isTorrentLike: Bool
    var showsTransferRates: Bool
    var canReorderInQueue: Bool
    var primaryControlAction: DownloadTaskControlAction?
    var canEditAndAddAgain: Bool
    var canRevealInFinder: Bool
    var destination: String
    var totalLength: Int64
    var queuePosition: Int?
    var addedAt: Date

    init(_ task: DownloadTask) {
        let display = DownloadListTaskDisplay(task: task)
        id = task.id; name = task.name; protocolKind = task.protocolKind
        status = task.status; phaseLabel = task.phaseLabel; statusSymbol = display.statusSymbol
        errorMessage = task.errorMessage; torrentFileIssue = task.torrentFileIssue
        scheduledStart = task.scheduledStart; isTorrentLike = task.isTorrentLike
        showsTransferRates = display.showsTransferRates; canReorderInQueue = task.canReorderInQueue
        primaryControlAction = task.primaryControlAction; canEditAndAddAgain = task.canEditAndAddAgain
        canRevealInFinder = task.status == .completed && DownloadFileLocation.revealURL(for: task) != nil
        destination = task.destination; totalLength = task.totalLength
        queuePosition = task.queuePosition; addedAt = task.addedAt
    }
}

@MainActor
@Observable
final class DownloadListPresentation {
    static func primaryAction(for ids: Set<String>, tasks: [DownloadTask]) -> DownloadAction? {
        guard ids.count == 1, let id = ids.first,
              let task = tasks.first(where: { $0.id == id }), let action = task.primaryControlAction else { return nil }
        return action == .pause ? .pause : .resume
    }
    @ObservationIgnored private var rows: [String: DownloadRowState] = [:]
    private(set) var orderedRows: [DownloadRowState] = []
    func update(_ tasks: [DownloadTask]) {
        let ids = Set(tasks.map(\.id))
        rows = rows.filter { ids.contains($0.key) }
        for task in tasks {
            if let row = rows[task.id] { row.update(task) }
            else { rows[task.id] = DownloadRowState(task) }
        }
        if orderedRows.map(\.id) != tasks.map(\.id) {
            orderedRows = tasks.compactMap { rows[$0.id] }
        }
    }
    func row(id: String) -> DownloadRowState? { orderedRows.first { $0.id == id } }

    func visibleRows(for destination: SidebarDestination, query: String = "") -> [DownloadRowState] {
        var result = orderedRows.filter { row in
            switch destination {
            case .all: true
            case .active: row.presentation.status == .active
            case .waiting: row.presentation.status == .waiting || row.presentation.status == .paused
            case .completed: row.presentation.status == .completed
            case .failed: row.presentation.status == .failed
            case .torrents: row.presentation.isTorrentLike
            case .ed2k: row.presentation.protocolKind == .ed2k
            case .browserCapture: false
            }
        }
        if destination == .waiting {
            result.sort {
                let lhs = $0.presentation, rhs = $1.presentation
                if lhs.queuePosition != rhs.queuePosition {
                    return (lhs.queuePosition ?? Int.max) < (rhs.queuePosition ?? Int.max)
                }
                return lhs.addedAt < rhs.addedAt
            }
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }
        return result.filter {
            $0.presentation.name.localizedCaseInsensitiveContains(query) ||
                $0.presentation.destination.localizedCaseInsensitiveContains(query)
        }
    }
    func row(for task: DownloadTask) -> DownloadRowState {
        if let row = rows[task.id] { return row }
        let row = DownloadRowState(task)
        rows[task.id] = row
        return row
    }
}

nonisolated struct DownloadListTaskDisplay {
    var task: DownloadTask

    var showsTransferRates: Bool {
        task.status == .active && task.isAvailableInEngine && !task.isChecking && task.media?.state != "finalizing"
    }

    var statusSymbol: String {
        if task.torrentFileIssue != nil { return "exclamationmark.triangle" }
        if task.isSharing { return "arrow.up.circle" }
        if task.isChecking { return "checkmark.shield" }
        if task.isFetchingMetadata { return "ellipsis.circle" }
        return task.status.symbolName
    }

    var sizeLabel: String {
        if task.status == .completed || task.isSharing { return ByteFormat.size(task.totalLength) }
        if let media = task.media {
            return String(localized: "\(ByteFormat.size(Int64(media.downloadedLength ?? "") ?? 0)) downloaded")
        }
        if task.totalLength <= 0 {
            return String(localized: "\(ByteFormat.size(task.completedLength)) downloaded")
        }
        return task.transferSizeLabel
    }
}
