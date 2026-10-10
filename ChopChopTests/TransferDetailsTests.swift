import Foundation
import SwiftUI
import XCTest
@testable import ChopChop

final class TransferDetailsTests: XCTestCase {
    func testPieceBitOrderSpareBitsAndFinalShortPiece() throws {
        let map = try XCTUnwrap(PieceMap(count: 10, pieceLength: 1024, bitfield: "81ff", totalSpan: 9500))
        XCTAssertEqual(map.completedCount, 4, "Ignore six spare bits after the tenth piece")
        XCTAssertEqual(map.state(at: 0), .complete)
        XCTAssertEqual(map.state(at: 1), .missing)
        XCTAssertEqual(map.state(at: 7), .complete)
        XCTAssertEqual(map.state(at: 8), .complete)
        XCTAssertEqual(map.state(at: 10), .unknown)
        XCTAssertEqual(map.size(at: 9), 284)
        XCTAssertNil(map.size(at: 10))
    }

    func testUnreportedAndMalformedBitsStayUnknown() throws {
        for bits in [nil, "", "xyz", "1", "zz"] as [String?] {
            let map = try XCTUnwrap(PieceMap(count: 20, pieceLength: 1024, bitfield: bits, totalSpan: nil))
            XCTAssertEqual(map.reportedCount, 0)
            XCTAssertEqual(map.state(at: 0), .unknown)
            XCTAssertTrue(map.overview.allSatisfy { $0 == nil })
        }
        let truncated = try XCTUnwrap(PieceMap(count: 20, pieceLength: 1024, bitfield: "ff", totalSpan: nil))
        XCTAssertEqual(truncated.reportedCount, 8)
        XCTAssertEqual(truncated.completedCount, 8)
        XCTAssertEqual(truncated.state(at: 8), .unknown)
        XCTAssertNil(PieceMap(count: 0, pieceLength: 1, bitfield: "", totalSpan: nil))
        XCTAssertNil(PieceMap(count: 2, pieceLength: .max, bitfield: "", totalSpan: nil))
        XCTAssertNil(PieceMap(count: 10_000_001, pieceLength: 1, bitfield: "", totalSpan: nil))
    }

