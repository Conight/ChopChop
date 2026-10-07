import Foundation
import Combine
import IOKit.pwr_mgt
import Security

struct UserFacingAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

struct DownloadRemovalRequest: Identifiable, Equatable {
    let id = UUID()
    var task: DownloadTask
}

private struct ED2KSearchSession {
    var gid: String
    var temporaryDirectory: URL
}

nonisolated enum PowerAssertionError: LocalizedError, Sendable {
    case acquisitionFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .acquisitionFailed(let result):
            "Could not prevent idle sleep. IOKit returned \(result)."
        }
    }
}

nonisolated protocol PowerAssertionControlling: AnyObject {
    var isAcquired: Bool { get }
    func update(preventSleep: Bool, hasActiveDownloads: Bool) throws
    func release()
}

nonisolated final class DownloadPowerAssertionController: PowerAssertionControlling {
    private var assertionID = IOPMAssertionID(0)
    private(set) var isAcquired = false

    func update(preventSleep: Bool, hasActiveDownloads: Bool) throws {
        guard preventSleep && hasActiveDownloads else {
            release()
            return
        }
        try acquireIfNeeded()
    }

    func release() {
        guard isAcquired else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isAcquired = false
    }

    deinit {
        release()
    }

    private func acquireIfNeeded() throws {
        guard !isAcquired else { return }
        var newAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Active ChopChop downloads" as CFString,
            &newAssertionID
        )
        guard result == kIOReturnSuccess else {
            throw PowerAssertionError.acquisitionFailed(result)
        }
        assertionID = newAssertionID
        isAcquired = true
    }
}

@MainActor
final class DownloadStore: ObservableObject {
    @Published var engineSettings: EngineSettings {
        didSet { persistEngineSettings() }
    }
    @Published var preferences: AppPreferences {
        didSet {
            persistAppPreferences()
            updatePowerAssertion()
        }
    }
    @Published var runtime = EngineRuntimeSnapshot()
    @Published private(set) var engineSetupState: EngineSetupState = .unchecked
    @Published private(set) var installedEngine: EngineInstallation?
    @Published private(set) var engineUpdateStatus = "Checks automatically at launch"
    @Published private(set) var availableEngineUpdate: EngineRelease?
    @Published private(set) var engineSettingsRequested = false
    @Published private(set) var isCheckingEngineUpdate = false
    @Published private(set) var engineUpgradeProgress: EngineInstallationProgress?
    @Published private(set) var engineUpgradeError: String?
    @Published private(set) var engineUpgradeResult: String?
    private var engineUpgradeTask: Task<Void, Never>?
    private let engineInstallationManager: any EngineInstallationManaging
    private var startupTask: Task<Void, Never>?
    private var engineUpdateTask: Task<Void, Never>?
    private var engineInstallTask: Task<Void, Never>?
    private var engineMaintenanceTask: Task<Void, Never>?
    @Published var tasks: [DownloadTask] = [] {
        didSet { updatePowerAssertion() }
    }
    @Published var speedSamples: [SpeedSample] = []
    @Published var selectedDestination: SidebarDestination = .today
    @Published var selectedTaskID: DownloadTask.ID?
    @Published var searchQuery = ""
    @Published var addDraft = AddDownloadDraft()
    @Published var isSyncingTrackers = false
    @Published var isSyncingED2KBootstrap = false
    @Published var ed2kBootstrapStatus = ED2KBootstrapStatus()
    @Published var ed2kSearchKeyword = ""
    @Published var ed2kSearchFileType: ED2KSearchFileType = .any
    @Published var ed2kSearchMinSources = 1
    @Published var isSearchingED2K = false
    @Published var ed2kSearchElapsedSeconds = 0
    @Published var ed2kSearchResults: [ED2KSearchResult] = []
    @Published var isResolvingBitTorrentFiles = false
    @Published var activityMessage: String?
    @Published var removalRequest: DownloadRemovalRequest?
    @Published var bitTorrentSelectionSession: BitTorrentFileSelectionSession?
    let addPanelRequests = PassthroughSubject<Void, Never>()
    let userAlerts = PassthroughSubject<UserFacingAlert, Never>()

    private let settingsStore: PersistentSettingsStore?
    private let engineController: any Aria2EngineControlling
    private let trackerFetcher: any BitTorrentTrackerSourceFetching
    private let ed2kBootstrapFetcher: any ED2KBootstrapFetching
    private let ed2kBootstrapApplicationSupportBase: URL?
    private let powerAssertionController: any PowerAssertionControlling
    private var pollTask: Task<Void, Never>?
    private var ed2kSearchTask: Task<Void, Never>?
    private var claimedAlertIDs: Set<UUID> = []
    private var pendingStartupAlerts: [UserFacingAlert] = []
    private var didAttemptLaunchStartup = false
    private var bitTorrentSelectionRequestID: UUID?
    private var didReportPowerAssertionFailure = false
    private var ed2kSearchSession: ED2KSearchSession?
    private var engineSessionID = UUID()
    private var isShuttingDown = false

