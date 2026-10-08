import Foundation
import SwiftData

nonisolated enum PersistentSettingsError: LocalizedError, Sendable {
    case recordCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .recordCreationFailed(let name):
            String(localized: "Could not create persistent \(name) settings record.")
        }
    }
}

@Model
final class PersistentEngineConfiguration {
    static let defaultKey = "engine"

    @Attribute(.unique) var key: String
    var rpcToken: String?
    var rpcPort: Int
    var downloadDirectoryPath: String?
    var downloadDirectoryBookmark: Data?
    var maxActiveDownloads: Int
    var maxConnectionsPerTask: Int
    var splitCount: Int
    var maxOverallDownloadLimitKB: Int
    var maxOverallUploadLimitKB: Int
    var retryCount: Int
    var retryWaitSeconds: Int
    var connectTimeoutSeconds: Int
    var timeoutSeconds: Int
    var fileAllocationRawValue: String
    var asyncDNS: Bool
    var userAgent: String
    var proxyURL: String
    var proxyBypass: String?
    var btMaxPeers: Int
    var btDHTEnabled: Bool
    var btPeerExchangeEnabled: Bool
    var btLocalPeerDiscoveryEnabled: Bool
    var btForceEncryption: Bool
    var pauseMetadata: Bool?
    var keepSharing: Bool
    var shareRatio: Int
    var shareTimeMinutes: Int
    var listenPort: Int
    var dhtListenPort: Int
    var btTracker: String?
    var btTrackerAutoSync: Bool?
    var btTrackerSyncIntervalHours: Int?
    var trackerSourceURLsData: Data?
    var customTrackerSourceURLsData: Data?
    var lastTrackerSyncAt: Date?
    var ed2kListenPort: Int?
    var ed2kUDPListenPort: Int?
    var ed2kServer: String?
    var ed2kServerMetURL: String?
    var ed2kNodesDatURL: String?
    var ed2kBootstrapAutoSync: Bool?
    var ed2kBootstrapSyncIntervalHours: Int?
    var lastED2KBootstrapSyncAt: Date?
    var ed2kUploadSlots: Int?
    var ed2kSearchTimeoutSeconds: Int?
    var updatedAt: Date

    init(key: String = PersistentEngineConfiguration.defaultKey) {
        let settings = EngineSettings()
        self.key = key
        self.rpcToken = settings.rpcToken
        self.rpcPort = settings.rpcPort
        self.downloadDirectoryPath = settings.downloadDirectoryPath
        self.downloadDirectoryBookmark = settings.downloadDirectoryBookmark
        self.maxActiveDownloads = settings.maxActiveDownloads
        self.maxConnectionsPerTask = settings.maxConnectionsPerTask
        self.splitCount = settings.splitCount
        self.maxOverallDownloadLimitKB = settings.maxOverallDownloadLimitKB
        self.maxOverallUploadLimitKB = settings.maxOverallUploadLimitKB
        self.retryCount = settings.retryCount
        self.retryWaitSeconds = settings.retryWaitSeconds
        self.connectTimeoutSeconds = settings.connectTimeoutSeconds
        self.timeoutSeconds = settings.timeoutSeconds
        self.fileAllocationRawValue = settings.fileAllocation.rawValue
        self.asyncDNS = settings.asyncDNS
        self.userAgent = settings.userAgent
        self.proxyURL = settings.proxyURL
        self.proxyBypass = settings.proxyBypass
        self.btMaxPeers = settings.btMaxPeers
        self.btDHTEnabled = settings.btDHTEnabled
        self.btPeerExchangeEnabled = settings.btPeerExchangeEnabled
        self.btLocalPeerDiscoveryEnabled = settings.btLocalPeerDiscoveryEnabled
        self.btForceEncryption = settings.btForceEncryption
        self.pauseMetadata = settings.pauseMetadata
        self.keepSharing = settings.keepSharing
        self.shareRatio = settings.shareRatio
        self.shareTimeMinutes = settings.shareTimeMinutes
        self.listenPort = settings.listenPort
        self.dhtListenPort = settings.dhtListenPort
        self.btTracker = settings.btTracker
        self.btTrackerAutoSync = settings.btTrackerAutoSync
        self.btTrackerSyncIntervalHours = settings.btTrackerSyncIntervalHours
        self.trackerSourceURLsData = Self.encodeStringArray(settings.trackerSourceURLs)
        self.customTrackerSourceURLsData = Self.encodeStringArray(settings.customTrackerSourceURLs)
        self.lastTrackerSyncAt = settings.lastTrackerSyncAt
        self.ed2kListenPort = settings.ed2kListenPort
        self.ed2kUDPListenPort = settings.ed2kUDPListenPort
        self.ed2kServer = settings.ed2kServer
        self.ed2kServerMetURL = settings.ed2kServerMetURL
        self.ed2kNodesDatURL = settings.ed2kNodesDatURL
        self.ed2kBootstrapAutoSync = settings.ed2kBootstrapAutoSync
        self.ed2kBootstrapSyncIntervalHours = settings.ed2kBootstrapSyncIntervalHours
        self.lastED2KBootstrapSyncAt = settings.lastED2KBootstrapSyncAt
        self.ed2kUploadSlots = settings.ed2kUploadSlots
        self.ed2kSearchTimeoutSeconds = settings.ed2kSearchTimeoutSeconds
        self.updatedAt = Date()
    }

