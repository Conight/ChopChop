import Foundation

extension DownloadStore {
    var engineRestartReasons: [String] {
        guard case .running = runtime.phase else { return [] }
        return engineSettingsApplication.restartReasons(for: engineSettings, bootstrap: ed2kBootstrapStatus)
    }

    var hasPendingEngineSettings: Bool {
        !engineSettingsApplication.pendingOptions(for: engineSettings).isEmpty
    }

    /// One worker per session. Edits arriving during an RPC are reconciled after
    /// its reply, never lost and never mistaken for already-applied settings.
    func scheduleEngineSettingsApplication() {
        guard engineSettingsApplication.launchedSettings != nil,
              case .running = runtime.phase, engineController.isRunning, !isUpdatingEngine, !isShuttingDown,
              hasPendingEngineSettings, engineSettingsTask == nil else { return }
        let workerID = UUID()
        engineSettingsTaskID = workerID
        engineSettingsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.engineSettingsTaskID == workerID { self.engineSettingsTask = nil }
            }
            while !Task.isCancelled, self.engineSettingsTaskID == workerID,
                  !self.isUpdatingEngine, !self.isShuttingDown,
                  case .running = self.runtime.phase, self.engineController.isRunning, self.hasPendingEngineSettings {
                do { try await Task.sleep(for: .milliseconds(350)) }
                catch { return }
                let requested = EngineSettingsApplication.runtimeOptions(self.engineSettings)
                await self.applyRuntimeEngineOptions()
                // A failed request is visible and retryable, not an endless loop.
                // A newer edit still gets its own attempt.
                if self.engineSettingsIssue != nil,
                   requested == EngineSettingsApplication.runtimeOptions(self.engineSettings) { return }
            }
        }
    }

    func cancelEngineSettingsApplication() {
        engineSettingsTaskID = UUID()
        engineSettingsTask?.cancel()
        engineSettingsTask = nil
        runtimeSettingsFeedback = .idle
    }

    func retryEngineSettingsApplication() {
        engineSettingsIssue = nil
        scheduleEngineSettingsApplication()
    }

    func applyRuntimeEngineOptions() async {
        guard !isUpdatingEngine, !isShuttingDown, engineController.isRunning,
              runtimeSettingsFeedback != .working else { return }
        let session = engineSessionID
        let settings = engineSettings
        let options = engineSettingsApplication.pendingOptions(for: settings)
        guard !options.isEmpty else { return }
        runtimeSettingsFeedback = .working
        engineSettingsIssue = nil
        defer {
            if engineSessionID == session, runtimeSettingsFeedback == .working {
                runtimeSettingsFeedback = .idle
            }
        }
        do {
            let client = try engineController.client()
            try await client.changeGlobalOption(options)
            guard engineSessionID == session, !isShuttingDown, !Task.isCancelled else { return }
            if options["bt-tracker"] != nil {
                try await applyTrackersToRunningTasks(settings.btTracker, using: client)
            }
            guard engineSessionID == session, !isShuttingDown, !Task.isCancelled else { return }
            engineSettingsApplication.didApply(options)
            runtimeSettingsFeedback = .succeeded
        } catch {
            guard engineSessionID == session, !isShuttingDown, !Task.isCancelled else { return }
            engineSettingsIssue = DownloadPrivacy.redact(error.localizedDescription)
        }
    }
}