    func testSelectedLengthDoesNotShrinkTorrentPieceMapAndV2PaddingIsNotGuessed() throws {
        let json = #"{"gid":"bt","status":"active","numPieces":"3","pieceLength":"10","bitfield":"c0","totalLength":"12","bittorrent":{},"files":[{"index":"1","length":"11","selected":"false"},{"index":"2","length":"12","selected":"true"}]}"#
        let value = try JSONDecoder().decode(TransferProgressDTO.self, from: Data(json.utf8))
        XCTAssertEqual(value.pieceMap?.totalSpan, 23)
        XCTAssertEqual(value.pieceMap?.size(at: 2), 3)
        let v2 = json.replacingOccurrences(of: #""bittorrent":{}"#, with: #""bittorrent":{"infoHashV2":"abc"}"#)
        let hybrid = try JSONDecoder().decode(TransferProgressDTO.self, from: Data(v2.utf8))
        XCTAssertEqual(hybrid.pieceMap?.count, 3)
        XCTAssertNil(hybrid.pieceMap?.totalSpan)
        XCTAssertNil(hybrid.pieceMap?.size(at: 0))
    }

    func testOverviewIncludesEveryPieceAndGridRejectsGaps() throws {
        let map = try XCTUnwrap(PieceMap(count: 9999, pieceLength: 10, bitfield: String(repeating: "ff", count: 1250), totalSpan: nil))
        XCTAssertEqual(map.completedCount, 9999)
        XCTAssertEqual(map.overview.count, 240)
        XCTAssertTrue(map.overview.allSatisfy { $0 == 1 })
        for width in [240.0, 280, 320, 640] {
            let layout = PieceGridLayout(width: width, count: 512)
            for index in 0..<512 {
                let rect = layout.rect(index)
                XCTAssertEqual(layout.index(at: CGPoint(x: rect.midX, y: rect.midY)), index)
                XCTAssertLessThanOrEqual(rect.maxX, width)
                XCTAssertLessThanOrEqual(rect.maxY, layout.height)
                XCTAssertNil(layout.index(at: CGPoint(x: rect.midX, y: rect.maxY + 1)))
            }
            XCTAssertNil(layout.index(at: CGPoint(x: -1, y: 1)))
            XCTAssertNil(layout.index(at: CGPoint(x: width, y: 0)))
            XCTAssertNil(layout.index(at: CGPoint(x: 0, y: layout.height)))
        }
    }

    func testPieceHoverHasNoDefaultOrFallbackInGapsAndOutside() {
        let layout = PieceGridLayout(width: 280, count: 256)
        var inspection = PieceMapInspection()
        XCTAssertNil(inspection.hoveredIndex)
        XCTAssertNil(inspection.detailIndex)

        // Keyboard inspection is available, but does not pin a visual selection.
        inspection.navigate(to: 7, count: 600)
        XCTAssertEqual(inspection.detailIndex, 7)
        XCTAssertNil(inspection.hoveredIndex)
        for index in [0, 19, 255] {
            let rect = layout.rect(index)
            inspection.point(at: CGPoint(x: rect.midX, y: rect.midY), in: layout, start: 0)
            XCTAssertEqual(inspection.hoveredIndex, index)
            XCTAssertEqual(inspection.detailIndex, index)
            for gap in [CGPoint(x: rect.maxX + 1, y: rect.midY), CGPoint(x: rect.midX, y: rect.maxY + 1)] {
                inspection.point(at: gap, in: layout, start: 0)
                XCTAssertNil(inspection.hoveredIndex)
                XCTAssertNil(inspection.detailIndex, "Moving off a piece must not restore the previous inspection")
            }
        }
        inspection.point(at: CGPoint(x: 1, y: 1), in: layout, start: 0)
        inspection.point(at: nil, in: layout, start: 0)
        XCTAssertNil(inspection.hoveredIndex)
        XCTAssertNil(inspection.detailIndex)
    }

    func testPieceNavigationAndResizeClearStaleHover() {
        let layout = PieceGridLayout(width: 280, count: 88)
        var inspection = PieceMapInspection()
        inspection.point(at: CGPoint(x: 1, y: 1), in: layout, start: 256)
        XCTAssertEqual(inspection.hoveredIndex, 256)
        inspection.navigate(to: 512, count: 600, inspect: false)
        XCTAssertNil(inspection.hoveredIndex)
        XCTAssertNil(inspection.detailIndex)
        inspection.point(at: CGPoint(x: 1, y: 1), in: layout, start: 512)
        XCTAssertEqual(inspection.hoveredIndex, 512)
        inspection.point(at: nil, in: PieceGridLayout(width: 400, count: 88), start: 512)
        XCTAssertNil(inspection.hoveredIndex)
        XCTAssertNil(inspection.detailIndex)

        let last = layout.rect(87)
        inspection.point(at: CGPoint(x: last.maxX + 5, y: last.midY), in: layout, start: 512)
        XCTAssertNil(inspection.hoveredIndex, "Unused space on the final row is not a piece")
        inspection.navigate(to: 800, count: 600)
        XCTAssertEqual(inspection.detailIndex, 599)
        XCTAssertNil(inspection.hoveredIndex)
        inspection.navigate(to: -1, count: 600)
        XCTAssertEqual(inspection.detailIndex, 0)
        XCTAssertNil(inspection.hoveredIndex)
    }

    func testEveryPieceBorderStaysInsideItsCellAtDifferentWidths() {
        for width in [240.0, 280, 320, 517, 640, 1024] {
            let layout = PieceGridLayout(width: width, count: 256)
            let canvas = CGRect(x: 0, y: 0, width: width, height: layout.height)
            for index in 0..<layout.count {
                for lineWidth in [1.0, 2.0] {
                    let border = layout.outline(index, lineWidth: lineWidth)
                        .strokedPath(StrokeStyle(lineWidth: lineWidth)).boundingRect
                    // SwiftUI stroke geometry rounds coordinates to single precision.
                    XCTAssertTrue(layout.rect(index).insetBy(dx: -0.001, dy: -0.001).contains(border),
                                  "The normal and hovered borders must remain within each piece")
                    XCTAssertTrue(canvas.insetBy(dx: -0.001, dy: -0.001).contains(border),
                                  "First and last pieces must render without overflowing or clipping")
                }
            }
        }
    }

    func testPeerIdentityProgressAndReportedRates() throws {
        let json = #"{"ip":"2001:db8::1","port":"6881","peerClientName":"aria2-next","state":"connected","progress":"0.75","downloadSpeed":"4096","uploadSpeed":"2048","incoming":"true","transport":"utp","encryption":"rc4","sources":["pex","dht"],"downloaded":"8192","uploaded":"1024"}"#
        var peer = try JSONDecoder().decode(PeerTransfer.self, from: Data(json.utf8))
        XCTAssertEqual(peer.address, "[2001:db8::1]:6881")
        XCTAssertEqual(peer.fraction, 0.75)
        XCTAssertEqual(peer.down, 4096)
        XCTAssertEqual(peer.up, 2048)
        peer.state = "handshaking"
        XCTAssertNil(peer.fraction)
        peer.state = "connected"
        for progress in ["NaN", "inf", "1.1", "-1", ""] { peer.progress = progress; XCTAssertNil(peer.fraction) }
    }

    func testServerSnapshotsExcludeCredentialsPathsAndSensitiveQueries() throws {
        let json = #"[{"index":"2","servers":[{"uri":"https://alice:password@origin.invalid/private/file?token=secret","currentUri":"https://bob:pass@[2001:db8::1]:8443/private/name?auth=private#fragment","downloadSpeed":"42"},{"uri":"sftp://name:password@example.org/secret-file","downloadSpeed":"-5"}]}]"#
        let result = ServerTransferDTO.connections(try JSONDecoder().decode([ServerTransferDTO].self, from: Data(json.utf8)))
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].address, "[2001:db8::1]:8443")
        XCTAssertEqual(result[0].downloadSpeed, 42)
        XCTAssertEqual(result[1].transport, "SFTP")
        XCTAssertEqual(result[1].downloadSpeed, 0)
        let display = String(describing: result)
        for secret in ["alice", "bob", "password", "secret", "private", "fragment", "auth="] { XCTAssertFalse(display.contains(secret)) }
    }

    func testUploadLimitUnitsZeroAndInvalidValues() throws {
        XCTAssertEqual(try TransferRateLimit.option(kib: 0), "0K")
        XCTAssertEqual(try TransferRateLimit.option(kib: 128), "128K")
        XCTAssertThrowsError(try TransferRateLimit.option(kib: -1))
        XCTAssertThrowsError(try TransferRateLimit.option(kib: Int.max))
        XCTAssertEqual(TransferRateLimit.bytes("128K"), 131072)
        XCTAssertEqual(TransferRateLimit.bytes("1.5M"), 1572864)
        XCTAssertEqual(TransferRateLimit.bytes("0"), 0)
        for value in ["-1", "nan", "inf", "1e100", "-10K", "garbage", ""] { XCTAssertNil(TransferRateLimit.bytes(value)) }
    }

    @MainActor
    func testMonitorDiscardsStaleResponsesAfterTaskSwitchAndCancellation() async throws {
        let monitor = TransferDetailMonitor()
        let gate = SnapshotGate()
        let old = Task { await monitor.observe { await gate.fetch() } }
        while !(await gate.started) { await Task.yield() }
        let fresh = Task { await monitor.observe { TransferSnapshot(connections: 7) } }
        for _ in 0..<100 where monitor.snapshot == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(monitor.snapshot?.connections, 7)
        await gate.release()
        await old.value
        XCTAssertEqual(monitor.snapshot?.connections, 7, "An older task's response must never replace the new selection")
        fresh.cancel(); await fresh.value
        XCTAssertNil(monitor.snapshot)
    }

    @MainActor
    func testMonitorShowsInlineFailureAndStopsOnCancellation() async throws {
        let monitor = TransferDetailMonitor()
        let work = Task { await monitor.observe { throw URLError(.notConnectedToInternet) } }
        for _ in 0..<100 where monitor.issue == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(monitor.issue)
        XCTAssertNil(monitor.snapshot)
        work.cancel(); await work.value
        XCTAssertNil(monitor.snapshot)
    }
}

private actor SnapshotGate {
    var started = false
    var continuation: CheckedContinuation<TransferSnapshot, Never>?
    func fetch() async -> TransferSnapshot {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: TransferSnapshot(connections: 99)); continuation = nil }
}
