import SwiftUI

struct DownloadWindowActions {
    var newDownload: @MainActor () -> Void = {}
    var pasteDownload: @MainActor () -> Void = {}
    var openDownloadFile: @MainActor () -> Void = {}
    var toggleDetails: @MainActor () -> Void = {}
    var detailsPresented: Bool = false
    var hasSelection: Bool = false
    var canPresentDownload: Bool = false
    var showDetails: (@MainActor (TaskDetailSection?) -> Void)? = nil
    var searchCommands: (@MainActor () -> Void)? = nil
    var searchDownloads: (@MainActor () -> Void)? = nil
    var openEngineSettings: (@MainActor () -> Void)? = nil
    var checkUpdates: (@MainActor () -> Void)? = nil
    var openDiagnostics: (@MainActor () -> Void)? = nil
    var openHelp: (@MainActor () -> Void)? = nil
}

private struct DownloadWindowActionsKey: FocusedValueKey {
    typealias Value = DownloadWindowActions
}

private struct DownloadListContextKey: FocusedValueKey {
    typealias Value = DownloadActionContext
}

extension FocusedValues {
    var downloadWindowActions: DownloadWindowActions? {
        get { self[DownloadWindowActionsKey.self] }
        set { self[DownloadWindowActionsKey.self] = newValue }
    }
    var downloadListContext: DownloadActionContext? {
        get { self[DownloadListContextKey.self] }
        set { self[DownloadListContextKey.self] = newValue }
    }
}

struct DownloadCommands: Commands {
    let store: DownloadStore
    @FocusedValue(\.downloadWindowActions) private var actions
    @FocusedValue(\.downloadListContext) private var listContext

    private var context: DownloadActionContext {
        DownloadActionContext(store: store, taskID: actions == nil ? nil : store.selectedTaskID, window: actions, taskIDs: actions == nil ? [] : store.selectedTaskIDs)
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            DownloadActionButton(action: .newDownload, context: context, usesShortcut: true)
            DownloadActionButton(action: .openFile, context: context, usesShortcut: true)
            DownloadActionButton(action: .pasteLink, context: context, usesShortcut: true)
        }
        CommandGroup(after: .textEditing) {
            DownloadActionButton(action: .searchDownloads, context: context, usesShortcut: true)
        }
        CommandGroup(replacing: .sidebar) {
            Button(actions?.detailsPresented == true ? String(localized: "Hide Details") : String(localized: "Show Details")) {
                actions?.toggleDetails()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(actions?.hasSelection != true)
        }
        CommandMenu(String(localized: "Downloads")) {
            Button(String(localized: "Search Commands…")) { actions?.searchCommands?() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(actions?.searchCommands == nil)
            DownloadActionButton(action: .refresh, context: context, usesShortcut: true)
            Divider()
            DownloadActionButton(action: .reveal, context: context, usesShortcut: true)
            ForEach([DownloadAction.pause, .resume, .speedLimits, .schedule, .editAgain, .remove]) { action in
                // Text editors retain Command-Delete (delete to the start of the line).
                // Only the focused task list registers the removal shortcut.
                DownloadActionButton(action: action, context: action == .remove ? listContext ?? context : context,
                                     usesShortcut: action == .remove && listContext != nil)
            }
            Divider()
            ForEach([DownloadAction.pauseAll, .forcePauseAll, .resumeAll, .clearFinished]) { action in
                DownloadActionButton(action: action, context: context)
            }
            Divider()
            Menu(String(localized: "Engine")) {
                ForEach([DownloadAction.startEngine, .restartEngine, .stopEngine, .engineSettings]) { action in
                    DownloadActionButton(action: action, context: context)
                }
            }
        }
    }
}
