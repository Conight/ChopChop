import Combine
import Foundation

/// Stable, in-memory row identity. A poll only publishes rows whose visible task changed.
@MainActor
final class DownloadRowState: ObservableObject, Identifiable {
    let id: String
    @Published private(set) var task: DownloadTask
    init(_ task: DownloadTask) { id = task.id; self.task = task }
    func update(_ task: DownloadTask) {
        if self.task != task { self.task = task }
    }
}

@MainActor
final class DownloadListPresentation {
    static func primaryAction(for ids: Set<String>, tasks: [DownloadTask]) -> DownloadAction? {
        guard ids.count == 1, let id = ids.first,
              let task = tasks.first(where: { $0.id == id }), let action = task.primaryControlAction else { return nil }
        return action == .pause ? .pause : .resume
    }
    private var rows: [String: DownloadRowState] = [:]
    func update(_ tasks: [DownloadTask]) {
        let ids = Set(tasks.map(\.id))
        rows = rows.filter { ids.contains($0.key) }
        for task in tasks {
            if let row = rows[task.id] { row.update(task) }
            else { rows[task.id] = DownloadRowState(task) }
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

    var showsProgress: Bool { task.status != .completed && !task.isSharing }

    var showsTransferRates: Bool {
        task.status == .active && task.isAvailableInEngine && !task.isChecking && task.media?.state != "finalizing"
    }

    var statusSymbol: String {
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
