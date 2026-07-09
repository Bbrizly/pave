import XCTest
@testable import PaveKit

final class PathMatcherTests: XCTestCase {
    private let base: TimeInterval = 4_000_000
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pave-match-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(_ name: String = "s.json") -> SuppressionStore {
        SuppressionStore(url: dir.appendingPathComponent(name))
    }

    private func ev(_ kind: PaveEventKind, _ t: TimeInterval, session: UUID,
                    bundle: String? = nil, folder: String? = nil, ext: String? = nil) -> PaveEvent {
        PaveEvent(timestamp: Date(timeIntervalSince1970: base + t), kind: kind,
                  bundleID: bundle, folder: folder, fileExtension: ext,
                  subjectHash: PaveHash.stable("f-\(t)-\(UUID().uuidString)"), sessionID: session)
    }

    // MARK: fixtures

    // The finance ritual as a whole session.
    private func ritual(_ start: TimeInterval, session: UUID) -> [PaveEvent] {
        [ev(.fileCreated, start + 0, session: session, folder: "~/Downloads", ext: "pdf"),
         ev(.fileMoved, start + 10, session: session, folder: "~/Finance", ext: "pdf"),
         ev(.appActivated, start + 20, session: session, bundle: "com.apple.Numbers"),
         ev(.fileRenamed, start + 30, session: session, folder: "~/Finance", ext: "xlsx")]
    }

    private func historicalIndex() -> PathIndex {
        let events = ritual(0, session: UUID())
            + ritual(86_400, session: UUID())
            + ritual(172_800, session: UUID())
        return PathIndex.build(from: events)
    }

    private let step1 = PaveFingerprint(kind: .fileCreated, folder: "~/Downloads", fileExtension: "pdf")
    private let step2 = PaveFingerprint(kind: .fileMoved, folder: "~/Finance", fileExtension: "pdf")
    private let fullRun = [
        PaveFingerprint(kind: .fileCreated, folder: "~/Downloads", fileExtension: "pdf"),
        PaveFingerprint(kind: .fileMoved, folder: "~/Finance", fileExtension: "pdf"),
        PaveFingerprint(kind: .appActivated, bundleID: "com.apple.Numbers"),
        PaveFingerprint(kind: .fileRenamed, folder: "~/Finance", fileExtension: "xlsx"),
    ]

    // MARK: tests

    func testFiresWhenUserStartsTheRitual() {
        let m = PathMatcher(index: historicalIndex(), suppression: store())
        let live = UUID()
        XCTAssertNil(m.observe(ev(.fileCreated, 900, session: live, folder: "~/Downloads", ext: "pdf"), at: at(900)))
        let match = m.observe(ev(.fileMoved, 910, session: live, folder: "~/Finance", ext: "pdf"), at: at(910))

        XCTAssertNotNil(match)
        XCTAssertEqual(match?.prefix, [step1, step2])
        XCTAssertEqual(match?.continuation.remainder, [
            PaveFingerprint(kind: .appActivated, bundleID: "com.apple.Numbers"),
            PaveFingerprint(kind: .fileRenamed, folder: "~/Finance", fileExtension: "xlsx"),
        ])
        XCTAssertEqual(match?.occurrences, 3)
        XCTAssertEqual(match?.confidence, 1.0)
        XCTAssertEqual(match?.run.fingerprints, fullRun)
    }

    func testGapToleranceAllowsOneOrTwoStrangers() {
        for strangers in 1...2 {
            let m = PathMatcher(index: historicalIndex(), suppression: store("g\(strangers).json"))
            let live = UUID()
            _ = m.observe(ev(.fileCreated, 0, session: live, folder: "~/Downloads", ext: "pdf"), at: at(0))
            for i in 0..<strangers {
                _ = m.observe(ev(.fileTrashed, TimeInterval(1 + i), session: live, folder: "~/Music"), at: at(TimeInterval(1 + i)))
            }
            let match = m.observe(ev(.fileMoved, 50, session: live, folder: "~/Finance", ext: "pdf"), at: at(50))
            XCTAssertNotNil(match, "\(strangers) stranger(s) inside the prefix should still match")
        }
    }

