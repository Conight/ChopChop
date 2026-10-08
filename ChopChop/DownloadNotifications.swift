import AppKit
import Combine
import UserNotifications

nonisolated enum CompletionNotificationPermission: Sendable {
    case notDetermined, allowed, denied
}

nonisolated struct CompletedDownload: Equatable, Sendable {
    var id: String
    var name: String
}

@MainActor
protocol CompletionNotificationDelivering: AnyObject {
    var onOpenDownloads: (([String]) -> Void)? { get set }
    func permission() async -> CompletionNotificationPermission
    func requestPermission() async throws -> Bool
    func deliver(_ downloads: [CompletedDownload]) async throws
    func cancelPending()
}

@MainActor
final class SystemCompletionNotifications: NSObject, CompletionNotificationDelivering, UNUserNotificationCenterDelegate {
    var onOpenDownloads: (([String]) -> Void)?
    private let center: UNUserNotificationCenter

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func permission() async -> CompletionNotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestPermission() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert])
    }

    func deliver(_ downloads: [CompletedDownload]) async throws {
        guard let first = downloads.first else { return }
        let content = UNMutableNotificationContent()
        content.title = downloads.count == 1 ? String(localized: "Download complete") : String(localized: "\(downloads.count) downloads complete")
        content.body = downloads.prefix(3).map { String(DownloadPrivacy.redact($0.name).prefix(160)) }.joined(separator: "\n")
        content.threadIdentifier = "download-completions"
        content.userInfo = ["downloadIDs": downloads.map(\.id)]
        let request = UNNotificationRequest(identifier: "download-complete.\(first.id)", content: content, trigger: nil)
        try await center.add(request)
    }

    func cancelPending() { center.removeAllPendingNotificationRequests() }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The active app already shows completion in its download list.
        completionHandler([])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let ids = response.notification.request.content.userInfo["downloadIDs"] as? [String] ?? []
        Task { @MainActor [weak self] in self?.onOpenDownloads?(ids) }
        completionHandler()
    }
}

@MainActor
final class SilentCompletionNotifications: CompletionNotificationDelivering {
    var onOpenDownloads: (([String]) -> Void)?
    func permission() async -> CompletionNotificationPermission { .notDetermined }
    func requestPermission() async throws -> Bool { false }
    func deliver(_ downloads: [CompletedDownload]) async throws {}
    func cancelPending() {}
}

@MainActor
final class DownloadNotificationCoordinator: ObservableObject {
    @Published private(set) var status: String?
    @Published private(set) var isRequestingPermission = false
    var onOpenDownloads: (([String]) -> Void)? {
        didSet { delivery.onOpenDownloads = onOpenDownloads }
    }
    private let delivery: any CompletionNotificationDelivering
    private let isForeground: () -> Bool
    private var hasBaseline = false
    private var explicitlyAddedIDs: Set<String> = []
    private var isEnabled = false
    private var preferenceRevision = 0

    init(delivery: (any CompletionNotificationDelivering)? = nil, isForeground: @escaping () -> Bool = { NSApp?.isActive == true }) {
        self.delivery = delivery ?? (AppLaunchConfiguration.isTestAutomation ? SilentCompletionNotifications() : SystemCompletionNotifications())
        self.isForeground = isForeground
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        preferenceRevision += 1
        if !enabled { delivery.cancelPending(); status = nil }
    }

    func requestEnable() async -> Bool {
        guard !isRequestingPermission else { return isEnabled }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        do {
            let permission = await delivery.permission()
            let allowed: Bool
            switch permission {
            case .allowed: allowed = true
            case .notDetermined: allowed = try await delivery.requestPermission()
            case .denied: allowed = false
            }
            status = allowed ? String(localized: "Completion notifications are enabled for background downloads.") : String(localized: "Notifications are blocked. Allow ChopChop in System Settings → Notifications, then enable this option again.")
            return allowed
        } catch {
            status = String(localized: "Could not enable notifications. \(DownloadPrivacy.redact(error.localizedDescription))")
            return false
        }
    }

    func noteAdded(_ ids: [String]) { explicitlyAddedIDs.formUnion(ids) }
    func resetBaseline() { hasBaseline = false }

    func observe(_ current: [DownloadTask], previous: [DownloadTask], history: DownloadHistoryStore?) async {
        let known = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let completed = current.filter(\.hasCompletedPayload)
        let unobserved = completed.filter { history?.hasObservedCompletion($0.id) == false }
        let deliverable = unobserved.filter { task in
            explicitlyAddedIDs.contains(task.id) || (hasBaseline && known[task.id]?.hasCompletedPayload == false)
        }.map { CompletedDownload(id: $0.id, name: $0.name) }
        hasBaseline = true
        explicitlyAddedIDs.subtract(completed.map(\.id))
        // Commit consumption before scheduling. Restart and repeated polling cannot notify twice.
        guard let history else { return }
        do { try history.markCompletionsObserved(Set(unobserved.map(\.id))) }
        catch { status = String(localized: "Completion notifications are paused because history could not be saved."); return }
        guard isEnabled, !isForeground(), !deliverable.isEmpty else { return }
        let revision = preferenceRevision
        guard await delivery.permission() == .allowed else {
            status = String(localized: "Allow ChopChop notifications in System Settings to receive completion alerts.")
            return
        }
        guard isEnabled, preferenceRevision == revision, !isForeground() else { return }
        do { try await delivery.deliver(deliverable) }
        catch { status = String(localized: "Could not deliver a completion notification.") }
    }
}

nonisolated extension DownloadTask {
    var hasCompletedPayload: Bool {
        guard !isFetchingMetadata, !requiresFileSelection else { return false }
        if status == .completed || isSharing { return true }
        guard isTorrentLike, status == .active || status == .paused, !isChecking, !isFetchingMetadata else { return false }
        let selected = files.filter(\.isSelected)
        return !selected.isEmpty && selected.allSatisfy { $0.length > 0 && $0.completedLength >= $0.length }
    }
}
