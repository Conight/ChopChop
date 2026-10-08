import CryptoKit
import XCTest
@testable import ChopChop

final class FileVerificationTests: XCTestCase {
    func testKnownDigestsAndExpectedChecksumValidation() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let sha256 = try await FileDigest.compute(file, algorithm: .sha256)
        let sha512 = try await FileDigest.compute(file, algorithm: .sha512)
        let sha1 = try await FileDigest.compute(file, algorithm: .sha1)
        let md5 = try await FileDigest.compute(file, algorithm: .md5)
        XCTAssertEqual(sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(sha512, SHA512.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(sha1, "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(md5, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(try FileDigestAlgorithm.sha256.normalizedExpected(" \(sha256.uppercased())\n"), sha256)
        XCTAssertThrowsError(try FileDigestAlgorithm.sha256.normalizedExpected("invalid"))
        XCTAssertNil(try FileDigestAlgorithm.sha256.normalizedExpected(""))
    }

    func testFileMutationDuringHashingCannotReportAMatch() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 42, count: 3 * 1_048_576).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await FileDigest.compute(file, algorithm: .sha256) { value in
                if value < 0.5 {
                    let handle = try? FileHandle(forWritingTo: file)
                    try? handle?.truncate(atOffset: 0)
                    try? handle?.close()
                }
            }
            XCTFail("A changing file must not be verified")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    }

    func testReplacingPathDuringVerificationIsDetected() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 42, count: 3 * 1_048_576).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await FileDigest.compute(file, algorithm: .sha256) { value in
                if value < 0.5 { try? Data(repeating: 24, count: 3 * 1_048_576).write(to: file, options: .atomic) }
            }
            XCTFail("Replacing a path must not verify the old unlinked file")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    }

    func testCancellationAndEmptyFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let digest = try await FileDigest.compute(file, algorithm: .sha256)
        XCTAssertEqual(digest, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let work = Task {
            try await Task.sleep(for: .seconds(1))
            return try await FileDigest.compute(file, algorithm: .sha256)
        }
        work.cancel()
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
