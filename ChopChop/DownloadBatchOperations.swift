import Foundation

nonisolated enum DownloadSelection {
    static func contextIDs(clicked: String, selected: Set<String>) -> Set<String> {
        selected.contains(clicked) ? selected : [clicked]
    }
}

extension DownloadStore {
    /// The selection is captured at dispatch, but task eligibility is checked again before each RPC.
    /// Errors are accumulated in the page, never one modal alert per task.
    func controlSelected(_ ids: Set<String>, action: DownloadTaskControlAction) async {
        guard !isUpdatingEngine, !isShuttingDown, !isPerformingBatchOperation else { return }
        isPerformingBatchOperation = true
        defer { isPerformingBatchOperation = false }
        let session = engineSessionID
        do {
            let client = try engineController.client()
            taskRevision += 1; taskMutationDepth += 1
            var failures = 0, needsSelection = 0
            var lastError: String?
            for id in ids.sorted() {
                guard !Task.isCancelled, session == engineSessionID, !isShuttingDown else { break }
                if action == .pause { cancelSchedule(id) }
                guard let task = tasks.first(where: { $0.id == id }), task.primaryControlAction == action else { continue }
                do {
                    if action == .resume {
                        if task.requiresFileSelection { needsSelection += 1; continue }
                        if task.media != nil {
                            let options = try await client.getOption(id)
                            guard session == engineSessionID, !isShuttingDown else { break }
                            if options["media-pause-after-probe"] == "true" { needsSelection += 1; continue }
                        }
                    }
                    cancelSchedule(id)
                    if action == .pause { try await DownloadTaskRPCOperations.pause(task, using: client) }
                    else { try await DownloadTaskRPCOperations.resume(task, using: client) }
                } catch { failures += 1; lastError = DownloadPrivacy.redact(error.localizedDescription) }
            }
            taskMutationDepth -= 1; taskRevision += 1
            guard session == engineSessionID, !isShuttingDown else { return }
            if let error = await saveSessionAfterTaskMutation(using: client) { failures += 1; lastError = DownloadPrivacy.redact(error.localizedDescription) }
            await refreshTasks()
            var messages: [String] = []
            if needsSelection > 0 { messages.append(String(localized: "\(needsSelection) downloads need file or track selection. Resume them individually to choose what to download.")) }
            if failures > 0 { messages.append(String(localized: "\(failures) operations failed. \(lastError ?? "")")) }
            batchOperationIssue = messages.isEmpty ? nil : messages.joined(separator: " ")
        } catch { batchOperationIssue = DownloadPrivacy.redact(error.localizedDescription) }
    }

    func beginRemoveSelected(_ ids: Set<String>) {
        guard !isUpdatingEngine, !isPerformingBatchOperation else { return }
        let selection = tasks.filter { ids.contains($0.id) }
        guard !selection.isEmpty else { return }
        if selection.count == 1 { beginRemove(selection[0]); return }
        if preferences.suppressRemoveConfirmation {
            let includingFiles = preferences.deleteFilesWhenSkippingRemoveConfirmation
            Task { await removeSelected(ids, includingFiles: includingFiles) }
        } else { removalRequest = DownloadRemovalRequest(tasks: selection) }
    }

    func removeSelected(_ ids: Set<String>, includingFiles: Bool) async {
        guard !isUpdatingEngine, !isShuttingDown, !isPerformingBatchOperation else { return }
        isPerformingBatchOperation = true
        defer { isPerformingBatchOperation = false }
        let session = engineSessionID
        let client = engineController.isRunning ? try? engineController.client() : nil
        taskRevision += 1; taskMutationDepth += 1
        var failures = 0
        var lastError: String?
        for id in ids.sorted() {
            guard !Task.isCancelled, session == engineSessionID, !isShuttingDown else { break }
            guard let task = tasks.first(where: { $0.id == id }) else { continue }
            do {
                if let client, task.isAvailableInEngine { try await DownloadTaskRPCOperations.remove(task, using: client) }
                else if includingFiles && task.removalAction != .removeDownloadResult { throw EngineError.notRunning }
                guard session == engineSessionID, !isShuttingDown else { break }
                if includingFiles { try DownloadTaskFileTrash.moveTaskFilesToTrash(task) }
                cancelSchedule(id)
                try hideHistory([id])
            } catch { failures += 1; lastError = DownloadPrivacy.redact(error.localizedDescription) }
        }
        taskMutationDepth -= 1; taskRevision += 1
        guard session == engineSessionID, !isShuttingDown else { return }
        if let client {
            if let error = await saveSessionAfterTaskMutation(using: client) { failures += 1; lastError = DownloadPrivacy.redact(error.localizedDescription) }
            await refreshTasks()
        }
        batchOperationIssue = failures == 0 ? nil : String(localized: "\(failures) operations failed. \(lastError ?? "")")
    }
}