    func engineSettings() -> EngineSettings {
        var settings = EngineSettings()
        settings.rpcToken = rpcToken ?? ""
        settings.rpcPort = rpcPort > 0 ? rpcPort : EngineSettings.defaultRPCPort
        settings.downloadDirectoryPath = downloadDirectoryPath ?? EngineSettings.defaultDownloadDirectoryPath
        settings.downloadDirectoryBookmark = downloadDirectoryBookmark
        settings.maxActiveDownloads = maxActiveDownloads > 0 ? maxActiveDownloads : settings.maxActiveDownloads
        settings.maxConnectionsPerTask = maxConnectionsPerTask > 0 ? maxConnectionsPerTask : settings.maxConnectionsPerTask
        settings.splitCount = splitCount > 0 ? splitCount : settings.splitCount
        settings.maxOverallDownloadLimitKB = max(0, maxOverallDownloadLimitKB)
        settings.maxOverallUploadLimitKB = max(0, maxOverallUploadLimitKB)
        settings.retryCount = max(0, retryCount)
        settings.retryWaitSeconds = retryWaitSeconds > 0 ? retryWaitSeconds : settings.retryWaitSeconds
        settings.connectTimeoutSeconds = connectTimeoutSeconds > 0 ? connectTimeoutSeconds : settings.connectTimeoutSeconds
        settings.timeoutSeconds = timeoutSeconds > 0 ? timeoutSeconds : settings.timeoutSeconds
        settings.fileAllocation = FileAllocationMode(rawValue: fileAllocationRawValue) ?? settings.fileAllocation
        settings.asyncDNS = asyncDNS
        if !userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.userAgent = userAgent
        }
        settings.proxyURL = proxyURL
        settings.proxyBypass = proxyBypass ?? settings.proxyBypass
        settings.btMaxPeers = btMaxPeers > 0 ? btMaxPeers : settings.btMaxPeers
        settings.btDHTEnabled = btDHTEnabled
        settings.btPeerExchangeEnabled = btPeerExchangeEnabled
        settings.btLocalPeerDiscoveryEnabled = btLocalPeerDiscoveryEnabled
        settings.btForceEncryption = btForceEncryption
        settings.pauseMetadata = pauseMetadata ?? settings.pauseMetadata
        settings.keepSharing = keepSharing
        settings.shareRatio = shareRatio > 0 ? shareRatio : settings.shareRatio
        settings.shareTimeMinutes = shareTimeMinutes > 0 ? shareTimeMinutes : settings.shareTimeMinutes
        settings.listenPort = listenPort > 0 ? listenPort : settings.listenPort
        settings.dhtListenPort = dhtListenPort > 0 ? dhtListenPort : settings.dhtListenPort
        settings.btTracker = btTracker ?? settings.btTracker
        settings.btTrackerAutoSync = btTrackerAutoSync ?? settings.btTrackerAutoSync
        settings.btTrackerSyncIntervalHours = btTrackerSyncIntervalHours ?? settings.btTrackerSyncIntervalHours
        settings.trackerSourceURLs = Self.decodeStringArray(trackerSourceURLsData) ?? settings.trackerSourceURLs
        settings.customTrackerSourceURLs = Self.decodeStringArray(customTrackerSourceURLsData) ?? settings.customTrackerSourceURLs
        settings.lastTrackerSyncAt = lastTrackerSyncAt
        settings.ed2kListenPort = validED2KPort(ed2kListenPort) ?? settings.ed2kListenPort
        settings.ed2kUDPListenPort = validED2KPort(ed2kUDPListenPort) ?? settings.ed2kUDPListenPort
        settings.ed2kServer = ed2kServer ?? settings.ed2kServer
        settings.ed2kServerMetURL = ed2kServerMetURL ?? settings.ed2kServerMetURL
        settings.ed2kNodesDatURL = ed2kNodesDatURL ?? settings.ed2kNodesDatURL
        settings.ed2kBootstrapAutoSync = ed2kBootstrapAutoSync ?? settings.ed2kBootstrapAutoSync
        settings.ed2kBootstrapSyncIntervalHours = ed2kBootstrapSyncIntervalHours ?? settings.ed2kBootstrapSyncIntervalHours
        settings.lastED2KBootstrapSyncAt = lastED2KBootstrapSyncAt
        settings.ed2kUploadSlots = (1...100).contains(ed2kUploadSlots ?? 0) ? ed2kUploadSlots ?? settings.ed2kUploadSlots : settings.ed2kUploadSlots
        settings.ed2kSearchTimeoutSeconds = (10...600).contains(ed2kSearchTimeoutSeconds ?? 0) ? ed2kSearchTimeoutSeconds ?? settings.ed2kSearchTimeoutSeconds : settings.ed2kSearchTimeoutSeconds
        return settings
    }

    func update(from settings: EngineSettings) {
        rpcToken = settings.rpcToken
        rpcPort = settings.rpcPort
        downloadDirectoryPath = settings.downloadDirectoryPath
        downloadDirectoryBookmark = settings.downloadDirectoryBookmark
        maxActiveDownloads = settings.maxActiveDownloads
        maxConnectionsPerTask = settings.maxConnectionsPerTask
        splitCount = settings.splitCount
        maxOverallDownloadLimitKB = settings.maxOverallDownloadLimitKB
        maxOverallUploadLimitKB = settings.maxOverallUploadLimitKB
        retryCount = settings.retryCount
        retryWaitSeconds = settings.retryWaitSeconds
        connectTimeoutSeconds = settings.connectTimeoutSeconds
        timeoutSeconds = settings.timeoutSeconds
        fileAllocationRawValue = settings.fileAllocation.rawValue
        asyncDNS = settings.asyncDNS
        userAgent = settings.userAgent
        proxyURL = settings.proxyURL
        proxyBypass = settings.proxyBypass
        btMaxPeers = settings.btMaxPeers
        btDHTEnabled = settings.btDHTEnabled
        btPeerExchangeEnabled = settings.btPeerExchangeEnabled
        btLocalPeerDiscoveryEnabled = settings.btLocalPeerDiscoveryEnabled
        btForceEncryption = settings.btForceEncryption
        pauseMetadata = settings.pauseMetadata
        keepSharing = settings.keepSharing
        shareRatio = settings.shareRatio
        shareTimeMinutes = settings.shareTimeMinutes
        listenPort = settings.listenPort
        dhtListenPort = settings.dhtListenPort
        btTracker = settings.btTracker
        btTrackerAutoSync = settings.btTrackerAutoSync
        btTrackerSyncIntervalHours = settings.btTrackerSyncIntervalHours
        trackerSourceURLsData = Self.encodeStringArray(settings.trackerSourceURLs)
        customTrackerSourceURLsData = Self.encodeStringArray(settings.customTrackerSourceURLs)
        lastTrackerSyncAt = settings.lastTrackerSyncAt
        ed2kListenPort = settings.ed2kListenPort
        ed2kUDPListenPort = settings.ed2kUDPListenPort
        ed2kServer = settings.ed2kServer
        ed2kServerMetURL = settings.ed2kServerMetURL
        ed2kNodesDatURL = settings.ed2kNodesDatURL
        ed2kBootstrapAutoSync = settings.ed2kBootstrapAutoSync
        ed2kBootstrapSyncIntervalHours = settings.ed2kBootstrapSyncIntervalHours
        lastED2KBootstrapSyncAt = settings.lastED2KBootstrapSyncAt
        ed2kUploadSlots = settings.ed2kUploadSlots
        ed2kSearchTimeoutSeconds = settings.ed2kSearchTimeoutSeconds
        updatedAt = Date()
    }

    private func validED2KPort(_ value: Int?) -> Int? {
        guard let value, EngineSettings.validED2KListenPortRange.contains(value) else { return nil }
        return value
    }

    private static func encodeStringArray(_ values: [String]) -> Data? {
        try? JSONEncoder().encode(values)
    }

    private static func decodeStringArray(_ data: Data?) -> [String]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}

