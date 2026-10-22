//
//  ChopChopApp.swift
//  ChopChop
//
//  Created by Conight on 3/6/26.
//

import AppKit
import Combine
import SwiftUI

@main
struct ChopChopApp: App {
    @NSApplicationDelegateAdaptor(ChopChopAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: DownloadStore
    @StateObject private var supportNavigation = AppSupportNavigation()
    @StateObject private var inputPresentation = DownloadInputPresentation()
    @State private var updates = AppUpdateCoordinator()

    init() {
        AppLaunchConfiguration.prepare()
        let store = AppLaunchConfiguration.uiTestScenario?.makeStore() ?? DownloadStore()
        DownloadIntentRouter.shared.store = store
        _store = State(initialValue: store)
    }

    var body: some Scene {
        // A value-identified group reuses one workspace while retaining normal
        // background-app behavior when its last window closes.
        WindowGroup(AppIdentity.displayName, id: AppWindowID.downloads, for: String.self) { _ in
            ContentView(updates: updates, supportNavigation: supportNavigation, inputPresentation: inputPresentation)
                .task {
                    guard !AppLaunchConfiguration.isTestAutomation else { return }
                    await updates.checkAtLaunch(using: store)
                }
                .onAppear {
                    store.startEngineOnAppLaunch()
                }
            .environment(store)
        } defaultValue: {
            AppWindowID.downloads
        }
        .defaultSize(width: 1100, height: 740)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(AppLaunchConfiguration.suppressesDefaultDownloadWindow ? .suppressed : .presented)
        .restorationBehavior(.disabled)
        .onChange(of: scenePhase, initial: true) { _, _ in
            // Register from the app, even when restoration did not create a window.
            appDelegate.configureMenuBar(store: store)
            appDelegate.registerDownloadWindowOpener {
                openWindow(id: AppWindowID.downloads, value: AppWindowID.downloads)
            }
        }
        .commands {
            DownloadCommands(store: store, inputPresentation: inputPresentation)
            AppSupportCommands(updates: updates, store: store, navigation: supportNavigation)
        }

        Window(String(localized: "About \(AppIdentity.displayName)"), id: AppWindowID.about) {
            AppAboutView(updates: updates).environment(store)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window(String(localized: "Acknowledgments"), id: AppWindowID.acknowledgments) {
            AppAcknowledgmentsView()
        }
        .defaultSize(width: 620, height: 580)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window(String(localized: "Keyboard Shortcuts"), id: AppWindowID.shortcuts) {
            AppKeyboardShortcutsView()
        }
        .defaultSize(width: 520, height: 620)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window(String(localized: "ChopChop Help"), id: AppWindowID.help) {
            AppSupportView(navigation: supportNavigation).environment(store)
        }
        .defaultSize(width: 600, height: 640)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window(String(localized: "ChopChop Updates"), id: AppWindowID.updates) {
            AppUpdateWindow(updates: updates)
        }
        .defaultSize(width: 540, height: 500)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(store)
                .environment(updates)
        }
        .defaultSize(width: 940, height: 640)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

enum AppLaunchConfiguration {
    private static let preparation: Void = {
        if ProcessInfo.processInfo.arguments.contains("--reset-preferences"), !isUITesting {
            PreferencesStore.reset()
            try? PersistentSettingsStore.resetLiveData()
        }
    }()

    nonisolated static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["CHOPCHOP_UI_TESTING"] == "1"
    }

    // Exercise the cold-launch fallback without depending on saved system state.
    nonisolated static var suppressesDefaultDownloadWindow: Bool {
        isUITesting && ProcessInfo.processInfo.environment["CHOPCHOP_UI_SUPPRESS_DEFAULT_WINDOW"] == "1"
    }

    nonisolated static var uiTestScenario: UITestScenario? {
        UITestScenario.read(from: ProcessInfo.processInfo.environment)
    }

    nonisolated static var testsAutomaticEngineStartup: Bool { uiTestScenario == .freshInstall }

    nonisolated static var isTestAutomation: Bool {
        let environment = ProcessInfo.processInfo.environment
        return isUITesting ||
            environment["CHOPCHOP_TESTING"] == "1" ||
            environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCInjectBundleInto"] != nil
    }

    static func prepare() {
        _ = preparation
    }
}

final class ChopChopAppDelegate: NSObject, NSApplicationDelegate {
    private let downloadWindowPresentation = DownloadWindowPresentation()
    private let menuBarController = MenuBarStatusController()
    private let dockProgressController = DockDownloadProgressController()
    private weak var store: DownloadStore?
    private let termination = AppTermination.shared
    private var pendingOpenURLs: [URL] = []
    private var notificationNavigation: AnyCancellable?
    private var addPanelNavigation: AnyCancellable?
    private var downloadNavigation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        revealDownloadWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeMenuBarStatusItem()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppLaunchConfiguration.isTestAutomation else { return .terminateNow }
        guard let store else { return .terminateNow }
        return termination.shouldTerminate(sender) { [weak self] in
            await store.prepareForAppTermination()
            self?.removeMenuBarStatusItem()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        store?.preferences.keepRunningAfterClose == false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if downloadWindow?.isVisible != true || downloadWindow?.isMiniaturized == true {
            revealDownloadWindow()
            return false
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // The browser launch URL carries no task or authentication data.
        let resources = urls.filter { $0.scheme?.lowercased() != "chopchop" }
        if let store { store.importDownloads(resources.map(DownloadImportInput.url)) }
        else { pendingOpenURLs.append(contentsOf: resources) }
        revealDownloadWindow()
    }

    func configureMenuBar(store: DownloadStore) {
        if self.store !== store {
            self.store = store
            downloadNavigation = store.downloadWindowRequests.sink { [weak self] in self?.revealDownloadWindow() }
            addPanelNavigation = store.addPanelRequests.sink { [weak self] in self?.revealDownloadWindow() }
            notificationNavigation = store.notificationNavigationRequests.sink { [weak self] _ in
                self?.revealDownloadWindow()
            }
        }
        menuBarController.configure(store: store)
        dockProgressController.configure(store: store)
        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            store.importDownloads(urls.map(DownloadImportInput.url))
        }
    }

    private var downloadWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == AppWindowID.downloadsWindow }
    }

