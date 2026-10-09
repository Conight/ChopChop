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
    @StateObject private var store: DownloadStore
    @StateObject private var supportNavigation = AppSupportNavigation()
    @StateObject private var updates = AppUpdateCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppLaunchConfiguration.prepare()
        let store = DownloadStore()
        DownloadIntentRouter.shared.store = store
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        WindowGroup(id: AppWindowID.downloads) {
            ContentView(updates: updates, supportNavigation: supportNavigation)
                .modifier(DownloadWindowRegistration(delegate: appDelegate))
                .task {
                    guard !AppLaunchConfiguration.isTestAutomation else { return }
                    await updates.check(automatically: true)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, !AppLaunchConfiguration.isTestAutomation else { return }
                    Task { await updates.check(automatically: true) }
                }
                .onAppear {
                    appDelegate.configureMenuBar(store: store)
                    store.startEngineOnAppLaunch()
                }
            .environmentObject(store)
        }
        .defaultSize(width: 1100, height: 740)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            DownloadCommands(store: store)
            AppSupportCommands(updates: updates, store: store, navigation: supportNavigation)
        }

        Window(String(localized: "ChopChop Help"), id: AppWindowID.help) {
            AppSupportView(navigation: supportNavigation).environmentObject(store)
        }
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
                .environmentObject(store)
                .environmentObject(updates)
        }
        .defaultSize(width: 940, height: 640)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
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

    nonisolated static var testsAutomaticEngineStartup: Bool {
        isUITesting && ProcessInfo.processInfo.environment["CHOPCHOP_UI_AUTO_START"] == "1"
    }

    nonisolated static var usesUITestFixtures: Bool {
        isUITesting && ProcessInfo.processInfo.environment["CHOPCHOP_UI_FIXTURE_TASKS"] == "1"
    }

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
    var openDownloadWindow: (() -> Void)?
    private let menuBarController = MenuBarStatusController()
    private let dockProgressController = DockDownloadProgressController()
    private weak var store: DownloadStore?
    private var isFinishingTermination = false
    private var pendingOpenURLs: [URL] = []
    private var notificationNavigation: AnyCancellable?
    private var addPanelNavigation: AnyCancellable?
    private var downloadNavigation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        presentMainWindowIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeMenuBarStatusItem()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppLaunchConfiguration.isTestAutomation else { return .terminateNow }
        guard !isFinishingTermination else { return .terminateLater }
        guard let store else { return .terminateNow }
        isFinishingTermination = true

        Task { @MainActor [weak self] in
            await store.prepareForAppTermination()
            self?.removeMenuBarStatusItem()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        store?.preferences.keepRunningAfterClose == false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            presentMainWindowIfNeeded()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let store { store.importDownloads(urls.map(DownloadImportInput.url)) }
        else { pendingOpenURLs.append(contentsOf: urls) }
        revealDownloadWindow()
    }

    func configureMenuBar(store: DownloadStore) {
        if self.store !== store {
            self.store = store
            downloadNavigation = store.downloadWindowRequests.sink { [weak self] in self?.revealDownloadWindow() }
            addPanelNavigation = store.addPanelRequests.sink { [weak self] in self?.revealDownloadWindow() }
            notificationNavigation = store.$notificationNavigationRevision.dropFirst().sink { [weak self] _ in
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

    private func revealDownloadWindow() {
        guard !AppLaunchConfiguration.isTestAutomation else { return }
        // Identifies a download window even when Settings is the current main window.
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "ChopChop.Downloads" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else { presentMainWindowIfNeeded() }
    }

    func removeMenuBarStatusItem() {
        menuBarController.remove()
    }

    private func presentMainWindowIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let hasVisibleWindow = NSApp.windows.contains { window in
                window.isVisible &&
                    !window.isMiniaturized &&
                    window.identifier?.rawValue == "ChopChop.Downloads"
            }
            guard !hasVisibleWindow else { return }
            self.openDownloadWindow?()
            NSApp.activate(ignoringOtherApps: true)
        }
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
            preferencesCancellable = store.$preferences
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
            item.button?.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "ChopChop")
            item.button?.imagePosition = .imageOnly
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            item.button?.toolTip = "ChopChop"
            statusItem = item
        }
    }

    private func ensurePopover() -> NSPopover? {
        guard let store else { return nil }
        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentSize = NSSize(width: 376, height: 520)
            popover.contentViewController = NSHostingController(rootView: MenuBarPanel().environmentObject(store))
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