    func testThreeStrangersBreakTheMatch() {
        let m = PathMatcher(index: historicalIndex(), suppression: store())
        let live = UUID()
        _ = m.observe(ev(.fileCreated, 0, session: live, folder: "~/Downloads", ext: "pdf"), at: at(0))
        for i in 0..<3 {
            _ = m.observe(ev(.fileTrashed, TimeInterval(1 + i), session: live, folder: "~/Music"), at: at(TimeInterval(1 + i)))
        }
        let match = m.observe(ev(.fileMoved, 50, session: live, folder: "~/Finance", ext: "pdf"), at: at(50))
        XCTAssertNil(match, "too many strangers, the prefix is broken")
    }

    func testAmbiguousPrefixStaysSilent() {
        // Same prefix, two endings: 6 times one way, 4 the other. 0.6 < 0.8.
        let p1: (TimeInterval, UUID) -> PaveEvent = { t, s in self.ev(.fileCreated, t, session: s, folder: "~/Downloads", ext: "pdf") }
        let p2: (TimeInterval, UUID) -> PaveEvent = { t, s in self.ev(.fileMoved, t + 10, session: s, folder: "~/Finance", ext: "pdf") }
        var events: [PaveEvent] = []
        for i in 0..<6 {
            let s = UUID(); let t = TimeInterval(i) * 1_000
            events += [p1(t, s), p2(t, s), ev(.fileRenamed, t + 20, session: s, folder: "~/Finance", ext: "xlsx")]
        }
        for i in 0..<4 {
            let s = UUID(); let t = TimeInterval(100 + i) * 1_000
            events += [p1(t, s), p2(t, s), ev(.fileTrashed, t + 20, session: s, folder: "~/Downloads", ext: "pdf")]
        }
        let m = PathMatcher(index: PathIndex.build(from: events), suppression: store())
        let live = UUID()
        _ = m.observe(ev(.fileCreated, 900_000, session: live, folder: "~/Downloads", ext: "pdf"), at: at(900_000))
        let match = m.observe(ev(.fileMoved, 900_010, session: live, folder: "~/Finance", ext: "pdf"), at: at(900_010))
        XCTAssertNil(match, "60/40 split is below the suggest bar")
    }

    func testSessionRotationResetsWindow() {
        let m = PathMatcher(index: historicalIndex(), suppression: store())
        _ = m.observe(ev(.fileCreated, 0, session: UUID(), folder: "~/Downloads", ext: "pdf"), at: at(0))
        // Second step arrives under a different session id: the window resets.
        let match = m.observe(ev(.fileMoved, 10, session: UUID(), folder: "~/Finance", ext: "pdf"), at: at(10))
        XCTAssertNil(match, "a new session should not complete the previous prefix")
    }

    func testIdleGapResetsWindow() {
        let m = PathMatcher(index: historicalIndex(), suppression: store())
        let live = UUID()
        _ = m.observe(ev(.fileCreated, 0, session: live, folder: "~/Downloads", ext: "pdf"), at: at(0))
        // Same session id, but a long idle gap breaks the sitting.
        let match = m.observe(ev(.fileMoved, 0, session: live, folder: "~/Finance", ext: "pdf"),
                              at: at(0).addingTimeInterval(3_600))
        XCTAssertNil(match, "an idle gap should reset the window")
    }

    func testSuppressionHonored() {
        let s = store()
        s.recordNeverAsk(SuppressionStore.pathKey(for: fullRun))
        let m = PathMatcher(index: historicalIndex(), suppression: s)
        let live = UUID()
        _ = m.observe(ev(.fileCreated, 0, session: live, folder: "~/Downloads", ext: "pdf"), at: at(0))
        let match = m.observe(ev(.fileMoved, 10, session: live, folder: "~/Finance", ext: "pdf"), at: at(10))
        XCTAssertNil(match, "a muted path must not surface")

        // Control: an unmuted store fires on the same feed.
        let m2 = PathMatcher(index: historicalIndex(), suppression: store("fresh.json"))
        let live2 = UUID()
        _ = m2.observe(ev(.fileCreated, 0, session: live2, folder: "~/Downloads", ext: "pdf"), at: at(0))
        XCTAssertNotNil(m2.observe(ev(.fileMoved, 10, session: live2, folder: "~/Finance", ext: "pdf"), at: at(10)))
    }

    private func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: base + t) }
}
