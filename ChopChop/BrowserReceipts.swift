import CryptoKit
import Foundation
import Observation

nonisolated struct BrowserRequestContext: Codable, Equatable, Sendable {
    var sourceOrigin: String = ""
    var userAgent: String = ""
    var referer: String = ""
    var cookie: String = ""
    var authorization: String = ""
    func matches(_ source: String) -> Bool {
        guard let expected = URLComponents(string: sourceOrigin), let actual = URLComponents(string: source),
              expected.user == nil, expected.password == nil, expected.query == nil, expected.fragment == nil,
              expected.path.isEmpty || expected.path == "/" else { return false }
        func port(_ url: URLComponents) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return expected.scheme?.lowercased() == actual.scheme?.lowercased() && expected.host?.lowercased() == actual.host?.lowercased() && port(expected) == port(actual)
    }
    var isValid: Bool {
        [sourceOrigin, userAgent, referer, cookie, authorization].allSatisfy { $0.utf8.count <= 8192 && !$0.contains(where: { $0.isNewline || $0 == "\0" }) }
        && (referer.isEmpty || URLComponents(string: referer).map { ["http", "https"].contains($0.scheme ?? "") && $0.host != nil && $0.user == nil && $0.password == nil } == true)
    }
}
nonisolated struct BrowserSubmission: Decodable, Sendable {
    var requestID: UUID
    var urls: [String]
    var issuedAt: Double
    var context: BrowserRequestContext?
}
nonisolated struct BrowserReceipt: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case pending, created, partial, cancelled, unknown }
    var requestID: UUID
    var fingerprint: String
    var createdAt = Date()
    var state = State.pending
    var taskIDs: [String] = []
    var remainingParts = 1
    var cancelledPart = false
}

/// Commit admission before enqueueing. Retained request identities are never
/// replayed; after an interrupted confirmation their outcome is explicitly unknown.
@MainActor @Observable
final class BrowserReceiptStore {
    private(set) var receipts: [UUID: BrowserReceipt] = [:]
    private let file: URL?
    private(set) var isAvailable = true
    init(file: URL? = nil) {
        self.file = file
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            guard data.count <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let saved = try JSONDecoder().decode([BrowserReceipt].self, from: data)
            guard saved.count <= 512 else { throw CocoaError(.fileReadCorruptFile) }
            for var receipt in saved where Date().timeIntervalSince(receipt.createdAt) < 7 * 86400 {
                if receipt.state == .pending { receipt.state = .unknown }
                receipts[receipt.requestID] = receipt
            }
            try save()
        } catch { isAvailable = false } // Do not erase admission identities on corruption.
    }
    func admit(_ submission: BrowserSubmission, body: Data) throws -> (BrowserReceipt, Bool) {
        pruneExpired()
        guard isAvailable else { throw CocoaError(.fileReadCorruptFile) }
        let fingerprint = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        if let old = receipts[submission.requestID] {
            guard old.fingerprint == fingerprint else { throw CocoaError(.fileReadCorruptFile) }
            return (old, false)
        }
        let now = Date().timeIntervalSince1970 * 1000
        guard submission.issuedAt.isFinite, submission.issuedAt <= now + 60_000,
              submission.issuedAt >= now - 7 * 86_400_000 else { throw CocoaError(.fileReadCorruptFile) }
        receipts = receipts.filter { Date().timeIntervalSince($0.value.createdAt) < 7 * 86400 }
        // Expired requests cannot be re-admitted: issuedAt is validated above.
        guard receipts.count < 512 else { throw CocoaError(.fileWriteOutOfSpace) }
        let receipt = BrowserReceipt(requestID: submission.requestID, fingerprint: fingerprint)
        receipts[submission.requestID] = receipt
        do { try save() } catch { receipts.removeValue(forKey: submission.requestID); throw error }
        return (receipt, true)
    }
    func pruneExpired() {
        let retained = receipts.filter { Date().timeIntervalSince($0.value.createdAt) < 7 * 86400 }
        guard retained.count != receipts.count else { return }
        let previous = receipts
        receipts = retained
        do { try save() } catch { receipts = previous; isAvailable = false }
    }
    func update(_ id: UUID, _ change: (inout BrowserReceipt) -> Void) {
        guard var receipt = receipts[id] else { return }
        change(&receipt)
        receipts[id] = receipt
        do { try save() } catch { isAvailable = false; receipts[id]?.state = .unknown }
    }
    func clear() throws {
        let previous = receipts
        receipts = [:]
        do { try save(); isAvailable = true }
        catch { receipts = previous; isAvailable = false; throw error }
    }
    private func save() throws {
        guard let file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(receipts.values)).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
