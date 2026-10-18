import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// App-wide import actions remain available when an auxiliary window is frontmost.
/// The main window owns the draft sheet; this object only owns the file chooser.
@MainActor final class DownloadInputPresentation: ObservableObject {
    @Published private(set) var isChoosingFile = false

    func canPresent(in store: DownloadStore) -> Bool {
        store.engineSetupState == .ready && store.inputCoordinator.owner == nil &&
            store.removalRequest == nil && !isChoosingFile
    }

    private func canBegin(in store: DownloadStore) -> Bool {
        canPresent(in: store) && NSApp.keyWindow?.attachedSheet == nil && NSApp.keyWindow?.sheetParent == nil
    }

    func newDownload(in store: DownloadStore) {
        guard canBegin(in: store) else { return }
        store.requestAddPanel()
    }

    func pasteDownload(in store: DownloadStore) {
        guard canBegin(in: store) else { return }
        let inputs = Self.clipboardInputs(from: .general)
        guard !inputs.isEmpty else {
            store.postError(String(localized: "Clipboard does not contain a download link."), title: String(localized: "Paste Failed"))
            return
        }
        store.importDownloads(inputs)
        store.downloadWindowRequests.send()
    }

    static func clipboardInputs(from pasteboard: NSPasteboard) -> [DownloadImportInput] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.map(DownloadImportInput.url)
        }
        guard let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [.text(text)]
    }

    func openDownloadFile(in store: DownloadStore) {
        guard canBegin(in: store) else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open Download File")
        panel.prompt = String(localized: "Open")
        panel.allowedContentTypes = ["torrent", "metalink", "meta4"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        isChoosingFile = true
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            self.isChoosingFile = false
            guard response == .OK else { return }
            store.importDownloads(panel.urls.map(DownloadImportInput.url))
            store.downloadWindowRequests.send()
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

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

private struct SettingsSearchActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var settingsSearchAction: (@MainActor () -> Void)? {
        get { self[SettingsSearchActionKey.self] }
        set { self[SettingsSearchActionKey.self] = newValue }
    }
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
    @ObservedObject var inputPresentation: DownloadInputPresentation
    @ObservedObject var inputCoordinator: DownloadInputCoordinator
    @FocusedValue(\.downloadWindowActions) private var actions
    @FocusedValue(\.downloadListContext) private var listContext
    @FocusedValue(\.settingsSearchAction) private var searchSettings

    init(store: DownloadStore, inputPresentation: DownloadInputPresentation) {
        self.store = store
        self.inputPresentation = inputPresentation
        self.inputCoordinator = store.inputCoordinator
    }

    private var inputContext: DownloadActionContext {
        DownloadActionContext(store: store, window: DownloadWindowActions(
            newDownload: { inputPresentation.newDownload(in: store) },
            pasteDownload: { inputPresentation.pasteDownload(in: store) },
            openDownloadFile: { inputPresentation.openDownloadFile(in: store) },
            canPresentDownload: inputPresentation.canPresent(in: store)))
    }

    private var context: DownloadActionContext {
        DownloadActionContext(store: store, taskID: actions == nil ? nil : store.selectedTaskID, window: actions, taskIDs: actions == nil ? [] : store.selectedTaskIDs)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            DownloadActionButton(action: .newDownload, context: inputContext, usesShortcut: true)
            DownloadActionButton(action: .openFile, context: inputContext, usesShortcut: true)
            DownloadActionButton(action: .pasteLink, context: inputContext, usesShortcut: true)
        }
        CommandGroup(after: .textEditing) {
            Button(searchSettings == nil ? DownloadAction.searchDownloads.title : String(localized: "Search Settings…")) {
                if let searchSettings { searchSettings() }
                else { actions?.searchDownloads?() }
            }
            .keyboardShortcut("f")
            .disabled(searchSettings == nil && actions?.searchDownloads == nil)
        }
        CommandGroup(before: .windowList) {
            Button(String(localized: "Show Downloads")) { store.downloadWindowRequests.send() }
                .keyboardShortcut("0", modifiers: .command)
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
            ForEach([DownloadAction.pause, .resume, .speedLimits, .schedule, .finishRecording, .retryMedia, .moveToTop, .editAgain, .remove]) { action in
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
