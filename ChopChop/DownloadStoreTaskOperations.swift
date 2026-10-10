import AppKit
import Foundation
import Combine

extension DownloadStore {
    func pause(_ task: DownloadTask) async {
        cancelSchedule(task.id)
        guard task.primaryControlAction == .pause else {
            postError(String(localized: "This task cannot be paused in its current state."), title: String(localized: "Pause Failed"))
            return
        }
        await performTaskMutation(alertTitle: String(localized: "Pause Failed")) { client in
            try await DownloadTaskRPCOperations.pause(task, using: client)
        }
    }

    func resume(_ task: DownloadTask) async {
        cancelSchedule(task.id)
        guard task.primaryControlAction == .resume else {
            postError(String(localized: "This task cannot be resumed in its current state."), title: String(localized: "Resume Failed"))
            return
        }
        if task.media != nil {
            guard inputCoordinator.owner == nil, !inputCoordinator.hasManualRequest else { return }
            do {
                let client = try engineController.client()
                let options = try await client.getOption(task.id)
                if options["media-pause-after-probe"] == "true" {
                    let snapshot = try await client.tellStatus(task.id).task
                    guard let tracks = snapshot.media?.tracks, !tracks.isEmpty else {
                        throw DownloadOperationError(String(localized: "Media tracks are not ready. Retry inspection or wait for the source to respond."))
                    }
                    guard inputCoordinator.owner == nil, !inputCoordinator.hasManualRequest else { return }
                    addDraft = defaultAddDraft()
                    addDraft.rawInput = task.sourceURL ?? ""
                    addDraft.savePath = task.destination
                    mediaDownloads.restore(snapshot, options: options)
                    inputCoordinator.requestManualSheet()
                    addPanelRequests.send()
                    return
                }
            } catch { postError(error, title: String(localized: "Resume Media Failed")); return }
        }
        if task.requiresFileSelection {
            guard bitTorrentSelectionSession == nil, inputCoordinator.owner == nil, !inputCoordinator.hasManualRequest else { return }
            addDraft = defaultAddDraft()
            addDraft.rawInput = task.sourceURL ?? ""
            addDraft.savePath = task.destination
            addDraftNotice = String(localized: "Choose files to continue this saved download. Its original progress is kept.")
            bitTorrentSelectionSession = BitTorrentFileSelectionSession(
                source: task.sourceURL ?? "", metadataTaskID: task.id, downloadTaskID: task.id,
                taskName: task.name, files: task.files,
                selectedFileIndexes: Set(task.files.filter(\.isSelected).map(\.index)), phase: .ready,
                removesTaskOnCancel: false, destination: task.destination, torrentDirectory: task.torrentDirectory)
            inputCoordinator.requestManualSheet()
            addPanelRequests.send()
            return
        }
        await performTaskMutation(alertTitle: String(localized: "Resume Failed")) { client in
            try await validateTorrentFilesBeforeResume(task)
            try await DownloadTaskRPCOperations.resume(task, using: client)
        }
    }

    func repairConnection(_ task: DownloadTask, repair: DownloadConnectionRepair) async throws {
        guard task.canRepairConnection, !isUpdatingEngine else { throw DownloadOperationError(String(localized: "Pause this task before editing its connection.")) }
        let client = try engineController.client()
        let current = try await client.tellStatus(task.id).task
        guard current.canRepairConnection else { throw DownloadOperationError(String(localized: "The task state changed. Refresh it before trying again.")) }
        let existing = try await client.getOption(task.id)
        let options = try repair.options(existing: existing)
        if !repair.replacementURL.trimmedForEngine.isEmpty {
            let uris = try await client.getURIs(task.id)
            guard let original = uris.first else { throw DownloadOperationError(String(localized: "The engine did not report a source address.")) }
            if let replacement = try repair.validatedReplacement(for: current, original: original) {
                try await client.replaceURI(task.id, old: uris, new: replacement)
            }
        }
        cancelSchedule(task.id)
        if current.canRetryMedia { try await client.retryMedia(task.id, options: options) }
        else {
            if !options.isEmpty { try await client.changeOption(gid: task.id, options: options) }
            // A media probe must still enter track confirmation rather than start payload transfer.
            if current.media != nil && existing["media-pause-after-probe"] == "true" {
                try await client.saveSession()
                await resume(current)
                return
            }
            try await client.resume(task.id)
        }
        try await client.saveSession()
        _ = await refreshTasks(reportErrors: false)
    }

