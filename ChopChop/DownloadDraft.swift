import Foundation

nonisolated extension AddDownloadDraft {
    init(defaults: EngineSettings) {
        self.init()
        savePath = defaults.downloadDirectoryPath ?? ""
        splitCount = defaults.splitCount
        userAgent = defaults.userAgent
        proxyURL = defaults.proxyURL
    }
}

nonisolated struct AddDownloadDraft: Equatable, Sendable {
    var rawInput = ""
    var startPaused = false
    var outputName = ""
    var savePath = ""
    var treatLinesAsMirrors = false
    var limitSpeed = false
    var speedLimitKB: Int = 0
    var splitCount = EngineSettings.defaultSplitCount
    var userAgent = EngineSettings.defaultUserAgent
    var referer = ""
    var cookie = ""
    var authorization = ""
    var customHeaders = ""
    var proxyURL = ""
    var importedDocuments: [String: ImportedDownloadDocument] = [:]
    var media = MediaDownloadOptions()
    var torrentDirectory: String? = nil

    var containsHTTPSource: Bool {
        ((try? normalizedResources()) ?? []).contains {
            let scheme = URL(string: $0)?.scheme?.lowercased()
            return scheme == "http" || scheme == "https" || Self.detectProtocol(for: $0) == .metalink
        }
    }

    var supportsOutputOptions: Bool {
        ((try? normalizedResources()) ?? []).contains { [.http, .sftp].contains(Self.detectProtocol(for: $0)) }
    }

    var detectedProtocol: TaskProtocol? {
        resourceLines.first.flatMap(Self.detectProtocol)
    }

    var resourceLines: [String] {
        rawInput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var isBatch: Bool {
        resourceLines.count > 1
    }

    var containsBitTorrentResource: Bool {
        ((try? normalizedResources()) ?? []).contains { resource in
            let protocolKind = Self.detectProtocol(for: resource)
            return protocolKind == .magnet || protocolKind == .bitTorrent
        }
    }

    var shouldResolveBitTorrentFilesBeforeSubmit: Bool {
        guard resourceLines.count == 1, !treatLinesAsMirrors else { return false }
        let kind = (try? normalizedResources().first).flatMap(Self.detectProtocol)
        return kind == .magnet || kind == .bitTorrent
    }

    var isSubmittable: Bool {
        !resourceLines.isEmpty &&
            resourceLines.allSatisfy { Self.detectProtocol(for: $0) != nil } &&
            (!limitSpeed || speedLimitKB > 0)
    }

    func normalizedResources() throws -> [String] {
        let resources = resourceLines
        guard !resources.isEmpty else { throw DownloadDraftError.emptyResource }
        return try resources.map { resource in
            let normalized = try Self.normalizedResource(resource)
            guard let kind = Self.detectProtocol(for: normalized), kind != .thunder else { throw DownloadDraftError.unsupportedProtocol }
            return normalized
        }
    }

    /// Inspect the decoded URI locally; submit Thunder links intact to the engine.
    func engineResources() throws -> [String] {
        let normalized = try normalizedResources()
        return zip(resourceLines, normalized).map { original, decoded in
            original.lowercased().hasPrefix("thunder://") ? original : decoded
        }
    }

    func engineOptions(fallbackDirectory: String?, autoOrganize: Bool) throws -> [String: String] {
        let normalized = try normalizedResources()
        if normalized.count > 1, media.mode != .file,
           (media.mode != .automatic || normalized.contains(where: Self.isMediaManifest)) {
            throw DownloadOperationError(String(localized: "Add one media source at a time to inspect and choose its tracks."))
        }
        if normalized.count > 1, !treatLinesAsMirrors, !outputName.trimmedForEngine.isEmpty {
            throw DownloadDraftError.outputNameRequiresSingleTask
        }

        var options: [String: String] = ["pause": startPaused.description]
        if !outputName.trimmedForEngine.isEmpty {
            options["out"] = outputName.trimmedForEngine
        }
        if !savePath.trimmedForEngine.isEmpty {
            options["dir"] = savePath.trimmedForEngine
        } else if let fallbackDirectory, !fallbackDirectory.trimmedForEngine.isEmpty {
            options["dir"] = fallbackDirectory.trimmedForEngine
        }
        if autoOrganize,
           let baseDirectory = options["dir"],
           !baseDirectory.isEmpty,
           !treatLinesAsMirrors,
           normalized.count == 1,
           let organized = FileCategoryRules.directory(for: normalized[0], baseDirectory: baseDirectory) {
            options["dir"] = organized
        }
        if limitSpeed, speedLimitKB > 0 {
            options["max-download-limit"] = "\(speedLimitKB)K"
        }
        if splitCount > 0 {
            options["split"] = "\(splitCount)"
        }
        if !proxyURL.trimmedForEngine.isEmpty {
            options["all-proxy"] = proxyURL.trimmedForEngine
        }
        if !userAgent.trimmedForEngine.isEmpty {
            try validateHeaderValue(userAgent, label: "User-Agent")
            options["user-agent"] = userAgent.trimmedForEngine
        }
        if !referer.trimmedForEngine.isEmpty {
            try validateHeaderValue(referer, label: "Referer")
            options["referer"] = referer.trimmedForEngine
        }

        let headerLines = try requestHeaderLines()
        if !headerLines.isEmpty {
            options["header"] = headerLines.joined(separator: "\n")
        }
        if media.mode != .automatic || shouldInspectMedia {
            options.merge(try media.engineOptions()) { _, new in new }
        }
        return options
    }

    private func requestHeaderLines() throws -> [String] {
        var lines: [String] = []
        if !cookie.trimmedForEngine.isEmpty {
            try validateHeaderValue(cookie, label: "Cookie")
            lines.append("Cookie: \(cookie.trimmedForEngine)")
        }
        if !authorization.trimmedForEngine.isEmpty {
            try validateHeaderValue(authorization, label: "Authorization")
            lines.append("Authorization: \(authorization.trimmedForEngine)")
        }
        for rawLine in customHeaders.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let separator = line.firstIndex(of: ":"),
                  separator != line.startIndex else {
                throw DownloadDraftError.invalidHeader(line)
            }
            try validateHeaderValue(line, label: String(localized: "Custom header"))
            lines.append(line)
        }
        return lines
    }

    private func validateHeaderValue(_ value: String, label: String) throws {
        if value.contains(where: \.isNewline) {
            throw DownloadDraftError.invalidHeader(label)
        }
    }

    static func detectProtocol(for resource: String) -> TaskProtocol? {
        let trimmed = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("ftp://") { return nil }
        if isBareBitTorrentInfoHash(trimmed) { return .magnet }
        if lowered.hasPrefix("thunder://") { return .thunder }
        if lowered.hasPrefix("magnet:") { return .magnet }
        if lowered.hasPrefix("ed2k://") { return .ed2k }
        if isTorrentResource(trimmed) { return .bitTorrent }
        if lowered.hasPrefix("sftp://") { return .sftp }
        if lowered.hasSuffix(".meta4") || lowered.hasSuffix(".metalink") { return .metalink }
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return .http }
        return nil
    }

    static func normalizedResource(_ resource: String) throws -> String {
        let trimmed = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DownloadDraftError.emptyResource }
        if isBareBitTorrentInfoHash(trimmed) {
            return "magnet:?xt=urn:btih:\(trimmed)"
        }
        if trimmed.lowercased().hasPrefix("thunder://") {
            let decoded = try decodeThunderResource(trimmed)
            // ED2K's pipe-delimited file links are not authority-based URLs.
            if isED2KFileResource(decoded) { return decoded }
            guard let url = URLComponents(string: decoded),
                  ["http", "https", "sftp", "magnet", "ed2k"].contains(url.scheme?.lowercased() ?? ""),
                  !["http", "https", "sftp"].contains(url.scheme?.lowercased() ?? "") || url.host?.isEmpty == false else {
                throw DownloadDraftError.unsupportedProtocol
            }
            return decoded
        }
        return trimmed
    }

    static func isED2KFileResource(_ resource: String) -> Bool {
        resource.replacingOccurrences(of: "%7C", with: "|", options: .caseInsensitive)
            .lowercased().hasPrefix("ed2k://|file|")
    }

    static func isBareBitTorrentInfoHash(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 40 || trimmed.count == 32 else { return false }
        if trimmed.count == 40 {
            return trimmed.allSatisfy { $0.isHexDigit }
        }
        return trimmed.allSatisfy { character in
            ("A"..."Z").contains(character) || ("2"..."7").contains(character)
        }
    }

    static func isLocalTorrentFile(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isTorrentResource(trimmed) else { return false }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            guard scheme.lowercased() == "file" else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        return FileManager.default.fileExists(atPath: trimmed)
    }

    static func localTorrentFileURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLocalTorrentFile(trimmed) else { return nil }
        if let url = URL(string: trimmed), url.scheme?.lowercased() == "file" {
            return url
        }
        return URL(fileURLWithPath: trimmed)
    }

    private static func isTorrentResource(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        if lowered.hasSuffix(".torrent") { return true }
        if let components = URLComponents(string: trimmed),
           let path = components.percentEncodedPath.removingPercentEncoding,
           path.lowercased().hasSuffix(".torrent") {
            return true
        }
        return false
    }

    private static func decodeThunderResource(_ resource: String) throws -> String {
        guard var payload = String(resource.dropFirst("thunder://".count)).removingPercentEncoding else {
            throw DownloadDraftError.invalidThunderLink
        }
        while payload.hasSuffix("/") { payload.removeLast() }
        payload += String(repeating: "=", count: (4 - payload.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), data.count > 4,
              data.starts(with: [0x41, 0x41]), data.suffix(2).elementsEqual([0x5a, 0x5a]) else {
            throw DownloadDraftError.invalidThunderLink
        }
        // Preserve original bytes, including GBK. Decoding as Unicode and re-encoding
        // would change the address requested from the server.
        var bytes = data.dropFirst(2).dropLast(2)
        let whitespace: Set<UInt8> = [9, 10, 11, 12, 13, 32]
        while let first = bytes.first, whitespace.contains(first) { bytes = bytes.dropFirst() }
        while let last = bytes.last, whitespace.contains(last) { bytes = bytes.dropLast() }
        guard !bytes.isEmpty else { throw DownloadDraftError.invalidThunderLink }
        return bytes.map { byte in
            byte > 0x20 && byte < 0x7f ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }
}

nonisolated enum DownloadDraftError: LocalizedError, Sendable {
    case emptyResource
    case unsupportedProtocol
    case invalidThunderLink
    case invalidHeader(String)
    case outputNameRequiresSingleTask
    case bitTorrentSelectionRequiresSingleResource
    case documentRequiresSingleResource

    var errorDescription: String? {
        switch self {
        case .unsupportedProtocol:
            String(localized: "This protocol is not supported. Use HTTP, HTTPS, SFTP, Magnet, ED2K, torrent, or Metalink. FTP is no longer supported by Aria2 Next.")
        case .emptyResource:
            String(localized: "Enter at least one download link.")
        case .invalidThunderLink:
            String(localized: "Thunder link could not be decoded.")
        case .invalidHeader(let value):
            String(localized: "Header value is invalid: \(value)")
        case .outputNameRequiresSingleTask:
            String(localized: "Output filename can only be set for one task or for a mirror group.")
        case .bitTorrentSelectionRequiresSingleResource:
            String(localized: "Add one Magnet or torrent at a time to choose files before downloading.")
        case .documentRequiresSingleResource:
            String(localized: "Review one Torrent or Metalink file at a time. Use File → Open Download File… to queue multiple files.")
        }
    }
}

nonisolated enum FileCategoryRules {
    private static let templates: [(extensions: Set<String>, subdirectory: String)] = [
        (["mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "ts", "m4v", "rmvb"], "Videos"),
        (["mp3", "flac", "aac", "ogg", "wav", "wma", "m4a", "opus", "ape"], "Music"),
        (["jpg", "jpeg", "png", "gif", "bmp", "svg", "webp", "ico", "tiff", "psd", "raw"], "Images"),
        (["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "epub", "md", "rtf"], "Documents"),
        (["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso", "zst"], "Archives"),
        (["exe", "msi", "deb", "rpm", "appimage", "pkg", "apk", "snap"], "Programs")
    ]

    static func directory(for resource: String, baseDirectory: String) -> String? {
        guard let ext = extensionName(from: resource) else { return nil }
        guard let template = templates.first(where: { $0.extensions.contains(ext) }) else { return nil }
        return URL(fileURLWithPath: baseDirectory)
            .appendingPathComponent(template.subdirectory, isDirectory: true)
            .path
    }

    private static func extensionName(from resource: String) -> String? {
        if resource.lowercased().hasPrefix("magnet:") { return nil }
        let path: String
        if let url = URL(string: resource), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            path = components.path
        } else {
            path = resource.components(separatedBy: "?").first?.components(separatedBy: "#").first ?? resource
        }
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
}
