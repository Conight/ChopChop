import AppKit
import SwiftUI

/// Stable identifiers shared by menus, contextual actions and command search.
/// Display strings never identify a command or locate a window.
enum DownloadAction: String, CaseIterable, Identifiable {
    case newDownload, pasteLink, openFile, details, reveal, pause, resume, editAgain, remove
    case finishRecording, retryMedia, moveToTop, speedLimits, schedule
    case refresh, pauseAll, forcePauseAll, resumeAll, clearFinished
    case startEngine, restartEngine, stopEngine, engineSettings, checkUpdates, diagnostics, help
    var id: String { rawValue }

    var title: String { L10n.key(titleKey) }
    var titleKey: String {
        switch self {
        case .newDownload: "New Download…"
        case .pasteLink: "Paste Download Link…"
        case .openFile: "Open Download File…"
        case .details: "Show Details"
        case .reveal: "Show in Finder"
        case .pause: "Pause Download"
        case .resume: "Resume Download"
        case .editAgain: "Edit and Add Again…"
        case .remove: "Remove Download…"
        case .finishRecording: "Finish Recording and Save"
        case .retryMedia: "Retry with Saved Progress"
        case .moveToTop: "Move to Top of Queue"
        case .speedLimits: "Set Task Speed Limits…"
        case .schedule: "Schedule Download…"
        case .refresh: "Refresh Downloads"
        case .pauseAll: "Pause All"
        case .forcePauseAll: "Force Pause All"
        case .resumeAll: "Resume All"
        case .clearFinished: "Clear Finished Records"
        case .startEngine: "Start Engine"
        case .restartEngine: "Restart Engine"
        case .stopEngine: "Stop Engine"
        case .engineSettings: "Engine Settings…"
        case .checkUpdates: "Check ChopChop Updates…"
        case .diagnostics: "Preview Diagnostic Report"
        case .help: "ChopChop Help"
        }
    }
    var symbol: String {
        switch self {
        case .newDownload: "plus"
        case .pasteLink: "doc.on.clipboard"
        case .openFile: "doc"
        case .details, .help: "info.circle"
        case .reveal: "folder"
        case .pause, .pauseAll, .forcePauseAll: "pause"
        case .resume, .resumeAll, .startEngine: "play"
        case .editAgain: "square.and.pencil"
        case .remove, .clearFinished: "trash"
        case .finishRecording, .stopEngine: "stop"
        case .retryMedia, .refresh, .restartEngine: "arrow.clockwise"
        case .moveToTop: "arrow.up.to.line"
        case .speedLimits: "speedometer"
        case .schedule: "calendar"
        case .engineSettings: "cpu"
        case .checkUpdates: "arrow.down.circle"
        case .diagnostics: "stethoscope"
        }
    }
    var group: String {
        switch self {
        case .newDownload, .pasteLink, .openFile: L10n.key("Add Download")
        case .details, .reveal, .pause, .resume, .editAgain, .remove, .finishRecording, .retryMedia, .moveToTop, .speedLimits, .schedule:
            L10n.key("Selected Download")
        case .refresh, .pauseAll, .forcePauseAll, .resumeAll, .clearFinished: L10n.key("Downloads")
        case .startEngine, .restartEngine, .stopEngine, .engineSettings: L10n.key("Engine")
        case .checkUpdates, .diagnostics, .help: "ChopChop"
        }
    }
    @MainActor func title(in context: DownloadActionContext) -> String {
        guard context.tasks.count > 1 else { return title }
        switch self {
        case .pause: return String(localized: "Pause Selected Downloads")
        case .resume: return String(localized: "Resume Selected Downloads")
        case .remove: return String(localized: "Remove Selected Downloads…")
        default: return title
        }
    }
    var shortcut: KeyboardShortcut? {
        switch self {
        case .newDownload: KeyboardShortcut("n", modifiers: [.command, .shift])
        case .pasteLink: KeyboardShortcut("v", modifiers: [.command, .shift])
        case .openFile: KeyboardShortcut("o")
        case .details: KeyboardShortcut("i", modifiers: [.command, .option])
        case .reveal: KeyboardShortcut("r", modifiers: [.command, .shift])
        case .refresh: KeyboardShortcut("r")
        default: nil
        }
    }
    var shortcutLabel: String? {
        switch self {
        case .newDownload: "⇧⌘N"
        case .pasteLink: "⇧⌘V"
        case .openFile: "⌘O"
        case .details: "⌥⌘I"
        case .reveal: "⇧⌘R"
        case .refresh: "⌘R"
        default: nil
        }
    }

    @MainActor static func engineReady(in store: DownloadStore) -> Bool {
        if case .running = store.runtime.phase { return !store.isUpdatingEngine }
        return false
    }

