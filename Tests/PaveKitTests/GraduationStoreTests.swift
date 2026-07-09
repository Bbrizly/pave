import XCTest
@testable import PaveKit

final class GraduationStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pave-grad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var url: URL { dir.appendingPathComponent("graduation.json") }
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let key = "run:abc"

    func testCountsConfirmedRuns() {
        let s = GraduationStore(url: url)
        XCTAssertEqual(s.confirmedRuns(key), 0)
        s.recordConfirmedRun(key, at: t0)
        s.recordConfirmedRun(key, at: t0.addingTimeInterval(60))
        XCTAssertEqual(s.confirmedRuns(key), 2)
    }

    func testEligibilityBoundary() {
        var cfg = PaveConfig()
        cfg.paveAfterConfirmedRuns = 5
        let s = GraduationStore(url: url, config: cfg)
        for i in 0..<4 { s.recordConfirmedRun(key, at: t0.addingTimeInterval(Double(i))) }
        XCTAssertFalse(s.eligibleForAutoRunOffer(key), "four runs is under the bar")
        s.recordConfirmedRun(key, at: t0.addingTimeInterval(5))
        XCTAssertTrue(s.eligibleForAutoRunOffer(key), "five runs meets the bar")
    }

    func testApproveAndRevoke() {
        var cfg = PaveConfig()
        cfg.paveAfterConfirmedRuns = 1
        let s = GraduationStore(url: url, config: cfg)
        s.recordConfirmedRun(key, at: t0)
        XCTAssertTrue(s.eligibleForAutoRunOffer(key))
        s.approveAutoRun(key, at: t0)
        XCTAssertTrue(s.isAutoRunApproved(key))
        XCTAssertFalse(s.eligibleForAutoRunOffer(key), "already approved is no longer an offer")
        s.revokeAutoRun(key)
        XCTAssertFalse(s.isAutoRunApproved(key))
        XCTAssertTrue(s.eligibleForAutoRunOffer(key), "revoke re-opens the offer, count is kept")
    }

    func testPersistsAcrossInstances() {
        do {
            let s = GraduationStore(url: url)
            s.recordConfirmedRun(key, at: t0)
            s.recordConfirmedRun(key, at: t0)
            s.approveAutoRun(key, at: t0)
        }
        let reopened = GraduationStore(url: url)
        XCTAssertEqual(reopened.confirmedRuns(key), 2)
        XCTAssertTrue(reopened.isAutoRunApproved(key))
    }

    func testCorruptFileStartsFresh() throws {
        try Data("not json at all".utf8).write(to: url)
        let s = GraduationStore(url: url)
        XCTAssertEqual(s.confirmedRuns(key), 0, "corrupt file recovers as empty")
        s.recordConfirmedRun(key, at: t0)
        XCTAssertEqual(s.confirmedRuns(key), 1, "usable after recovery")
    }
}
