import SwiftUI

struct DownloadWindowActions {
    var newDownload: @MainActor () -> Void
    var pasteDownload: @MainActor () -> Void
    var openDownloadFile: @MainActor () -> Void
    var toggleDetails: @MainActor () -> Void
    var detailsPresented: Bool
    var hasSelection: Bool
    var canPresentDownload: Bool
}

private struct DownloadWindowActionsKey: FocusedValueKey {
    typealias Value = DownloadWindowActions
}

extension FocusedValues {
    var downloadWindowActions: DownloadWindowActions? {
        get { self[DownloadWindowActionsKey.self] }
        set { self[DownloadWindowActionsKey.self] = newValue }
    }
}

struct DownloadCommands: Commands {
    @ObservedObject var store: DownloadStore
    @FocusedValue(\.downloadWindowActions) private var actions

    private var engineReady: Bool {
        guard actions != nil, !store.isUpdatingEngine else { return false }
        if case .running = store.runtime.phase { return true }
        return false
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(String(localized: "New Download…")) { actions?.newDownload() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions?.canPresentDownload != true)
            Button(String(localized: "Open Download File…")) { actions?.openDownloadFile() }
                .keyboardShortcut("o")
                .disabled(actions?.canPresentDownload != true)
            Button(String(localized: "Paste Download Link…")) { actions?.pasteDownload() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(actions?.canPresentDownload != true)
        }
        CommandGroup(replacing: .sidebar) {
            Button(actions?.detailsPresented == true ? String(localized: "Hide Details") : String(localized: "Show Details")) {
                actions?.toggleDetails()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(actions?.hasSelection != true)
        }
        CommandMenu(String(localized: "Downloads")) {
            Button(String(localized: "Refresh Downloads")) { Task { await store.refreshTasks() } }
                .keyboardShortcut("r")
                .disabled(!engineReady)
            Divider()
            Button(String(localized: "Show in Finder")) {
                if let task = store.selectedTask { store.showInFinder(task) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(actions?.hasSelection != true || store.selectedTask.flatMap { DownloadFileLocation.revealURL(for: $0) } == nil)
            Button(String(localized: "Pause Download")) {
                if let task = store.selectedTask { Task { await store.pause(task) } }
            }
            .disabled(!engineReady || store.selectedTask?.primaryControlAction != .pause)
            Button(String(localized: "Resume Download")) {
                if let task = store.selectedTask { Task { await store.resume(task) } }
            }
            .disabled(!engineReady || store.selectedTask?.primaryControlAction != .resume)
            Button(String(localized: "Edit and Add Again…")) {
                if let task = store.selectedTask { store.editAndAddAgain(task) }
            }
            .disabled(store.selectedTask?.canEditAndAddAgain != true || store.isUpdatingEngine)
            Button(String(localized: "Remove Download…")) {
                if let task = store.selectedTask { store.beginRemove(task) }
            }
            .disabled(store.isUpdatingEngine || actions?.hasSelection != true)
            Divider()
            Button(String(localized: "Pause All")) { Task { await store.pauseAll() } }
                .disabled(!engineReady)
            Button(String(localized: "Force Pause All")) { Task { await store.forcePauseAll() } }
                .disabled(!engineReady)
            Button(String(localized: "Resume All")) { Task { await store.resumeAll() } }
                .disabled(!engineReady)
            Button(String(localized: "Clear Finished Records")) { Task { await store.purgeCompletedRecords() } }
                .disabled(!store.canClearFinishedRecords)
            Divider()
            Menu(String(localized: "Engine")) {
                Button(String(localized: "Start Engine")) { Task { await store.startEngine() } }
                    .disabled(!store.canStartEngine)
                Button(String(localized: "Restart Engine")) { Task { await store.restartEngine() } }
                    .disabled(!store.canRestartEngine)
                Button(String(localized: "Stop Engine")) { Task { await store.stopEngine() } }
                    .disabled(!store.canStopEngine)
            }
        }
    }
}
