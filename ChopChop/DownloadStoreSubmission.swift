import Combine
import Foundation

extension DownloadStore {
    func rememberSubmittedTasks(_ gids: [String], draft: AddDownloadDraft) {
        taskRevision += 1
        notifications.noteAdded(gids)
        let newTasks = DownloadHistoryStore.submittedTasks(gids, draft: draft)
        let ids = Set(gids)
        tasks.removeAll { ids.contains($0.id) }
        tasks.append(contentsOf: newTasks)
        persistTaskHistory()
    }

    func editAndAddAgain(_ task: DownloadTask) {
        guard task.canEditAndAddAgain, inputCoordinator.owner == nil, !inputCoordinator.hasManualRequest else { return }
        addDraft = defaultAddDraft()
        addDraft.savePath = task.destination
        addDraft.rawInput = task.sourceURL ?? ""
        if addDraft.rawInput.isEmpty, task.isTorrentLike, let hash = task.infoHash, AddDownloadDraft.isBareBitTorrentInfoHash(hash) {
            addDraft.rawInput = "magnet:?xt=urn:btih:\(hash)"
        }
        addDraftNotice = String(localized: "This creates a new download. Review the link and add any required authentication again. Existing partial files are preserved by the engine's filename collision policy.")
        inputCoordinator.requestManualSheet()
        addPanelRequests.send()
    }

    var canClearFinishedRecords: Bool {
        !isUpdatingEngine && tasks.contains { $0.removalAction == .removeDownloadResult }
    }

    @discardableResult
    func submitDraft() async -> Bool {
        guard !browserSubmissionIsUncertain() else {
            postError(String(localized: "The previous submission result is unknown. Check Downloads before creating another task."), title: String(localized: "Submission Needs Review"))
            return false
        }
        guard addDraft.isSubmittable else {
            postError(DownloadDraftError.unsupportedProtocol, title: String(localized: "Invalid Download"))
            return false
        }
        guard engineController.isRunning else {
            postError(String(localized: "The engine is unavailable. Open Engine settings to retry the connection."), title: String(localized: "Engine Not Running"))
            return false
        }
        if let capabilities = engineCapabilities {
            do {
                for source in try addDraft.normalizedResources() {
                    if let kind = AddDownloadDraft.detectProtocol(for: source), !capabilities.supports(kind) {
                        postError(String(localized: "The running engine does not support \(kind.rawValue). Check Engine settings."), title: String(localized: "Unsupported Protocol"))
                        return false
                    }
                }
            } catch {
                postError(error, title: String(localized: "Invalid Download"))
                return false
            }
        }
        if addDraft.containsBitTorrentResource, !addDraft.shouldResolveBitTorrentFilesBeforeSubmit {
            postError(DownloadDraftError.bitTorrentSelectionRequiresSingleResource, title: String(localized: "Add Download Failed"))
            return false
        }
        if addDraft.shouldInspectMedia {
            guard engineCapabilities?.supportsMedia == true else {
                postError(String(localized: "The running engine does not advertise media track selection. Update Aria2 Next in Settings → Updates."), title: String(localized: "Media Unavailable"))
                return false
            }
            do {
                try await mediaDownloads.inspect(addDraft, using: engineController.client(), fallbackDirectory: engineSettings.downloadDirectoryPath)
                _ = await refreshTasks(reportErrors: false)
            } catch { noteUncertainBrowserSubmission(error, requestID: addDraft.browserRequestID); postError(error, title: String(localized: "Inspect Media Failed")) }
            return false
        }
        if addDraft.shouldResolveBitTorrentFilesBeforeSubmit {
            await prepareBitTorrentFileSelection()
            return false
        }
        if ((try? addDraft.normalizedResources()) ?? []).contains(where: { AddDownloadDraft.detectProtocol(for: $0) == .ed2k }),
           !ed2kDownloadContext().hasBootstrapOrServer {
            postError(
                String(localized: "Sync ED2K bootstrap files or add ED2K servers in Settings before adding ED2K downloads."),
                title: String(localized: "Add Download Failed")
            )
            return false
        }
        let submissionDraft = addDraft
        let owner = inputCoordinator.owner
        do {
            let client = try engineController.client()
            let gids = try await client.addDownloads(
                submissionDraft,
                fallbackDirectory: engineSettings.downloadDirectoryPath,
                autoOrganize: preferences.autoOrganizeFiles,
                ed2kContext: ed2kDownloadContext()
            )
            rememberSubmittedTasks(gids, draft: submissionDraft)
            noteBrowserTasks(gids, confirmed: true, requestID: submissionDraft.browserRequestID, owner: owner)
            selectedTaskID = gids.first
            if inputCoordinator.owner == owner {
                addDraftNotice = nil
                addDraft = defaultAddDraft()
            }
            let saveError = await saveSessionAfterTaskMutation(using: client)
            _ = await refreshTasks(reportErrors: false)
            if let saveError {
                postError(saveError, title: String(localized: "Save Session Failed"))
            } else {
                postActivity(String(localized: "Added \(gids.count) downloads."))
            }
            return true
        } catch let partial as PartialDownloadSubmissionError {
            rememberSubmittedTasks(partial.addedIDs, draft: submissionDraft)
            noteBrowserTasks(partial.addedIDs, requestID: submissionDraft.browserRequestID)
            if let id = submissionDraft.browserRequestID { browserCapture.receiptStore.update(id) { $0.state = .unknown } }
            if inputCoordinator.owner == owner { addDraft.rawInput = submissionDraft.resourceLines.dropFirst(partial.addedIDs.count).joined(separator: "\n") }
            if let client = try? engineController.client() { _ = await saveSessionAfterTaskMutation(using: client) }
            _ = await refreshTasks(reportErrors: false)
            postError(partial, title: String(localized: "Some Downloads Were Added"))
            return false
        } catch {
            noteUncertainBrowserSubmission(error, requestID: submissionDraft.browserRequestID)
            postError(error, title: String(localized: "Add Download Failed"))
            return false
        }
    }

    func confirmMediaSelection() async -> Bool {
        do {
            let browserMediaID = mediaDownloads.gid
            let browserID = addDraft.browserRequestID
            let owner = inputCoordinator.owner
            let confirmed = await mediaDownloads.confirm(using: try engineController.client(), startPaused: addDraft.startPaused)
            if confirmed {
                noteBrowserTasks(browserMediaID.map { [$0] } ?? [], confirmed: true, requestID: browserID, owner: owner)
                if inputCoordinator.owner == owner { addDraft = defaultAddDraft() }
                _ = await refreshTasks(reportErrors: false)
            }
            return confirmed
        } catch { postError(error, title: String(localized: "Start Media Failed")); return false }
    }

    func cancelMediaSelection() async {
        guard mediaDownloads.isPresented else { return }
        inputCoordinator.cancelManualRequest()
        await mediaDownloads.cancel(using: try? engineController.client())
        _ = await refreshTasks(reportErrors: false)
    }

}