@Model
final class PersistentAppConfiguration {
    static let defaultKey = "app"

    @Attribute(.unique) var key: String
    var launchAtLogin: Bool
    var showMenuBar: Bool
    var notifyOnDownloadCompletion: Bool = false
    var bandwidthScheduleData: Data?
    var browserCaptureEnabled: Bool = false
    var browserCaptureToken: String = ""
    var keepRunningAfterClose: Bool
    var autoRevealCompletedFile: Bool
    var askBeforeOverwrite: Bool
    var autoOrganizeFiles: Bool
    var preventSleepDuringActiveDownloads: Bool?
    var handleMagnetLinks: Bool
    var handleED2KLinks: Bool
    var handleTorrentFiles: Bool
    var handleMetalinkFiles: Bool
    var captureAskBeforeSending: Bool
    var captureMinimumSizeMB: Int
    var captureForwardCookies: Bool
    var captureIgnoreImagesAndFonts: Bool
    var suppressRemoveConfirmation: Bool
    var deleteFilesWhenSkippingRemoveConfirmation: Bool
    var updatedAt: Date

    init(key: String = PersistentAppConfiguration.defaultKey) {
        let preferences = AppPreferences()
        self.key = key
        self.launchAtLogin = preferences.launchAtLogin
        self.showMenuBar = preferences.showMenuBar
        self.notifyOnDownloadCompletion = preferences.notifyOnDownloadCompletion
        self.browserCaptureEnabled = preferences.browserCaptureEnabled
        self.browserCaptureToken = preferences.browserCaptureToken
        self.keepRunningAfterClose = preferences.keepRunningAfterClose
        self.autoRevealCompletedFile = preferences.autoRevealCompletedFile
        self.askBeforeOverwrite = preferences.askBeforeOverwrite
        self.autoOrganizeFiles = preferences.autoOrganizeFiles
        self.preventSleepDuringActiveDownloads = preferences.preventSleepDuringActiveDownloads
        self.handleMagnetLinks = preferences.handleMagnetLinks
        self.handleED2KLinks = preferences.handleED2KLinks
        self.handleTorrentFiles = preferences.handleTorrentFiles
        self.handleMetalinkFiles = preferences.handleMetalinkFiles
        self.captureAskBeforeSending = preferences.captureAskBeforeSending
        self.captureMinimumSizeMB = preferences.captureMinimumSizeMB
        self.captureForwardCookies = preferences.captureForwardCookies
        self.captureIgnoreImagesAndFonts = preferences.captureIgnoreImagesAndFonts
        self.suppressRemoveConfirmation = preferences.suppressRemoveConfirmation
        self.deleteFilesWhenSkippingRemoveConfirmation = preferences.deleteFilesWhenSkippingRemoveConfirmation
        self.updatedAt = Date()
    }

