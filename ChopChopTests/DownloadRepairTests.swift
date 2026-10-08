import XCTest
@testable import ChopChop

final class DownloadRepairTests: XCTestCase {
    func testAuthenticationReplacementKeepsOtherHeadersAndRejectsInjection() throws {
        var repair = DownloadConnectionRepair(authorization: "Bearer updated", cookie: "session=new")
        let result = try repair.options(existing: ["header": "Authorization: Bearer old\nX-Test: keep\nCookie: stale"])
        XCTAssertEqual(result["header"], "X-Test: keep\nAuthorization: Bearer updated\nCookie: session=new")
        repair.authorization = "bad\nX-Injected: yes"
        XCTAssertThrowsError(try repair.options(existing: [:]))
        repair = DownloadConnectionRepair(clearAuthentication: true)
        XCTAssertEqual(try repair.options(existing: ["header": "Authorization: secret\nCookie: secret"])["header"], "")
    }

    func testReplacementRequiresNoPartialDataAndSameOrigin() throws {
        var task = try JSONDecoder().decode(Aria2TaskDTO.self, from: Data(#"{"gid":"http","status":"paused","completedLength":"0","files":[{"index":"1","path":"/tmp/file","completedLength":"0"}]}"#.utf8)).toTask()
        var repair = DownloadConnectionRepair(replacementURL: "https://example.com/file?fresh=2")
        XCTAssertEqual(try repair.validatedReplacement(for: task, original: "https://example.com/file?expired=1"), repair.replacementURL)
        task.completedLength = 1
        XCTAssertThrowsError(try repair.validatedReplacement(for: task, original: "https://example.com/file"))
        task.completedLength = 0; repair.replacementURL = "https://other.example/file"
        XCTAssertThrowsError(try repair.validatedReplacement(for: task, original: "https://example.com/file"))
        repair.replacementURL = "http://example.com/file"
        XCTAssertThrowsError(try repair.validatedReplacement(for: task, original: "https://example.com/file"))
    }
}
