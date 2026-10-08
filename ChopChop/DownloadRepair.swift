import SwiftUI

nonisolated struct DownloadConnectionRepair: Sendable {
    var authorization = ""
    var cookie = ""
    var referer = ""
    var replacementURL = ""
    var clearAuthentication = false

    func options(existing: [String: String]) throws -> [String: String] {
        for value in [authorization, cookie, referer] {
            guard !value.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw DownloadOperationError(String(localized: "Request fields cannot contain newlines."))
            }
        }
        var headers = (existing["header"] ?? "").components(separatedBy: .newlines).filter { !$0.isEmpty }
        for (key, value) in [("Authorization", authorization), ("Cookie", cookie)] {
            if clearAuthentication || !value.isEmpty {
                headers.removeAll { $0.split(separator: ":", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame }
                if !value.isEmpty { headers.append("\(key): \(value)") }
            }
        }
        var result: [String: String] = [:]
        if clearAuthentication || !authorization.isEmpty || !cookie.isEmpty { result["header"] = headers.joined(separator: "\n") }
        if !referer.isEmpty { result["referer"] = referer }
        return result
    }

    func validatedReplacement(for task: DownloadTask, original: String) throws -> String? {
        let candidate = replacementURL.trimmedForEngine
        guard !candidate.isEmpty, candidate != original else { return nil }
        guard task.media == nil, task.status == .paused, task.completedLength == 0,
              task.files.allSatisfy({ $0.completedLength == 0 }), task.files.count <= 1,
              let old = URLComponents(string: original), let new = URLComponents(string: candidate),
              ["http", "https"].contains(new.scheme?.lowercased() ?? ""),
              new.user == nil, new.password == nil, new.fragment == nil, let host = new.host, !host.isEmpty,
              new.scheme?.lowercased() == old.scheme?.lowercased(), host.lowercased() == old.host?.lowercased(),
              (new.port ?? (new.scheme == "https" ? 443 : 80)) == (old.port ?? (old.scheme == "https" ? 443 : 80)) else {
            throw DownloadOperationError(String(localized: "This source cannot be replaced safely. Add a new download for a different host, media presentation, or a task that already has partial data."))
        }
        return candidate
    }
}

nonisolated extension DownloadTask {
    var canRepairConnection: Bool {
        isAvailableInEngine && ((status == .paused && (protocolKind == .http || media != nil) && !requiresFileSelection) || canRetryMedia)
    }
}

struct DownloadRepairView: View {
    @EnvironmentObject private var store: DownloadStore
    let task: DownloadTask
    @State private var repair = DownloadConnectionRepair()
    @State private var busy = false
    @State private var issue: String?
    @State private var isExpanded: Bool
    init(task: DownloadTask, initiallyExpanded: Bool = false) {
        self.task = task
        _isExpanded = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        if task.canRepairConnection {
            DisclosureGroup(String(localized: "Repair Connection"), isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField(String(localized: "Authorization (leave empty to keep)"), text: $repair.authorization)
                    SecureField(String(localized: "Cookie (leave empty to keep)"), text: $repair.cookie)
                    TextField(String(localized: "Referer (optional)"), text: $repair.referer)
                    Toggle(String(localized: "Clear existing Authorization and Cookie"), isOn: $repair.clearAuthentication)
                    if task.media == nil && task.completedLength == 0 {
                        TextField(String(localized: "Replacement URL (optional, same host)"), text: $repair.replacementURL)
                    }
                    Text(String(localized: "Updates only this task. Authentication is sent to the engine and is not copied into ChopChop history or diagnostics. Existing partial data and the GID are kept."))
                        .font(.caption).foregroundStyle(.secondary)
                    if task.completedLength > 0 || task.media != nil {
                        Text(String(localized: "For a new source address, use Edit and Add Again. Partial data cannot safely be matched by filename alone."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(task.status == .failed ? String(localized: "Apply and Retry with Saved Progress") : String(localized: "Apply and Resume")) {
                        busy = true; issue = nil
                        Task {
                            defer { busy = false }
                            do { try await store.repairConnection(task, repair: repair); repair = DownloadConnectionRepair() }
                            catch { issue = DownloadPrivacy.redact(error.localizedDescription) }
                        }
                    }.buttonStyle(.borderedProminent)
                    if let issue { Text(issue).font(.caption).foregroundStyle(.red) }
                }.nativeTextFieldStyle().padding(.top, 8).disabled(busy)
            }
            .onDisappear { repair = DownloadConnectionRepair() }
        }
    }
}
