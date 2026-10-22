import Combine
import Foundation

extension DownloadStore {
    func configureBrowserReceipts() {
        if !AppLaunchConfiguration.isTestAutomation, let directory = try? Aria2NextPaths.supportDirectory() {
            browserCapture.receiptStore = BrowserReceiptStore(file: directory.appendingPathComponent("browser-receipts.json"))
        }
        browserCapture.onSubmission = { [weak self] submission in self?.importBrowserSubmission(submission) }
        browserCapture.onReadTasks = { [weak self] ids in
            guard let self else { return [] }
            return ids.compactMap { id in
                guard let task = self.tasks.first(where: { $0.id == id }) else { return nil }
                return ["id": task.id, "name": DownloadPrivacy.redact(task.name), "status": task.status.rawValue,
                        "completed": task.completedLength, "total": task.totalLength,
                        "speed": task.isAvailableInEngine ? task.downloadSpeed : 0,
                        "available": task.isAvailableInEngine] as [String: Any]
            }
        }
        browserCapture.onRevealTasks = { [weak self] ids in
            guard let self else { return }
            self.searchQuery = ""
            self.selectedDestination = .all
            self.selectedTaskIDs = Set(ids).intersection(Set(self.tasks.map(\.id)))
            self.downloadWindowRequests.send()
        }
    }

    func importBrowserSubmission(_ submission: BrowserSubmission) {
        let preceding = inputTask
        let preferences = preferences
        inputTask = Task { @MainActor [weak self] in
            await preceding?.value
            guard let self, !Task.isCancelled, !self.isShuttingDown else { return }
            var requests = await DownloadImportReader.prepare(submission.urls.map(DownloadImportInput.text), preferences: preferences)
            guard !Task.isCancelled, !self.isShuttingDown else { return }
            for index in requests.indices {
                requests[index].browserRequestID = submission.requestID
                requests[index].browserContext = submission.context
            }
            self.browserCapture.receiptStore.update(submission.requestID) { receipt in
                receipt.remainingParts = requests.count
                receipt.cancelledPart = requests.contains { !$0.issues.isEmpty }
                if requests.isEmpty || requests.allSatisfy({ $0.resources.isEmpty }) { receipt.state = .cancelled }
            }
            self.inputCoordinator.enqueue(requests)
            self.downloadWindowRequests.send()
        }
    }

    func noteBrowserTasks(_ ids: [String], confirmed: Bool = false, requestID: UUID?, owner: UUID? = nil) {
        guard let id = requestID else { return }
        let stillOwned = inputCoordinator.owner == owner && inputCoordinator.browserRequestID == id
        browserCapture.receiptStore.update(id) { receipt in
            receipt.taskIDs = Array(Set(receipt.taskIDs + ids).sorted().prefix(100))
            if confirmed && !stillOwned { receipt.state = .unknown }
        }
        if confirmed && stillOwned { browserPartConfirmed = true }
    }

    func browserSubmissionIsUncertain() -> Bool {
        guard let id = inputCoordinator.browserRequestID else { return false }
        return browserCapture.receiptStore.receipts[id]?.state == .unknown
    }

    func noteUncertainBrowserSubmission(_ error: Error, requestID: UUID?) {
        guard let id = requestID else { return }
        let uncertain: Bool
        if error is URLError || error is CancellationError { uncertain = true }
        else if let error = error as? RPCError {
            switch error {
            case .nonHTTPResponse, .unexpectedHTTPStatus, .invalidResponseBody, .missingResult: uncertain = true
            case .invalidPort, .serverError, .tokenMissing: uncertain = false
            }
        } else { uncertain = false }
        if uncertain { browserCapture.receiptStore.update(id) { $0.state = .unknown } }
    }

    func finishBrowserPart() {
        guard let id = inputCoordinator.browserRequestID else { return }
        browserCapture.receiptStore.update(id) { receipt in
            guard receipt.state == .pending else { return }
            if isShuttingDown { receipt.state = .unknown; return }
            receipt.remainingParts = max(0, receipt.remainingParts - 1)
            receipt.cancelledPart = receipt.cancelledPart || !browserPartConfirmed
            if receipt.remainingParts == 0 {
                receipt.state = receipt.taskIDs.isEmpty ? .cancelled : (receipt.cancelledPart ? .partial : .created)
            }
        }
        browserPartConfirmed = false
    }
}
