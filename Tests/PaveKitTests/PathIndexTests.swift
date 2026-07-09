import XCTest
@testable import PaveKit

final class PathIndexTests: XCTestCase {
    private let base: TimeInterval = 3_000_000

    private func ev(_ kind: PaveEventKind, _ t: TimeInterval, session: UUID,
                    origin: PaveEventOrigin = .user,
                    bundle: String? = nil, folder: String? = nil, ext: String? = nil) -> PaveEvent {
        PaveEvent(timestamp: Date(timeIntervalSince1970: base + t), kind: kind, origin: origin,
                  bundleID: bundle, folder: folder, fileExtension: ext,
                  subjectHash: PaveHash.stable("f-\(t)"), sessionID: session)
    }

    // The finance ritual, one session, starting at `start`.
    private func ritual(_ start: TimeInterval, session: UUID,
                        origin: PaveEventOrigin = .user) -> [PaveEvent] {
        [ev(.fileCreated, start + 0, session: session, origin: origin, folder: "~/Downloads", ext: "pdf"),
         ev(.fileMoved, start + 10, session: session, origin: origin, folder: "~/Finance", ext: "pdf"),
         ev(.appActivated, start + 20, session: session, origin: origin, bundle: "com.apple.Numbers"),
         ev(.fileRenamed, start + 30, session: session, origin: origin, folder: "~/Finance", ext: "xlsx")]
    }

    private let prefix = [
        PaveFingerprint(kind: .fileCreated, folder: "~/Downloads", fileExtension: "pdf"),
        PaveFingerprint(kind: .fileMoved, folder: "~/Finance", fileExtension: "pdf"),
    ]
    private let remainder = [
        PaveFingerprint(kind: .appActivated, bundleID: "com.apple.Numbers"),
        PaveFingerprint(kind: .fileRenamed, folder: "~/Finance", fileExtension: "xlsx"),
    ]

    func testIndexesRepeatedRitual() {
        let events = ritual(0, session: UUID())
            + ritual(86_400, session: UUID())
            + ritual(172_800, session: UUID())

        let index = PathIndex.build(from: events)
        let conts = index.continuations(after: prefix)

        XCTAssertEqual(conts.count, 1, "one continuation, nested slices collapsed")
        let c = conts[0]
        XCTAssertEqual(c.remainder, remainder)
        XCTAssertEqual(c.occurrences, 3)
        XCTAssertEqual(c.distinctDays, 3)
        XCTAssertEqual(c.occurrenceEventIDs.count, 3)
        XCTAssertTrue(c.occurrenceEventIDs.allSatisfy { $0.count == 4 },
                      "each occurrence keeps the whole run's event ids")
    }

    func testMacroAndSystemOriginExcluded() {
        var events = ritual(0, session: UUID())
            + ritual(86_400, session: UUID())
            + ritual(172_800, session: UUID())
        // Pave's own run and a system-origin run must not inflate the count.
        events += ritual(200_000, session: UUID(), origin: .macro(UUID()))
        events += ritual(300_000, session: UUID(), origin: .system)

        let index = PathIndex.build(from: events)
        let conts = index.continuations(after: prefix)
        XCTAssertEqual(conts.count, 1)
        XCTAssertEqual(conts[0].occurrences, 3, "macro and system rituals dropped")
    }

    func testBulkChangeExcluded() {
        let s = UUID()
        var events = ritual(0, session: UUID())
            + ritual(86_400, session: UUID())
            + ritual(172_800, session: UUID())
        events.append(ev(.bulkChange, 500, session: s, folder: "~/Downloads"))

        let index = PathIndex.build(from: events)
        // The bulkChange never becomes a fingerprint in any continuation.
        for prefix in index.prefixes {
            for c in index.continuations(after: prefix) {
                XCTAssertFalse((prefix + c.remainder).contains { $0.kind == .bulkChange })
            }
        }
    }

    func testUnknownPrefixHasNoContinuations() {
        let index = PathIndex.build(from: ritual(0, session: UUID()))
        let bogus = [PaveFingerprint(kind: .fileTrashed), PaveFingerprint(kind: .fileTrashed)]
        XCTAssertTrue(index.continuations(after: bogus).isEmpty)
    }

    func testTooFewEventsIndexNothing() {
        // A single two-event session cannot form a run of length prefix+1.
        let s = UUID()
        let events = [ev(.fileCreated, 0, session: s, folder: "~/Downloads", ext: "pdf"),
                      ev(.fileMoved, 10, session: s, folder: "~/Finance", ext: "pdf")]
        let index = PathIndex.build(from: events)
        XCTAssertTrue(index.prefixes.isEmpty)
    }
}
