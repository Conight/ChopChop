import Foundation

nonisolated struct ED2KBootstrapPaths: Equatable, Sendable {
    var serverMetPath: String
    var nodesDatPath: String
}

nonisolated struct ED2KBootstrapStatus: Equatable, Sendable {
    var serverMetSize: Int64?
    var nodesDatSize: Int64?
    var serverMetModified: Date?
    var nodesDatModified: Date?

    var hasUsableFiles: Bool {
        (serverMetSize ?? 0) > 0 && (nodesDatSize ?? 0) > 0
    }

    var latestModificationDate: Date? {
        [serverMetModified, nodesDatModified].compactMap { $0 }.max()
    }
}

nonisolated struct ED2KBootstrapFetchResult: Equatable, Sendable {
    var serverMet: Data
    var nodesDat: Data
}

nonisolated struct ED2KBootstrapFetchFailure: LocalizedError, Sendable {
    var reason: String

    var errorDescription: String? { reason }
}

nonisolated protocol ED2KBootstrapFetching: Sendable {
    func fetch(serverMetURL: String, nodesDatURL: String, proxyURL: String) async throws -> ED2KBootstrapFetchResult
}

nonisolated struct URLSessionED2KBootstrapFetcher: ED2KBootstrapFetching {
    private static let maxBootstrapFileSize = 16 * 1024 * 1024

    @concurrent
    func fetch(serverMetURL: String, nodesDatURL: String, proxyURL: String) async throws -> ED2KBootstrapFetchResult {
        async let serverMet = download(urlString: serverMetURL, proxyURL: proxyURL)
        async let nodesDat = download(urlString: nodesDatURL, proxyURL: proxyURL)
        return try await ED2KBootstrapFetchResult(serverMet: serverMet, nodesDat: nodesDat)
    }

    private func download(urlString: String, proxyURL: String) async throws -> Data {
        guard ED2KBootstrapURLValidator.isValid(urlString),
              let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ED2KBootstrapFetchFailure(reason: String(localized: "ED2K bootstrap URL must use HTTP or HTTPS."))
        }

        let session = URLSession(configuration: sessionConfiguration(proxyURL: proxyURL))
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw ED2KBootstrapFetchFailure(reason: String(localized: "ED2K bootstrap file returned HTTP \(httpResponse.statusCode)."))
        }
        guard !data.isEmpty, data.count <= Self.maxBootstrapFileSize else {
            throw ED2KBootstrapFetchFailure(reason: String(localized: "Invalid ED2K bootstrap file size: \(data.count)."))
        }
        return data
    }

    private func sessionConfiguration(proxyURL: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        let trimmedProxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedProxy),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              let port = url.port else {
            return configuration
        }

        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port
        ]
        return configuration
    }
}

nonisolated enum ED2KBootstrapURLValidator {
    static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return false
        }
        return true
    }
}

nonisolated enum ED2KServerText {
    static func servers(from text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawValue in text.components(separatedBy: CharacterSet(charactersIn: ",\n\r")) {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, isValidServer(value), seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    static func lineSeparated(from text: String) -> String {
        servers(from: text).joined(separator: "\n")
    }

    static func commaSeparated(from text: String) -> String {
        servers(from: text).joined(separator: ",")
    }

    static func containsInvalidServer(in text: String) -> Bool {
        let values = text.components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.contains { !isValidServer($0) }
    }

    private static func isValidServer(_ value: String) -> Bool {
        let separator = value.lastIndex(of: ":")
        guard let separator, separator != value.startIndex, separator != value.index(before: value.endIndex) else {
            return false
        }
        let host = value[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = value[value.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = Int(portText), (1...65_535).contains(port) else {
            return false
        }
        return true
    }
}

nonisolated enum ED2KBootstrapCache {
    static let directoryName = "ed2k"
    static let serverMetFileName = "server.met"
    static let nodesDatFileName = "nodes.dat"

    static func paths(applicationSupportBase: URL? = nil) throws -> ED2KBootstrapPaths {
        let directory = try directory(applicationSupportBase: applicationSupportBase)
        return ED2KBootstrapPaths(
            serverMetPath: directory.appendingPathComponent(serverMetFileName, isDirectory: false).path,
            nodesDatPath: directory.appendingPathComponent(nodesDatFileName, isDirectory: false).path
        )
    }

    static func cachedPathsIfAvailable(applicationSupportBase: URL? = nil) -> ED2KBootstrapPaths? {
        guard let paths = try? paths(applicationSupportBase: applicationSupportBase),
              FileManager.default.fileExists(atPath: paths.serverMetPath),
              FileManager.default.fileExists(atPath: paths.nodesDatPath),
              (fileSize(at: paths.serverMetPath) ?? 0) > 0,
              (fileSize(at: paths.nodesDatPath) ?? 0) > 0 else {
            return nil
        }
        return paths
    }

    static func status(applicationSupportBase: URL? = nil) -> ED2KBootstrapStatus {
        guard let paths = try? paths(applicationSupportBase: applicationSupportBase) else {
            return ED2KBootstrapStatus()
        }
        return status(paths: paths)
    }

    static func status(paths: ED2KBootstrapPaths) -> ED2KBootstrapStatus {
        ED2KBootstrapStatus(
            serverMetSize: fileSize(at: paths.serverMetPath),
            nodesDatSize: fileSize(at: paths.nodesDatPath),
            serverMetModified: modificationDate(at: paths.serverMetPath),
            nodesDatModified: modificationDate(at: paths.nodesDatPath)
        )
    }

    static func write(_ result: ED2KBootstrapFetchResult, applicationSupportBase: URL? = nil) throws -> ED2KBootstrapStatus {
        let paths = try paths(applicationSupportBase: applicationSupportBase)
        try atomicWrite(result.serverMet, to: URL(fileURLWithPath: paths.serverMetPath))
        try atomicWrite(result.nodesDat, to: URL(fileURLWithPath: paths.nodesDatPath))
        return status(paths: paths)
    }

    private static func directory(applicationSupportBase: URL?) throws -> URL {
        let support = try Aria2NextPaths.supportDirectory(
            applicationSupportBase: applicationSupportBase ?? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        )
        let directory = support.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).tmp", isDirectory: false)
        if FileManager.default.fileExists(atPath: temporaryURL.path) {
            try FileManager.default.removeItem(at: temporaryURL)
        }
        try data.write(to: temporaryURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    private static func fileSize(at path: String) -> Int64? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private static func modificationDate(at path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }
}
