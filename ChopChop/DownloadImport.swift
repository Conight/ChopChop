import AppKit
import Combine
import UniformTypeIdentifiers

nonisolated struct ImportedDownloadDocument: Equatable, Sendable {
    enum Kind: String, Sendable { case torrent, metalink }
    var kind: Kind
    var data: Data
}

nonisolated enum DownloadImportInput: Sendable {
    case url(URL)
    case text(String)
}

nonisolated struct DownloadImportRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    var resources: [String]
    var documents: [String: ImportedDownloadDocument] = [:]
    var issues: [String] = []
}

nonisolated enum DownloadImportReader {
    static let maximumDocumentBytes = 16 * 1024 * 1024
    static let maximumBatchBytes = 32 * 1024 * 1024
    static let maximumResources = 100

    @concurrent
    static func prepare(_ inputs: [DownloadImportInput], preferences: AppPreferences) async -> [DownloadImportRequest] {
        var requests: [DownloadImportRequest] = []
        var links: [String] = []
        var issues: [String] = []
        var seen: Set<String> = []
        var retainedBytes = 0
        var count = 0
        func flushLinks() {
            if !links.isEmpty { requests.append(.init(resources: links)); links = [] }
        }
        for input in inputs {
            let values: [String]
            let originalURL: URL?
            switch input {
            case .url(let url):
                originalURL = url
                values = [url.absoluteString]
            case .text(let text):
                originalURL = nil
                guard text.utf8.count <= 1024 * 1024 else {
                    issues.append(String(localized: "The dropped text is too large. Import at most 100 links at a time."))
                    continue
                }
                values = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            for raw in values {
                guard seen.insert(raw).inserted else { continue }
                count += 1
                guard count <= maximumResources else { continue }
                do {
                    if let url = originalURL ?? URL(string: raw), url.isFileURL {
                        let document = try readDocument(url, preferences: preferences)
                        guard retainedBytes + document.data.count <= maximumBatchBytes else {
                            issues.append(String(localized: "The imported documents exceed 32 MB. Open the remaining files separately."))
                            continue
                        }
                        retainedBytes += document.data.count
                        flushLinks()
                        requests.append(.init(resources: [raw], documents: [raw: document]))
                        continue
                    }
                    let resource = try AddDownloadDraft.normalizedResource(raw)
                    guard let kind = AddDownloadDraft.detectProtocol(for: resource),
                          let url = URL(string: resource),
                          ["http", "https", "sftp", "magnet", "ed2k"].contains(url.scheme?.lowercased() ?? ""),
                          !["http", "https", "sftp"].contains(url.scheme?.lowercased() ?? "") || url.host?.isEmpty == false else {
                        throw ImportError.unsupported
                    }
                    guard (kind != .magnet || preferences.handleMagnetLinks),
                          (kind != .ed2k || preferences.handleED2KLinks),
                          (kind != .bitTorrent || preferences.handleTorrentFiles),
                          (kind != .metalink || preferences.handleMetalinkFiles) else { throw ImportError.disabled }
                    if kind == .magnet || kind == .bitTorrent || AddDownloadDraft.isMediaManifest(resource) {
                        flushLinks()
                        requests.append(.init(resources: [resource]))
                    } else {
                        links.append(resource)
                    }
                } catch {
                    issues.append(DownloadPrivacy.redact(error.localizedDescription))
                }
            }
        }
        flushLinks()
        if count > maximumResources { issues.append(String(localized: "Only the first 100 items were imported. Open the remaining items separately.")) }
        if !issues.isEmpty {
            let uniqueIssues = Array(Set(issues)).sorted()
            if requests.isEmpty { requests.append(.init(resources: [], issues: uniqueIssues)) }
            else { requests[0].issues = uniqueIssues }
        }
        return requests
    }

    static func readDocument(_ url: URL, preferences: AppPreferences) throws -> ImportedDownloadDocument {
        let kind: ImportedDownloadDocument.Kind
        switch url.pathExtension.lowercased() {
        case "torrent":
            guard preferences.handleTorrentFiles else { throw ImportError.disabled }
            kind = .torrent
        case "metalink", "meta4":
            guard preferences.handleMetalinkFiles else { throw ImportError.disabled }
            kind = .metalink
        default: throw ImportError.unsupported
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ImportError.unsupported }
        guard (values.fileSize ?? 0) <= maximumDocumentBytes else { throw ImportError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumDocumentBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumDocumentBytes else { throw ImportError.tooLarge }
        return .init(kind: kind, data: data)
    }

    private enum ImportError: LocalizedError {
        case unsupported, disabled, tooLarge
        var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "Some items could not be imported. Use download links, Torrent files, or Metalink files.")
            case .disabled: String(localized: "This link or file type is disabled in Settings → Protocols.")
            case .tooLarge: String(localized: "Torrent and Metalink files must be nonempty and no larger than 16 MB.")
            }
        }
    }
}

@MainActor
final class DownloadInputCoordinator: ObservableObject {
    @Published private(set) var revision = 0
    private(set) var pending: [DownloadImportRequest] = []
    private(set) var owner: UUID?
    private(set) var hasManualRequest = false
    private var savedDraft: AddDownloadDraft?
    private var claimedImport: DownloadImportRequest?

    func enqueue(_ requests: [DownloadImportRequest]) {
        // Repeated platform events while an item is waiting must not create duplicate sheets.
        for request in requests where !pending.contains(where: { $0.resources == request.resources && $0.documents == request.documents && $0.issues == request.issues }) {
            if claimedImport?.resources == request.resources && claimedImport?.documents == request.documents { continue }
            pending.append(request)
        }
        revision += 1
    }

    func requestManualSheet() {
        guard owner == nil else { return }
        hasManualRequest = true
        revision += 1
    }

    func cancelManualRequest() {
        guard owner == nil, hasManualRequest else { return }
        hasManualRequest = false
        revision += 1
    }

    func claimManualSheet(owner: UUID) -> Bool {
        guard self.owner == nil else { return false }
        self.owner = owner
        hasManualRequest = false
        revision += 1
        return true
    }

    func claimImport(owner: UUID, preserving draft: AddDownloadDraft) -> DownloadImportRequest? {
        guard self.owner == nil, !hasManualRequest, !pending.isEmpty else { return nil }
        self.owner = owner
        savedDraft = draft
        claimedImport = pending.removeFirst()
        revision += 1
        return claimedImport
    }

    func finish(owner: UUID) -> AddDownloadDraft? {
        guard self.owner == owner else { return nil }
        let draft = savedDraft
        self.owner = nil
        savedDraft = nil
        claimedImport = nil
        revision += 1
        return draft
    }

    static func droppedInputs(_ providers: [NSItemProvider]) async -> [DownloadImportInput] {
        var inputs: [DownloadImportInput] = []
        for provider in providers.prefix(DownloadImportReader.maximumResources + 1) {
            guard let type = [UTType.fileURL, .url, .plainText].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { continue }
            let input: DownloadImportInput? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { value, _ in
                    // Keep the original URL: recreating it from a string loses its sandbox extension.
                    if let url = value as? URL { continuation.resume(returning: .url(url)); return }
                    let text = (value as? String) ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
                    guard let text else { continuation.resume(returning: nil); return }
                    if type != .plainText, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        continuation.resume(returning: .url(url))
                    } else { continuation.resume(returning: .text(text)) }
                }
            }
            inputs.append(input ?? .text(String(localized: "Unsupported dropped item")))
        }
        return inputs
    }
}
