import Foundation

nonisolated enum PreferencesError: LocalizedError, Sendable {
    case staleBookmark(String)
    case missingBookmark(String)

    var errorDescription: String? {
        switch self {
        case .staleBookmark(let label):
            String(localized: "\(label) permission is stale. Select it again in Settings.")
        case .missingBookmark(let label):
            String(localized: "\(label) has not been selected.")
        }
    }
}

nonisolated enum PreferenceKey {
    static let rpcToken = "engine.rpcToken"
    static let rpcPort = "engine.rpcPort"
    static let downloadDirectoryPath = "engine.downloadDirectoryPath"
    static let downloadDirectoryBookmark = "engine.downloadDirectoryBookmark"
    static let maxActiveDownloads = "engine.maxActiveDownloads"
    static let maxConnectionsPerTask = "engine.maxConnectionsPerTask"
    static let splitCount = "engine.splitCount"
    static let maxOverallDownloadLimitKB = "engine.maxOverallDownloadLimitKB"
    static let maxOverallUploadLimitKB = "engine.maxOverallUploadLimitKB"
    static let retryCount = "engine.retryCount"
    static let retryWaitSeconds = "engine.retryWaitSeconds"
    static let connectTimeoutSeconds = "engine.connectTimeoutSeconds"
    static let timeoutSeconds = "engine.timeoutSeconds"
    static let fileAllocation = "engine.fileAllocation"
    static let asyncDNS = "engine.asyncDNS"
    static let userAgent = "engine.userAgent"
    static let proxyURL = "engine.proxyURL"
    static let btMaxPeers = "engine.btMaxPeers"
    static let btDHTEnabled = "engine.btDHTEnabled"
    static let btPeerExchangeEnabled = "engine.btPeerExchangeEnabled"
    static let btLocalPeerDiscoveryEnabled = "engine.btLocalPeerDiscoveryEnabled"
    static let btForceEncryption = "engine.btForceEncryption"
    static let keepSharing = "engine.keepSharing"
    static let shareRatio = "engine.shareRatio"
    static let shareTimeMinutes = "engine.shareTimeMinutes"
    static let listenPort = "engine.listenPort"
    static let dhtListenPort = "engine.dhtListenPort"

    static let launchAtLogin = "app.launchAtLogin"
    static let showMenuBar = "app.showMenuBar"
    static let keepRunningAfterClose = "app.keepRunningAfterClose"
    static let autoRevealCompletedFile = "app.autoRevealCompletedFile"
    static let askBeforeOverwrite = "app.askBeforeOverwrite"
    static let autoOrganizeFiles = "app.autoOrganizeFiles"
    static let handleMagnetLinks = "app.handleMagnetLinks"
    static let handleED2KLinks = "app.handleED2KLinks"
    static let handleTorrentFiles = "app.handleTorrentFiles"
    static let handleMetalinkFiles = "app.handleMetalinkFiles"
    static let captureAskBeforeSending = "app.captureAskBeforeSending"
    static let captureMinimumSizeMB = "app.captureMinimumSizeMB"
    static let captureForwardCookies = "app.captureForwardCookies"
    static let captureIgnoreImagesAndFonts = "app.captureIgnoreImagesAndFonts"

    static let all = [
        rpcToken,
        rpcPort,
        downloadDirectoryPath,
        downloadDirectoryBookmark,
        maxActiveDownloads,
        maxConnectionsPerTask,
        splitCount,
        maxOverallDownloadLimitKB,
        maxOverallUploadLimitKB,
        retryCount,
        retryWaitSeconds,
        connectTimeoutSeconds,
        timeoutSeconds,
        fileAllocation,
        asyncDNS,
        userAgent,
        proxyURL,
        btMaxPeers,
        btDHTEnabled,
        btPeerExchangeEnabled,
        btLocalPeerDiscoveryEnabled,
        btForceEncryption,
        keepSharing,
        shareRatio,
        shareTimeMinutes,
        listenPort,
        dhtListenPort,
        launchAtLogin,
        showMenuBar,
        keepRunningAfterClose,
        autoRevealCompletedFile,
        askBeforeOverwrite,
        autoOrganizeFiles,
        handleMagnetLinks,
        handleED2KLinks,
        handleTorrentFiles,
        handleMetalinkFiles,
        captureAskBeforeSending,
        captureMinimumSizeMB,
        captureForwardCookies,
        captureIgnoreImagesAndFonts
    ]
}

nonisolated enum PreferencesStore {
    static func reset() {
        let defaults = UserDefaults.standard
        PreferenceKey.all.forEach { defaults.removeObject(forKey: $0) }
    }

    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolveBookmark(_ data: Data?, label: String) throws -> URL {
        guard let data else { throw PreferencesError.missingBookmark(label) }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            throw PreferencesError.staleBookmark(label)
        }
        return url
    }
}
