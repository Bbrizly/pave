import XCTest
@testable import PaveKit

final class FingerprintTests: XCTestCase {

    // Two renames of different files yield the same fingerprint. The raw name
    // lives only in subjectHash, which the fingerprint must ignore.
    func testNameIndependence() {
        let a = PaveEvent(timestamp: Date(), kind: .fileRenamed, folder: "~/Documents",
                          fileExtension: "pdf", subjectHash: PaveHash.stable("invoice-a.pdf"))
        let b = PaveEvent(timestamp: Date(), kind: .fileRenamed, folder: "~/Documents",
                          fileExtension: "pdf", subjectHash: PaveHash.stable("invoice-b.pdf"))

        XCTAssertNotEqual(a.subjectHash, b.subjectHash)
        XCTAssertEqual(PaveFingerprint(event: a), PaveFingerprint(event: b))
    }

    func testDifferentFolderDiffersFingerprint() {
        let a = PaveEvent(timestamp: Date(), kind: .fileCreated, folder: "~/Downloads", fileExtension: "pdf")
        let b = PaveEvent(timestamp: Date(), kind: .fileCreated, folder: "~/Documents", fileExtension: "pdf")
        XCTAssertNotEqual(PaveFingerprint(event: a), PaveFingerprint(event: b))
    }

    func testHashIsStable() {
        XCTAssertEqual(PaveHash.stable("report.pdf"), PaveHash.stable("report.pdf"))
        XCTAssertNotEqual(PaveHash.stable("report.pdf"), PaveHash.stable("report.txt"))
    }

    func testConfigRoundTrips() throws {
        var c = PaveConfig()
        c.retentionDays = 7
        let data = try PaveConfig.encoder().encode(c)
        let back = try JSONDecoder().decode(PaveConfig.self, from: data)
        XCTAssertEqual(back, c)
    }

    func testConfigTolerantDecode() throws {
        let json = Data(#"{"retentionDays": 5}"#.utf8)
        let c = try JSONDecoder().decode(PaveConfig.self, from: json)
        XCTAssertEqual(c.retentionDays, 5)
        XCTAssertEqual(c.flushBatchSize, PaveDefaults.flushBatchSize)
        XCTAssertEqual(c.watchedFolders, PaveDefaults.watchedFolders)
    }
}
