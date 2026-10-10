import Foundation

nonisolated enum ED2KSearchFileType: String, CaseIterable, Identifiable, Sendable {
    case any = ""
    case audio
    case video
    case document = "doc"
    case archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: String(localized: "Any")
        case .audio: String(localized: "Audio")
        case .video: String(localized: "Video")
        case .document: String(localized: "Document")
        case .archive: String(localized: "Archive")
        }
    }
}

nonisolated struct ED2KSearchOptions: Equatable, Sendable {
    var fileType: ED2KSearchFileType = .any
    var minSourceCount: Int?

    func engineOptions(directory: String, context: ED2KDownloadContext?) -> [String: String] {
        var options: [String: String] = ["dir": directory]
        if fileType != .any {
            options["fileType"] = fileType.rawValue
        }
        if let minSourceCount, minSourceCount > 0 {
            options["minSourceCount"] = "\(minSourceCount)"
        }
        context?.apply(to: &options)
        return options
    }
}

nonisolated struct ED2KSearchResult: Identifiable, Decodable, Equatable, Sendable {
    var hash: String?
    var name: String?
    var length: String?
    var sourceCount: String?
    var completeSourceCount: String?
    var fileType: String?
    var extensionName: String?
    var sourceNetwork: String?
    var ed2kLink: String?

    enum CodingKeys: String, CodingKey {
        case hash
        case name
        case length
        case sourceCount
        case completeSourceCount
        case fileType
        case extensionName = "extension"
        case sourceNetwork
        case ed2kLink
    }

    var id: String {
        ed2kLink?.trimmedForEngine.nonEmptyValue ??
            hash?.trimmedForEngine.nonEmptyValue ??
            "\(name ?? "unknown")-\(length ?? "0")-\(sourceCount ?? "0")"
    }

    var displayName: String {
        name?.trimmedForEngine.nonEmptyValue ?? String(localized: "Unnamed ED2K file")
    }

    var lengthBytes: Int64 {
        Int64(length ?? "") ?? 0
    }
}

nonisolated struct ED2KSearchResults: Decodable, Equatable, Sendable {
    var gid: String?
    var status: String?
    var moreResults: Bool?
    var results: [ED2KSearchResult]?
}

nonisolated struct ED2KDownloadContext: Equatable, Sendable {
    var bootstrapPaths: ED2KBootstrapPaths?
    var serverList: String

    var hasBootstrapOrServer: Bool {
        bootstrapPaths != nil || !serverList.trimmedForEngine.isEmpty
    }

    func apply(to options: inout [String: String]) {
        if let bootstrapPaths {
            options["ed2k-server-list"] = bootstrapPaths.serverMetPath
            options["ed2k-node-list"] = bootstrapPaths.nodesDatPath
        }
        if !serverList.trimmedForEngine.isEmpty {
            options["ed2k-server"] = serverList.trimmedForEngine
        }
    }
}

nonisolated enum ED2KSearchTempCache {
    static let directoryPrefix = "chopchop-ed2k-search-"

    static func createDirectory(root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = root.appendingPathComponent("\(directoryPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func cleanup(_ url: URL?) {
        guard let url else { return }
        guard url.lastPathComponent.hasPrefix(directoryPrefix) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