    init(
        settingsStore: PersistentSettingsStore? = nil,
        engineController: (any Aria2EngineControlling)? = nil,
        trackerFetcher: (any BitTorrentTrackerSourceFetching)? = nil,
        ed2kBootstrapFetcher: (any ED2KBootstrapFetching)? = nil,
        ed2kBootstrapApplicationSupportBase: URL? = nil,
        powerAssertionController: (any PowerAssertionControlling)? = nil,
        engineInstallationManager: (any EngineInstallationManaging)? = nil
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
                    title: "Settings Store Failed",
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
                        title: "Engine Settings Load Failed",
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
                        title: "App Settings Load Failed",
                        message: error.localizedDescription
                    )
                )
                loadedPreferences = AppPreferences()
            }
        } else {
            loadedPreferences = AppPreferences()
        }

        self.engineInstallationManager = engineInstallationManager ?? EngineInstallationManager()
        self.settingsStore = resolvedSettingsStore
        self.engineController = engineController ?? Aria2NextEngineController()
        self.trackerFetcher = trackerFetcher ?? URLSessionBitTorrentTrackerSourceFetcher()
        self.ed2kBootstrapFetcher = ed2kBootstrapFetcher ?? URLSessionED2KBootstrapFetcher()
        self.ed2kBootstrapApplicationSupportBase = ed2kBootstrapApplicationSupportBase
        self.powerAssertionController = powerAssertionController ?? DownloadPowerAssertionController()
        self.engineSettings = loadedSettings
        self.preferences = loadedPreferences
        self.addDraft = defaultAddDraft()
        self.ed2kBootstrapStatus = ED2KBootstrapCache.status(applicationSupportBase: ed2kBootstrapApplicationSupportBase)
        self.pendingStartupAlerts = startupAlerts
        if AppLaunchConfiguration.usesUITestFixtures {
            seedUITestFixtures()
        }
    }

    deinit {
        startupTask?.cancel()
        engineUpdateTask?.cancel()
        engineInstallTask?.cancel()
        engineUpgradeTask?.cancel()
        engineMaintenanceTask?.cancel()
        pollTask?.cancel()
        ed2kSearchTask?.cancel()
    }

    func shutdown() {
        isShuttingDown = true
        startupTask?.cancel()
        engineUpdateTask?.cancel()
        engineInstallTask?.cancel()
        engineUpgradeTask?.cancel()
        engineMaintenanceTask?.cancel()
        engineSessionID = UUID()
        pollTask?.cancel()
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
        startEngineUpdateCheck()
        await startEngine(startupSync: true)
    }

    var engineVersionDescription: String {
        if let installedEngine { return installedEngine.version.description }
        return "Unavailable"
    }

    var engineSidebarVersionDescription: String {
        guard let release = availableEngineUpdate else { return engineVersionDescription }
        return "\(engineVersionDescription) → \(release.version)"
    }

    func requestEngineSettings() { engineSettingsRequested = true }

    func consumeEngineSettingsRequest() -> Bool {
        guard engineSettingsRequested else { return false }
        engineSettingsRequested = false
        return true
    }

    var isUpdatingEngine: Bool { engineUpgradeProgress != nil }

    var canUpdateEngine: Bool {
        !isShuttingDown && !isUpdatingEngine && !isCheckingEngineUpdate && !isEngineTransitioning
            && installedEngine != nil && availableEngineUpdate != nil
            && !isSearchingED2K && !isResolvingBitTorrentFiles && bitTorrentSelectionSession == nil
    }

    func updateEngine() {
        guard canUpdateEngine, let release = availableEngineUpdate, let previous = installedEngine else { return }
        engineUpgradeError = nil
        engineUpgradeResult = nil
        engineUpgradeProgress = .init(stage: .connecting)
        engineUpgradeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.engineUpgradeProgress = nil; self.engineUpgradeTask = nil }
            let wasRunning = self.engineController.isRunning
            var switchingEngine = false
            var backup: EngineRuntimeBackup?
            do {
                let installation = try await self.engineInstallationManager.install(release) { [weak self] stage in
                    await self?.updateEngineUpgradeProgress(stage)
                }
                try Task.checkCancellation()
                guard !self.isShuttingDown else { throw CancellationError() }
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
                if wasRunning {
                    self.engineUpgradeProgress = .init(stage: .restarting)
                    await self.launchEngine(showAlerts: false)
                    try Task.checkCancellation()
                    guard case .running = self.runtime.phase else {
                        throw EngineError.executableLaunchFailed(path: installation.executableURL.path, reason: self.runtime.lastError ?? "The updated engine did not start.")
                    }
                }
                self.engineUpgradeProgress = .init(stage: .activating)
                try await self.engineInstallationManager.activate(installation)
                self.useEngine(installation)
                self.engineUpdateStatus = "Up to date (\(installation.version))"
                self.engineUpgradeResult = "Aria2 Next \(installation.version) is installed."
                await backup?.discard()
            } catch {
                let failure = error.localizedDescription
                let failedStage = self.engineUpgradeProgress?.title.replacingOccurrences(of: "…", with: "") ?? "Updating engine"
                if switchingEngine {
                    self.suspendEngineMonitoring()
                    do {
                        if self.engineController.isRunning { self.runtime = try await self.engineController.stop() }
                        self.engineController.selectInstallation(previous)
                        try await backup?.restore()
                        self.runtime = EngineRuntimeSnapshot(phase: .stopped)
                        if wasRunning && !self.isShuttingDown && !Task.isCancelled {
                            self.engineUpgradeProgress = .init(stage: .restoring)
                            await self.launchEngine(showAlerts: false)
                        }
                        await backup?.discard()
                    } catch {
                        self.engineUpgradeError = "Update failed: \(failure) Recovery failed: \(error.localizedDescription)"
                        self.updatePowerAssertion()
                        return
                    }
                }
                guard !self.isShuttingDown else { return }
                if Task.isCancelled {
                    self.engineUpgradeResult = "Update canceled. Aria2 Next \(previous.version) is still installed."
                    return
                }
                self.engineUpgradeError = "\(failedStage): \(failure)\nVersion \(previous.version) is still installed. You can retry the update."
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
        engineSessionID = UUID()
        engineMaintenanceTask?.cancel()
        pollTask?.cancel()
        pollTask = nil
    }

    private func useEngine(_ installation: EngineInstallation) {
        installedEngine = installation
        if let update = availableEngineUpdate, update.version <= installation.version {
            availableEngineUpdate = nil
        }
        engineController.selectInstallation(installation)
        engineSetupState = .ready
        if engineSettings.rpcToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            generateRPCToken()
        }
        if engineSettings.downloadDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            engineSettings.downloadDirectoryPath = EngineSettings().downloadDirectoryPath
        }
    }

    func startEngineUpdateCheck() {
        guard engineUpdateTask == nil, let installedEngine, !isShuttingDown, !isUpdatingEngine else { return }
        // UI automation uses a local engine without contacting GitHub.
        guard !AppLaunchConfiguration.isUITesting else { return }
        isCheckingEngineUpdate = true
        engineUpdateStatus = "Checking for updates…"
        engineUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.engineUpdateTask = nil; self.isCheckingEngineUpdate = false }
            do {
                let release = try await self.engineInstallationManager.latestRelease()
                guard !self.isShuttingDown, !Task.isCancelled else { return }
                if release.version > installedEngine.version {
                    self.engineUpdateStatus = "Version \(release.version) available"
                    self.availableEngineUpdate = release
                } else {
                    self.engineUpdateStatus = "Up to date (\(installedEngine.version))"
                    self.availableEngineUpdate = nil
                }
            } catch {
                guard !self.isShuttingDown, !Task.isCancelled else { return }
                self.engineUpdateStatus = "Could not check for updates. Try again later."
            }
        }
    }

    func installRequiredEngine() {
        guard engineSetupState.requiresInstallation, !engineSetupState.isInstalling, !isShuttingDown else { return }
        engineSetupState = .installing(.init(stage: .checkingRelease))
        engineInstallTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.engineInstallTask = nil }
            do {
                let release = try await self.engineInstallationManager.latestRelease()
                let installation = try await self.engineInstallationManager.install(release) { [weak self] stage in
                    await self?.updateEngineInstallationProgress(stage)
                }
                guard !self.isShuttingDown, !Task.isCancelled else { return }
                self.engineSetupState = .installing(.init(stage: .activating))
                try await self.engineInstallationManager.activate(installation)
                self.useEngine(installation)
                self.engineUpdateStatus = "Up to date (\(installation.version))"
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

    var selectedTask: DownloadTask? {
        guard let selectedTaskID else { return nil }
        return tasks.first { $0.id == selectedTaskID }
    }

    var visibleTasks: [DownloadTask] {
        visibleTasks(for: selectedDestination)
    }

    func visibleTasks(for destination: SidebarDestination) -> [DownloadTask] {
        var filtered = tasks
        switch destination {
        case .today:
            filtered = filtered.filter { Calendar.current.isDateInToday($0.addedAt) || $0.status == .active || $0.status == .waiting }
        case .all:
            break
        case .active:
            filtered = filtered.filter { $0.status == .active }
        case .waiting:
            filtered = filtered.filter { $0.status == .waiting || $0.status == .paused }
        case .completed:
            filtered = filtered.filter { $0.status == .completed }
        case .failed:
            filtered = filtered.filter { $0.status == .failed }
        case .torrents:
            filtered = filtered.filter { $0.protocolKind == .bitTorrent || $0.protocolKind == .magnet }
        case .ed2k:
            filtered = filtered.filter { $0.protocolKind == .ed2k }
        case .browserCapture:
            filtered = []
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return filtered }
        return filtered.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.destination.localizedCaseInsensitiveContains(query)
        }
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
        switch destination {
        case .today:
            tasks.filter { Calendar.current.isDateInToday($0.addedAt) || $0.status == .active || $0.status == .waiting }.count
        case .all:
            tasks.count
        case .active:
            tasks.filter { $0.status == .active }.count
        case .waiting:
            tasks.filter { $0.status == .waiting || $0.status == .paused }.count
        case .completed:
            tasks.filter { $0.status == .completed }.count
        case .failed:
            tasks.filter { $0.status == .failed }.count
        case .torrents:
            tasks.filter { $0.protocolKind == .bitTorrent || $0.protocolKind == .magnet }.count
        case .ed2k:
            tasks.filter { $0.protocolKind == .ed2k }.count
        case .browserCapture:
            0
        }
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
            postActivity("Download directory set.")
        } catch {
            postError(error, title: "Download Folder Failed")
        }
    }

    func generateRPCToken() {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            postError("Could not generate a secure RPC token.", title: "RPC Token Failed")
            return
        }
        engineSettings.rpcToken = bytes.map { String(format: "%02x", $0) }.joined()
        postActivity("Generated a new RPC token. Restart the engine if it is running.")
    }

    @discardableResult
    func addCustomTrackerSource(_ rawValue: String) -> Bool {
        let url = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            postError("Enter a tracker source URL.", title: "Tracker Source Failed")
            return false
        }
        guard TrackerSourceURLValidator.isValid(url) else {
            postError("Enter a valid HTTP or HTTPS tracker source URL.", title: "Tracker Source Failed")
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
            postActivity("Tracker source already exists.")
            return false
        }

        engineSettings = settings
        postActivity("Tracker source added.")
        return true
    }

    func removeCustomTrackerSource(_ url: String) {
        var settings = engineSettings
        settings.customTrackerSourceURLs.removeAll { $0 == url }
        settings.trackerSourceURLs.removeAll { $0 == url }
        engineSettings = settings
        postActivity("Tracker source removed.")
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
        await syncBitTorrentTrackers(startup: false, reportFailures: true)
    }

    func requestAddPanel() {
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

    private func launchEngine(startupSync: Bool = false, showAlerts: Bool = true) async {
        guard !isShuttingDown else { return }
        clearActivityMessage()
        do {
            try engineSettings.validateLaunchRequirements()
        } catch {
            runtime = EngineRuntimeSnapshot(phase: .failed(error.localizedDescription), lastError: error.localizedDescription)
            if showAlerts { postError(error, title: "Start Engine Failed") }
            return
        }

        // The controller validates port availability immediately before launching.
        // Keeping that check there also lets injected controllers stay independent of live engines.
        let sessionID = UUID()
        engineSessionID = sessionID
        var launchArguments: [String] = []
        runtime = EngineRuntimeSnapshot(
            phase: .starting,
            lastLaunchArguments: runtime.lastLaunchArguments,
            lastError: nil
        )
        do {
            try Task.checkCancellation()
            guard engineSessionID == sessionID else { return }
            let launchSettings = engineSettings
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
            runtime = launchSnapshot
            if showAlerts, let backup = launchSnapshot.sessionBackupURL {
                userAlerts.send(UserFacingAlert(
                    title: "Download Engine Updated",
                    message: "Your previous task list was backed up before updating the engine. Unfinished downloads from older versions may restart from zero; existing partial files are preserved.\n\nBackup: \(backup.path)"
                ))
            }
            await refreshTasks(reportErrors: showAlerts)
            guard engineSessionID == sessionID, engineController.isRunning else { return }
            startPolling()
            engineMaintenanceTask?.cancel()
            engineMaintenanceTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.syncBitTorrentTrackersIfDue(startup: startupSync)
                guard !Task.isCancelled, self.engineSessionID == sessionID else { return }
                await self.syncED2KBootstrapIfDue(startup: startupSync)
            }
        } catch is CancellationError {
            guard engineSessionID == sessionID else { return }
            pollTask?.cancel()
            pollTask = nil
            if engineController.isRunning { _ = try? await engineController.stop() }
            engineController.terminateForAppExit()
            runtime = EngineRuntimeSnapshot(phase: .stopped, lastLaunchArguments: launchArguments)
            updatePowerAssertion()
        } catch {
            guard engineSessionID == sessionID else { return }
            pollTask?.cancel()
            pollTask = nil
            if engineController.isRunning { _ = try? await engineController.stop() }
            engineController.terminateForAppExit()
            runtime = EngineRuntimeSnapshot(
                phase: .failed(error.localizedDescription),
                lastLaunchArguments: launchArguments,
                lastError: error.localizedDescription
            )
            updatePowerAssertion()
            if showAlerts { postError(error, title: "Start Engine Failed") }
        }
    }

    func stopEngine() async {
        guard canStopEngine else {
            postError(EngineError.notRunning, title: "Stop Engine Failed")
            return
        }
        engineSessionID = UUID()
        engineMaintenanceTask?.cancel()
        clearActivityMessage()
        do {
            pollTask?.cancel()
            pollTask = nil
            runtime = EngineRuntimeSnapshot(
                phase: .stopping,
                lastLaunchArguments: runtime.lastLaunchArguments,
                lastError: runtime.lastError
            )
            runtime = try await engineController.stop()
            updatePowerAssertion()
        } catch {
            runtime = EngineRuntimeSnapshot(
                phase: .failed(error.localizedDescription),
                lastLaunchArguments: runtime.lastLaunchArguments,
                lastError: error.localizedDescription
            )
            updatePowerAssertion()
            postError(error, title: "Stop Engine Failed")
        }
    }

    func prepareForAppTermination() async {
        isShuttingDown = true
        startupTask?.cancel()
        engineUpdateTask?.cancel()
        engineInstallTask?.cancel()
        engineUpgradeTask?.cancel()
        await engineUpgradeTask?.value
        engineMaintenanceTask?.cancel()
        engineSessionID = UUID()
        pollTask?.cancel()
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
            postError(error, title: "Restart Engine Failed")
            return
        }
        if engineController.isRunning {
            await stopEngine()
            guard !engineController.isRunning else { return }
        }
        await startEngine()
    }

    @discardableResult
    func refreshTasks(reportErrors: Bool = true) async -> Error? {
        let sessionID = engineSessionID
        guard !Task.isCancelled, !isShuttingDown else { return nil }
        if let exitStatus = engineController.clearTerminatedProcess() {
            let error = EngineError.processExited(exitStatus, "Aria2 Next stopped unexpectedly.")
            pollTask?.cancel()
            pollTask = nil
            runtime = EngineRuntimeSnapshot(
                phase: .failed(error.localizedDescription),
                lastLaunchArguments: runtime.lastLaunchArguments,
                lastError: error.localizedDescription
            )
            updatePowerAssertion()
            if reportErrors {
                postError(error, title: "Engine Stopped")
            }
            return error
        }
        guard engineController.isRunning else { return nil }
        do {
            let client = try engineController.client()
            async let taskSnapshot = client.pollTasks()
            async let globalStat = client.globalStat()
            let (polledTasks, stat) = try await (taskSnapshot, globalStat)
            guard !Task.isCancelled, engineSessionID == sessionID, engineController.isRunning else { return nil }
            tasks = mergePolledTasks(polledTasks)
            recordSpeed(download: stat.downloadBytesPerSecond, upload: stat.uploadBytesPerSecond)
            return nil
        } catch {
            guard !Task.isCancelled, engineSessionID == sessionID else { return nil }
            if let exitStatus = engineController.clearTerminatedProcess() {
                let exitError = EngineError.processExited(exitStatus, "Aria2 Next stopped unexpectedly.")
                pollTask?.cancel()
                pollTask = nil
                runtime = EngineRuntimeSnapshot(
                    phase: .failed(exitError.localizedDescription),
                    lastLaunchArguments: runtime.lastLaunchArguments,
                    lastError: exitError.localizedDescription
                )
                updatePowerAssertion()
                if reportErrors {
                    postError(exitError, title: "Engine Stopped")
                }
                return exitError
            }
            guard engineController.isRunning else { return nil }
            updateRuntime(lastError: error.localizedDescription)
            if reportErrors {
                postError(error, title: "Refresh Failed")
            }
            return error
        }
    }

    @discardableResult
    func submitDraft() async -> Bool {
        guard addDraft.isSubmittable else {
            postError("Enter a valid HTTP, FTP, Magnet, ED2K, torrent, or metalink URL.", title: "Invalid Download")
            return false
        }
        guard engineController.isRunning else {
            postError("Start Aria2 Next before adding downloads.", title: "Engine Not Running")
            return false
        }
        if addDraft.containsBitTorrentResource, !addDraft.shouldResolveBitTorrentFilesBeforeSubmit {
            postError(DownloadDraftError.bitTorrentSelectionRequiresSingleResource, title: "Add Download Failed")
            return false
        }
        if addDraft.shouldResolveBitTorrentFilesBeforeSubmit {
            await prepareBitTorrentFileSelection()
            return false
        }
        if addDraft.resourceLines.contains(where: { AddDownloadDraft.detectProtocol(for: $0) == .ed2k }),
           !ed2kDownloadContext().hasBootstrapOrServer {
            postError(
                "Sync ED2K bootstrap files or add ED2K servers in Settings before adding ED2K downloads.",
                title: "Add Download Failed"
            )
            return false
        }
        do {
            let client = try engineController.client()
            let gids = try await client.addDownloads(
                addDraft,
                fallbackDirectory: engineSettings.downloadDirectoryPath,
                autoOrganize: preferences.autoOrganizeFiles,
                ed2kContext: ed2kDownloadContext()
            )
            selectedTaskID = gids.first
            addDraft = defaultAddDraft()
            let refreshError = await refreshTasks(reportErrors: false)
            let saveError = await saveSessionAfterTaskMutation(using: client)
            if let refreshError {
                postError(refreshError, title: "Refresh Failed")
            } else if let saveError {
                postError(saveError, title: "Save Session Failed")
            } else {
                postActivity("Added \(gids.count) download \(gids.count == 1 ? "task" : "tasks").")
            }
            return true
        } catch {
            postError(error, title: "Add Download Failed")
            return false
        }
    }

    func prepareBitTorrentFileSelection() async {
        guard !isResolvingBitTorrentFiles else { return }
        guard addDraft.isSubmittable else {
            postError("Enter a valid Magnet or torrent link.", title: "Invalid Download")
            return
        }
        guard addDraft.shouldResolveBitTorrentFilesBeforeSubmit else {
            postError(DownloadDraftError.bitTorrentSelectionRequiresSingleResource, title: "Add Download Failed")
            return
        }

        let source = addDraft.resourceLines.first ?? ""
        let requestID = UUID()
        bitTorrentSelectionRequestID = requestID
        isResolvingBitTorrentFiles = true
        clearActivityMessage()
        bitTorrentSelectionSession = BitTorrentFileSelectionSession(
            source: source,
            metadataTaskID: nil,
            downloadTaskID: nil,
            taskName: "Loading torrent metadata",
            files: [],
            selectedFileIndexes: [],
            phase: .loading
        )
        defer { isResolvingBitTorrentFiles = false }

        do {
            let client = try engineController.client()
            let metadataGID = try await client.addBitTorrentMetadataDownload(
                addDraft,
                fallbackDirectory: engineSettings.downloadDirectoryPath,
                autoOrganize: preferences.autoOrganizeFiles
            )
            updateBitTorrentSelectionSession { session in
                session.metadataTaskID = metadataGID
            }
            guard isCurrentBitTorrentSelection(requestID) else {
                await cleanupBitTorrentSelection(
                    BitTorrentFileSelectionSession(
                        source: source,
                        metadataTaskID: metadataGID,
                        downloadTaskID: nil,
                        taskName: "Loading torrent metadata",
                        files: [],
                        selectedFileIndexes: [],
                        phase: .loading
                    ),
                    using: client
                )
                return
            }

            let prepared = try await waitForBitTorrentFiles(
                metadataGID: metadataGID,
                source: source,
                client: client,
                requestID: requestID
            )
            guard isCurrentBitTorrentSelection(requestID) else {
                await cleanupBitTorrentSelection(prepared, using: client)
                return
            }
            bitTorrentSelectionSession = prepared
            selectedTaskID = prepared.downloadTaskID
            _ = await refreshTasks(reportErrors: false)
        } catch {
            guard isCurrentBitTorrentSelection(requestID) else { return }
            let staleSession = bitTorrentSelectionSession
            bitTorrentSelectionRequestID = nil
            bitTorrentSelectionSession = nil
            if let staleSession {
                await cleanupBitTorrentSelection(staleSession, using: try? engineController.client())
            }
            postError(error, title: "Load Torrent Files Failed")
        }
    }

    @discardableResult
    func confirmBitTorrentFileSelection() async -> Bool {
        guard let session = bitTorrentSelectionSession,
              session.phase == .ready,
              let downloadTaskID = session.downloadTaskID else {
            postError("Torrent files are not ready yet.", title: "Start Download Failed")
            return false
        }
        guard session.hasSelection else {
            postError("Select at least one file to download.", title: "Start Download Failed")
            return false
        }

        do {
            let client = try engineController.client()
            let snapshot = try await client.tellStatus(downloadTaskID)
            switch snapshot.task.status {
            case .active, .waiting:
                try await client.forcePause(downloadTaskID)
            case .paused:
                break
            case .completed, .failed, .removed:
                throw DownloadTaskOperationError.bitTorrentContentNotSelectable(status: snapshot.task.status.rawValue)
            }

            try await client.changeOption(gid: downloadTaskID, options: ["select-file": session.selectFileOption])
            try await client.resume(downloadTaskID)
            if let metadataTaskID = session.metadataTaskID, metadataTaskID != downloadTaskID {
                do {
                    try await client.removeDownloadResult(metadataTaskID)
                } catch where isTaskAlreadyAbsent(error) {
                    // Aria2 may already have discarded the metadata GID after following the content task.
                }
            }

            bitTorrentSelectionRequestID = nil
            bitTorrentSelectionSession = nil
            addDraft = defaultAddDraft()
            let refreshError = await refreshTasks(reportErrors: false)
            let saveError = await saveSessionAfterTaskMutation(using: client)
            if let refreshError {
                postError(refreshError, title: "Refresh Failed")
                return false
            }
            if let saveError {
                postError(saveError, title: "Save Session Failed")
                return false
            }
            postActivity("Started selected torrent files.")
            return true
        } catch {
            postError(error, title: "Start Download Failed")
            return false
        }
    }

    func cancelBitTorrentFileSelection() async {
        guard let session = bitTorrentSelectionSession else { return }
        bitTorrentSelectionRequestID = nil
        bitTorrentSelectionSession = nil
        await cleanupBitTorrentSelection(session, using: try? engineController.client())
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

    func setAllBitTorrentFilesSelected(_ isSelected: Bool) {
        guard var session = bitTorrentSelectionSession else { return }
        session.selectedFileIndexes = isSelected ? Set(session.files.map(\.index)) : []
        bitTorrentSelectionSession = session
    }

    func refreshDetails(for taskID: DownloadTask.ID) async {
        guard engineController.isRunning else { return }
        guard let task = tasks.first(where: { $0.id == taskID }), task.isTorrentLike else { return }

        do {
            let client = try engineController.client()
            let peers = try await client.getPeers(taskID)
            guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            tasks[index].peers = peers
        } catch where isTaskAlreadyAbsent(error) {
            return
        } catch {
            updateRuntime(lastError: error.localizedDescription)
        }
    }

    func pause(_ task: DownloadTask) async {
        guard task.primaryControlAction == .pause else {
            postError("This task cannot be paused in its current state.", title: "Pause Failed")
            return
        }
        await performTaskMutation(alertTitle: "Pause Failed") { client in
            try await DownloadTaskRPCOperations.pause(task, using: client)
        }
    }

    func resume(_ task: DownloadTask) async {
        guard task.primaryControlAction == .resume else {
            postError("This task cannot be resumed in its current state.", title: "Resume Failed")
            return
        }
        await performTaskMutation(alertTitle: "Resume Failed") { client in
            try await DownloadTaskRPCOperations.resume(task, using: client)
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
        await remove(request.task, includingFiles: includingFiles)
    }

    func cancelRemoval(_ request: DownloadRemovalRequest? = nil) {
        guard request == nil || removalRequest?.id == request?.id else { return }
        removalRequest = nil
    }

    func remove(_ task: DownloadTask, includingFiles: Bool = false) async {
        await performTaskMutation(alertTitle: "Remove Failed") { client in
            if includingFiles, task.removalAction == .removeDownloadResult {
                try DownloadTaskFileTrash.moveTaskFilesToTrash(task)
            }
            try await DownloadTaskRPCOperations.remove(task, using: client)
            if includingFiles, task.removalAction == .removeActiveDownload {
                try DownloadTaskFileTrash.moveTaskFilesToTrash(task)
            }
            selectedTaskID = nil
            tasks.removeAll { $0.id == task.id }
        }
    }

    func pauseAll() async {
        await performTaskMutation(alertTitle: "Pause All Failed") { client in
            let pausedCount = try await DownloadTaskRPCOperations.pauseAll(tasks, using: client)
            if pausedCount == 0 {
                postActivity("No active or waiting downloads to pause.")
            }
        }
    }

    func resumeAll() async {
        await performTaskMutation(alertTitle: "Resume All Failed") { client in
            try await client.unpauseAll()
        }
    }

    func forcePauseAll() async {
        await performTaskMutation(alertTitle: "Force Pause All Failed") { client in
            try await client.forcePauseAll()
        }
    }

    func purgeCompletedRecords() async {
        await performTaskMutation(alertTitle: "Clear Records Failed") { client in
            try await client.purgeDownloadResult()
            selectedTaskID = nil
            tasks.removeAll { $0.removalAction == .removeDownloadResult }
            postActivity("Cleared completed, failed, and removed records.")
        }
    }

    func applyRuntimeEngineOptions() async {
        guard !isUpdatingEngine else { return }
        guard engineController.isRunning else {
            postError("Start Aria2 Next before applying runtime options.", title: "Apply Settings Failed")
            return
        }
        do {
            let options = engineSettings.hotReloadableEngineOptions(downloadDirectoryPath: engineSettings.downloadDirectoryPath)
            try await engineController.client().changeGlobalOption(options)
            postActivity("Runtime settings applied. Restart Aria2 Next for RPC, BT, ED2K, DHT, peer, encryption, or bootstrap changes.")
        } catch {
            postError(error, title: "Apply Settings Failed")
        }
    }

    private func syncBitTorrentTrackersIfDue(startup: Bool) async {
        guard shouldSyncBitTorrentTrackers(startup: startup) else { return }
        await syncBitTorrentTrackers(startup: startup, reportFailures: false)
    }

    private func shouldSyncBitTorrentTrackers(startup: Bool, now: Date = Date()) -> Bool {
        guard engineSettings.btTrackerAutoSync else { return false }
        guard !engineSettings.trackerSourceURLs.isEmpty else { return false }

        let intervalHours = max(0, engineSettings.btTrackerSyncIntervalHours)
        if intervalHours == 0 {
            return startup
        }

        guard let lastTrackerSyncAt = engineSettings.lastTrackerSyncAt else {
            return true
        }
        return now.timeIntervalSince(lastTrackerSyncAt) >= Double(intervalHours * 3_600)
    }

    private func syncBitTorrentTrackers(startup: Bool, reportFailures: Bool) async {
        guard !isSyncingTrackers else { return }
        let sources = engineSettings.trackerSourceURLs
        guard !sources.isEmpty else {
            if reportFailures {
                postError("Select at least one tracker source.", title: "Tracker Sync Failed")
            }
            return
        }

        isSyncingTrackers = true
        defer { isSyncingTrackers = false }

        let result = await trackerFetcher.fetchTrackerSources(sources)
        guard !Task.isCancelled, !isShuttingDown else { return }
        let trackerText = TrackerText.lineSeparated(fromChunks: result.data)
        guard !trackerText.isEmpty else {
            if reportFailures {
                postError(trackerFailureMessage(result.failures, successCount: 0, totalCount: sources.count), title: "Tracker Sync Failed")
            }
            return
        }

        var settings = engineSettings
        settings.btTracker = trackerText
        settings.lastTrackerSyncAt = Date()
        engineSettings = settings

        if engineController.isRunning {
            do {
                try await engineController.client().changeGlobalOption([
                    "bt-tracker": TrackerText.reducedCommaSeparated(from: trackerText)
                ])
            } catch {
                updateRuntime(lastError: error.localizedDescription)
                if reportFailures {
                    postError(error, title: "Apply Trackers Failed")
                    return
                }
            }
        }

        let successCount = result.data.count
        if result.failures.isEmpty {
            postActivity(startup ? "Trackers auto-synced." : "Trackers synced.")
        } else if reportFailures {
            postError(
                trackerFailureMessage(result.failures, successCount: successCount, totalCount: sources.count),
                title: "Tracker Sync Partially Failed"
            )
        }
    }

    private func trackerFailureMessage(
        _ failures: [TrackerSourceFetchFailure],
        successCount: Int,
        totalCount: Int
    ) -> String {
        var lines: [String] = []
        if successCount > 0 {
            lines.append("Synced \(successCount) of \(totalCount) tracker sources.")
        }
        if failures.isEmpty {
            lines.append("No trackers were returned.")
        } else {
            lines.append("Failed sources:")
            lines.append(
                contentsOf: failures.prefix(6).map { "\($0.url): \($0.reason)" }
            )
            if failures.count > 6 {
                lines.append("\(failures.count - 6) more failed sources.")
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
        guard ED2KBootstrapURLValidator.isValid(engineSettings.ed2kServerMetURL),
              ED2KBootstrapURLValidator.isValid(engineSettings.ed2kNodesDatURL) else {
            if reportFailures {
                postError("ED2K bootstrap URLs must use HTTP or HTTPS.", title: "ED2K Bootstrap Failed")
            }
            return
        }

        isSyncingED2KBootstrap = true
        defer { isSyncingED2KBootstrap = false }

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
            postActivity(startup ? "ED2K bootstrap auto-synced." : "ED2K bootstrap files synced.")
        } catch {
            updateRuntime(lastError: error.localizedDescription)
            if reportFailures {
                postError(error, title: "ED2K Bootstrap Failed")
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
        guard !isSearchingED2K else { return }
        guard engineController.isRunning else {
            postError("Start Aria2 Next before searching ED2K.", title: "ED2K Search Failed")
            return
        }
        let keyword = ed2kSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            postError("Enter an ED2K search keyword.", title: "ED2K Search Failed")
            return
        }
        let context = ed2kDownloadContext()
        guard context.hasBootstrapOrServer else {
            postError(
                "Sync ED2K bootstrap files or add ED2K servers before searching.",
                title: "ED2K Search Failed"
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
                postError(error, title: "ED2K Search Failed")
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
                    postActivity("ED2K search completed with no results.")
                } else {
                    postActivity("ED2K search completed with \(results.count) result\(results.count == 1 ? "" : "s").")
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
                postError(error, title: "ED2K Search Failed")
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
        postActivity(ed2kSearchResults.isEmpty ? "ED2K search cancelled." : "ED2K search cancelled with \(ed2kSearchResults.count) result\(ed2kSearchResults.count == 1 ? "" : "s").")
    }

    func downloadED2KSearchResult(_ result: ED2KSearchResult) async {
        guard let link = result.ed2kLink?.trimmingCharacters(in: .whitespacesAndNewlines),
              !link.isEmpty else {
            postError("The selected ED2K result does not include a download link.", title: "ED2K Download Failed")
            return
        }
        guard engineController.isRunning else {
            postError("Start Aria2 Next before adding downloads.", title: "ED2K Download Failed")
            return
        }
        let context = ed2kDownloadContext()
        guard context.hasBootstrapOrServer else {
            postError(
                "Sync ED2K bootstrap files or add ED2K servers before adding ED2K downloads.",
                title: "ED2K Download Failed"
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
            selectedDestination = .ed2k
            selectedTaskID = gid
            let refreshError = await refreshTasks(reportErrors: false)
            let saveError = await saveSessionAfterTaskMutation(using: client)
            if let refreshError {
                postError(refreshError, title: "Refresh Failed")
            } else if let saveError {
                postError(saveError, title: "Save Session Failed")
            } else {
                postActivity("ED2K download started.")
            }
        } catch {
            postError(error, title: "ED2K Download Failed")
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

    private func ed2kDownloadContext() -> ED2KDownloadContext {
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
        let deadline = Date().addingTimeInterval(90)
        var lastError: Error?
        let canUseMetadataTaskDirectly = AddDownloadDraft.localTorrentFileURL(source) != nil

        while Date() < deadline {
            try Task.checkCancellation()
            guard isCurrentBitTorrentSelection(requestID) else {
                throw CancellationError()
            }
            do {
                let metadataSnapshot = try await client.tellStatus(metadataGID)
                let followedDownloadID = metadataSnapshot.firstFollowedDownloadID
                let downloadGID = followedDownloadID ?? metadataGID
                let downloadSnapshot = downloadGID == metadataGID ? metadataSnapshot : try await client.tellStatus(downloadGID)
                let files = usableBitTorrentContentFiles(try await client.getFiles(downloadGID))
                let isResolvedContentTask = followedDownloadID != nil || canUseMetadataTaskDirectly

                if isResolvedContentTask && !files.isEmpty {
                    return BitTorrentFileSelectionSession(
                        source: source,
                        metadataTaskID: metadataGID,
                        downloadTaskID: downloadGID,
                        taskName: downloadSnapshot.task.name,
                        files: files,
                        selectedFileIndexes: Set(files.map(\.index)),
                        phase: .ready
                    )
                }
            } catch {
                lastError = error
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        throw DownloadTaskOperationError.bitTorrentMetadataTimedOut(
            reason: lastError?.localizedDescription ?? "Aria2 did not expose torrent files before the timeout."
        )
    }

    private func usableBitTorrentContentFiles(_ files: [DownloadFile]) -> [DownloadFile] {
        files.filter { file in
            file.length > 0 && !isBitTorrentMetadataPlaceholder(file)
        }
    }

    private func isBitTorrentMetadataPlaceholder(_ file: DownloadFile) -> Bool {
        let trimmedPath = file.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return false }
        if trimmedPath.hasPrefix("[METADATA]") {
            return true
        }
        return URL(fileURLWithPath: trimmedPath).lastPathComponent.hasPrefix("[METADATA]")
    }

    private func isCurrentBitTorrentSelection(_ requestID: UUID) -> Bool {
        bitTorrentSelectionRequestID == requestID && bitTorrentSelectionSession != nil
    }

    private func mergePolledTasks(_ polledTasks: [DownloadTask]) -> [DownloadTask] {
        let existingTasks = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return polledTasks.map { polled in
            guard let existing = existingTasks[polled.id] else { return polled }
            var merged = polled
            merged.addedAt = existing.addedAt
            if merged.peers.isEmpty {
                merged.peers = existing.peers
            }
            if merged.trackers.isEmpty {
                merged.trackers = existing.trackers
            }
            return merged
        }.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status.sortOrder < rhs.status.sortOrder
            }
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
            return lhs.id < rhs.id
        }
    }

    private func updateBitTorrentSelectionSession(_ transform: (inout BitTorrentFileSelectionSession) -> Void) {
        guard var session = bitTorrentSelectionSession else { return }
        transform(&session)
        bitTorrentSelectionSession = session
    }

    private func cleanupBitTorrentSelection(_ session: BitTorrentFileSelectionSession, using client: Aria2RPCClient?) async {
        guard let client else { return }
        let gids = [session.downloadTaskID, session.metadataTaskID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
    }

    private func isTaskAlreadyAbsent(_ error: Error) -> Bool {
        guard case RPCError.serverError(_, let message) = error else { return false }
        let lowered = message.lowercased()
        return lowered.contains("active download not found") ||
            lowered.contains("download result not found") ||
            (lowered.contains("gid") && lowered.contains("not found"))
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    break
                }
                guard let self else { break }
                await self.refreshTasks()
            }
        }
    }

    private func waitForEngineRPC(port: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var lastError: Error?

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let exitStatus = engineController.clearTerminatedProcess() {
                throw EngineError.processExited(exitStatus, "Aria2 Next exited before RPC became available.")
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
            throw EngineError.processExited(exitStatus, "Aria2 Next exited before RPC became available.")
        }

        throw EngineError.rpcUnavailableAfterLaunch(
            port: port,
            reason: lastError?.localizedDescription ?? "RPC port did not open before timeout."
        )
    }

    private func recordSpeed(download: Int64, upload: Int64) {
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

    private func updateRuntime(lastError: String?) {
        runtime = EngineRuntimeSnapshot(
            phase: runtime.phase,
            lastLaunchArguments: runtime.lastLaunchArguments,
            lastError: lastError
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
        userAlerts.send(UserFacingAlert(title: title, message: message))
    }

    func applyDetectedSystemProxy() {
        guard let proxy = SystemProxyDetector.detect() else {
            postError("No enabled HTTP or HTTPS system proxy was found.", title: "System Proxy Not Found")
            return
        }

        guard !proxy.isSocks else {
            postError(
                "The enabled system proxy is SOCKS. Aria2 Next accepts HTTP proxy URLs here, so set an HTTP proxy manually.",
                title: "Unsupported System Proxy"
            )
            return
        }

        var settings = engineSettings
        settings.proxyURL = proxy.server
        settings.proxyBypass = proxy.bypass
        engineSettings = settings
        postActivity(proxy.bypass.isEmpty ? "System proxy applied." : "System proxy and bypass list applied.")
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
                    title: "Prevent Sleep Failed",
                    message: error.localizedDescription
                )
            )
        }
    }

    private func performTaskMutation(
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

        let operationError: Error?
        do {
            try await operation(client)
            operationError = nil
        } catch {
            operationError = error
        }

        let refreshError = await refreshTasks(reportErrors: false)
        let saveError = await saveSessionAfterTaskMutation(using: client)

        if let operationError {
            postError(operationError, title: alertTitle)
        } else if let refreshError {
            postError(refreshError, title: "Refresh Failed")
        } else if let saveError {
            postError(saveError, title: "Save Session Failed")
        }
    }

    private func saveSessionAfterTaskMutation(using client: Aria2RPCClient) async -> Error? {
        do {
            try await client.saveSession()
            return nil
        } catch {
            updateRuntime(lastError: error.localizedDescription)
            return error
        }
    }

    private func defaultAddDraft() -> AddDownloadDraft {
        var draft = AddDownloadDraft()
        draft.savePath = engineSettings.downloadDirectoryPath ?? ""
        draft.splitCount = engineSettings.splitCount
        draft.userAgent = engineSettings.userAgent
        draft.proxyURL = engineSettings.proxyURL
        return draft
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
            failures.append("Persistent settings storage is unavailable.")
        }

        guard !failures.isEmpty else { return }
        sendDeferredAlert(
            UserFacingAlert(
                title: "Engine Settings Save Failed",
                message: failures.joined(separator: "\n")
            )
        )
    }

    private func persistAppPreferences() {
        guard let settingsStore else {
            sendDeferredAlert(
                UserFacingAlert(
                    title: "App Settings Save Failed",
                    message: "Persistent settings storage is unavailable."
                )
            )
            return
        }

        do {
            try settingsStore.saveAppPreferences(preferences)
        } catch {
            sendDeferredAlert(
                UserFacingAlert(
                    title: "App Settings Save Failed",
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

nonisolated struct DownloadTaskTrashPlan: Equatable, Sendable {
    var primaryTargets: [URL]
    var companionTargets: [URL]
}

nonisolated enum DownloadTaskFileTrash {
    static func plan(for task: DownloadTask, fileManager: FileManager = .default) -> DownloadTaskTrashPlan {
        let destinationURL = task.destination.trimmedForEngine.isEmpty
            ? nil
            : URL(fileURLWithPath: task.destination).standardizedFileURL
        let reportedURLs = uniqueURLs(
            task.files
                .map(\.path)
                .filter(DownloadTaskTrashPath.isReportedUserContentPath)
                .map { URL(fileURLWithPath: $0).standardizedFileURL }
                .filter { url in
                    guard url.path != "/" else { return false }
                    guard let destinationURL else { return true }
                    return url.path != destinationURL.path
                }
        )
        let primaryTargets = primaryTargets(
            for: reportedURLs,
            destinationURL: destinationURL,
            fileManager: fileManager
        )
        let companionTargets = companionTargets(for: primaryTargets, task: task, destinationURL: destinationURL)
        return DownloadTaskTrashPlan(primaryTargets: primaryTargets, companionTargets: companionTargets)
    }

    static func moveTaskFilesToTrash(_ task: DownloadTask, fileManager: FileManager = .default) throws {
        let plan = plan(for: task, fileManager: fileManager)
        guard !plan.primaryTargets.isEmpty else {
            throw DownloadFileTrashError.noReportedFiles(taskName: task.name)
        }

        var movedPrimaryCount = 0
        var failures: [DownloadFileTrashError] = []
        for target in plan.primaryTargets {
            guard fileManager.fileExists(atPath: target.path) else { continue }
            do {
                try fileManager.trashItem(at: target, resultingItemURL: nil)
                movedPrimaryCount += 1
            } catch {
                failures.append(
                    .moveToTrashFailed(path: target.path, reason: error.localizedDescription)
                )
            }
        }

        if let failure = failures.first {
            throw failure
        }
        guard movedPrimaryCount > 0 else {
            throw DownloadFileTrashError.noExistingReportedFiles(
                paths: plan.primaryTargets.map(\.path)
            )
        }

        for companion in plan.companionTargets where fileManager.fileExists(atPath: companion.path) {
            try? fileManager.trashItem(at: companion, resultingItemURL: nil)
        }
    }

    private static func primaryTargets(
        for reportedURLs: [URL],
        destinationURL: URL?,
        fileManager: FileManager
    ) -> [URL] {
        guard reportedURLs.count > 1, let destinationURL else {
            return reportedURLs
        }
        let firstChildren = reportedURLs.compactMap {
            firstChildURL(of: $0, under: destinationURL)
        }
        guard firstChildren.count == reportedURLs.count,
              let commonChild = firstChildren.first,
              firstChildren.allSatisfy({ $0.path == commonChild.path }) else {
            return reportedURLs
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: commonChild.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return [commonChild]
        }
        return reportedURLs
    }

    private static func firstChildURL(of url: URL, under destinationURL: URL) -> URL? {
        let destinationPath = destinationURL.path.hasSuffix("/")
            ? destinationURL.path
            : destinationURL.path + "/"
        guard url.path.hasPrefix(destinationPath) else { return nil }
        let suffix = String(url.path.dropFirst(destinationPath.count))
        guard let childName = suffix.split(separator: "/", maxSplits: 1).first,
              !childName.isEmpty else { return nil }
        return destinationURL.appendingPathComponent(String(childName)).standardizedFileURL
    }

    private static func companionTargets(
        for primaryTargets: [URL],
        task: DownloadTask,
        destinationURL: URL?
    ) -> [URL] {
        var companions = primaryTargets.map {
            URL(fileURLWithPath: $0.path + ".aria2").standardizedFileURL
        }
        if let destinationURL,
           let infoHash = task.infoHash?.trimmedForEngine,
           !infoHash.isEmpty {
            companions.append(
                destinationURL
                    .appendingPathComponent(infoHash + ".aria2")
                    .standardizedFileURL
            )
        }
        return uniqueURLs(companions)
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []
        for url in urls where seen.insert(url.path).inserted {
            unique.append(url)
        }
        return unique
    }
}

nonisolated enum DownloadFileTrashError: LocalizedError, Equatable, Sendable {
    case noReportedFiles(taskName: String)
    case noExistingReportedFiles(paths: [String])
    case moveToTrashFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .noReportedFiles(let taskName):
            "Aria2 Next did not report any file paths for \(taskName), so ChopChop cannot move files to Trash safely."
        case .noExistingReportedFiles(let paths):
            "None of the reported downloaded files exist on disk:\n\(paths.joined(separator: "\n"))"
        case .moveToTrashFailed(let path, let reason):
            "Could not move \(path) to Trash.\n\(reason)"
        }
    }
}

nonisolated enum DownloadTaskRPCOperations {
    static func pause(_ task: DownloadTask, using client: Aria2RPCClient) async throws {
        do {
            if task.isTorrentLike {
                try await client.forcePause(task.id)
            } else {
                try await client.pause(task.id)
            }
        } catch where isTaskAlreadyAbsent(error) {
            return
        }
    }

    static func resume(_ task: DownloadTask, using client: Aria2RPCClient) async throws {
        do {
            try await client.resume(task.id)
        } catch where isTaskAlreadyAbsent(error) {
            return
        }
    }

    static func remove(_ task: DownloadTask, using client: Aria2RPCClient) async throws {
        switch task.removalAction {
        case .removeActiveDownload:
            do {
                try await client.forceRemove(task.id)
            } catch where isTaskAlreadyAbsent(error) {
                try await removeDownloadResultIfPresent(task.id, using: client)
                return
            }
            await removeDownloadResultBestEffort(task.id, using: client)
        case .removeDownloadResult:
            try await removeDownloadResultIfPresent(task.id, using: client)
        }
    }

    static func pauseAll(_ tasks: [DownloadTask], using client: Aria2RPCClient) async throws -> Int {
        let pausableTasks = tasks.filter { $0.primaryControlAction == .pause && !$0.isSharing }
        var failedMessages: [String] = []

        for task in pausableTasks {
            do {
                try await client.forcePause(task.id)
            } catch where isTaskAlreadyAbsent(error) {
                continue
            } catch {
                failedMessages.append(error.localizedDescription)
            }
        }

        if let firstFailure = failedMessages.first {
            throw DownloadTaskOperationError.batchPauseFailed(
                failedCount: failedMessages.count,
                totalCount: pausableTasks.count,
                firstFailure: firstFailure
            )
        }
        return pausableTasks.count
    }

    private static func removeDownloadResultIfPresent(_ gid: String, using client: Aria2RPCClient) async throws {
        do {
            try await client.removeDownloadResult(gid)
        } catch where isTaskAlreadyAbsent(error) {
            return
        }
    }

    private static func removeDownloadResultBestEffort(_ gid: String, using client: Aria2RPCClient) async {
        do {
            try await client.removeDownloadResult(gid)
        } catch {
            return
        }
    }

    private static func isTaskAlreadyAbsent(_ error: Error) -> Bool {
        guard case RPCError.serverError(_, let message) = error else { return false }
        let lowered = message.lowercased()
        return lowered.contains("active download not found") ||
            lowered.contains("download result not found") ||
            (lowered.contains("gid") && lowered.contains("not found"))
    }
}

nonisolated enum DownloadTaskOperationError: LocalizedError, Equatable, Sendable {
    case batchPauseFailed(failedCount: Int, totalCount: Int, firstFailure: String)
    case bitTorrentMetadataTimedOut(reason: String)
    case bitTorrentContentNotSelectable(status: String)

    var errorDescription: String? {
        switch self {
        case .batchPauseFailed(let failedCount, let totalCount, let firstFailure):
            "Could not pause \(failedCount) of \(totalCount) tasks.\n\(firstFailure)"
        case .bitTorrentMetadataTimedOut(let reason):
            "Torrent metadata did not become available.\n\(reason)"
        case .bitTorrentContentNotSelectable(let status):
            "Torrent files cannot be selected because the content task is \(status). Remove it and add the Magnet again."
        }
    }
}
