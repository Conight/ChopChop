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
