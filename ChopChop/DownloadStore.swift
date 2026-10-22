import Foundation
import AppKit
import Combine
import Observation
import Security

struct UserFacingAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

struct DownloadRemovalRequest: Identifiable, Equatable {
    let id = UUID()
    var tasks: [DownloadTask]
    var task: DownloadTask { tasks[0] }
    init(task: DownloadTask) { tasks = [task] }
    init(tasks: [DownloadTask]) { precondition(!tasks.isEmpty); self.tasks = tasks }
    var canTrashFiles: Bool { tasks.allSatisfy(\.hasReportedTrashableFiles) }
    var message: String {
        if tasks.count == 1 {
            return String(localized: "\"\(task.name)\" will be removed from Aria2 Next. You can keep downloaded files or move the files reported by Aria2 Next to Trash.")
        }
        return String(localized: "Remove \(tasks.count) selected downloads? You can keep downloaded files or move the files reported by Aria2 Next to Trash.")
    }
}

private struct ED2KSearchSession {
    var gid: String
    var temporaryDirectory: URL
}

@MainActor
@Observable
final class DownloadStore {
    var engineSettings: EngineSettings {
        didSet {
            persistEngineSettings()
            // A pristine, unopened draft follows preferences. An edited or
            // presented draft belongs to the user and keeps its own options.
            if inputCoordinator.owner == nil, addDraft == AddDownloadDraft(defaults: oldValue) {
                addDraft = AddDownloadDraft(defaults: engineSettings)
            }
            if oldValue != engineSettings { startPlanClock() }
            if oldValue != engineSettings {
                engineSettingsIssue = nil
                scheduleEngineSettingsApplication()
            }
            if oldValue.trackerSourceURLs != engineSettings.trackerSourceURLs {
                trackerSyncPending = true
                trackerSyncRetryAfter = nil
            }
            if trackerSyncClockStarted && (oldValue.btTrackerAutoSync != engineSettings.btTrackerAutoSync
                || oldValue.btTrackerSyncIntervalHours != engineSettings.btTrackerSyncIntervalHours
                || oldValue.trackerSourceURLs != engineSettings.trackerSourceURLs
                || oldValue.lastTrackerSyncAt != engineSettings.lastTrackerSyncAt) {
                scheduleTrackerSync()
            }
        }
    }
    var preferences: AppPreferences {
        didSet {
            persistAppPreferences()
            if oldValue != preferences { preferenceChanges.send(preferences) }
            if oldValue.notifyOnDownloadCompletion != preferences.notifyOnDownloadCompletion {
                notifications.setEnabled(preferences.notifyOnDownloadCompletion)
            }
            if oldValue.browserCaptureEnabled != preferences.browserCaptureEnabled || oldValue.browserCaptureToken != preferences.browserCaptureToken {
                configureBrowserCapture()
            }
            updatePowerAssertion()
            if oldValue.bandwidthSchedule != preferences.bandwidthSchedule || oldValue.temporaryBandwidth != preferences.temporaryBandwidth { startPlanClock() }
        }
    }
    let inputCoordinator = DownloadInputCoordinator()
    let notifications: DownloadNotificationCoordinator
    let mediaDownloads = MediaDownloadCoordinator()
    let browserCapture = BrowserCaptureServer()
    let trackerDiagnostics: TrackerDiagnostics
    // Explicit event streams for AppKit integrations; SwiftUI observes properties.
    let taskSnapshots = CurrentValueSubject<[DownloadTask], Never>([])
    let preferenceChanges = PassthroughSubject<AppPreferences, Never>()
    let notificationNavigationRequests = PassthroughSubject<Void, Never>()
    let downloadWindowRequests = PassthroughSubject<Void, Never>()
    @ObservationIgnored var inputTask: Task<Void, Never>?
    private(set) var importIssues: [String] = []
    var browserPartConfirmed = false
    private(set) var notificationNavigationRevision = 0 {
        didSet { notificationNavigationRequests.send() }
    }
    var runtime = EngineRuntimeSnapshot()
    var engineCapabilities: EngineCapabilities?
    var connectionIssue: String?
    var historyIssue: String?
    var addDraftNotice: String?
    let historyStore: DownloadHistoryStore?
    var hiddenTaskIDs: Set<String> = []
    var sessionProtectedTorrentIDs: Set<String> = []
    var taskRevision = 0
    var refreshSequence = 0
    var taskMutationDepth = 0

    private(set) var engineSetupState: EngineSetupState = .unchecked
    private(set) var installedEngine: EngineInstallation?
    private(set) var engineUpdateStatus = String(localized: "Not checked yet")
    private(set) var availableEngineUpdate: EngineRelease?
    private(set) var latestEngineRelease: EngineRelease?
    private(set) var recentEngineReleases: [EngineRelease] = []
    /// nil follows the upstream Latest release; explicit versions apply to this installation only.
    var selectedEngineVersion: EngineVersion? {
        didSet {
            engineUpgradeError = nil
            engineUpgradeResult = nil
            engineVersionSelectionNotice = nil
        }
    }
    private(set) var engineReleaseListError: String?
    private(set) var engineVersionSelectionNotice: String?
    private var didLoadEngineReleases = false
    private(set) var engineSettingsRequested = false
    private(set) var updateSettingsRequested = false
    private(set) var isCheckingEngineUpdate = false
    private(set) var engineUpgradeProgress: EngineInstallationProgress?
    private(set) var engineUpgradeError: String?
    private(set) var engineUpgradeResult: String?
    @ObservationIgnored private var engineUpgradeTask: Task<Void, Never>?
    private let engineInstallationManager: any EngineInstallationManaging
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var engineUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var engineInstallTask: Task<Void, Never>?
    @ObservationIgnored private var engineMaintenanceTask: Task<Void, Never>?
    let listPresentation = DownloadListPresentation()
    var tasks: [DownloadTask] = [] {
        didSet {
            listPresentation.update(tasks)
            if oldValue != tasks { taskSnapshots.send(tasks) }
            updatePowerAssertion()
            let wasTransferring = oldValue.contains { $0.status == .active || $0.status == .waiting || $0.isSharing }
            if !wasTransferring, tasks.contains(where: { $0.status == .active || $0.status == .waiting || $0.isSharing }) {
                // A start notification can show a brief checking/queued snapshot.
                // Do not leave it frozen behind the previous idle polling delay.
                pollWakeContinuation?.yield(())
            }
        }
    }
    var speedSamples: [SpeedSample] = []
    var selectedDestination: SidebarDestination = .all
    var selectedTaskIDs: Set<DownloadTask.ID> = []
    var selectedTaskID: DownloadTask.ID? {
        get { selectedTaskIDs.count == 1 ? selectedTaskIDs.first : nil }
        set { selectedTaskIDs = newValue.map { [$0] } ?? [] }
    }
    var batchOperationIssue: String?
    var isPerformingBatchOperation = false
    var searchQuery = ""
    var addDraft = AddDownloadDraft()
    var isReorderingQueue = false
    var trackerSyncFeedback = ActionFeedback.idle
    var bootstrapSyncFeedback = ActionFeedback.idle
    var runtimeSettingsFeedback = ActionFeedback.idle
    var engineSettingsApplication = EngineSettingsApplication()
    var engineSettingsIssue: String?
    @ObservationIgnored var engineSettingsTask: Task<Void, Never>?
    var engineSettingsTaskID = UUID()
    var isSyncingTrackers = false
    var trackerSyncIssue: String?
    @ObservationIgnored private var trackerSyncClock: Task<Void, Never>?
    @ObservationIgnored private var trackerSyncOperation: Task<Void, Never>?
    private var trackerSyncClockStarted = false
    private var trackerSyncPending = false
    private var trackerSyncRetryAfter: Date?
    var isSyncingED2KBootstrap = false
    var ed2kBootstrapStatus = ED2KBootstrapStatus()
    var ed2kSearchKeyword = ""
    var ed2kSearchFileType: ED2KSearchFileType = .any
    var ed2kSearchMinSources = 1
    var isSearchingED2K = false
    var ed2kSearchElapsedSeconds = 0
    var ed2kSearchResults: [ED2KSearchResult] = []
    var isResolvingBitTorrentFiles = false
    private(set) var isRetryingBitTorrentDiscovery = false
    var activityMessage: String?
    var removalRequest: DownloadRemovalRequest?
    var bitTorrentSelectionSession: BitTorrentFileSelectionSession?
    let addPanelRequests = PassthroughSubject<Void, Never>()
    let userAlerts = PassthroughSubject<UserFacingAlert, Never>()

    private let settingsStore: PersistentSettingsStore?
    let engineController: any Aria2EngineControlling
    private let trackerFetcher: any BitTorrentTrackerSourceFetching
    private let ed2kBootstrapFetcher: any ED2KBootstrapFetching
    private let ed2kBootstrapApplicationSupportBase: URL?
    private let powerAssertionController: any PowerAssertionControlling
    @ObservationIgnored var pollTask: Task<Void, Never>?
    @ObservationIgnored var pollWakeContinuation: AsyncStream<Void>.Continuation?
    var fullRefreshesInFlight = 0
    var transferRefreshInFlight = false
    var transferRefreshDeferred = false
    var lastFullRefresh: ContinuousClock.Instant?
    @ObservationIgnored var engineEventTask: Task<Void, Never>?
    @ObservationIgnored var engineEventRefreshTask: Task<Void, Never>?
    var engineEventRefreshPending = false
    var engineEventsConnected = false
    var refreshClockStarted = false
    @ObservationIgnored var planTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObservers: Set<AnyCancellable> = []
    @ObservationIgnored private var ed2kSearchTask: Task<Void, Never>?
    private var claimedAlertIDs: Set<UUID> = []
    private var pendingStartupAlerts: [UserFacingAlert] = []
    private var didAttemptLaunchStartup = false
    private var bitTorrentSelectionRequestID: UUID?
    private var bitTorrentDiscoveryRetryRequested = false
    private var didReportPowerAssertionFailure = false
    private var ed2kSearchSession: ED2KSearchSession?
    var engineSessionID = UUID()
    var isShuttingDown = false
    var armedScheduledTaskIDs: Set<String> = []
    var downloadPlanIssue: String?
    var bandwidthPlanIssue: String?
    var applyingDownloadPlans = false
    var scheduleRequests: [String: UUID] = [:]
    var lastBandwidthOptions: [String: String]?


