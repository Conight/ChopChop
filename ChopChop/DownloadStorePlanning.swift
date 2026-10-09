import AppKit
import Foundation

extension DownloadStore {
    func cancelSchedule(_ id: String) {
        scheduleRequests.removeValue(forKey: id)
        armedScheduledTaskIDs.remove(id)
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].scheduledStart != nil else { return }
        taskRevision += 1
        tasks[index].scheduledStart = nil
        persistTaskHistory()
    }

    func scheduleTask(_ id: String, at date: Date) async {
        guard !isUpdatingEngine, date > Date(), let task = tasks.first(where: { $0.id == id }),
              task.primaryControlAction != nil, !task.requiresFileSelection else { return }
        let request = UUID()
        let session = engineSessionID
        scheduleRequests[id] = request
        defer { if scheduleRequests[id] == request { scheduleRequests.removeValue(forKey: id) } }
        do {
            let client = try engineController.client()
            if task.media != nil, try await client.getOption(id)["media-pause-after-probe"] == "true" {
                throw DownloadOperationError(String(localized: "Choose media tracks before scheduling this download."))
            }
            if task.status != .paused { try await client.pause(id) }
            try await client.saveSession()
            guard scheduleRequests[id] == request, engineSessionID == session,
                  let index = tasks.firstIndex(where: { $0.id == id }), !isShuttingDown else { return }
            taskRevision += 1
            tasks[index].scheduledStart = date
            tasks[index].status = .paused
            guard persistTaskHistory() else { return }
            armedScheduledTaskIDs.insert(id)
            startPlanClock()
            downloadPlanIssue = nil
        } catch { downloadPlanIssue = DownloadPrivacy.redact(error.localizedDescription) }
    }

    func runDownloadPlans(now: Date = Date()) async {
        guard taskMutationDepth == 0, !applyingDownloadPlans, !isShuttingDown, !isUpdatingEngine, engineController.isRunning else { return }
        let session = engineSessionID
        applyingDownloadPlans = true
        defer { applyingDownloadPlans = false }
        let client: Aria2RPCClient
        do { client = try engineController.client() }
        catch { downloadPlanIssue = DownloadPrivacy.redact(error.localizedDescription); return }

        // A bandwidth error must not prevent an independently armed task from starting.
        do {
            if preferences.bandwidthSchedule.enabled, let issue = preferences.bandwidthSchedule.validationIssue {
                throw DownloadOperationError(issue)
            }
            let options = preferences.bandwidthSchedule.options(at: now, base: engineSettings)
            if options != lastBandwidthOptions {
                try await client.changeGlobalOption(options)
                guard engineSessionID == session, !isShuttingDown else { return }
                lastBandwidthOptions = options
            }
            bandwidthPlanIssue = nil
        } catch { bandwidthPlanIssue = DownloadPrivacy.redact(error.localizedDescription) }

        guard engineSessionID == session, !isShuttingDown, !isUpdatingEngine, !Task.isCancelled else { return }
        let due = tasks.filter { armedScheduledTaskIDs.contains($0.id) && ($0.scheduledStart.map { $0 <= now } ?? false) }
        var failures: [String] = []
        for task in due {
            guard engineSessionID == session, !Task.isCancelled, armedScheduledTaskIDs.contains(task.id), !isShuttingDown, !isUpdatingEngine,
                  task.isAvailableInEngine else { continue }
            // Disarm before RPC: a failed start requires user action, never repeated alerts or starts.
            armedScheduledTaskIDs.remove(task.id)
            guard task.status == .paused else { continue }
            do {
                try await client.resume(task.id)
                guard engineSessionID == session, !isShuttingDown else { return }
                cancelSchedule(task.id)
                try await client.saveSession()
            } catch { failures.append(DownloadPrivacy.redact(error.localizedDescription)) }
        }
        if !failures.isEmpty { downloadPlanIssue = String(localized: "Scheduled start failed. Enable the schedule to try again. ") + failures[0] }
        else if !due.isEmpty { downloadPlanIssue = nil }
    }
}
