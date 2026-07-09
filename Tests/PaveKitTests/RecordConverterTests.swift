import XCTest
@testable import PaveKit

final class RecordConverterTests: XCTestCase {
    private let base: TimeInterval = 5_000_000

    private func ev(_ kind: PaveEventKind, _ t: TimeInterval,
                    bundle: String? = nil, folder: String? = nil, ext: String? = nil,
                    hash: String? = nil, rawName: String? = nil,
                    origin: PaveEventOrigin = .user) -> PaveEvent {
        PaveEvent(timestamp: Date(timeIntervalSince1970: base + t), kind: kind, origin: origin,
                  bundleID: bundle, folder: folder, fileExtension: ext,
                  subjectHash: hash, sessionID: UUID(), rawName: rawName)
    }

    func testStatementRitualCapturesRenameAndMove() {
        // A file lands, gets renamed, then moved. The move recovers its source
        // from the rename event that last held the moved file's current hash.
        let events = [
            ev(.fileCreated, 0, folder: "~/Downloads", ext: "pdf", hash: "a", rawName: "scan.pdf"),
            ev(.fileRenamed, 5, folder: "~/Downloads", ext: "pdf", hash: "b", rawName: "Statement.pdf"),
            ev(.fileMoved, 10, folder: "~/Finance", ext: "pdf", hash: "b", rawName: "Statement.pdf"),
        ]
        let macro = RecordConverter.convert(events: events, config: PaveConfig())
        XCTAssertNotNil(macro)
        guard let macro else { return }
        XCTAssertFalse(macro.enabled)
        XCTAssertTrue(macro.name.hasPrefix("Recorded: "))
        XCTAssertEqual(macro.paveOrigin?.hasPrefix("record:"), true)
        // fileCreated is dropped, so the ritual is rename then move.
        XCTAssertEqual(macro.steps.count, 2)
        guard case .renameFile(let rm, let template) = macro.steps[0] else {
            return XCTFail("expected renameFile first") }
        XCTAssertEqual(rm.folder, "~/Downloads")
        XCTAssertEqual(template, "{name}")
        guard case .moveFile(let mm, let dest, _) = macro.steps[1] else {
            return XCTFail("expected moveFile second") }
        XCTAssertEqual(mm.folder, "~/Downloads")
        XCTAssertEqual(dest, "~/Finance")
    }

    func testUnrecoverableMoveIsSkipped() {
        // The moved file shares no earlier hash, so its source cannot be found.
        // That step is skipped, leaving just the rename, which is below the
        // two-step floor, so the whole capture yields nil.
        let events = [
            ev(.fileRenamed, 0, folder: "~/Downloads", ext: "pdf", hash: "b", rawName: "Statement.pdf"),
            ev(.fileMoved, 10, folder: "~/Finance", ext: "pdf", hash: "z", rawName: "Statement.pdf"),
        ]
        let macro = RecordConverter.convert(events: events, config: PaveConfig())
        XCTAssertNil(macro, "one mapped step after skipping the unrecoverable move is not enough")
    }

    func testAppOpenCapture() {
        let events = [
            ev(.appActivated, 0, bundle: "com.apple.Safari"),
            ev(.appLaunched, 5, bundle: "com.apple.mail"),
        ]
        let macro = RecordConverter.convert(events: events, config: PaveConfig())
        XCTAssertEqual(macro?.steps, [.app(bundleId: "com.apple.Safari"), .app(bundleId: "com.apple.mail")])
        XCTAssertEqual(macro?.enabled, false)
    }

    func testJunkOnlyWindowReturnsNil() {
        let events = [
            ev(.fileCreated, 0, folder: "~/Downloads", ext: "pdf", hash: "a", rawName: "x.pdf"),
            ev(.fileTrashed, 5, folder: "~/Downloads", ext: "tmp", hash: "c", rawName: "y.tmp"),
            ev(.bulkChange, 8),
        ]
        XCTAssertNil(RecordConverter.convert(events: events, config: PaveConfig()),
                     "nothing mappable means no macro")
    }

    func testNonUserEventsAreIgnored() {
        // Two app steps, but one is macro-origin. Only the user one maps, which
        // drops below the floor and yields nil.
        let events = [
            ev(.appActivated, 0, bundle: "com.apple.Safari"),
            ev(.appActivated, 5, bundle: "com.apple.mail", origin: .macro(UUID())),
        ]
        XCTAssertNil(RecordConverter.convert(events: events, config: PaveConfig()),
                     "macro-origin events are not part of the user's capture")
    }
}