    init(
        settingsStore: PersistentSettingsStore? = nil,
        engineController: (any Aria2EngineControlling)? = nil,
        trackerFetcher: (any BitTorrentTrackerSourceFetching)? = nil,
        ed2kBootstrapFetcher: (any ED2KBootstrapFetching)? = nil,
        ed2kBootstrapApplicationSupportBase: URL? = nil,
        powerAssertionController: (any PowerAssertionControlling)? = nil,
        engineInstallationManager: (any EngineInstallationManaging)? = nil,
        notificationCoordinator: DownloadNotificationCoordinator? = nil
    ) {
        var startupAlerts: [UserFacingAlert] = []
        let resolvedSettingsStore: PersistentSettingsStore?
        do {
            if let settingsStore {
                resolvedSettingsStore = settingsStore
            } else {
                resolvedSettingsStore = try PersistentSettingsStore.live()
            }
        } catch {
            startupAlerts.append(
                UserFacingAlert(
                    title: String(localized: "Settings Store Failed"),
                    message: error.localizedDescription
                )
            )
            resolvedSettingsStore = nil
        }

        let loadedSettings: EngineSettings
        if let resolvedSettingsStore {
            do {
                loadedSettings = try resolvedSettingsStore.loadEngineSettings()
            } catch {
                startupAlerts.append(
                    UserFacingAlert(
                        title: String(localized: "Engine Settings Load Failed"),
                        message: error.localizedDescription
                    )
                )
                loadedSettings = EngineSettings()
            }
        } else {
            loadedSettings = EngineSettings()
        }

        let loadedPreferences: AppPreferences
        if let resolvedSettingsStore {
            do {
                loadedPreferences = try resolvedSettingsStore.loadAppPreferences()
            } catch {
                startupAlerts.append(
                    UserFacingAlert(
                        title: String(localized: "App Settings Load Failed"),
                        message: error.localizedDescription
                    )
                )
                loadedPreferences = AppPreferences()
            }
        } else {
            loadedPreferences = AppPreferences()
        }

        var loadedHistory: [DownloadTask] = []
        var resolvedHistory: DownloadHistoryStore?
        var loadHistoryIssue: String?
        do {
            resolvedHistory = try resolvedSettingsStore?.makeHistoryStore()
            loadedHistory = try resolvedHistory?.load() ?? []
            if resolvedHistory == nil { loadHistoryIssue = String(localized: "Download history storage is unavailable.") }
        } catch {
            loadHistoryIssue = String(localized: "Could not load download history: \(DownloadPrivacy.redact(error.localizedDescription))")
        }
        self.notifications = notificationCoordinator ?? DownloadNotificationCoordinator()
        self.historyStore = resolvedHistory
        self.hiddenTaskIDs = resolvedHistory?.deletedIDs ?? []
        self.historyIssue = loadHistoryIssue
        self.tasks = loadedHistory
        listPresentation.update(loadedHistory)
        self.engineInstallationManager = engineInstallationManager ?? EngineInstallationManager()
        self.settingsStore = resolvedSettingsStore
        self.engineController = engineController ?? Aria2NextEngineController()
        let diagnosticFile = AppLaunchConfiguration.isTestAutomation ? nil : (try? Aria2NextPaths.supportDirectory())?.appendingPathComponent("tracker-diagnostics.json")
        self.trackerDiagnostics = TrackerDiagnostics(file: diagnosticFile, monitorNetwork: !AppLaunchConfiguration.isTestAutomation)
        self.trackerFetcher = trackerFetcher ?? URLSessionBitTorrentTrackerSourceFetcher()
        self.ed2kBootstrapFetcher = ed2kBootstrapFetcher ?? URLSessionED2KBootstrapFetcher()
        self.ed2kBootstrapApplicationSupportBase = ed2kBootstrapApplicationSupportBase
        self.powerAssertionController = powerAssertionController ?? DownloadPowerAssertionController()
        self.engineSettings = loadedSettings
        self.preferences = loadedPreferences
        self.addDraft = defaultAddDraft()
        self.ed2kBootstrapStatus = ED2KBootstrapCache.status(applicationSupportBase: ed2kBootstrapApplicationSupportBase)
        self.pendingStartupAlerts = startupAlerts
        self.notifications.setEnabled(loadedPreferences.notifyOnDownloadCompletion)
        self.notifications.onOpenDownloads = { [weak self] ids in self?.showNotifiedDownloads(ids) }
        browserCapture.onImport = { [weak self] urls in
            self?.importDownloads(urls.map(DownloadImportInput.text))
            self?.downloadWindowRequests.send()
        }
        configureBrowserReceipts()
        configureBrowserCapture()
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isShuttingDown else { return }
                    self.scheduleTrackerSync()
                    guard self.refreshClockStarted, self.engineController.isRunning else { return }
                    await self.refreshTasks()
                    self.pollWakeContinuation?.yield(())
                    self.startPlanClock()
                }
            }.store(in: &wakeObservers)
        mediaDownloads.onUnknownCreation = { [weak self] error, draft in self?.noteUncertainBrowserSubmission(error, requestID: draft.browserRequestID) }
        mediaDownloads.onAdded = { [weak self] gid, draft in self?.rememberSubmittedTasks([gid], draft: draft) }
        mediaDownloads.onDiscarded = { [weak self] gid in
            do { try self?.hideHistory([gid]) }
            catch { self?.postError(error, title: String(localized: "Save History Failed")) }
        }
        mediaDownloads.onSaveError = { [weak self] message in self?.postError(message, title: String(localized: "Media Task")) }
        if AppLaunchConfiguration.usesUITestFixtures {
            seedUITestFixtures()
        }
    }

    deinit {
        trackerSyncClock?.cancel()
        trackerSyncOperation?.cancel()
        engineEventTask?.cancel()
        engineEventRefreshTask?.cancel()
        inputTask?.cancel()
        startupTask?.cancel()
        engineUpdateTask?.cancel()
        engineInstallTask?.cancel()
        engineUpgradeTask?.cancel()
        engineMaintenanceTask?.cancel()
        engineSettingsTask?.cancel()
        pollTask?.cancel()
        planTask?.cancel()
        ed2kSearchTask?.cancel()
    }

    func shutdown() {
        cancelEngineSettingsApplication()
        trackerSyncClock?.cancel()
        trackerSyncOperation?.cancel()
        stopEngineEvents()
        isShuttingDown = true
        browserCapture.stop()
        inputTask?.cancel()
        startupTask?.cancel()
        engineUpdateTask?.cancel()
        engineInstallTask?.cancel()
        engineUpgradeTask?.cancel()
        engineMaintenanceTask?.cancel()
        engineSessionID = UUID()
        pollTask?.cancel()
        refreshClockStarted = false
        planTask?.cancel()
        pollTask = nil
        ed2kSearchTask?.cancel()
        ed2kSearchTask = nil
        ED2KSearchTempCache.cleanup(ed2kSearchSession?.temporaryDirectory)
        ed2kSearchSession = nil
        powerAssertionController.release()
        engineController.terminateForAppExit()
        runtime = EngineRuntimeSnapshot(phase: .stopped, lastLaunchArguments: runtime.lastLaunchArguments)
    }

    func startEngineOnAppLaunch() {
        guard !AppLaunchConfiguration.isTestAutomation || AppLaunchConfiguration.testsAutomaticEngineStartup else { return }
        guard startupTask == nil else { return }
        startupTask = Task { @MainActor [weak self] in
            await self?.prepareEngineOnLaunch()
            // The app can keep the cached list up to date even with its engine stopped.
            if self?.trackerSyncClockStarted == false { self?.startTrackerSyncClock(startup: true) }
        }
    }

    /// Shared by normal startup and deterministic tests. Reopening a window must not restart a stopped engine.
    func prepareEngineOnLaunch() async {
        guard !didAttemptLaunchStartup, !isShuttingDown else { return }
        didAttemptLaunchStartup = true
        engineSetupState = .checking
        let installation = await engineInstallationManager.localInstallation()
        guard !isShuttingDown, !Task.isCancelled else { return }
        guard let installation else {
            engineSetupState = .required
            return
        }
        useEngine(installation)
        await startEngine(startupSync: true)
    }

    var engineVersionDescription: String {
        if let installedEngine { return installedEngine.version.description }
        return String(localized: "Unavailable")
    }

    var engineSidebarVersionDescription: String { engineVersionDescription }

    func requestEngineSettings() { engineSettingsRequested = true }

    func requestUpdateSettings() { updateSettingsRequested = true }

    func consumeUpdateSettingsRequest() -> Bool {
        guard updateSettingsRequested else { return false }
        updateSettingsRequested = false
        return true
    }

    func consumeEngineSettingsRequest() -> Bool {
        guard engineSettingsRequested else { return false }
        engineSettingsRequested = false
        return true
    }

    var isUpdatingEngine: Bool { engineUpgradeProgress != nil }

    var selectedEngineRelease: EngineRelease? {
        guard let selectedEngineVersion else { return latestEngineRelease }
        return recentEngineReleases.first { $0.version == selectedEngineVersion }
    }

    var canInstallRequiredEngine: Bool {
        engineSetupState.requiresInstallation && !engineSetupState.isInstalling && !isShuttingDown
            && !isCheckingEngineUpdate && (selectedEngineVersion == nil || selectedEngineRelease != nil)
    }

    var hasEngineVersionChange: Bool {
        installedEngine != nil && selectedEngineRelease != nil
            && (selectedEngineVersion == nil ? availableEngineUpdate != nil : selectedEngineVersion != installedEngine?.version)
    }

    var canUpdateEngine: Bool {
        !isShuttingDown && !isUpdatingEngine && !isCheckingEngineUpdate && !isEngineTransitioning
            && hasEngineVersionChange
            && !isSearchingED2K && !isResolvingBitTorrentFiles && bitTorrentSelectionSession == nil && !mediaDownloads.isPresented
    }

    func updateEngine() {
        guard canUpdateEngine, let previous = installedEngine else { return }
        let selection = selectedEngineVersion
        engineUpgradeError = nil
        engineUpgradeResult = nil
        engineUpgradeProgress = .init(stage: selection == nil ? .checkingRelease : .connecting)
        engineUpgradeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.engineUpgradeProgress = nil
                self.engineUpgradeTask = nil
                self.scheduleEngineSettingsApplication()
                self.startPlanClock()
            }
            let wasRunning = self.engineController.isRunning
            let previousConfiguration = self.engineSettingsApplication.launchedSettings ?? self.engineSettings
            var switchingEngine = false
            var backup: EngineRuntimeBackup?
            do {
                let release = try await self.resolveEngineRelease(selection)
                // Latest can move while the settings page is open. Never implicitly downgrade.
                if selection == nil, release.version <= previous.version {
                    self.refreshEngineUpdateStatus()
                    return
                }
                let installation = try await self.engineInstallationManager.install(release) { [weak self] stage in
                    await self?.updateEngineUpgradeProgress(stage)
                }
                try Task.checkCancellation()
                guard !self.isShuttingDown else { throw CancellationError() }
                try self.engineSettings.validateLaunchRequirements()
                self.engineUpgradeProgress = .init(stage: .savingDownloads)
                if wasRunning { try await self.engineController.client().saveSession() }
                try Task.checkCancellation()
                self.suspendEngineMonitoring()
                switchingEngine = true
                if self.engineController.isRunning { self.runtime = try await self.engineController.stop() }
                try Task.checkCancellation()
                backup = try await self.engineInstallationManager.backupRuntimeState()
                try Task.checkCancellation()
                self.engineController.selectInstallation(installation)
                self.engineUpgradeProgress = .init(stage: .restarting)
                await self.launchEngine(showAlerts: false)
                try Task.checkCancellation()
                guard case .running = self.runtime.phase else {
                    throw EngineError.executableLaunchFailed(path: installation.executableURL.path, reason: self.runtime.lastError ?? String(localized: "The updated engine did not start."))
                }
                self.engineUpgradeProgress = .init(stage: .activating)
                try await self.engineInstallationManager.activate(installation)
                self.useEngine(installation)
                self.engineUpgradeResult = String(localized: "Aria2 Next \(installation.version.description) is installed.")
                await backup?.discard()
            } catch {
                let failure = error.localizedDescription
                let failedStage = self.engineUpgradeProgress?.title.replacingOccurrences(of: "…", with: "") ?? String(localized: "Updating engine")
                if switchingEngine {
                    self.suspendEngineMonitoring()
                    do {
                        if self.engineController.isRunning { self.runtime = try await self.engineController.stop() }
                        self.engineController.selectInstallation(previous)
                        try await backup?.restore()
                        self.runtime = EngineRuntimeSnapshot(phase: .stopped)
                        if wasRunning && !self.isShuttingDown && !Task.isCancelled {
                            self.engineUpgradeProgress = .init(stage: .restoring)
                            // Roll back with the configuration that actually ran,
                            // not pending connection edits that may have failed.
                            await self.launchEngine(configuration: previousConfiguration, showAlerts: false)
                        }
                        await backup?.discard()
                    } catch {
                        self.engineUpgradeError = String(localized: "Update failed: \(failure) Recovery failed: \(error.localizedDescription)")
                        self.updatePowerAssertion()
                        return
                    }
                }
                guard !self.isShuttingDown else { return }
                if Task.isCancelled {
                    self.engineUpgradeResult = String(localized: "Update canceled. Aria2 Next \(previous.version.description) is still installed.")
                    return
                }
                self.engineUpgradeError = String(localized: "\(failedStage): \(failure)\nVersion \(previous.version.description) is still installed. You can retry the update.")
                self.updatePowerAssertion()
            }
        }
    }

    func cancelEngineUpdate() {
        guard engineUpgradeProgress?.canCancel == true else { return }
        engineUpgradeTask?.cancel()
    }

    private func updateEngineUpgradeProgress(_ stage: EngineInstallationProgress) {
        guard isUpdatingEngine, !isShuttingDown else { return }
        engineUpgradeProgress = stage
    }

    private func suspendEngineMonitoring() {
        cancelEngineSettingsApplication()
        stopEngineEvents()
        engineSessionID = UUID()
        engineMaintenanceTask?.cancel()
        pollTask?.cancel()
        refreshClockStarted = false
        planTask?.cancel()
        pollTask = nil
    }

    private func useEngine(_ installation: EngineInstallation) {
        installedEngine = installation
        refreshEngineUpdateStatus()
        engineController.selectInstallation(installation)
        engineSetupState = .ready
        if engineSettings.rpcToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            generateRPCToken()
        }
        if engineSettings.downloadDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            engineSettings.downloadDirectoryPath = EngineSettings().downloadDirectoryPath
        }
    }

    private func refreshEngineUpdateStatus() {
        guard let latestEngineRelease else {
            availableEngineUpdate = nil
            return
        }
        if let installedEngine, latestEngineRelease.version <= installedEngine.version {
            availableEngineUpdate = nil
            engineUpdateStatus = String(localized: "Up to date (\(installedEngine.version.description))")
        } else {
            availableEngineUpdate = installedEngine == nil ? nil : latestEngineRelease
            engineUpdateStatus = String(localized: "Version \(latestEngineRelease.version.description) available")
        }
    }

    func loadEngineReleasesIfNeeded() {
        guard !didLoadEngineReleases, !AppLaunchConfiguration.isTestAutomation else { return }
        startEngineUpdateCheck()
    }

    var canCheckEngineUpdates: Bool {
        engineUpdateTask == nil && !isShuttingDown && !isUpdatingEngine && !engineSetupState.isInstalling
    }

    func startEngineUpdateCheck() {
        guard canCheckEngineUpdates else { return }
        // UI automation uses a local engine without contacting GitHub.
        guard !AppLaunchConfiguration.isUITesting else { return }
        isCheckingEngineUpdate = true
        didLoadEngineReleases = true
        if latestEngineRelease == nil {
            engineUpdateStatus = String(localized: "Checking for updates…")
        }
        engineUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.engineUpdateTask = nil; self.isCheckingEngineUpdate = false }
            do {
                let release = try await self.engineInstallationManager.latestRelease()
                guard !self.isShuttingDown, !Task.isCancelled else { return }
                self.latestEngineRelease = release
                self.refreshEngineUpdateStatus()
            } catch {
                guard !self.isShuttingDown, !Task.isCancelled else { return }
                self.engineUpdateStatus = String(localized: "Could not check for updates. Try again later.")
            }
            do {
                let releases = try await self.engineInstallationManager.recentReleases()
                guard !self.isShuttingDown, !Task.isCancelled else { return }
                guard !releases.isEmpty else { throw EngineInstallationError.invalidRelease }
                self.engineReleaseListError = nil
                self.engineVersionSelectionNotice = nil
                self.recentEngineReleases = releases
                if let selected = self.selectedEngineVersion, !releases.contains(where: { $0.version == selected }) {
                    self.selectedEngineVersion = nil
                    self.engineVersionSelectionNotice = String(localized: "The selected version is no longer in the recent releases. Latest is selected.")
                }
            } catch {
                guard !self.isShuttingDown, !Task.isCancelled else { return }
                self.engineReleaseListError = String(localized: "Could not load recent versions. Refresh to try again, or choose Latest.")
            }
        }
    }

    func waitForEngineUpdateCheck() async {
        await engineUpdateTask?.value
    }

    private func resolveEngineRelease(_ version: EngineVersion?) async throws -> EngineRelease {
        if let version {
            guard let release = recentEngineReleases.first(where: { $0.version == version }) else {
                throw EngineInstallationError.invalidRelease
            }
            return release
        }
        let release = try await engineInstallationManager.latestRelease()
        try Task.checkCancellation()
        latestEngineRelease = release
        refreshEngineUpdateStatus()
        return release
    }

    func installRequiredEngine() {
        guard canInstallRequiredEngine else { return }
        let selection = selectedEngineVersion
        engineSetupState = .installing(.init(stage: selection == nil ? .checkingRelease : .connecting))
        engineInstallTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.engineInstallTask = nil }
            do {
                let release = try await self.resolveEngineRelease(selection)
                let installation = try await self.engineInstallationManager.install(release) { [weak self] stage in
                    await self?.updateEngineInstallationProgress(stage)
                }
                guard !self.isShuttingDown, !Task.isCancelled else { return }
                self.engineSetupState = .installing(.init(stage: .activating))
                try await self.engineInstallationManager.activate(installation)
                self.useEngine(installation)
                await self.startEngine(startupSync: true)
            } catch {
                guard !self.isShuttingDown else { return }
                if Task.isCancelled { self.engineSetupState = .required; return }
                self.engineSetupState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelEngineInstallation() {
        guard case .installing(let progress) = engineSetupState, progress.canCancel else { return }
        engineInstallTask?.cancel()
    }

    private func updateEngineInstallationProgress(_ stage: EngineInstallationProgress) {
        guard !isShuttingDown, engineSetupState.isInstalling else { return }
        engineSetupState = .installing(stage)
    }

    var selectedTaskRow: DownloadRowState? {
        guard let selectedTaskID else { return nil }
        return listPresentation.row(id: selectedTaskID)
    }

    var selectedTask: DownloadTask? { selectedTaskRow?.task }

    var visibleTasks: [DownloadTask] {
        visibleTasks(for: selectedDestination)
    }

    func visibleTasks(for destination: SidebarDestination) -> [DownloadTask] {
        listPresentation.visibleRows(for: destination, query: searchQuery).map(\.task)
    }

    var activeSpeed: Int64 {
        recentSpeedSamples.last?.downloadBytesPerSecond ?? tasks.reduce(0) { $0 + $1.downloadSpeed }
    }

    var uploadSpeed: Int64 {
        recentSpeedSamples.last?.uploadBytesPerSecond ?? tasks.reduce(0) { $0 + $1.uploadSpeed }
    }

    var recentSpeedSamples: [SpeedSample] {
        SpeedSample.rollingWindowSamples(speedSamples)
    }

    var speedLabel: String {
        "↓ \(ByteFormat.speed(activeSpeed))"
    }

    var canStartEngine: Bool {
        guard !isShuttingDown, !isUpdatingEngine, !engineController.isRunning, !engineSetupState.requiresInstallation, engineSetupState != .checking else { return false }
        switch runtime.phase {
        case .stopped, .failed:
            return true
        case .starting, .running, .stopping:
            return false
        }
    }

    var canStopEngine: Bool {
        guard !isUpdatingEngine else { return false }
        switch runtime.phase {
        case .running:
            return true
        case .stopped, .starting, .stopping, .failed:
            return engineController.isRunning
        }
    }

    var canRestartEngine: Bool {
        !isShuttingDown && !isUpdatingEngine && !isEngineTransitioning && !engineSetupState.requiresInstallation && engineSetupState != .checking
            && !isSearchingED2K && !isResolvingBitTorrentFiles && bitTorrentSelectionSession == nil
            && !mediaDownloads.isPresented && !isPerformingBatchOperation
    }

    private var isEngineTransitioning: Bool {
        switch runtime.phase {
        case .starting, .stopping:
            return true
        case .stopped, .running, .failed:
            return false
        }
    }

    func count(for destination: SidebarDestination) -> Int {
        listPresentation.visibleRows(for: destination).count
    }

    func adoptDownloadDirectory(_ url: URL) {
        do {
            var settings = engineSettings
            settings.downloadDirectoryPath = url.path
            settings.downloadDirectoryBookmark = try PreferencesStore.bookmark(for: url)
            engineSettings = settings
            if addDraft.savePath.isEmpty {
                addDraft.savePath = url.path
            }
            postActivity(String(localized: "Download directory set."))
        } catch {
            postError(error, title: String(localized: "Download Folder Failed"))
        }
    }

    func generateRPCToken() {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            postError(String(localized: "Could not generate a secure RPC token."), title: String(localized: "RPC Token Failed"))
            return
        }
        engineSettings.rpcToken = bytes.map { String(format: "%02x", $0) }.joined()
        postActivity(String(localized: "Generated a new RPC token. Restart the engine if it is running."))
    }

    @discardableResult
    func addCustomTrackerSource(_ rawValue: String) -> Bool {
        let url = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            postError(String(localized: "Enter a tracker source URL."), title: String(localized: "Tracker Source Failed"))
            return false
        }
        guard TrackerSourceURLValidator.isValid(url) else {
            postError(String(localized: "Enter a valid HTTP or HTTPS tracker source URL."), title: String(localized: "Tracker Source Failed"))
            return false
        }

        var settings = engineSettings
        var changed = false
        if !settings.customTrackerSourceURLs.contains(url) {
            settings.customTrackerSourceURLs.append(url)
            changed = true
        }
        if !settings.trackerSourceURLs.contains(url) {
            settings.trackerSourceURLs.append(url)
            changed = true
        }

        guard changed else {
            postActivity(String(localized: "Tracker source already exists."))
            return false
        }

        engineSettings = settings
        postActivity(String(localized: "Tracker source added."))
        return true
    }

    func removeCustomTrackerSource(_ url: String) {
        var settings = engineSettings
        settings.customTrackerSourceURLs.removeAll { $0 == url }
        settings.trackerSourceURLs.removeAll { $0 == url }
        engineSettings = settings
        postActivity(String(localized: "Tracker source removed."))
    }

    func setTrackerSource(_ url: String, isSelected: Bool) {
        var settings = engineSettings
        if isSelected {
            guard !settings.trackerSourceURLs.contains(url) else { return }
            settings.trackerSourceURLs.append(url)
        } else {
            settings.trackerSourceURLs.removeAll { $0 == url }
        }
        engineSettings = settings
    }

    func syncBitTorrentTrackersManually() async {
        await syncBitTorrentTrackers(reportFailures: true)
    }

    func setBrowserCaptureEnabled(_ enabled: Bool) {
        var updated = preferences
        if enabled, updated.browserCaptureToken.isEmpty {
            updated.browserCaptureToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        updated.browserCaptureEnabled = enabled
        preferences = updated
    }

    func resetBrowserPairing() {
        do { try browserCapture.receiptStore.clear() } catch { postError(error, title: String(localized: "Reset Pairing Failed")); return }
        preferences.browserCaptureToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func configureBrowserCapture() {
        guard !AppLaunchConfiguration.isTestAutomation, !isShuttingDown else { return }
        if preferences.browserCaptureEnabled { browserCapture.start(token: preferences.browserCaptureToken) }
        else { browserCapture.stop() }
    }

    func importDownloads(_ inputs: [DownloadImportInput]) {
        guard !isShuttingDown else { return }
        let preceding = inputTask
        let preferences = preferences
        inputTask = Task { @MainActor [weak self] in
            await preceding?.value
            guard !Task.isCancelled else { return }
            let requests = await DownloadImportReader.prepare(inputs, preferences: preferences)
            guard !Task.isCancelled else { return }
            self?.inputCoordinator.enqueue(requests)
        }
    }

    func importDroppedItems(_ providers: [NSItemProvider]) {
        Task { @MainActor [weak self] in
            let inputs = await DownloadInputCoordinator.droppedInputs(providers)
            self?.importDownloads(inputs)
        }
    }

    func beginImportedDownload(owner: UUID) -> Bool {
        guard engineSetupState == .ready,
              let request = inputCoordinator.claimImport(owner: owner, preserving: addDraft) else { return false }
        addDraft = defaultAddDraft()
        addDraft.rawInput = request.resources.joined(separator: "\n")
        addDraft.importedDocuments = request.documents
        addDraft.browserRequestID = request.browserRequestID
        browserPartConfirmed = false
        if let context = request.browserContext {
            if !context.userAgent.isEmpty { addDraft.userAgent = context.userAgent }
            addDraft.referer = context.referer
            addDraft.cookie = context.cookie
            addDraft.authorization = context.authorization
            addDraft.browserContextOrigin = context.sourceOrigin
        }
        addDraftNotice = request.browserContext == nil ? nil : String(localized: "Browser request details are included. Review the source and authentication before confirming.")
        if request.browserContext != nil, addDraft.detectedProtocol == .metalink,
           !addDraft.cookie.isEmpty || !addDraft.authorization.isEmpty {
            addDraftNotice = String(localized: "Metalink files received with browser credentials stay as documents. Open the saved file to review its downloads.")
        }
        importIssues = request.issues
        return true
    }

    func finishDownloadPanel(owner: UUID) {
        guard inputCoordinator.owner == owner else { return }
        finishBrowserPart()
        if let original = inputCoordinator.finish(owner: owner) { addDraft = original }
        importIssues = []
        addDraftNotice = nil
    }

    func setCompletionNotificationsEnabled(_ enabled: Bool) async {
        if enabled { preferences.notifyOnDownloadCompletion = await notifications.requestEnable() }
        else { preferences.notifyOnDownloadCompletion = false }
    }

    private func showNotifiedDownloads(_ ids: [String]) {
        searchQuery = ""
        selectedDestination = .all
        selectedTaskID = ids.first { id in tasks.contains { $0.id == id } }
        notificationNavigationRevision += 1
    }

    func requestAddPanel() {
        addDraftNotice = nil
        inputCoordinator.requestManualSheet()
        addPanelRequests.send()
    }

    func prepareAddDraftForPresentation() {
        guard addDraft.savePath.isEmpty else { return }
        addDraft.savePath = engineSettings.downloadDirectoryPath ?? ""
    }

    func startEngine(startupSync: Bool = false) async {
        guard canStartEngine else { return }
        await launchEngine(startupSync: startupSync)
    }

    private func launchEngine(configuration: EngineSettings? = nil, startupSync: Bool = false, showAlerts: Bool = true) async {
        guard !isShuttingDown else { return }
        clearActivityMessage()
        let launchSettings = configuration ?? engineSettings
        do {
            try launchSettings.validateLaunchRequirements()
        } catch {
            runtime = EngineRuntimeSnapshot(phase: .failed(error.localizedDescription), lastError: error.localizedDescription)
            if showAlerts { postError(error, title: String(localized: "Start Engine Failed")) }
            return
        }

        // The controller validates port availability immediately before launching.
        // Keeping that check there also lets injected controllers stay independent of live engines.
        let sessionID = UUID()
        cancelEngineSettingsApplication()
        armedScheduledTaskIDs.removeAll()
        scheduleRequests.removeAll()
        lastBandwidthOptions = nil
        engineSessionID = sessionID
        engineCapabilities = nil
        sessionProtectedTorrentIDs.removeAll()
        notifications.resetBaseline()
        var launchArguments: [String] = []
        runtime = EngineRuntimeSnapshot(
            phase: .starting,
            lastLaunchArguments: runtime.lastLaunchArguments,
            lastError: nil
        )
        do {
            try Task.checkCancellation()
            guard engineSessionID == sessionID else { return }
            let launchBootstrap = ed2kBootstrapStatus
            let launchSnapshot = try await engineController.start(settings: launchSettings)
            guard engineSessionID == sessionID else { return }
            launchArguments = launchSnapshot.lastLaunchArguments
            runtime = EngineRuntimeSnapshot(
                phase: .starting,
                lastLaunchArguments: launchArguments,
                lastError: nil
            )
            try await waitForEngineRPC(port: launchSettings.rpcPort)
            try Task.checkCancellation()
            guard engineSessionID == sessionID else { return }
            engineCapabilities = try await engineController.client().getVersion()
            guard engineSessionID == sessionID, !Task.isCancelled else { return }
            runtime = launchSnapshot
            engineSettingsApplication.didLaunch(launchSettings, bootstrap: launchBootstrap)
            engineSettingsIssue = nil
            scheduleEngineSettingsApplication()
            if showAlerts, let backup = launchSnapshot.sessionBackupURL {
                userAlerts.send(UserFacingAlert(
                    title: String(localized: "Download Engine Updated"),
                    message: String(localized: "Your previous task list was backed up before updating the engine. Unfinished downloads from older versions may restart from zero; existing partial files are preserved.\n\nBackup: \(backup.path)")
                ))
            }
            await refreshTasks(reportErrors: showAlerts)
            guard engineSessionID == sessionID, engineController.isRunning else { return }
            startPolling()
            startTrackerSyncClock(startup: startupSync)
            engineMaintenanceTask?.cancel()
            engineMaintenanceTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.syncED2KBootstrapIfDue(startup: startupSync)
            }
        } catch is CancellationError {
            guard engineSessionID == sessionID else { return }
            stopEngineEvents()
            pollTask?.cancel()
            refreshClockStarted = false
            planTask?.cancel()
            pollTask = nil
            if engineController.isRunning { _ = try? await engineController.stop() }
            engineController.terminateForAppExit()
            runtime = EngineRuntimeSnapshot(phase: .stopped, lastLaunchArguments: launchArguments)
            updatePowerAssertion()
        } catch {
            guard engineSessionID == sessionID else { return }
            stopEngineEvents()
            pollTask?.cancel()
            refreshClockStarted = false
            planTask?.cancel()
            pollTask = nil
            if engineController.isRunning { _ = try? await engineController.stop() }
            engineController.terminateForAppExit()
            runtime = EngineRuntimeSnapshot(
                phase: .failed(error.localizedDescription),
                lastLaunchArguments: launchArguments,
                lastError: error.localizedDescription
            )
            updatePowerAssertion()
            if showAlerts { postError(error, title: String(localized: "Start Engine Failed")) }
        }
    }

    func stopEngine() async {
        guard canStopEngine else {
            postError(EngineError.notRunning, title: String(localized: "Stop Engine Failed"))
            return
        }
        cancelEngineSettingsApplication()
        engineSessionID = UUID()
        stopEngineEvents()
        engineMaintenanceTask?.cancel()
        clearActivityMessage()
        do {
            pollTask?.cancel()
            refreshClockStarted = false
            planTask?.cancel()
            pollTask = nil
            runtime = EngineRuntimeSnapshot(
                phase: .stopping,
                lastLaunchArguments: runtime.lastLaunchArguments,
                lastError: runtime.lastError
            )
            runtime = try await engineController.stop()
            tasks = tasks.map(\.disconnectedSnapshot)
            engineCapabilities = nil
            updatePowerAssertion()
        } catch {
            runtime = EngineRuntimeSnapshot(
                phase: .failed(error.localizedDescription),
                lastLaunchArguments: runtime.lastLaunchArguments,
                lastError: error.localizedDescription
            )
            updatePowerAssertion()
            postError(error, title: String(localized: "Stop Engine Failed"))
        }
    }

    func prepareForAppTermination() async {
        cancelEngineSettingsApplication()
        trackerSyncClock?.cancel()
        trackerSyncOperation?.cancel()
        stopEngineEvents()
        isShuttingDown = true
        browserCapture.stop()
        inputTask?.cancel()
        startupTask?.cancel()
        engineUpdateTask?.cancel()
        engineInstallTask?.cancel()
        engineUpgradeTask?.cancel()
        await engineUpgradeTask?.value
        engineMaintenanceTask?.cancel()
        engineSessionID = UUID()
        pollTask?.cancel()
        refreshClockStarted = false
        planTask?.cancel()
        pollTask = nil
        guard engineController.isRunning else {
            engineController.terminateForAppExit()
            runtime = EngineRuntimeSnapshot(phase: .stopped, lastLaunchArguments: runtime.lastLaunchArguments)
            updatePowerAssertion()
            return
        }

        runtime = EngineRuntimeSnapshot(
            phase: .stopping,
            lastLaunchArguments: runtime.lastLaunchArguments,
            lastError: runtime.lastError
        )

        do {
            let client = try engineController.client()
            do {
                _ = try await DownloadTaskRPCOperations.pauseAll(tasks, using: client)
            } catch {
                updateRuntime(lastError: error.localizedDescription)
            }

            do {
                try await client.saveSession()
            } catch {
                updateRuntime(lastError: error.localizedDescription)
            }
        } catch {
            updateRuntime(lastError: error.localizedDescription)
        }

        do {
            runtime = try await engineController.stop()
            tasks = tasks.map(\.disconnectedSnapshot)
            engineCapabilities = nil
            updatePowerAssertion()
        } catch {
            updateRuntime(lastError: error.localizedDescription)
            engineController.terminateForAppExit()
            updatePowerAssertion()
        }
    }

    func restartEngine() async {
        guard canRestartEngine, !isShuttingDown else { return }
        do {
            try engineSettings.validateLaunchRequirements()
        } catch {
            updateRuntime(lastError: error.localizedDescription)
            postError(error, title: String(localized: "Restart Engine Failed"))
            return
        }
        if engineController.isRunning {
            await stopEngine()
            guard !engineController.isRunning else { return }
        }
        await startEngine()
    }

    func finishRecording(_ task: DownloadTask) async {
        guard task.canFinishRecording, !isUpdatingEngine else { return }
        await performTaskMutation(alertTitle: String(localized: "Finish Recording Failed")) { client in
            try await client.finishMedia(task.id)
        }
    }

    func retryMedia(_ task: DownloadTask) async {
        guard task.canRetryMedia, !isUpdatingEngine else { return }
        await performTaskMutation(alertTitle: String(localized: "Retry Media Failed")) { client in
            try await client.retryMedia(task.id)
        }
    }

    func prepareBitTorrentFileSelection() async {
        guard !browserSubmissionIsUncertain() else {
            postError(String(localized: "The previous submission result is unknown. Check Downloads before creating another task."), title: String(localized: "Submission Needs Review"))
            return
        }
        guard !isResolvingBitTorrentFiles else { return }
        guard addDraft.isSubmittable, addDraft.shouldResolveBitTorrentFilesBeforeSubmit else {
            postError(DownloadDraftError.bitTorrentSelectionRequiresSingleResource, title: String(localized: "Add Download Failed"))
            return
        }
        var draft = addDraft
        let source = draft.resourceLines.first ?? ""
        let requestID = UUID()
        bitTorrentSelectionRequestID = requestID
        isResolvingBitTorrentFiles = true
        isRetryingBitTorrentDiscovery = false
        bitTorrentDiscoveryRetryRequested = false
        clearActivityMessage()
        if var retained = bitTorrentSelectionSession {
            retained.phase = .loading; retained.issue = nil
            retained.startedAt = Date(); retained.discovery = nil
            bitTorrentSelectionSession = retained
        } else {
            bitTorrentSelectionSession = BitTorrentFileSelectionSession(
                source: source, taskName: TorrentFileTree.sourceName(source), files: [],
                selectedFileIndexes: [], phase: .loading, destination: draft.savePath)
        }
        defer {
            if bitTorrentSelectionRequestID == requestID {
                isResolvingBitTorrentFiles = false
                isRetryingBitTorrentDiscovery = false
                bitTorrentDiscoveryRetryRequested = false
            }
        }
        do {
            let client = try engineController.client()
            if let directory = bitTorrentSelectionSession?.torrentDirectory {
                draft.savePath = directory
                draft.torrentDirectory = directory
            } else {
                let options = try draft.engineOptions(fallbackDirectory: engineSettings.downloadDirectoryPath,
                                                       autoOrganize: preferences.autoOrganizeFiles)
                guard let base = options["dir"], base.hasPrefix("/") else { throw EngineError.missingDownloadDirectory }
                let directory = try TorrentStorage.createDirectory(in: URL(fileURLWithPath: base),
                                                                   name: TorrentFileTree.sourceName(source).replacingOccurrences(of: "\\.torrent$", with: "", options: [.regularExpression, .caseInsensitive]))
                draft.savePath = directory.path
                draft.torrentDirectory = directory.path
                updateBitTorrentSelectionSession { $0.torrentDirectory = directory.path }
            }
            let metadataGID: String
            if let retained = bitTorrentSelectionSession?.metadataTaskID {
                metadataGID = retained
            } else {
                metadataGID = try await client.addBitTorrentMetadataDownload(
                    draft, fallbackDirectory: engineSettings.downloadDirectoryPath,
                    autoOrganize: false)
                guard isCurrentBitTorrentSelection(requestID) else {
                    await cleanupBitTorrentSelection(BitTorrentFileSelectionSession(
                        source: source, metadataTaskID: metadataGID, taskName: "", files: [],
                        selectedFileIndexes: [], phase: .loading, torrentDirectory: draft.torrentDirectory), using: client)
                    return
                }
                updateBitTorrentSelectionSession { $0.metadataTaskID = metadataGID }
                rememberSubmittedTasks([metadataGID], draft: draft)
                _ = await saveSessionAfterTaskMutation(using: client)
            }
            // Diagnostics must never delay the file-list poll, even if one endpoint stalls.
            let diagnostics = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.isCurrentBitTorrentSelection(requestID),
                          self.bitTorrentSelectionSession?.phase == .loading else { return }
                    let gid = self.bitTorrentSelectionSession?.downloadTaskID ?? metadataGID
                    let attempt = self.bitTorrentSelectionSession?.startedAt
                    let observation = await client.torrentDiscovery(gid)
                    guard !Task.isCancelled, self.isCurrentBitTorrentSelection(requestID),
                          self.bitTorrentSelectionSession?.phase == .loading else { return }
                    if self.bitTorrentSelectionSession?.startedAt == attempt,
                       (self.bitTorrentSelectionSession?.downloadTaskID ?? metadataGID) == gid {
                        self.updateBitTorrentSelectionSession { $0.discovery = observation }
                    }
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
            defer { diagnostics.cancel() }
            let prepared = try await waitForBitTorrentFiles(
                metadataGID: metadataGID, source: source, client: client, requestID: requestID)
            guard isCurrentBitTorrentSelection(requestID) else { return }
            if let contentID = prepared.downloadTaskID, contentID != metadataGID {
                rememberSubmittedTasks([contentID], draft: draft)
                try hideHistory([metadataGID])
            }
            bitTorrentSelectionSession = prepared
            selectedTaskID = prepared.downloadTaskID
            _ = await saveSessionAfterTaskMutation(using: client)
            _ = await refreshTasks(reportErrors: false)
        } catch {
            guard isCurrentBitTorrentSelection(requestID) else { return }
            if bitTorrentSelectionSession?.metadataTaskID == nil { noteUncertainBrowserSubmission(error, requestID: draft.browserRequestID) }
            // Retain the GID and any acquired metadata so a retry doesn't start discovery over.
            updateBitTorrentSelectionSession {
                $0.phase = .failed
                $0.issue = DownloadPrivacy.redact(error.localizedDescription)
            }
        }
    }

    @discardableResult
    func confirmBitTorrentFileSelection() async -> Bool {
        guard let session = bitTorrentSelectionSession,
              session.phase == .ready,
              let downloadTaskID = session.downloadTaskID else {
            postError(String(localized: "Torrent files are not ready yet."), title: String(localized: "Start Download Failed"))
            return false
        }
        guard session.hasSelection else {
            postError(String(localized: "Select at least one file to download."), title: String(localized: "Start Download Failed"))
            return false
        }

        let startPaused = addDraft.startPaused
        let browserID = addDraft.browserRequestID
        let owner = inputCoordinator.owner
        do {
            let client = try engineController.client()
            let snapshot = try await client.tellStatus(downloadTaskID)
            guard !snapshot.task.isFetchingMetadata else {
                throw DownloadOperationError(String(localized: "Torrent files are not ready yet."))
            }
            switch snapshot.task.status {
            case .active, .waiting:
                try await client.forcePause(downloadTaskID)
            case .paused:
                break
            case .completed, .failed, .removed:
                throw DownloadTaskOperationError.bitTorrentContentNotSelectable(status: snapshot.task.status.localizedTitle)
            }

            if let directory = session.torrentDirectory, let infoHash = snapshot.task.infoHash {
                try await client.saveSession()
                try await saveTorrentCopy(taskID: downloadTaskID, infoHash: infoHash, name: session.taskName,
                    directory: URL(fileURLWithPath: directory), source: session.source,
                    metadataFilePath: session.metadataFilePath)
            }
            guard bitTorrentSelectionSession?.id == session.id, inputCoordinator.owner == owner else { throw CancellationError() }
            try await client.changeOption(gid: downloadTaskID, options: ["select-file": session.selectFileOption,
                "bt-file-priority": session.files.sorted { $0.index < $1.index }.map {
                    "\($0.index)=\(session.selectedFileIndexes.contains($0.index) ? "normal" : "off")"
                }.joined(separator: ",")])
            if snapshot.task.privateTorrent == false {
                let currentTrackers = try await client.torrentTrackerStatus(downloadTaskID)
                let plan = PublicTrackerPolicy.replacement(current: currentTrackers,
                    selected: TrackerText.trackers(from: engineSettings.btTracker), previous: nil, infoHash: snapshot.task.infoHash)
                if plan.trackers != TorrentTrackerAddress.merging(currentTrackers, additional: []) {
                    try await client.replaceTorrentTrackers(downloadTaskID, trackers: plan.trackers)
                }
                if let index = tasks.firstIndex(where: { $0.id == downloadTaskID && $0.infoHash == snapshot.task.infoHash }) {
                    tasks[index].publicTrackerOwnership = plan.ownership
                    persistTaskHistory()
                }
            }
            guard bitTorrentSelectionSession?.id == session.id, inputCoordinator.owner == owner else { throw CancellationError() }
            if !startPaused { try await client.resume(downloadTaskID) }
            if let metadataTaskID = session.metadataTaskID, metadataTaskID != downloadTaskID {
                do {
                    try await client.removeDownloadResult(metadataTaskID)
                } catch where isTaskAlreadyAbsent(error) {
                    // Aria2 may already have discarded the metadata GID after following the content task.
                }
            }

            noteBrowserTasks([downloadTaskID], confirmed: true, requestID: browserID, owner: owner)
            let keptPaused = startPaused
            if bitTorrentSelectionSession?.id == session.id {
                bitTorrentSelectionRequestID = nil
                bitTorrentSelectionSession = nil
            }
            if inputCoordinator.owner == owner { addDraft = defaultAddDraft() }
            let saveError = await saveSessionAfterTaskMutation(using: client)
            _ = await refreshTasks(reportErrors: false)
            if let saveError {
                postError(saveError, title: String(localized: "Save Session Failed"))
                return false
            }
            postActivity(keptPaused ? String(localized: "Added selected torrent files, paused.") : String(localized: "Started selected torrent files."))
            return true
        } catch {
            postError(error, title: String(localized: "Start Download Failed"))
            return false
        }
    }

    func retryBitTorrentDiscovery() {
        guard isResolvingBitTorrentFiles, !isRetryingBitTorrentDiscovery, !isShuttingDown,
              let session = bitTorrentSelectionSession, session.phase == .loading,
              session.metadataTaskID != nil, !session.isQueued else { return }
        bitTorrentDiscoveryRetryRequested = true
        isRetryingBitTorrentDiscovery = true
    }

    func cancelBitTorrentFileSelection() async {
        // AppKit dismisses sheets while quitting. The shutdown path saves these
        // paused tasks for the next launch; disappearance is not user cancellation.
        guard !isShuttingDown, let session = bitTorrentSelectionSession else { return }
        inputCoordinator.cancelManualRequest()
        bitTorrentSelectionRequestID = nil
        isResolvingBitTorrentFiles = false
        isRetryingBitTorrentDiscovery = false
        bitTorrentDiscoveryRetryRequested = false
        bitTorrentSelectionSession = nil
        await cleanupBitTorrentSelection(session, using: try? engineController.client())
    }

    private func saveTorrentCopy(taskID: String, infoHash: String, name: String, directory: URL,
                                 source: String, metadataFilePath: String?) async throws {
        let original = addDraft.importedDocuments[source]?.data
        let metadataURL = metadataFilePath.map { URL(fileURLWithPath: $0) }
            ?? AddDownloadDraft.localTorrentFileURL(source)
        let state = EngineStorage(supportDirectory: try Aria2NextPaths.supportDirectory()).state
        try await TorrentStorage.saveEngineCopy(taskID: taskID, infoHash: infoHash, name: name, directory: directory,
            original: original, metadataURL: metadataURL, stateDirectory: state)
    }

    func showInFinder(_ task: DownloadTask) {
        guard let url = DownloadFileLocation.revealURL(for: task) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func setBitTorrentFile(_ file: DownloadFile, isSelected: Bool) {
        guard var session = bitTorrentSelectionSession else { return }
        if isSelected {
            session.selectedFileIndexes.insert(file.index)
        } else {
            session.selectedFileIndexes.remove(file.index)
        }
        bitTorrentSelectionSession = session
    }

    func setBitTorrentFileIndexes(_ indexes: Set<Int>, selected: Bool) {
        guard var session = bitTorrentSelectionSession, session.phase == .ready else { return }
        let valid = indexes.intersection(Set(session.files.map(\.index)))
        if selected { session.selectedFileIndexes.formUnion(valid) }
        else { session.selectedFileIndexes.subtract(valid) }
        bitTorrentSelectionSession = session
    }

    func setAllBitTorrentFilesSelected(_ isSelected: Bool) {
        guard var session = bitTorrentSelectionSession, session.phase == .ready else { return }
        session.selectedFileIndexes = isSelected ? Set(session.files.map(\.index)) : []
        bitTorrentSelectionSession = session
    }

    func selectBitTorrentFiles(ofKind kind: TorrentFileKind) {
        guard var session = bitTorrentSelectionSession, session.phase == .ready else { return }
        session.selectedFileIndexes = kind.indexes(in: session.files)
        bitTorrentSelectionSession = session
    }

    func refreshDetails(for taskID: DownloadTask.ID) async {
        guard engineController.isRunning else { return }
        guard let task = tasks.first(where: { $0.id == taskID }), task.isTorrentLike, task.isAvailableInEngine else { return }
        guard task.status == .active else {
            if let index = tasks.firstIndex(where: { $0.id == taskID }) {
                tasks[index].peers = []
                tasks[index].trackers = []
            }
            return
        }

        do {
            let client = try engineController.client()
            let peers = try await client.getPeers(taskID)
            let trackers = engineCapabilities?.supportsTorrentManagement == true ? try await client.getTorrentTrackers(taskID) : nil
            guard !Task.isCancelled, let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            tasks[index].peers = peers
            if let trackers { tasks[index].trackers = trackers }
        } catch where isTaskAlreadyAbsent(error) {
            return
        } catch {
            updateRuntime(lastError: error.localizedDescription)
        }
    }

    func startTrackerSyncClock(startup: Bool = false) {
        guard !isShuttingDown else { return }
        trackerSyncClockStarted = true
        if startup && engineSettings.btTrackerSyncIntervalHours == 0 { trackerSyncPending = true }
        scheduleTrackerSync()
    }

    func nextTrackerSyncDate(now: Date = Date()) -> Date? {
        TrackerSyncSchedule.nextDate(settings: engineSettings, now: now,
            force: trackerSyncPending, retryAfter: trackerSyncRetryAfter)
    }

    private func scheduleTrackerSync() {
        trackerSyncClock?.cancel()
        trackerSyncClock = nil
        guard trackerSyncClockStarted, !isShuttingDown, !isSyncingTrackers,
              let deadline = nextTrackerSyncDate() else { return }
        trackerSyncClock = Task { [weak self] in
            // Reevaluate wall-clock deadlines after sleep/wake and clock changes.
            let delay = min(60, max(0, deadline.timeIntervalSinceNow))
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self, !self.isShuttingDown else { return }
            if deadline > Date() { self.scheduleTrackerSync(); return }
            await self.syncBitTorrentTrackers(reportFailures: false)
        }
    }

    private func syncBitTorrentTrackers(reportFailures: Bool) async {
        guard !isShuttingDown else { return }
        if let operation = trackerSyncOperation { await operation.value; return }
        let operation = Task { [weak self] in
            guard let self else { return }
            await self.performTrackerSync(automatic: !reportFailures)
        }
        trackerSyncOperation = operation
        await operation.value
    }

    private func performTrackerSync(automatic: Bool) async {
        let sources = engineSettings.trackerSourceURLs
        let originalText = engineSettings.btTracker
        trackerSyncFeedback = .idle
        trackerSyncIssue = nil
        trackerSyncPending = false
        isSyncingTrackers = true
        trackerSyncFeedback = .working
        defer {
            isSyncingTrackers = false
            trackerSyncOperation = nil
            if trackerSyncFeedback == .working { trackerSyncFeedback = .idle }
            scheduleTrackerSync()
        }
        func report(_ message: String, title: String) {
            let safe = DownloadPrivacy.redact(message)
            trackerSyncIssue = safe
            trackerSyncRetryAfter = Date().addingTimeInterval(300)
            if !automatic { postError(safe, title: title) }
        }
        guard !sources.isEmpty else {
            report(String(localized: "Select at least one tracker source."), title: String(localized: "Tracker Sync Failed"))
            return
        }
        let result = await trackerFetcher.fetchTrackerSources(sources)
        // A completed fetch must not overwrite source changes or a manual edit made
        // while the network was suspended, nor apply to an app that is shutting down.
        guard !Task.isCancelled, !isShuttingDown, engineSettings.trackerSourceURLs == sources,
              !automatic || engineSettings.btTrackerAutoSync else { return }
        guard engineSettings.btTracker == originalText else {
            // Do not immediately retry an overdue sync and overwrite the edit anyway.
            if engineSettings.btTrackerSyncIntervalHours > 0 {
                trackerSyncRetryAfter = Date().addingTimeInterval(Double(engineSettings.btTrackerSyncIntervalHours) * 3_600)
            }
            return
        }
        let fetchedText = TrackerText.lineSeparated(fromChunks: result.data)
        guard !fetchedText.isEmpty else {
            report(trackerFailureMessage(result.failures, successCount: 0, totalCount: sources.count),
                title: String(localized: "Tracker Sync Failed"))
            return
        }
        // Keep cached entries from unreachable sources until a complete fetch succeeds.
        let trackerText = trackerDiagnostics.curate(result, sourceURLs: sources, current: originalText, proxy: engineSettings.proxyURL)
        var settings = engineSettings
        settings.btTracker = trackerText
        settings.lastTrackerSyncAt = Date()
        engineSettings = settings
        trackerSyncRetryAfter = nil

        if engineController.isRunning {
            let sessionID = engineSessionID
            // Tracker sync joins the same writer as settings edits. A second
            // changeGlobalOption request could otherwise overwrite newer edits.
            if let pending = engineSettingsTask { await pending.value }
            else { await applyRuntimeEngineOptions() }
            guard engineSessionID == sessionID, !isShuttingDown, !Task.isCancelled else { return }
            if let issue = engineSettingsIssue {
                report(issue, title: String(localized: "Apply Trackers Failed"))
                return
            }
        }
        if result.failures.isEmpty {
            trackerSyncFeedback = .succeeded
            postActivity(automatic ? String(localized: "Trackers auto-synced.") : String(localized: "Trackers synced."))
        } else {
            report(trackerFailureMessage(result.failures, successCount: result.data.count, totalCount: sources.count),
                title: String(localized: "Tracker Sync Partially Failed"))
        }
    }

    func applyTrackersToRunningTasks(_ text: String, using client: Aria2RPCClient) async throws {
        let additional = TrackerText.trackers(from: text)
        let sessionID = engineSessionID
        let active = try await client.activeTorrentTasks()
        var failures: [String] = []
        var changed = false
        for task in active {
            try Task.checkCancellation()
            guard sessionID == engineSessionID, engineController.isRunning, !isShuttingDown else { throw CancellationError() }
            do {
                // Read at dispatch, not from a possibly stale list snapshot. Unknown
                // metadata is protected exactly like a private torrent.
                let snapshot = try await client.tellStatus(task.id).task
                guard snapshot.status == .active, snapshot.privateTorrent == false else { continue }
                let current = try await client.torrentTrackerStatus(task.id)
                let ownership = tasks.first { $0.id == task.id }?.publicTrackerOwnership
                let plan = PublicTrackerPolicy.replacement(current: current, selected: additional, previous: ownership, infoHash: snapshot.infoHash)
                if plan.trackers != TorrentTrackerAddress.merging(current, additional: []) {
                    try Task.checkCancellation()
                    guard sessionID == engineSessionID, engineController.isRunning else { throw CancellationError() }
                    try await client.replaceTorrentTrackers(task.id, trackers: plan.trackers)
                    changed = true
                }
                guard sessionID == engineSessionID, engineController.isRunning else { throw CancellationError() }
                if let index = tasks.firstIndex(where: { $0.id == task.id && $0.infoHash == snapshot.infoHash }) {
                    tasks[index].publicTrackerOwnership = plan.ownership
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // A torrent can finish, pause or disappear between the snapshot and
                // replacement. Never resume it just to apply a tracker update.
                let failure = error
                guard sessionID == engineSessionID, !isShuttingDown else { throw CancellationError() }
                guard case RPCError.serverError = error else { throw error }
                do {
                    let latest = try await client.tellStatus(task.id)
                    if latest.task.status != .active { continue }
                } catch where isTaskAlreadyAbsent(error) { continue }
                catch { /* Preserve the original actionable failure below. */ }
                failures.append("\(task.id): \(DownloadPrivacy.redact(failure.localizedDescription))")
            }
        }
        try Task.checkCancellation()
        guard sessionID == engineSessionID, engineController.isRunning else { throw CancellationError() }
        if changed { try await client.saveSession() }
        persistTaskHistory()
        if !failures.isEmpty {
            throw DownloadOperationError(String(localized: "Could not update trackers for \(failures.count) running torrents.\n\(failures.joined(separator: "\n"))"))
        }
    }

    private func trackerFailureMessage(
        _ failures: [TrackerSourceFetchFailure],
        successCount: Int,
        totalCount: Int
    ) -> String {
        var lines: [String] = []
        if successCount > 0 {
            lines.append(String(localized: "Synced \(successCount) of \(totalCount) tracker sources."))
        }
        if failures.isEmpty {
            lines.append(String(localized: "No trackers were returned."))
        } else {
            lines.append(String(localized: "Failed sources:"))
            lines.append(
                contentsOf: failures.prefix(6).map { String(localized: "\($0.url): \($0.reason)") }
            )
            if failures.count > 6 {
                lines.append(String(localized: "\(failures.count - 6) more failed sources."))
            }
        }
        return lines.joined(separator: "\n")
    }

    func refreshED2KBootstrapStatus() {
        ed2kBootstrapStatus = ED2KBootstrapCache.status(applicationSupportBase: ed2kBootstrapApplicationSupportBase)
    }

    func syncED2KBootstrapManually() async {
        await syncED2KBootstrap(startup: false, reportFailures: true)
    }

    private func syncED2KBootstrapIfDue(startup: Bool) async {
        guard shouldSyncED2KBootstrap(startup: startup) else { return }
        await syncED2KBootstrap(startup: startup, reportFailures: false)
    }

    private func shouldSyncED2KBootstrap(startup: Bool, now: Date = Date()) -> Bool {
        guard engineSettings.ed2kBootstrapAutoSync else { return false }
        let intervalHours = max(0, engineSettings.ed2kBootstrapSyncIntervalHours)
        if intervalHours == 0 {
            return startup
        }
        guard let lastSyncAt = engineSettings.lastED2KBootstrapSyncAt else {
            return true
        }
        return now.timeIntervalSince(lastSyncAt) >= Double(intervalHours * 3_600)
    }

    private func syncED2KBootstrap(startup: Bool, reportFailures: Bool) async {
        guard !isSyncingED2KBootstrap else { return }
        bootstrapSyncFeedback = .idle
        guard ED2KBootstrapURLValidator.isValid(engineSettings.ed2kServerMetURL),
              ED2KBootstrapURLValidator.isValid(engineSettings.ed2kNodesDatURL) else {
            if reportFailures {
                postError(String(localized: "ED2K bootstrap URLs must use HTTP or HTTPS."), title: String(localized: "ED2K Bootstrap Failed"))
            }
            return
        }

        isSyncingED2KBootstrap = true
        bootstrapSyncFeedback = .working
        defer {
            isSyncingED2KBootstrap = false
            if bootstrapSyncFeedback == .working { bootstrapSyncFeedback = .idle }
        }

        do {
            let result = try await ed2kBootstrapFetcher.fetch(
                serverMetURL: engineSettings.ed2kServerMetURL,
                nodesDatURL: engineSettings.ed2kNodesDatURL,
                proxyURL: engineSettings.proxyURL
            )
            guard !Task.isCancelled, !isShuttingDown else { return }
            let status = try ED2KBootstrapCache.write(result, applicationSupportBase: ed2kBootstrapApplicationSupportBase)
            ed2kBootstrapStatus = status
            var settings = engineSettings
            settings.lastED2KBootstrapSyncAt = Date()
            engineSettings = settings
            bootstrapSyncFeedback = .succeeded
            postActivity(startup ? String(localized: "ED2K bootstrap auto-synced.") : String(localized: "ED2K bootstrap files synced."))
        } catch {
            updateRuntime(lastError: error.localizedDescription)
            if reportFailures {
                postError(error, title: String(localized: "ED2K Bootstrap Failed"))
            }
        }
    }

    func startOrCancelED2KSearch() async {
        if isSearchingED2K {
            await cancelED2KSearch()
        } else {
            await startED2KSearch()
        }
    }

    func startED2KSearch() async {
        guard engineCapabilities?.supports(.ed2k) != false else {
            postError(String(localized: "The running engine does not support ED2K."), title: String(localized: "ED2K Search Unavailable"))
            return
        }
        guard !isSearchingED2K else { return }
        guard engineController.isRunning else {
            postError(String(localized: "The engine is unavailable. Open Engine settings to retry the connection."), title: String(localized: "ED2K Search Failed"))
            return
        }
        let keyword = ed2kSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            postError(String(localized: "Enter an ED2K search keyword."), title: String(localized: "ED2K Search Failed"))
            return
        }
        let context = ed2kDownloadContext()
        guard context.hasBootstrapOrServer else {
            postError(
                String(localized: "Sync ED2K bootstrap files or add ED2K servers before searching."),
                title: String(localized: "ED2K Search Failed")
            )
            return
        }

        ed2kSearchTask?.cancel()
        ed2kSearchResults = []
        ed2kSearchElapsedSeconds = 0
        isSearchingED2K = true
        clearActivityMessage()

        let fileType = ed2kSearchFileType
        let minSources = max(1, ed2kSearchMinSources)
        let timeoutSeconds = min(600, max(10, engineSettings.ed2kSearchTimeoutSeconds))

        ed2kSearchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let searchDirectory: URL
            do {
                searchDirectory = try ED2KSearchTempCache.createDirectory()
            } catch {
                isSearchingED2K = false
                postError(error, title: String(localized: "ED2K Search Failed"))
                return
            }

            do {
                let client = try engineController.client()
                let gid = try await client.ed2kSearch(
                    keyword: keyword,
                    options: ED2KSearchOptions(fileType: fileType, minSourceCount: minSources),
                    directory: searchDirectory.path,
                    context: context
                )
                ed2kSearchSession = ED2KSearchSession(gid: gid, temporaryDirectory: searchDirectory)
                let results = try await pollED2KSearchResults(gid: gid, client: client, timeoutSeconds: timeoutSeconds)
                ed2kSearchResults = results
                if results.isEmpty {
                    postActivity(String(localized: "ED2K search completed with no results."))
                } else {
                    postActivity(String(localized: "ED2K search completed with \(results.count) results."))
                }
                do {
                    try await client.cleanupED2KSearch(gid)
                } catch {
                    updateRuntime(lastError: error.localizedDescription)
                }
            } catch is CancellationError {
                if let session = ed2kSearchSession, let client = try? engineController.client() {
                    try? await client.cleanupED2KSearch(session.gid)
                }
            } catch {
                postError(error, title: String(localized: "ED2K Search Failed"))
            }
            ED2KSearchTempCache.cleanup(ed2kSearchSession?.temporaryDirectory ?? searchDirectory)
            ed2kSearchSession = nil
            isSearchingED2K = false
            ed2kSearchTask = nil
        }
    }

    func cancelED2KSearch() async {
        ed2kSearchTask?.cancel()
        ed2kSearchTask = nil
        if let session = ed2kSearchSession, let client = try? engineController.client() {
            try? await client.cleanupED2KSearch(session.gid)
            ED2KSearchTempCache.cleanup(session.temporaryDirectory)
        }
        ed2kSearchSession = nil
        isSearchingED2K = false
        postActivity(ed2kSearchResults.isEmpty ? String(localized: "ED2K search cancelled.") : String(localized: "ED2K search cancelled with \(ed2kSearchResults.count) results."))
    }

    func downloadED2KSearchResult(_ result: ED2KSearchResult) async {
        guard let link = result.ed2kLink?.trimmingCharacters(in: .whitespacesAndNewlines),
              !link.isEmpty else {
            postError(String(localized: "The selected ED2K result does not include a download link."), title: String(localized: "ED2K Download Failed"))
            return
        }
        guard engineController.isRunning else {
            postError(String(localized: "The engine is unavailable. Open Engine settings to retry the connection."), title: String(localized: "ED2K Download Failed"))
            return
        }
        let context = ed2kDownloadContext()
        guard context.hasBootstrapOrServer else {
            postError(
                String(localized: "Sync ED2K bootstrap files or add ED2K servers before adding ED2K downloads."),
                title: String(localized: "ED2K Download Failed")
            )
            return
        }

        do {
            var draft = defaultAddDraft()
            draft.rawInput = link
            draft.outputName = result.displayName
            let client = try engineController.client()
            let gid = try await client.addDownload(
                draft,
                fallbackDirectory: engineSettings.downloadDirectoryPath,
                autoOrganize: preferences.autoOrganizeFiles,
                ed2kContext: context
            )
            rememberSubmittedTasks([gid], draft: draft)
            selectedDestination = .ed2k
            selectedTaskID = gid
            let saveError = await saveSessionAfterTaskMutation(using: client)
            _ = await refreshTasks(reportErrors: false)
            if let saveError {
                postError(saveError, title: String(localized: "Save Session Failed"))
            } else {
                postActivity(String(localized: "ED2K download started."))
            }
        } catch {
            postError(error, title: String(localized: "ED2K Download Failed"))
        }
    }

    private func pollED2KSearchResults(
        gid: String,
        client: Aria2RPCClient,
        timeoutSeconds: Int
    ) async throws -> [ED2KSearchResult] {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        var latestResults: [ED2KSearchResult] = []

        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            ed2kSearchElapsedSeconds = min(timeoutSeconds, ed2kSearchElapsedSeconds + 1)
            let payload = try await client.getED2KSearchResults(gid)
            latestResults = payload.results ?? []
            ed2kSearchResults = latestResults
            if payload.moreResults == false {
                break
            }
        }

        return latestResults
    }

    func ed2kDownloadContext() -> ED2KDownloadContext {
        ED2KDownloadContext(
            bootstrapPaths: ED2KBootstrapCache.cachedPathsIfAvailable(applicationSupportBase: ed2kBootstrapApplicationSupportBase),
            serverList: ED2KServerText.commaSeparated(from: engineSettings.ed2kServer)
        )
    }

    private func waitForBitTorrentFiles(
        metadataGID: String,
        source: String,
        client: Aria2RPCClient,
        requestID: UUID
    ) async throws -> BitTorrentFileSelectionSession {
        while true {
            try Task.checkCancellation()
            guard isCurrentBitTorrentSelection(requestID) else { throw CancellationError() }
            let metadata = try await client.tellStatus(metadataGID)
            let contentID = metadata.firstFollowedDownloadID
            let gid = contentID ?? metadataGID
            let snapshot = contentID == nil ? metadata : try await client.tellStatus(gid)
            guard isCurrentBitTorrentSelection(requestID) else { throw CancellationError() }
            updateBitTorrentSelectionSession {
                $0.downloadTaskID = contentID
                $0.diagnostics = snapshot.task.torrentDiagnostics
                $0.isQueued = snapshot.task.status == .waiting
                $0.isPaused = snapshot.task.status == .paused
            }
            if snapshot.task.status == .failed || snapshot.task.status == .removed {
                throw DownloadOperationError(snapshot.task.errorMessage ?? String(localized: "The engine could not retrieve this torrent. Check the source or open a local torrent file."))
            }
            // Aria2 Next resolves magnets on the SAME GID. fileSelectionState=awaiting
            // is authoritative; followedBy is only needed for fetched torrent documents.
            let resolved = TorrentFileTree.isResolved(snapshot, source: source, followed: contentID != nil)
            if resolved {
                let files = TorrentFileTree.contentFiles(snapshot.task.files.isEmpty
                    ? try await client.getFiles(gid) : snapshot.task.files)
                if !files.isEmpty {
                    if snapshot.task.status == .active || snapshot.task.status == .waiting {
                        try await client.forcePause(gid)
                    }
                    guard isCurrentBitTorrentSelection(requestID), var session = bitTorrentSelectionSession else { throw CancellationError() }
                    session.downloadTaskID = gid
                    session.taskName = snapshot.task.name
                    session.destination = snapshot.task.destination
                    if contentID != nil { session.metadataFilePath = metadata.task.files.first?.path }
                    session.files = files
                    session.selectedFileIndexes = Set(files.map(\.index))
                    session.phase = .ready
                    return session
                }
            }
            if bitTorrentDiscoveryRetryRequested {
                bitTorrentDiscoveryRetryRequested = false
                try await reconnectBitTorrentDiscovery(gid: gid, source: source, followed: contentID != nil,
                    client: client, requestID: requestID)
            }
            // Long waits show a stage-specific explanation and an explicit reconnect
            // action while continuing to watch the original, metadata-only task.
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func reconnectBitTorrentDiscovery(gid: String, source: String, followed: Bool,
                                               client: Aria2RPCClient, requestID: UUID) async throws {
        defer {
            if bitTorrentSelectionRequestID == requestID { isRetryingBitTorrentDiscovery = false }
        }
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard isCurrentBitTorrentSelection(requestID) else { throw CancellationError() }
        }
        try checkCurrent()
        let snapshot = try await client.tellStatus(gid)
        try checkCurrent()
        // Metadata may arrive while the user presses Retry. Never resume a task
        // that is already waiting for file selection, or bypass its queue position.
        if TorrentFileTree.isResolved(snapshot, source: source, followed: followed) || snapshot.task.status == .waiting { return }
        if snapshot.task.status == .active {
            // Keep existing metadata connections and the pause-metadata selection gate.
            do {
                try await client.announceTorrent(gid)
            } catch {
                try checkCurrent()
                // Metadata can complete and pause the handle between tellStatus
                // and announce. A ready file-selection sheet is still success.
                let latest = try await client.tellStatus(gid)
                try checkCurrent()
                if TorrentFileTree.isResolved(latest, source: source, followed: followed) { return }
                throw error
            }
        } else if snapshot.task.status == .paused {
            try await client.changeOption(gid: gid, options: ["pause-metadata": "true"])
            try checkCurrent()
            try await client.resume(gid)
        } else {
            throw DownloadOperationError(snapshot.task.errorMessage ?? String(localized: "The engine could not retrieve this torrent. Check the source or open a local torrent file."))
        }
        try checkCurrent()
        updateBitTorrentSelectionSession {
            $0.startedAt = Date(); $0.discovery = nil; $0.isPaused = false
        }
        _ = await saveSessionAfterTaskMutation(using: client)
    }

    private func isCurrentBitTorrentSelection(_ requestID: UUID) -> Bool {
        !isShuttingDown && bitTorrentSelectionRequestID == requestID && bitTorrentSelectionSession != nil
    }

    private func updateBitTorrentSelectionSession(_ transform: (inout BitTorrentFileSelectionSession) -> Void) {
        guard var session = bitTorrentSelectionSession else { return }
        transform(&session)
        bitTorrentSelectionSession = session
    }

    private func cleanupBitTorrentSelection(_ session: BitTorrentFileSelectionSession, using client: Aria2RPCClient?) async {
        guard session.removesTaskOnCancel else { return }
        defer { TorrentStorage.removeEmptyDirectory(session.torrentDirectory) }
        var gids = [session.downloadTaskID, session.metadataTaskID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // A fetched .torrent can create a child between the last poll and cancellation.
        if let client, let metadataID = session.metadataTaskID,
           let snapshot = try? await client.tellStatus(metadataID) {
            gids.append(contentsOf: snapshot.followedBy)
        }
        do { try hideHistory(Set(gids)) }
        catch { historyIssue = DownloadPrivacy.redact(error.localizedDescription) }
        guard let client else { return }
        var seen = Set<String>()

        for gid in gids where seen.insert(gid).inserted {
            do {
                try await client.forceRemove(gid)
            } catch where isTaskAlreadyAbsent(error) {
                continue
            } catch {
                updateRuntime(lastError: error.localizedDescription)
            }
        }

        seen.removeAll()
        for gid in gids where seen.insert(gid).inserted {
            do {
                try await client.removeDownloadResult(gid)
            } catch where isTaskAlreadyAbsent(error) {
                continue
            } catch {
                updateRuntime(lastError: error.localizedDescription)
            }
        }
        _ = await saveSessionAfterTaskMutation(using: client)
    }

    func isTaskAlreadyAbsent(_ error: Error) -> Bool {
        guard case RPCError.serverError(_, let message) = error else { return false }
        let lowered = message.lowercased()
        return lowered.contains("active download not found") ||
            lowered.contains("download result not found") ||
            (lowered.contains("gid") && lowered.contains("not found"))
    }

    private func waitForEngineRPC(port: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var lastError: Error?

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let exitStatus = engineController.clearTerminatedProcess() {
                throw EngineError.processExited(exitStatus, String(localized: "Aria2 Next exited before RPC became available."))
            }
            guard engineController.hasLaunchedProcess else {
                throw CancellationError()
            }

            do {
                let client = try engineController.client()
                _ = try await client.globalStat()
                return
            } catch {
                try Task.checkCancellation()
                lastError = error
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }

        if let exitStatus = engineController.clearTerminatedProcess() {
            throw EngineError.processExited(exitStatus, String(localized: "Aria2 Next exited before RPC became available."))
        }

        throw EngineError.rpcUnavailableAfterLaunch(
            port: port,
            reason: lastError?.localizedDescription ?? String(localized: "RPC port did not open before timeout.")
        )
    }

    func postActivity(_ message: String) {
        if activityMessage != message {
            activityMessage = message
        }
    }

    func postError(_ error: Error, title: String) {
        postError(error.localizedDescription, title: title)
    }

    func postError(_ message: String, title: String) {
        clearActivityMessage()
        userAlerts.send(UserFacingAlert(title: title, message: DownloadPrivacy.redact(message)))
    }

    func applyDetectedSystemProxy() {
        guard let proxy = SystemProxyDetector.detect() else {
            postError(String(localized: "No enabled HTTP or HTTPS system proxy was found."), title: String(localized: "System Proxy Not Found"))
            return
        }

        guard !proxy.isSocks else {
            postError(
                String(localized: "The enabled system proxy is SOCKS. Aria2 Next accepts HTTP proxy URLs here, so set an HTTP proxy manually."),
                title: String(localized: "Unsupported System Proxy")
            )
            return
        }

        var settings = engineSettings
        settings.proxyURL = proxy.server
        settings.proxyBypass = proxy.bypass
        engineSettings = settings
        postActivity(proxy.bypass.isEmpty ? String(localized: "System proxy applied.") : String(localized: "System proxy and bypass list applied."))
    }

    func publishStartupAlerts() {
        guard !pendingStartupAlerts.isEmpty else { return }
        let alerts = pendingStartupAlerts
        pendingStartupAlerts.removeAll()
        for alert in alerts {
            userAlerts.send(alert)
        }
    }

    func claimAlert(_ alert: UserFacingAlert) -> Bool {
        guard !claimedAlertIDs.contains(alert.id) else { return false }
        claimedAlertIDs.insert(alert.id)
        if claimedAlertIDs.count > 100 {
            claimedAlertIDs.removeAll(keepingCapacity: true)
            claimedAlertIDs.insert(alert.id)
        }
        return true
    }

    private func clearActivityMessage() {
        if activityMessage != nil {
            activityMessage = nil
        }
    }

    private func updatePowerAssertion() {
        let hasActiveDownloads = engineController.isRunning && tasks.contains { $0.status == .active }
        do {
            try powerAssertionController.update(
                preventSleep: preferences.preventSleepDuringActiveDownloads,
                hasActiveDownloads: hasActiveDownloads
            )
            if !preferences.preventSleepDuringActiveDownloads ||
                !hasActiveDownloads ||
                powerAssertionController.isAcquired {
                didReportPowerAssertionFailure = false
            }
        } catch {
            guard !didReportPowerAssertionFailure else { return }
            didReportPowerAssertionFailure = true
            sendDeferredAlert(
                UserFacingAlert(
                    title: String(localized: "Prevent Sleep Failed"),
                    message: error.localizedDescription
                )
            )
        }
    }

    func defaultAddDraft() -> AddDownloadDraft {
        AddDownloadDraft(defaults: engineSettings)
    }

    private func persistEngineSettings() {
        var failures: [String] = []
        if let settingsStore {
            do {
                try settingsStore.saveEngineSettings(engineSettings)
            } catch {
                failures.append(error.localizedDescription)
            }
        } else {
            failures.append(String(localized: "Persistent settings storage is unavailable."))
        }

        guard !failures.isEmpty else { return }
        sendDeferredAlert(
            UserFacingAlert(
                title: String(localized: "Engine Settings Save Failed"),
                message: failures.joined(separator: "\n")
            )
        )
    }

    private func persistAppPreferences() {
        guard let settingsStore else {
            sendDeferredAlert(
                UserFacingAlert(
                    title: String(localized: "App Settings Save Failed"),
                    message: String(localized: "Persistent settings storage is unavailable.")
                )
            )
            return
        }

        do {
            try settingsStore.saveAppPreferences(preferences)
        } catch {
            sendDeferredAlert(
                UserFacingAlert(
                    title: String(localized: "App Settings Save Failed"),
                    message: error.localizedDescription
                )
            )
        }
    }

    private func sendDeferredAlert(_ alert: UserFacingAlert) {
        Task { @MainActor [weak self] in
            self?.userAlerts.send(alert)
        }
    }

    private func seedUITestFixtures() {
        // Model an installed, stopped engine. Imported links wait for setup to
        // finish; fixture-only UI tests deliberately never launch the engine.
        engineSetupState = .ready
        selectedDestination = .all
        tasks = [
            DownloadTask(
                id: "active-fixture",
                name: "Ubuntu.iso",
                protocolKind: .bitTorrent,
                status: .active,
                totalLength: 4_294_967_296,
                completedLength: 1_073_741_824,
                downloadSpeed: 524_288,
                uploadSpeed: 0,
                connections: 8,
                destination: "/Users/conight/Downloads",
                addedAt: Date(),
                errorMessage: nil,
                files: [],
                peers: [],
                trackers: [
                    TrackerEntry(url: "udp://tracker.opentrackr.org:1337/announce", status: "Announced", lastAnnounce: nil),
                    TrackerEntry(url: "udp://tracker.opentrackr.org:1337/announce", status: "Announced", lastAnnounce: nil)
                ],
                recentLogs: []
            ),
            DownloadTask(
                id: "waiting-fixture",
                name: "Queue.mov",
                protocolKind: .http,
                status: .waiting,
                totalLength: 104_857_600,
                completedLength: 0,
                downloadSpeed: 0,
                uploadSpeed: 0,
                connections: 0,
                destination: "/Users/conight/Downloads",
                addedAt: Date(),
                errorMessage: nil,
                files: [],
                peers: [],
                trackers: [],
                recentLogs: []
            ),
            DownloadTask(
                id: "paused-fixture",
                name: "Paused.zip",
                protocolKind: .http,
                status: .paused,
                totalLength: 209_715_200,
                completedLength: 104_857_600,
                downloadSpeed: 0,
                uploadSpeed: 0,
                connections: 0,
                destination: "/Users/conight/Downloads",
                addedAt: Date(),
                errorMessage: nil,
                files: [],
                peers: [],
                trackers: [],
                recentLogs: []
            ),
            DownloadTask(
                id: "completed-fixture",
                name: "Finished.dmg",
                protocolKind: .http,
                status: .completed,
                totalLength: 52_428_800,
                completedLength: 52_428_800,
                downloadSpeed: 0,
                uploadSpeed: 0,
                connections: 0,
                destination: "/Users/conight/Downloads",
                addedAt: Date(),
                errorMessage: nil,
                files: [],
                peers: [],
                trackers: [],
                recentLogs: []
            )
        ]
        speedSamples = [
            SpeedSample(timestamp: Date(), downloadBytesPerSecond: 524_288, uploadBytesPerSecond: 0)
        ]
    }
}
