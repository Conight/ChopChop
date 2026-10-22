import Foundation

@main struct DomainPolicyChecks {
    @MainActor static func main() throws {
        let now = Date()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("receipts.json")
        let store = BrowserReceiptStore(file: file)
        let id = UUID()
        let source = "https://example.com/file?signature=private"
        var submission = BrowserSubmission(requestID: id, urls: [source], issuedAt: now.timeIntervalSince1970 * 1000)
        let body = Data(source.utf8)
        let first = try store.admit(submission, body: body)
        precondition(first.1 && first.0.state == .pending)
        let duplicate = try store.admit(submission, body: body)
        precondition(!duplicate.1)
        do { _ = try store.admit(submission, body: Data("changed".utf8)); preconditionFailure("identity collision accepted") } catch {}
        let persisted = try Data(contentsOf: file)
        precondition(!String(decoding: persisted, as: UTF8.self).contains("signature"))
        let restored = BrowserReceiptStore(file: file)
        precondition(restored.receipts[id]?.state == .unknown)
        let recovered = try restored.admit(submission, body: body)
        precondition(!recovered.1)
        submission.requestID = UUID(); submission.issuedAt = 0
        do { _ = try store.admit(submission, body: body); preconditionFailure("expired request accepted") } catch {}
        let context = BrowserRequestContext(sourceOrigin: "https://example.com", cookie: "session=private")
        precondition(context.isValid && context.matches("https://example.com:443/other"))
        precondition(!context.matches("http://example.com/other") && !context.matches("https://example.com.evil/"))
        var injected = context; injected.cookie = "session=x\r\nInjected: yes"
        precondition(!injected.isValid)
        let corruptFile = directory.appendingPathComponent("corrupt.json")
        try Data("invalid".utf8).write(to: corruptFile)
        precondition(!BrowserReceiptStore(file: corruptFile).isAvailable)
        let schedule = BandwidthSchedule(enabled: true, startMinute: 0, endMinute: 0, downloadKB: 500, uploadKB: 0)
        let temporary = TemporaryBandwidthLimit(enabled: true, downloadKiB: 2000, uploadKiB: 100, expiresAt: now.addingTimeInterval(30))
        let active = EffectiveBandwidth.compute(baseDownload: 0, baseUpload: 0, schedule: schedule, temporary: temporary, now: now)
        precondition(active.downloadKiB == 500 && active.uploadKiB == 100)
        let expired = EffectiveBandwidth.compute(baseDownload: 0, baseUpload: 0, schedule: schedule, temporary: temporary, now: now.addingTimeInterval(31))
        precondition(expired.downloadKiB == 500 && expired.uploadKiB == 0 && expired.reason == .schedule)
        let roundTrip = try JSONDecoder().decode(TemporaryBandwidthLimit.self, from: JSONEncoder().encode(temporary))
        precondition(roundTrip == temporary)
        let huge = EffectiveBandwidth.compute(baseDownload: Int.max, baseUpload: Int.max, schedule: BandwidthSchedule(), temporary: TemporaryBandwidthLimit(), now: now)
        precondition(huge.downloadKiB == Int(Int32.max) && huge.uploadKiB == Int(Int32.max))
        let bounded = BrowserReceiptStore()
        for _ in 0..<512 {
            let item = BrowserSubmission(requestID: UUID(), urls: [source], issuedAt: now.timeIntervalSince1970 * 1000)
            _ = try bounded.admit(item, body: body)
        }
        do {
            _ = try bounded.admit(BrowserSubmission(requestID: UUID(), urls: [source], issuedAt: now.timeIntervalSince1970 * 1000), body: body)
            preconditionFailure("admission evicted a retained identity")
        } catch {}
        precondition(bounded.receipts.count == 512)
        print("Receipt admission, collision, recovery, credential scope and effective bandwidth checks passed.")
    }
}