    @MainActor func isEnabled(in context: DownloadActionContext) -> Bool {
        let store = context.store, task = context.task
        let ready = Self.engineReady(in: store) && !store.isPerformingBatchOperation
        switch self {
        case .newDownload, .pasteLink, .openFile: return context.window?.canPresentDownload == true
        case .details: return task != nil && context.window?.showDetails != nil
        case .reveal: return context.tasks.contains { DownloadFileLocation.revealURL(for: $0) != nil }
        case .pause: return ready && context.tasks.contains { $0.primaryControlAction == .pause }
        case .resume: return ready && context.tasks.contains { $0.primaryControlAction == .resume }
        case .editAgain: return !store.isUpdatingEngine && task?.canEditAndAddAgain == true
        case .remove: return !store.isUpdatingEngine && !store.isPerformingBatchOperation && !context.tasks.isEmpty
        case .finishRecording: return ready && task?.canFinishRecording == true
        case .retryMedia: return ready && task?.canRetryMedia == true
        case .moveToTop: return ready && task?.isAvailableInEngine == true && task?.queuePosition != nil
        case .speedLimits, .schedule:
            return ready && context.window?.showDetails != nil && task?.isAvailableInEngine == true && task?.primaryControlAction != nil && task?.requiresFileSelection == false
        case .refresh, .pauseAll, .forcePauseAll, .resumeAll: return ready
        case .clearFinished: return !store.isUpdatingEngine && store.canClearFinishedRecords
        case .startEngine: return store.canStartEngine
        case .restartEngine: return store.canRestartEngine
        case .stopEngine: return store.canStopEngine
        case .engineSettings: return context.window?.openEngineSettings != nil
        case .checkUpdates: return context.window?.checkUpdates != nil
        case .diagnostics: return context.window?.openDiagnostics != nil
        case .help: return context.window?.openHelp != nil
        }
    }

    /// Revalidate immediately before dispatch; a menu or palette may have been open during an RPC refresh.
    @MainActor @discardableResult func perform(in context: DownloadActionContext) -> Bool {
        guard isEnabled(in: context) else { return false }
        let store = context.store, task = context.task
        switch self {
        case .newDownload: context.window?.newDownload()
        case .pasteLink: context.window?.pasteDownload()
        case .openFile: context.window?.openDownloadFile()
        case .details: context.window?.showDetails?(nil)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting(context.tasks.compactMap { DownloadFileLocation.revealURL(for: $0) })
        case .pause: if let task { Task { await store.pause(task) } } else { Task { await store.controlSelected(context.ids, action: .pause) } }
        case .resume: if let task { Task { await store.resume(task) } } else { Task { await store.controlSelected(context.ids, action: .resume) } }
        case .editAgain: if let task { store.editAndAddAgain(task) }
        case .remove: store.beginRemoveSelected(context.ids)
        case .finishRecording: if let task { Task { await store.finishRecording(task) } }
        case .retryMedia: if let task { Task { await store.retryMedia(task) } }
        case .moveToTop: if let task { Task { await store.moveQueuedTask(task.id) } }
        case .speedLimits: context.window?.showDetails?(.speedLimits)
        case .schedule: context.window?.showDetails?(.schedule)
        case .refresh: Task { await store.refreshTasks() }
        case .pauseAll: Task { await store.pauseAll() }
        case .forcePauseAll: Task { await store.forcePauseAll() }
        case .resumeAll: Task { await store.resumeAll() }
        case .clearFinished: Task { await store.purgeCompletedRecords() }
        case .startEngine: Task { await store.startEngine() }
        case .restartEngine: Task { await store.restartEngine() }
        case .stopEngine: Task { await store.stopEngine() }
        case .engineSettings: context.window?.openEngineSettings?()
        case .checkUpdates: context.window?.checkUpdates?()
        case .diagnostics: context.window?.openDiagnostics?()
        case .help: context.window?.openHelp?()
        }
        return true
    }
}

@MainActor struct DownloadActionContext {
    let store: DownloadStore
    var taskID: String?
    var window: DownloadWindowActions?
    var taskIDs: Set<String>?
    var ids: Set<String> { taskIDs ?? taskID.map { [$0] } ?? [] }
    var tasks: [DownloadTask] { store.tasks.filter { ids.contains($0.id) } }
    var task: DownloadTask? { tasks.count == 1 ? tasks.first : nil }
}

struct DownloadActionButton: View {
    let action: DownloadAction
    let context: DownloadActionContext
    var usesShortcut = false
    var body: some View {
        Button(role: action == .remove ? .destructive : nil) { action.perform(in: context) } label: {
            Label(action.title(in: context), systemImage: action.symbol)
        }
        .keyboardShortcut(usesShortcut ? action.shortcut : nil)
        .disabled(!action.isEnabled(in: context))
    }
}