    func appPreferences() -> AppPreferences {
        var preferences = AppPreferences()
        preferences.launchAtLogin = launchAtLogin
        preferences.showMenuBar = showMenuBar
        preferences.notifyOnDownloadCompletion = notifyOnDownloadCompletion
        preferences.bandwidthSchedule = bandwidthScheduleData.flatMap { try? JSONDecoder().decode(BandwidthSchedule.self, from: $0) } ?? BandwidthSchedule()
        preferences.browserCaptureEnabled = browserCaptureEnabled
        preferences.browserCaptureToken = browserCaptureToken
        preferences.keepRunningAfterClose = keepRunningAfterClose
        preferences.autoRevealCompletedFile = autoRevealCompletedFile
        preferences.askBeforeOverwrite = askBeforeOverwrite
        preferences.autoOrganizeFiles = autoOrganizeFiles
        preferences.preventSleepDuringActiveDownloads =
            preventSleepDuringActiveDownloads ?? preferences.preventSleepDuringActiveDownloads
        preferences.handleMagnetLinks = handleMagnetLinks
        preferences.handleED2KLinks = handleED2KLinks
        preferences.handleTorrentFiles = handleTorrentFiles
        preferences.handleMetalinkFiles = handleMetalinkFiles
        preferences.captureAskBeforeSending = captureAskBeforeSending
        preferences.captureMinimumSizeMB = captureMinimumSizeMB > 0 ? captureMinimumSizeMB : preferences.captureMinimumSizeMB
        preferences.captureForwardCookies = captureForwardCookies
        preferences.captureIgnoreImagesAndFonts = captureIgnoreImagesAndFonts
        preferences.suppressRemoveConfirmation = suppressRemoveConfirmation
        preferences.deleteFilesWhenSkippingRemoveConfirmation = deleteFilesWhenSkippingRemoveConfirmation
        return preferences
    }

