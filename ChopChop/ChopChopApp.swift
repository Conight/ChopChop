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

    init() {
        AppLaunchConfiguration.prepare()
        _store = StateObject(wrappedValue: DownloadStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
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
            SidebarCommands()
            DownloadCommands(store: store)
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
        .defaultSize(width: 860, height: 640)
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
    private let menuBarController = MenuBarStatusController()
    private weak var store: DownloadStore?
    private var isFinishingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        presentMainWindowIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeMenuBarStatusItem()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppLaunchConfiguration.isTestAutomation else { return .terminateNow }
        guard !isFinishingTermination else { return .terminateNow }
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

    func configureMenuBar(store: DownloadStore) {
        self.store = store
        menuBarController.configure(store: store)
    }

    func removeMenuBarStatusItem() {
        menuBarController.remove()
    }

    private func presentMainWindowIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let hasVisibleWindow = NSApp.windows.contains { window in
                window.isVisible &&
                    !window.isMiniaturized &&
                    window.canBecomeMain &&
                    window.level == .normal
            }
            guard !hasVisibleWindow else { return }
            let didOpenWindow = self.openNewWindowFromSystemMenu()
            if !didOpenWindow {
                NSApp.sendAction(#selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func openNewWindowFromSystemMenu() -> Bool {
        guard let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu,
              let newWindowItem = fileMenu.items.first(where: { $0.title == "New Window" }),
              newWindowItem.isEnabled,
              let action = newWindowItem.action else {
            return false
        }

        return NSApp.sendAction(action, to: newWindowItem.target, from: newWindowItem)
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
