import Foundation
import SwiftData

@Model
final class PersistentDownloadRecord {
    @Attribute(.unique) var gid: String
    var snapshot: Data?
    var isDeleted: Bool = false
    var completionObserved: Bool = false

    init(gid: String, snapshot: Data? = nil, isDeleted: Bool = false) {
        self.gid = gid
        self.snapshot = snapshot
        self.isDeleted = isDeleted
    }
}

@MainActor
final class DownloadHistoryStore {
    private let context: ModelContext
    private var records: [String: PersistentDownloadRecord]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(context: ModelContext) throws {
        self.context = context
        context.autosaveEnabled = false
        records = Dictionary(try context.fetch(FetchDescriptor<PersistentDownloadRecord>()).map { ($0.gid, $0) },
                             uniquingKeysWith: { first, _ in first })
        encoder.outputFormatting = .sortedKeys
    }

    var deletedIDs: Set<String> { Set(records.values.filter(\.isDeleted).map(\.gid)) }

    func load() throws -> [DownloadTask] {
        try records.values.filter { !$0.isDeleted }.compactMap { record in
            guard let data = record.snapshot else { return nil }
            return try decoder.decode(DownloadTask.self, from: data).disconnectedSnapshot
        }.sorted(by: Self.ordered)
    }

    func save(_ tasks: [DownloadTask]) throws {
        for task in tasks where records[task.id]?.isDeleted != true {
            let data = try encoder.encode(DownloadPrivacy.historySnapshot(task))
            if let record = records[task.id] {
                if record.snapshot != data { record.snapshot = data }
            } else {
                let record = PersistentDownloadRecord(gid: task.id, snapshot: data)
                records[task.id] = record
                context.insert(record)
            }
        }
        if context.hasChanges { try context.save() }
    }

    func hide(_ ids: Set<String>) throws {
        // Keep only GIDs as tombstones. Offline clearing cannot be undone by a stale poll.
        for id in ids {
            let record = records[id] ?? PersistentDownloadRecord(gid: id)
            if records[id] == nil { context.insert(record); records[id] = record }
            record.isDeleted = true
            record.snapshot = nil
        }
        do { try context.save() }
        catch {
            context.rollback()
            records = Dictionary(try context.fetch(FetchDescriptor<PersistentDownloadRecord>()).map { ($0.gid, $0) },
                                 uniquingKeysWith: { first, _ in first })
            throw error
        }
    }

    func hasObservedCompletion(_ id: String) -> Bool { records[id]?.completionObserved == true }

    func markCompletionsObserved(_ ids: Set<String>) throws {
        for id in ids where records[id]?.isDeleted == false { records[id]?.completionObserved = true }
        if context.hasChanges { try context.save() }
    }

    static func submittedTasks(_ gids: [String], draft: AddDownloadDraft, date: Date = Date()) -> [DownloadTask] {
        let sources = (try? draft.normalizedResources()) ?? []
        return gids.enumerated().map { index, gid in
            let source = sources.indices.contains(index) ? sources[index] : sources.first
            let name = source.flatMap { URL(string: $0)?.lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? gid
            return DownloadTask(id: gid, name: draft.outputName.isEmpty ? name : draft.outputName,
                protocolKind: source.flatMap(AddDownloadDraft.detectProtocol) ?? .http,
                status: .waiting, totalLength: 0, completedLength: 0, downloadSpeed: 0, uploadSpeed: 0, connections: 0,
                destination: draft.savePath, addedAt: date, errorMessage: nil, files: [], peers: [], trackers: [], recentLogs: [], infoHash: nil,
                sourceURL: source, addedAtIsFirstSeen: false, torrentDirectory: draft.torrentDirectory)
        }
    }

    static func merge(_ incoming: [DownloadTask], existing: [DownloadTask], hidden: Set<String>) -> [DownloadTask] {
        var result = Dictionary(existing.filter { !hidden.contains($0.id) }.map { ($0.id, $0.disconnectedSnapshot) },
                                uniquingKeysWith: { first, _ in first })
        for var task in incoming where !hidden.contains(task.id) {
            if let old = result[task.id] {
                task.scheduledStart = old.scheduledStart
                task.torrentDirectory = old.torrentDirectory
                task.torrentFileIssue = old.torrentFileIssue
                task.addedAt = old.addedAt
                task.addedAtIsFirstSeen = old.addedAtIsFirstSeen
                if task.sourceURL == nil { task.sourceURL = old.sourceURL }
                if task.peers.isEmpty { task.peers = old.peers }
                // The lightweight status poll only lists configured trackers. Detailed RPC
                // observations are refreshed explicitly from the Network inspector.
                if !old.trackers.isEmpty && task.trackers.allSatisfy({ $0.status == "Configured" }) {
                    let urls = Set(task.trackers.map { DownloadPrivacy.redact($0.url) })
                    task.trackers = old.trackers.filter { urls.contains($0.url) }
                }
                // File UUIDs are presentation identity, not engine state. Preserve them across polls.
                for index in task.files.indices {
                    if let file = old.files.first(where: { $0.index == task.files[index].index && $0.path == task.files[index].path }) {
                        task.files[index].id = file.id
                    }
                }
            }
            task.isAvailableInEngine = true
            result[task.id] = task
        }
        return result.values.sorted(by: ordered)
    }

    private static func ordered(_ lhs: DownloadTask, _ rhs: DownloadTask) -> Bool {
        if lhs.status != rhs.status { return lhs.status.sortOrder < rhs.status.sortOrder }
        if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
        return lhs.id < rhs.id
    }
}