    func update(from preferences: AppPreferences) {
        launchAtLogin = preferences.launchAtLogin
        showMenuBar = preferences.showMenuBar
        notifyOnDownloadCompletion = preferences.notifyOnDownloadCompletion
        bandwidthScheduleData = try? JSONEncoder().encode(preferences.bandwidthSchedule)
        browserCaptureEnabled = preferences.browserCaptureEnabled
        browserCaptureToken = preferences.browserCaptureToken
        keepRunningAfterClose = preferences.keepRunningAfterClose
        autoRevealCompletedFile = preferences.autoRevealCompletedFile
        askBeforeOverwrite = preferences.askBeforeOverwrite
        autoOrganizeFiles = preferences.autoOrganizeFiles
        preventSleepDuringActiveDownloads = preferences.preventSleepDuringActiveDownloads
        handleMagnetLinks = preferences.handleMagnetLinks
        handleED2KLinks = preferences.handleED2KLinks
        handleTorrentFiles = preferences.handleTorrentFiles
        handleMetalinkFiles = preferences.handleMetalinkFiles
        captureAskBeforeSending = preferences.captureAskBeforeSending
        captureMinimumSizeMB = preferences.captureMinimumSizeMB
        captureForwardCookies = preferences.captureForwardCookies
        captureIgnoreImagesAndFonts = preferences.captureIgnoreImagesAndFonts
        suppressRemoveConfirmation = preferences.suppressRemoveConfirmation
        deleteFilesWhenSkippingRemoveConfirmation = preferences.deleteFilesWhenSkippingRemoveConfirmation
        updatedAt = Date()
    }
}