    func registerDownloadWindowOpener(_ open: @escaping () -> Void) {
        downloadWindowPresentation.register { [weak self] in
            // Reuse the existing workspace, including a closed/minimized window.
            if let window = self?.downloadWindow {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            } else {
                open()
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func revealDownloadWindow() {
        downloadWindowPresentation.request()
    }

    func removeMenuBarStatusItem() {
        menuBarController.remove()
    }


}

@MainActor
private final class MenuBarStatusController: NSObject {
    private weak var store: DownloadStore?
    private var preferencesCancellable: AnyCancellable?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func configure(store: DownloadStore) {
        guard !AppLaunchConfiguration.isTestAutomation else {
            remove()
            return
        }

        if self.store !== store {
            self.store = store
            popover = nil
            preferencesCancellable = store.preferenceChanges
                .map(\.showMenuBar)
                .removeDuplicates()
                .sink { [weak self] isVisible in
                    Task { @MainActor [weak self] in
                        self?.setStatusItemVisible(isVisible)
                    }
                }
        }

        setStatusItemVisible(store.preferences.showMenuBar)
    }

    func remove() {
        popover?.performClose(nil)
        popover = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func setStatusItemVisible(_ isVisible: Bool) {
        guard !AppLaunchConfiguration.isTestAutomation else {
            remove()
            return
        }

        if isVisible {
            ensureStatusItem()
        } else {
            remove()
        }
    }

    private func ensureStatusItem() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = AppBrand.menuBarImage
            item.button?.imagePosition = .imageOnly
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            item.button?.toolTip = AppIdentity.displayName
            statusItem = item
        }
    }

    private func ensurePopover() -> NSPopover? {
        guard let store else { return nil }
        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentSize = NSSize(width: 376, height: 520)
            popover.contentViewController = NSHostingController(rootView: MenuBarPanel().environment(store))
            self.popover = popover
        }
        return popover
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        ensureStatusItem()
        guard let popover = ensurePopover() else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

// Test data belongs to the application composition root, not DownloadStore.
extension UITestScenario {
    @MainActor
    func makeStore(settingsStore: PersistentSettingsStore? = nil) -> DownloadStore {
        let installation = self == .freshInstall ? nil : EngineInstallation(
            executableURL: URL(fileURLWithPath: "/tmp/ChopChopFixtures/aria2c"),
            version: EngineVersion(Self.installedEngineVersion)!)
        let store = DownloadStore(settingsStore: settingsStore, initialEngineInstallation: installation)
        // Installed scenarios model a stopped engine and never launch a process.
        guard self == .installedTasks else { return store }
        store.selectedDestination = .all
        store.tasks = [
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
                destination: "/tmp/ChopChopFixtures",
                addedAt: Date(timeIntervalSince1970: 1_700_000_000),
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
                destination: "/tmp/ChopChopFixtures",
                addedAt: Date(timeIntervalSince1970: 1_700_000_000),
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
                destination: "/tmp/ChopChopFixtures",
                addedAt: Date(timeIntervalSince1970: 1_700_000_000),
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
                destination: "/tmp/ChopChopFixtures",
                addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                errorMessage: nil,
                files: [],
                peers: [],
                trackers: [],
                recentLogs: []
            )
        ]
        store.speedSamples = [
            SpeedSample(timestamp: Date(timeIntervalSince1970: 1_700_000_000), downloadBytesPerSecond: 524_288, uploadBytesPerSecond: 0)
        ]
        return store
    }
}
