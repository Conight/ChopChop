import CryptoKit
import Darwin
import Foundation

/// Keeps user-visible torrent copies separate from the engine's private resume state.
nonisolated enum TorrentStorage {
    private enum MetadataError: Error { case missingV2PieceLayers }
    static let maximumMetadataSize = 16 * 1_024 * 1_024

    static func createDirectory(in base: URL, name: String, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let name = safeName(name)
        for suffix in 0..<10_000 {
            let url = base.appendingPathComponent(suffix == 0 ? name : "\(name) (\(suffix + 1))", isDirectory: true)
            // mkdir atomically reserves a new directory; FileManager accepts existing ones.
            if mkdir(url.path, 0o755) == 0 { return url }
            if errno == EEXIST { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        throw DownloadOperationError(String(localized: "Could not create a separate folder for this torrent."))
    }

    static func safeName(_ value: String) -> String {
        let cleaned = value.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) || "/:\\".unicodeScalars.contains(scalar) ? "_" : String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var name = ""
        for character in cleaned {
            guard name.utf8.count + String(character).utf8.count <= 160 else { break }
            name.append(character)
        }
        return name.isEmpty ? "Torrent" : name
    }

    static func removeEmptyDirectory(_ path: String?) {
        guard let path, let entries = try? FileManager.default.contentsOfDirectory(atPath: path), entries.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    static func readMetadata(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumMetadataSize + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumMetadataSize else { throw invalidMetadata }
        return data
    }

    @concurrent
    static func saveEngineCopy(infoHash: String, name: String, directory: URL, original: Data?,
                               metadataURL: URL?, stateDirectory: URL) async throws {
        let hash = infoHash.lowercased()
        guard [40, 64].contains(hash.count), hash.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw invalidMetadata }
        if let data = original ?? metadataURL.flatMap({ try? readMetadata($0) }) {
            let torrent = try metainfo(from: data, infoHash: hash, resume: false)
            try saveCopy(torrent, in: directory, name: name)
            return
        }
        let resume = stateDirectory.appendingPathComponent("bittorrent/torrents/\(hash).fastresume")
        // Pausing commits fast-resume asynchronously. A short bounded retry avoids racing it.
        for attempt in 0..<15 {
            try Task.checkCancellation()
            if let data = try? readMetadata(resume) {
                do {
                    let torrent = try metainfo(from: data, infoHash: hash, resume: true)
                    try saveCopy(torrent, in: directory, name: name)
                    return
                } catch MetadataError.missingV2PieceLayers {
                    // BEP 9 only transfers the info dictionary. Without v2 piece layers,
                    // a .torrent cannot be re-added by the engine. A Finder URL shortcut
                    // preserves the usable source instead, including private trackers.
                    let entries = try BencodedDictionary.entries(data)
                    var link = URLComponents()
                    link.scheme = "magnet"
                    link.queryItems = [URLQueryItem(name: "xt", value: hash.count == 40 ? "urn:btih:\(hash)" : "urn:btmh:1220\(hash)")]
                    if let trackers = entries["trackers"] {
                        link.queryItems! += try BencodedDictionary.strings(trackers).map { URLQueryItem(name: "tr", value: $0) }
                    }
                    guard let url = link.string else { throw invalidMetadata }
                    let bookmark = try PropertyListSerialization.data(fromPropertyList: ["URL": url], format: .xml, options: 0)
                    try saveCopy(bookmark, in: directory, name: name, extension: "magnet.webloc")
                    return
                } catch let error as DownloadOperationError {
                    if attempt == 14 { throw error }
                }
            }
            if attempt < 14 { try await Task.sleep(for: .milliseconds(200)) }
        }
        throw invalidMetadata
    }

    /// Preserve the exact info dictionary bytes: re-encoding it can change the info hash.
    /// Whitelist metainfo fields so paths, peers, progress and resume credentials never leak.
    static func metainfo(from data: Data, infoHash: String, resume: Bool) throws -> Data {
        let entries = try BencodedDictionary.entries(data)
        guard let info = entries["info"], info.first == UInt8(ascii: "d") else { throw invalidMetadata }
        let hash = infoHash.lowercased()
        let sha1 = Insecure.SHA1.hash(data: info).map { String(format: "%02x", $0) }.joined()
        let sha256 = SHA256.hash(data: info).map { String(format: "%02x", $0) }.joined()
        guard hash == sha1 || hash == sha256 else { throw invalidMetadata }
        // A supplied .torrent is already a user document, including any publisher fields.
        if !resume { return data }
        if resume, entries["piece layers"] == nil,
           try BencodedDictionary.entries(info)["meta version"] == Data("i2e".utf8) {
            throw MetadataError.missingV2PieceLayers
        }
        var exported = ["info": info]
        for key in ["announce", "announce-list", "url-list", "httpseeds", "piece layers", "comment", "created by", "creation date"] {
            exported[key] = entries[key]
        }
        if resume { exported["announce-list"] = entries["trackers"] }
        var result = Data("d".utf8)
        for key in exported.keys.sorted() {
            result.append(Data("\(key.utf8.count):\(key)".utf8))
            result.append(exported[key]!)
        }
        result.append(UInt8(ascii: "e"))
        return result
    }

    @discardableResult
    static func saveCopy(_ data: Data, in directory: URL, name: String, extension suffixExtension: String = "torrent") throws -> URL {
        let base = safeName(name)
        for suffix in 0..<10_000 {
            let url = directory.appendingPathComponent(suffix == 0 ? "\(base).\(suffixExtension)" : "\(base) (\(suffix + 1)).\(suffixExtension)")
            if FileManager.default.fileExists(atPath: url.path) {
                if (try? readMetadata(url)) == data { return url }
                continue
            }
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
        }
        throw invalidMetadata
    }

    static var invalidMetadata: DownloadOperationError {
        DownloadOperationError(String(localized: "The torrent copy is not ready yet. Retry after the engine has saved its metadata."))
    }
}

/// A bounded scanner, not a torrent implementation. Values remain encoded and unmodified.
private nonisolated struct BencodedDictionary {
    let bytes: [UInt8]
    var offset = 0
    var tokens = 0

    static func entries(_ data: Data) throws -> [String: Data] {
        guard data.count <= TorrentStorage.maximumMetadataSize else { throw TorrentStorage.invalidMetadata }
        var parser = Self(bytes: Array(data))
        guard parser.take() == UInt8(ascii: "d") else { throw TorrentStorage.invalidMetadata }
        var result: [String: Data] = [:]
        while parser.peek != UInt8(ascii: "e") {
            let key = String(decoding: try parser.string(), as: UTF8.self)
            guard result[key] == nil else { throw TorrentStorage.invalidMetadata }
            let start = parser.offset
            try parser.skip(depth: 0)
            result[key] = Data(parser.bytes[start..<parser.offset])
        }
        _ = parser.take()
        guard parser.offset == parser.bytes.count else { throw TorrentStorage.invalidMetadata }
        return result
    }

    static func strings(_ data: Data) throws -> [String] {
        var parser = Self(bytes: Array(data))
        var result: [String] = []
        // The dictionary scanner already validated the nested bencode and bounds.
        while let c = parser.peek {
            if c == UInt8(ascii: "l") || c == UInt8(ascii: "e") { parser.offset += 1 }
            else { result.append(String(decoding: try parser.string(), as: UTF8.self)) }
        }
        return result
    }

    var peek: UInt8? { offset < bytes.count ? bytes[offset] : nil }
    mutating func take() -> UInt8? { defer { offset += 1 }; return peek }
    mutating func string() throws -> ArraySlice<UInt8> {
        let start = offset
        while let c = peek, (48...57).contains(c) { offset += 1 }
        guard offset > start, offset - start <= 9,
              let length = Int(String(decoding: bytes[start..<offset], as: UTF8.self)),
              take() == UInt8(ascii: ":"), length <= bytes.count - offset else { throw TorrentStorage.invalidMetadata }
        defer { offset += length }
        return bytes[offset..<(offset + length)]
    }
    mutating func skip(depth: Int) throws {
        tokens += 1
        guard depth < 64, tokens < 500_000, let c = peek else { throw TorrentStorage.invalidMetadata }
        if c == UInt8(ascii: "d") || c == UInt8(ascii: "l") {
            offset += 1
            while peek != UInt8(ascii: "e") {
                if c == UInt8(ascii: "d") { _ = try string() }
                try skip(depth: depth + 1)
            }
            offset += 1
        } else if c == UInt8(ascii: "i") {
            offset += 1
            let start = offset
            if peek == UInt8(ascii: "-") { offset += 1 }
            let digits = offset
            while let c = peek, (48...57).contains(c) { offset += 1 }
            guard offset > digits, offset - start <= 20, take() == UInt8(ascii: "e") else { throw TorrentStorage.invalidMetadata }
        } else { _ = try string() }
    }
}