@MainActor
final class PersistentSettingsStore {
    private let container: ModelContainer
    private let context: ModelContext

    init(inMemory: Bool = false, storeURL: URL? = nil) throws {
        let schema = Schema([
            PersistentEngineConfiguration.self,
            PersistentAppConfiguration.self,
            PersistentDownloadRecord.self
        ])
        let configuration: ModelConfiguration
        if let storeURL { configuration = ModelConfiguration(schema: schema, url: storeURL) }
        else { configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory) }
        self.container = try ModelContainer(for: schema, configurations: [configuration])
        self.context = ModelContext(container)
    }

    func makeHistoryStore() throws -> DownloadHistoryStore {
        try DownloadHistoryStore(context: ModelContext(container))
    }

    static func live() throws -> PersistentSettingsStore {
        try PersistentSettingsStore(inMemory: AppLaunchConfiguration.isTestAutomation)
    }

    static func resetLiveData() throws {
        let store = try PersistentSettingsStore(inMemory: false)
        try store.reset()
    }

    func loadEngineSettings() throws -> EngineSettings {
        guard let record = try engineRecord(createIfNeeded: false) else {
            return EngineSettings()
        }
        return record.engineSettings()
    }

    func saveEngineSettings(_ settings: EngineSettings) throws {
        guard let record = try engineRecord(createIfNeeded: true) else {
            throw PersistentSettingsError.recordCreationFailed("engine")
        }
        record.update(from: settings)
        try context.save()
    }

    func loadAppPreferences() throws -> AppPreferences {
        guard let record = try appRecord(createIfNeeded: false) else {
            return AppPreferences()
        }
        return record.appPreferences()
    }

    func saveAppPreferences(_ preferences: AppPreferences) throws {
        guard let record = try appRecord(createIfNeeded: true) else {
            throw PersistentSettingsError.recordCreationFailed("app")
        }
        record.update(from: preferences)
        try context.save()
    }

    func reset() throws {
        for record in try context.fetch(FetchDescriptor<PersistentEngineConfiguration>()) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<PersistentAppConfiguration>()) {
            context.delete(record)
        }
        try context.save()
    }

    private func engineRecord(createIfNeeded: Bool) throws -> PersistentEngineConfiguration? {
        let records = try context.fetch(FetchDescriptor<PersistentEngineConfiguration>())
        if let record = records.first(where: { $0.key == PersistentEngineConfiguration.defaultKey }) {
            removeDuplicateEngineRecords(keeping: record, from: records)
            return record
        }
        guard createIfNeeded else { return nil }
        let record = PersistentEngineConfiguration()
        context.insert(record)
        return record
    }

    private func appRecord(createIfNeeded: Bool) throws -> PersistentAppConfiguration? {
        let records = try context.fetch(FetchDescriptor<PersistentAppConfiguration>())
        if let record = records.first(where: { $0.key == PersistentAppConfiguration.defaultKey }) {
            removeDuplicateAppRecords(keeping: record, from: records)
            return record
        }
        guard createIfNeeded else { return nil }
        let record = PersistentAppConfiguration()
        context.insert(record)
        return record
    }

    private func removeDuplicateEngineRecords(
        keeping keptRecord: PersistentEngineConfiguration,
        from records: [PersistentEngineConfiguration]
    ) {
        for record in records where record !== keptRecord {
            context.delete(record)
        }
    }

    private func removeDuplicateAppRecords(
        keeping keptRecord: PersistentAppConfiguration,
        from records: [PersistentAppConfiguration]
    ) {
        for record in records where record !== keptRecord {
            context.delete(record)
        }
    }
}
