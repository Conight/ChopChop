import AppKit
import Foundation

extension DownloadStore {
    @discardableResult
    func refreshTasks(reportErrors: Bool = true) async -> Error? {
        let sessionID = engineSessionID
        guard !Task.isCancelled, !isShuttingDown, taskMutationDepth == 0 else { return nil }
        refreshSequence += 1
        let sequence = refreshSequence
        let revision = taskRevision
        if let exitStatus = engineController.clearTerminatedProcess() {
            let error = EngineError.processExited(exitStatus, String(localized: "Aria2 Next stopped unexpectedly."))
            pollTask?.cancel()
            refreshClockStarted = false
            planTask?.cancel()
            pollTask = nil
            runtime = EngineRuntimeSnapshot(phase: .failed(error.localizedDescription),
                lastLaunchArguments: runtime.lastLaunchArguments, lastError: error.localizedDescription)
            tasks = tasks.map(\.disconnectedSnapshot)
            connectionIssue = String(localized: "Engine stopped. Your saved downloads are still available. Restart it in Engine settings.")
            return error
        }
        guard engineController.isRunning else { return nil }
        do {
            let client = try engineController.client()
            async let taskSnapshot = client.pollTasks()
            async let globalStat = client.globalStat()
            let (polledTasks, stat) = try await (taskSnapshot, globalStat)
            guard !Task.isCancelled, engineSessionID == sessionID, engineController.isRunning,
                  revision == taskRevision, sequence == refreshSequence else { return nil }
            let archivedTorrentIDs = Set(tasks.filter { $0.isTorrentLike && $0.status == .completed }.map(\.id))
            let visibleSnapshot = polledTasks.map { task in
                var task = task
                if archivedTorrentIDs.contains(task.id), task.isTorrentLike {
                    task.status = .completed
                    task.isSharing = false
                    task.downloadSpeed = 0
                    task.uploadSpeed = 0
                }
                return task
            }
            let previousTasks = tasks
            var merged = DownloadHistoryStore.merge(visibleSnapshot, existing: tasks, hidden: hiddenTaskIDs)
            let fileIssues = await TorrentFileSafety.issues(in: merged.filter {
                $0.isTorrentLike && $0.isAvailableInEngine && $0.removalAction == .removeActiveDownload
            }, previous: previousTasks)
            guard !Task.isCancelled, engineSessionID == sessionID, engineController.isRunning,
                  revision == taskRevision, sequence == refreshSequence else { return nil }
            for index in merged.indices {
                if let issue = fileIssues[merged[index].id] { merged[index].torrentFileIssue = issue }
                if merged[index].torrentFileIssue != nil {
                    merged[index].scheduledStart = nil
                    armedScheduledTaskIDs.remove(merged[index].id)
                    scheduleRequests.removeValue(forKey: merged[index].id)
                }
            }
            tasks = merged
            // Save the safety hold before RPC: reconnect/restart must not lose it if pausing fails.
            var historySaved = persistTaskHistory()
            connectionIssue = nil
            updateRuntime(lastError: nil)
            var sessionChanged = false
            for task in merged where task.torrentFileIssue != nil && task.isAvailableInEngine
                && (task.status == .active || task.status == .waiting || task.isSharing) {
                try await client.forcePause(task.id)
                guard !Task.isCancelled, engineSessionID == sessionID, engineController.isRunning,
                      revision == taskRevision, sequence == refreshSequence else { return nil }
                if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[index].status = .paused
                    tasks[index].isSharing = false
                    tasks[index].downloadSpeed = 0
                    tasks[index].uploadSpeed = 0
                    tasks[index].connections = 0
                }
                sessionChanged = true
            }
            if sessionChanged { historySaved = persistTaskHistory() }
            // Upgrade existing torrent tasks as well as newly added ones. force-save is needed
            // for seeding, which the engine session serializer otherwise treats as finished.
            for task in polledTasks where task.isTorrentLike && task.removalAction == .removeActiveDownload
                && !archivedTorrentIDs.contains(task.id) && !hiddenTaskIDs.contains(task.id)
                && !sessionProtectedTorrentIDs.contains(task.id) {
                try await client.changeOption(gid: task.id, options: ["force-save": "true"])
                sessionProtectedTorrentIDs.insert(task.id)
                sessionChanged = true
            }
            // Once seeding has ended, keep its result in SwiftData. A force-saved terminal
            // engine result would otherwise reappear as a paused torrent at the next launch.
            for task in polledTasks where historySaved && task.isTorrentLike
                && (task.status == .completed || archivedTorrentIDs.contains(task.id)) && !hiddenTaskIDs.contains(task.id) {
                // Also handle a crash between archiving a result and pruning its saved session.
                try await DownloadTaskRPCOperations.remove(task, using: client)
                if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index].isAvailableInEngine = false }
                sessionChanged = true
            }
            // Clearing history offline must also clear any matching engine records on reconnect.
            for task in polledTasks where hiddenTaskIDs.contains(task.id) {
                try await DownloadTaskRPCOperations.remove(task, using: client)
                sessionChanged = true
            }
            if sessionChanged {
                _ = await saveSessionAfterTaskMutation(using: client)
            }
            recordSpeed(download: stat.downloadBytesPerSecond, upload: stat.uploadBytesPerSecond)
            if historySaved { await notifications.observe(tasks, previous: previousTasks, history: historyStore) }
            return nil
        } catch {
            guard !Task.isCancelled, engineSessionID == sessionID,
                  revision == taskRevision, sequence == refreshSequence else { return nil }
            tasks = tasks.map(\.disconnectedSnapshot)
            connectionIssue = String(localized: "Unable to refresh engine state. Showing saved downloads; retrying automatically. \(DownloadPrivacy.redact(error.localizedDescription))")
            updateRuntime(lastError: DownloadPrivacy.redact(error.localizedDescription))
            return error
        }
    }

    @discardableResult
    func persistTaskHistory() -> Bool {
        guard let historyStore else { return false }
        do {
            try historyStore.save(tasks)
            historyIssue = nil
            return true
        } catch {
            historyIssue = String(localized: "Download history could not be saved. \(DownloadPrivacy.redact(error.localizedDescription))")
            return false
        }
    }
    func startPolling() {
        pollTask?.cancel()
        refreshClockStarted = true
        startPlanClock()
        pollTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let delay = self?.refreshInterval(failures: failures) else { return }
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled, let error = await self?.refreshTasks(reportErrors: false) else {
                    failures = 0
                    if self == nil { return }
                    continue
                }
                _ = error
                failures += 1
            }
        }
    }

    func refreshInterval(failures: Int) -> Duration {
        let foreground = NSApp.isActive && NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
        return DownloadRefreshPolicy.interval(foreground: foreground,
            hasTransfers: tasks.contains { $0.status == .active || $0.status == .waiting || $0.isSharing }, failures: failures)
    }

    func startPlanClock() {
        guard refreshClockStarted, engineController.isRunning, !isShuttingDown, !isUpdatingEngine else { return }
        planTask?.cancel()
        planTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runDownloadPlans()
                guard !Task.isCancelled, let delay = self?.nextPlanDelay() else { return }
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    func nextPlanDelay(now: Date = Date()) -> Duration {
        if applyingDownloadPlans || taskMutationDepth > 0 { return .milliseconds(100) }
        return DownloadRefreshPolicy.planDelay(now: now,
            deadlines: tasks.filter { armedScheduledTaskIDs.contains($0.id) }.compactMap { task in
                guard let date = task.scheduledStart else { return nil }
                return date <= now && !task.isAvailableInEngine ? now.addingTimeInterval(5) : date
            },
            bandwidthEnabled: preferences.bandwidthSchedule.enabled)
    }
    func recordSpeed(download: Int64, upload: Int64) {
        let now = Date()
        speedSamples.append(
            SpeedSample(
                timestamp: now,
                downloadBytesPerSecond: download,
                uploadBytesPerSecond: upload
            )
        )
        speedSamples = SpeedSample.rollingWindowSamples(speedSamples, now: now)
    }

    func updateRuntime(lastError: String?) {
        runtime = EngineRuntimeSnapshot(
            phase: runtime.phase,
            lastLaunchArguments: runtime.lastLaunchArguments,
            lastError: lastError
        )
    }
}
