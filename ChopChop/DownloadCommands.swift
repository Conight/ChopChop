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
    var openEngineSettings: (@MainActor () -> Void)? = nil
    var checkUpdates: (@MainActor () -> Void)? = nil
    var openDiagnostics: (@MainActor () -> Void)? = nil
    var openHelp: (@MainActor () -> Void)? = nil
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

    private var context: DownloadActionContext {
        DownloadActionContext(store: store, taskID: actions == nil ? nil : store.selectedTaskID, window: actions, taskIDs: actions == nil ? [] : store.selectedTaskIDs)
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            DownloadActionButton(action: .newDownload, context: context, usesShortcut: true)
            DownloadActionButton(action: .openFile, context: context, usesShortcut: true)
            DownloadActionButton(action: .pasteLink, context: context, usesShortcut: true)
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
                DownloadActionButton(action: action, context: context)
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
