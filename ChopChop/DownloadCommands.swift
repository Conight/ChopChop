import SwiftUI

struct DownloadWindowActions {
    var newDownload: @MainActor () -> Void
    var pasteDownload: @MainActor () -> Void
    var toggleInspector: @MainActor () -> Void
    var inspectorPresented: Bool
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
            Button("New Download…") { actions?.newDownload() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions?.canPresentDownload != true)
            Button("Paste Download Link…") { actions?.pasteDownload() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(actions?.canPresentDownload != true)
        }
        CommandGroup(after: .sidebar) {
            Button(actions?.inspectorPresented == true ? "Hide Details" : "Show Details") {
                actions?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(actions?.hasSelection != true)
        }
        CommandMenu("Downloads") {
            Button("Refresh Downloads") { Task { await store.refreshTasks() } }
                .keyboardShortcut("r")
                .disabled(!engineReady)
            Divider()
            Button("Pause Download") {
                if let task = store.selectedTask { Task { await store.pause(task) } }
            }
            .disabled(!engineReady || store.selectedTask?.primaryControlAction != .pause)
            Button("Resume Download") {
                if let task = store.selectedTask { Task { await store.resume(task) } }
            }
            .disabled(!engineReady || store.selectedTask?.primaryControlAction != .resume)
            Button("Remove Download…") {
                if let task = store.selectedTask { store.beginRemove(task) }
            }
            .disabled(!engineReady || actions?.hasSelection != true)
            Divider()
            Button("Pause All") { Task { await store.pauseAll() } }
                .disabled(!engineReady)
            Button("Force Pause All") { Task { await store.forcePauseAll() } }
                .disabled(!engineReady)
            Button("Resume All") { Task { await store.resumeAll() } }
                .disabled(!engineReady)
            Button("Clear Finished Records") { Task { await store.purgeCompletedRecords() } }
                .disabled(!engineReady)
            Divider()
            Menu("Engine") {
                Button("Start Engine") { Task { await store.startEngine() } }
                    .disabled(!store.canStartEngine)
                Button("Restart Engine") { Task { await store.restartEngine() } }
                    .disabled(!store.canRestartEngine)
                Button("Stop Engine") { Task { await store.stopEngine() } }
                    .disabled(!store.canStopEngine)
            }
        }
    }
}
