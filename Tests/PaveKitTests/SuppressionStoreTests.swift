import XCTest
@testable import PaveKit

final class SuppressionStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pave-suppress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var url: URL { dir.appendingPathComponent("suppression.json") }

    private func path(_ ext: String) -> [PaveFingerprint] {
        [PaveFingerprint(kind: .fileCreated, folder: "~/Downloads", fileExtension: ext),
         PaveFingerprint(kind: .fileMoved, folder: "~/Finance", fileExtension: ext)]
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testOfferCooldown() {
        let s = SuppressionStore(url: url)
        let key = SuppressionStore.pathKey(for: path("pdf"))
        XCTAssertFalse(s.isSuppressed(key, now: t0))

        s.recordOffered(key, at: t0)
        // Inside the 6h cooldown: suppressed.
        XCTAssertTrue(s.isSuppressed(key, now: t0.addingTimeInterval(5 * 3_600)))
        // Past the cooldown: open again.
        XCTAssertFalse(s.isSuppressed(key, now: t0.addingTimeInterval(7 * 3_600)))
    }

    func testDismissalWindow() {
        let s = SuppressionStore(url: url)
        let key = SuppressionStore.pathKey(for: path("xlsx"))
        s.recordDismissed(key, at: t0)
        XCTAssertTrue(s.isSuppressed(key, now: t0.addingTimeInterval(6 * 86_400)))
        XCTAssertFalse(s.isSuppressed(key, now: t0.addingTimeInterval(8 * 86_400)))
    }

    func testNeverAskIsPermanent() {
        let s = SuppressionStore(url: url)
        let key = SuppressionStore.pathKey(for: path("png"))
        s.recordNeverAsk(key)
        XCTAssertTrue(s.isSuppressed(key, now: t0))
        XCTAssertTrue(s.isSuppressed(key, now: t0.addingTimeInterval(365 * 86_400)))
    }

    func testPersistsAcrossInstances() {
        let key = SuppressionStore.pathKey(for: path("pdf"))
        do {
            let s = SuppressionStore(url: url)
            s.recordNeverAsk(key)
        }
        let reopened = SuppressionStore(url: url)
        XCTAssertTrue(reopened.isSuppressed(key, now: t0))
    }

    func testDifferentPathsAreIndependent() {
        let s = SuppressionStore(url: url)
        let a = SuppressionStore.pathKey(for: path("pdf"))
        let b = SuppressionStore.pathKey(for: path("xlsx"))
        s.recordDismissed(a, at: t0)
        XCTAssertTrue(s.isSuppressed(a, now: t0))
        XCTAssertFalse(s.isSuppressed(b, now: t0))
    }

    func testCorruptFileStartsFresh() throws {
        try Data("garbage not json".utf8).write(to: url)
        let s = SuppressionStore(url: url)
        let key = SuppressionStore.pathKey(for: path("pdf"))
        XCTAssertFalse(s.isSuppressed(key, now: t0), "corrupt file recovers as empty")
        s.recordOffered(key, at: t0)
        XCTAssertTrue(s.isSuppressed(key, now: t0.addingTimeInterval(60)), "usable after recovery")
    }
}