    func recheckTorrent(_ task: DownloadTask) async {
        guard task.isTorrentLike, task.isAvailableInEngine, task.primaryControlAction != nil,
              engineCapabilities?.supportsTorrentManagement == true, !isUpdatingEngine else { return }
        cancelSchedule(task.id)
        await performTaskMutation(alertTitle: String(localized: "Recheck Files Failed")) { client in
            let current = tasks.first { $0.id == task.id } ?? task
            if current.torrentFileIssue != nil {
                let issues = await TorrentFileSafety.issues(in: [current])
                if let issue = issues[task.id] { throw issue }
                // An explicit recheck releases the hold; it never resumes a held task.
                try await client.forcePause(task.id)
            }
            try await client.recheckTorrent(task.id)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index].torrentFileIssue = nil
                persistTaskHistory()
            }
        }
    }

    func reannounceTorrent(_ task: DownloadTask) async {
        guard task.isTorrentLike, task.isAvailableInEngine, task.status == .active,
              engineCapabilities?.supportsTorrentManagement == true, !isUpdatingEngine else { return }
        await performTaskMutation(alertTitle: String(localized: "Announce Failed")) { client in try await client.reannounceTorrent(task.id) }
        await refreshDetails(for: task.id)
    }

    func taskOptions(_ id: String) async throws -> [String: String] {
        try await engineController.client().getOption(id)
    }

    func transferClient(for taskID: String) throws -> Aria2RPCClient {
        guard !isUpdatingEngine, tasks.contains(where: { $0.id == taskID && $0.isAvailableInEngine }) else {
            throw EngineError.notRunning
        }
        return try engineController.client()
    }

    func setTaskBandwidthLimits(_ task: DownloadTask, limits: TaskBandwidthLimits) async throws {
        guard task.primaryControlAction != nil, task.isTorrentLike == (limits.uploadKiB != nil) else {
            throw EngineError.notRunning
        }
        let options = try limits.engineOptions()
        let client = try transferClient(for: task.id)
        try await client.changeOption(gid: task.id, options: options)
        try await client.saveSession()
    }

    func setTorrentUploadLimit(_ task: DownloadTask, kib: Int) async throws {
        guard task.isTorrentLike, task.primaryControlAction != nil else { throw EngineError.notRunning }
        let option = try TransferRateLimit.option(kib: kib)
        let client = try transferClient(for: task.id)
        try await client.changeOption(gid: task.id, options: ["max-upload-limit": option])
        try await client.saveSession()
    }

    func updateTorrent(_ task: DownloadTask, options: BitTorrentTaskOptions) async throws {
        guard !isUpdatingEngine, task.isTorrentLike, task.isAvailableInEngine,
              task.primaryControlAction != nil, engineCapabilities?.supportsTorrentManagement == true else {
            throw DownloadOperationError(String(localized: "Torrent settings are unavailable in the current engine state."))
        }
        let values = try options.engineOptions()
        let client = try engineController.client()
        taskRevision += 1
        taskMutationDepth += 1
        do {
            try await client.changeOption(gid: task.id, options: values)
            try await client.saveSession()
        } catch {
            taskMutationDepth -= 1; taskRevision += 1
            throw error
        }
        taskMutationDepth -= 1; taskRevision += 1
        _ = await refreshTasks(reportErrors: false)
    }

    func moveQueuedTask(_ id: String, before target: String? = nil) async {
        guard !isUpdatingEngine else { return }
        await performTaskMutation(alertTitle: String(localized: "Reorder Queue Failed")) { client in
            let queue = try await client.waitingQueueIDs()
            guard let position = DownloadQueueOrder.position(moving: id, before: target, in: queue) else { return }
            try await client.changePosition(id, to: position)
        }
    }
    func beginRemove(_ task: DownloadTask) {
        guard !preferences.suppressRemoveConfirmation else {
            let includingFiles = preferences.deleteFilesWhenSkippingRemoveConfirmation
            Task { @MainActor [weak self] in
                await self?.remove(task, includingFiles: includingFiles)
            }
            return
        }
        removalRequest = DownloadRemovalRequest(task: task)
    }

    func confirmRemoval(
        _ request: DownloadRemovalRequest,
        includingFiles: Bool,
        suppressFutureConfirmation: Bool = false
    ) async {
        if suppressFutureConfirmation {
            var updatedPreferences = preferences
            updatedPreferences.suppressRemoveConfirmation = true
            updatedPreferences.deleteFilesWhenSkippingRemoveConfirmation = includingFiles
            preferences = updatedPreferences
        }
        if removalRequest?.id == request.id {
            removalRequest = nil
        }
        if request.tasks.count == 1 { await remove(request.task, includingFiles: includingFiles) }
        else { await removeSelected(Set(request.tasks.map(\.id)), includingFiles: includingFiles) }
    }

    func cancelRemoval(_ request: DownloadRemovalRequest? = nil) {
        guard request == nil || removalRequest?.id == request?.id else { return }
        removalRequest = nil
    }

    func remove(_ task: DownloadTask, includingFiles: Bool = false) async {
        guard !isUpdatingEngine else { return }
        if !engineController.isRunning {
            do {
                if includingFiles {
                    try trashFilesAfterRemoval(task, engineTaskRemoved: false)
                }
                try hideHistory([task.id])
            } catch { postError(error, title: String(localized: "Remove Failed")) }
            return
        }
        await performTaskMutation(alertTitle: String(localized: "Remove Failed")) { client in
            try await DownloadTaskRPCOperations.remove(task, using: client)
            if includingFiles { try trashFilesAfterRemoval(task, engineTaskRemoved: true) }
            try hideHistory([task.id])
        }
    }

    func pauseForShortcut() async throws {
        for id in Set(tasks.filter { $0.scheduledStart != nil }.map(\.id)).union(scheduleRequests.keys) { cancelSchedule(id) }
        guard !isUpdatingEngine else { throw DownloadOperationError(String(localized: "Wait for the engine update to finish.")) }
        guard engineController.isRunning else { return }
        let client = try engineController.client()
        _ = try await DownloadTaskRPCOperations.pauseAll(tasks, using: client)
        try await client.saveSession()
        _ = await refreshTasks(reportErrors: false)
    }

    func pauseAll() async {
        for id in Set(tasks.filter { $0.scheduledStart != nil }.map(\.id)).union(scheduleRequests.keys) { cancelSchedule(id) }
        await performTaskMutation(alertTitle: String(localized: "Pause All Failed")) { client in
            let pausedCount = try await DownloadTaskRPCOperations.pauseAll(tasks, using: client)
            if pausedCount == 0 {
                postActivity(String(localized: "No active or waiting downloads to pause."))
            }
        }
    }

    func resumeAll() async {
        // Use the same selection checks as batch Resume; unpauseAll would bypass unfinished setup.
        await controlSelected(Set(tasks.map(\.id)), action: .resume)
    }

    func forcePauseAll() async {
        for id in Set(tasks.filter { $0.scheduledStart != nil }.map(\.id)).union(scheduleRequests.keys) { cancelSchedule(id) }
        await performTaskMutation(alertTitle: String(localized: "Force Pause All Failed")) { client in
            try await client.forcePauseAll()
        }
    }

    func purgeCompletedRecords() async {
        guard !isUpdatingEngine else { return }
        let ids = Set(tasks.filter { $0.removalAction == .removeDownloadResult }.map(\.id))
        do {
            try hideHistory(ids)
            if engineController.isRunning { _ = await refreshTasks(reportErrors: false) }
            postActivity(String(localized: "Cleared finished records. Downloaded files were kept."))
        } catch { postError(error, title: String(localized: "Clear Records Failed")) }
    }

    func hideHistory(_ ids: Set<String>) throws {
        guard let historyStore else { throw CocoaError(.fileWriteUnknown) }
        try historyStore.hide(ids)
        armedScheduledTaskIDs.subtract(ids)
        hiddenTaskIDs.formUnion(ids)
        taskRevision += 1
        tasks.removeAll { ids.contains($0.id) }
        selectedTaskIDs.subtract(ids)
    }
    func performTaskMutation(
        alertTitle: String,
        operation: (Aria2RPCClient) async throws -> Void
    ) async {
        let client: Aria2RPCClient
        do {
            client = try engineController.client()
        } catch {
            postError(error, title: alertTitle)
            return
        }

        taskRevision += 1
        taskMutationDepth += 1
        let operationError: Error?
        do {
            try await operation(client)
            operationError = nil
        } catch {
            operationError = error
        }

        taskMutationDepth -= 1
        taskRevision += 1
        let saveError = await saveSessionAfterTaskMutation(using: client)
        _ = await refreshTasks(reportErrors: false)

        if let operationError {
            postError(operationError, title: alertTitle)
        } else if let saveError {
            postError(saveError, title: String(localized: "Save Session Failed"))
        }
    }

    func saveSessionAfterTaskMutation(using client: Aria2RPCClient) async -> Error? {
        do {
            try await client.saveSession()
            return nil
        } catch {
            updateRuntime(lastError: error.localizedDescription)
            return error
        }
    }
}
