import XCTest
@testable import PaveKit

final class PathToMacroTests: XCTestCase {
    private let base: TimeInterval = 4_000_000

    private func ev(_ kind: PaveEventKind, _ t: TimeInterval, session: UUID,
                    bundle: String? = nil, folder: String? = nil, ext: String? = nil,
                    hash: String? = nil, rawName: String? = nil, previousName: String? = nil) -> PaveEvent {
        PaveEvent(timestamp: Date(timeIntervalSince1970: base + t), kind: kind,
                  bundleID: bundle, folder: folder, fileExtension: ext,
                  subjectHash: hash, sessionID: session, rawName: rawName, previousName: previousName)
    }

    /// A UTC midnight date, matching the inferencer's formatter.
    private func day(_ s: String) -> TimeInterval {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)!.timeIntervalSince1970 - base
    }

    /// Builds a PathMatch and the flat event list a coordinator would fetch
    /// by id, from an explicit list of per-occurrence event sequences. Every
    /// occurrence must be the same length as `fps`.
    private func match(fps: [PaveFingerprint], occurrences: [[PaveEvent]]) -> (PathMatch, [PaveEvent]) {
        let prefixLen = min(2, fps.count)
        let prefix = Array(fps.prefix(prefixLen))
        let remainder = Array(fps.suffix(from: prefixLen))
        let ids = occurrences.map { $0.map { $0.id } }
        let cont = PathIndex.Continuation(remainder: remainder, occurrences: occurrences.count,
                                          lastSeen: Date(timeIntervalSince1970: base + 1),
                                          distinctDays: occurrences.count, occurrenceEventIDs: ids)
        let run = RepeatedRun(fingerprints: fps, occurrences: occurrences.count,
                              lastSeen: cont.lastSeen, distinctDays: cont.distinctDays)
        let m = PathMatch(prefix: prefix, continuation: cont, confidence: 1.0,
                          occurrences: occurrences.count, run: run, pathKey: "test-key")
        let flat = occurrences.flatMap { $0 }
        return (m, flat)
    }

    // MARK: statement fixture: created -> renamed -> moved

    private func statementOccurrence(_ t: TimeInterval, session: UUID) -> [PaveEvent] {
        [ev(.fileCreated, t, session: session, folder: "~/Downloads", ext: "pdf", hash: "orig-\(t)"),
         ev(.fileRenamed, t + 5, session: session, folder: "~/Downloads", ext: "pdf", hash: "renamed-\(t)"),
         ev(.fileMoved, t + 10, session: session, folder: "~/Finance", ext: "pdf", hash: "renamed-\(t)")]
    }

    func testStatementFixtureConvertsToRenameAndMove() {
        let fps = [
            PaveFingerprint(kind: .fileCreated, folder: "~/Downloads", fileExtension: "pdf"),
            PaveFingerprint(kind: .fileRenamed, folder: "~/Downloads", fileExtension: "pdf"),
            PaveFingerprint(kind: .fileMoved, folder: "~/Finance", fileExtension: "pdf"),
        ]
        let occs = [statementOccurrence(0, session: UUID()),
                    statementOccurrence(100, session: UUID()),
                    statementOccurrence(200, session: UUID())]
        let (m, events) = match(fps: fps, occurrences: occs)

        let macro = PathToMacro.convert(match: m, events: events, config: PaveConfig())
        XCTAssertNotNil(macro)
        guard let macro else { return }
        XCTAssertFalse(macro.enabled)
        XCTAssertTrue(macro.name.hasPrefix("Draft (edit rename): "))
        XCTAssertEqual(macro.steps.count, 2)
        guard case .renameFile(let renameMatcher, let template) = macro.steps[0] else {
            return XCTFail("expected renameFile first"); }
        XCTAssertEqual(renameMatcher.folder, "~/Downloads")
        XCTAssertEqual(renameMatcher.ext, "pdf")
        XCTAssertEqual(template, "{name}")
        guard case .moveFile(let moveMatcher, let dest, let overwrite) = macro.steps[1] else {
            return XCTFail("expected moveFile second"); }
        XCTAssertEqual(moveMatcher.folder, "~/Downloads")
        XCTAssertEqual(moveMatcher.ext, "pdf")
        XCTAssertEqual(dest, "~/Finance")
        XCTAssertFalse(overwrite)
    }

    // MARK: rename with inferable template -> real template, normal name

    func testInferredRenameTemplateProducesCleanDraft() {
        let fps = [
            PaveFingerprint(kind: .fileCreated, folder: "~/Downloads", fileExtension: "pdf"),
            PaveFingerprint(kind: .fileRenamed, folder: "~/Downloads", fileExtension: "pdf"),
            PaveFingerprint(kind: .fileMoved, folder: "~/Finance", fileExtension: "pdf"),
        ]
        func occ(_ dateStr: String, session: UUID) -> [PaveEvent] {
            let rt = day(dateStr)
            return [
                ev(.fileCreated, rt - 10, session: session, folder: "~/Downloads", ext: "pdf",
                   hash: "orig-\(dateStr)", rawName: "scan.pdf"),
                ev(.fileRenamed, rt, session: session, folder: "~/Downloads", ext: "pdf",
                   hash: "renamed-\(dateStr)", rawName: "Statement \(dateStr).pdf", previousName: "scan.pdf"),
                ev(.fileMoved, rt + 10, session: session, folder: "~/Finance", ext: "pdf",
                   hash: "renamed-\(dateStr)"),
            ]
        }
        let occs = [occ("2026-05-01", session: UUID()),
                    occ("2026-06-01", session: UUID()),
                    occ("2026-07-01", session: UUID())]
        let (m, events) = match(fps: fps, occurrences: occs)

        let macro = PathToMacro.convert(match: m, events: events, config: PaveConfig())
        XCTAssertNotNil(macro)
        guard let macro else { return }
        // Inference succeeded, so this is a clean draft, not an edit-rename one.
        XCTAssertTrue(macro.name.hasPrefix("Draft: "))
        XCTAssertEqual(macro.paveOrigin, "test-key")
        guard case .renameFile(_, let template) = macro.steps[0] else {
            return XCTFail("expected renameFile first") }
        XCTAssertEqual(template, "Statement {date}.pdf")
        guard case .moveFile = macro.steps[1] else { return XCTFail("expected moveFile second") }
    }

    // MARK: simple move, no rename

    func testSimpleMoveNoRenameConverts() {
        let fps = [
            PaveFingerprint(kind: .fileCreated, folder: "~/Downloads", fileExtension: "pdf"),
            PaveFingerprint(kind: .fileMoved, folder: "~/Finance", fileExtension: "pdf"),
        ]
        func occ(_ t: TimeInterval, session: UUID) -> [PaveEvent] {
            [ev(.fileCreated, t, session: session, folder: "~/Downloads", ext: "pdf", hash: "same-\(t)"),
             ev(.fileMoved, t + 5, session: session, folder: "~/Finance", ext: "pdf", hash: "same-\(t)")]
        }
        let occs = [occ(0, session: UUID()), occ(100, session: UUID()), occ(200, session: UUID())]
        let (m, events) = match(fps: fps, occurrences: occs)

        let macro = PathToMacro.convert(match: m, events: events, config: PaveConfig())
        XCTAssertNotNil(macro)
        XCTAssertEqual(macro?.steps.count, 1)
        guard case .moveFile(let matcher, let dest, _) = macro?.steps[0] else {
            return XCTFail("expected moveFile"); }
        XCTAssertEqual(matcher.folder, "~/Downloads")
        XCTAssertEqual(dest, "~/Finance")
        XCTAssertTrue(macro!.name.hasPrefix("Draft: "))
    }

    // MARK: inconsistent source across occurrences -> nil

    func testInconsistentSourceAcrossOccurrencesReturnsNil() {
        // Two candidate anchor positions with different folders: a fileCreated
        // in Downloads and a fileRenamed in Desktop. One occurrence's moved
        // file hash chains back to the created step, the other to the renamed
        // step, so the recovered source genuinely disagrees between them.
        let fps = [
            PaveFingerprint(kind: .fileCreated, folder: "~/Downloads", fileExtension: "pdf"),
            PaveFingerprint(kind: .fileRenamed, folder: "~/Desktop", fileExtension: "pdf"),
            PaveFingerprint(kind: .fileMoved, folder: "~/Finance", fileExtension: "pdf"),
        ]
        let session1 = UUID()
        let session2 = UUID()
        // Occurrence 1: moved event hash matches the created event (index 0).
        let occ1 = [ev(.fileCreated, 0, session: session1, folder: "~/Downloads", ext: "pdf", hash: "a"),
                    ev(.fileRenamed, 3, session: session1, folder: "~/Desktop", ext: "pdf", hash: "unrelated1"),
                    ev(.fileMoved, 5, session: session1, folder: "~/Finance", ext: "pdf", hash: "a")]
        // Occurrence 2: moved event hash matches the renamed event (index 1).
        let occ2 = [ev(.fileCreated, 100, session: session2, folder: "~/Downloads", ext: "pdf", hash: "unrelated2"),
                    ev(.fileRenamed, 103, session: session2, folder: "~/Desktop", ext: "pdf", hash: "b"),
                    ev(.fileMoved, 105, session: session2, folder: "~/Finance", ext: "pdf", hash: "b")]
        let (m, events) = match(fps: fps, occurrences: [occ1, occ2])

        let macro = PathToMacro.convert(match: m, events: events, config: PaveConfig())
        XCTAssertNil(macro, "inconsistent recovered source across occurrences must not convert")
    }

    // MARK: no earlier event to recover source -> nil

    func testNoAnchorForMoveReturnsNil() {
        let fps = [PaveFingerprint(kind: .fileMoved, folder: "~/Finance", fileExtension: "pdf")]
        let session1 = UUID()
        let session2 = UUID()
        let occ1 = [ev(.fileMoved, 0, session: session1, folder: "~/Finance", ext: "pdf", hash: "solo1")]
        let occ2 = [ev(.fileMoved, 100, session: session2, folder: "~/Finance", ext: "pdf", hash: "solo2")]
        let (m, events) = match(fps: fps, occurrences: [occ1, occ2])
        let macro = PathToMacro.convert(match: m, events: events, config: PaveConfig())
        XCTAssertNil(macro, "a fileMoved with no earlier matching event cannot recover a source")
    }

    // MARK: app-open run

    func testAppOpenRunConvertsToAppSteps() {
        let fps = [
            PaveFingerprint(kind: .appActivated, bundleID: "com.apple.Safari"),
            PaveFingerprint(kind: .appActivated, bundleID: "com.apple.mail"),
        ]
        func occ(_ t: TimeInterval, session: UUID) -> [PaveEvent] {
            [ev(.appActivated, t, session: session, bundle: "com.apple.Safari"),
             ev(.appActivated, t + 5, session: session, bundle: "com.apple.mail")]
        }
        let occs = [occ(0, session: UUID()), occ(100, session: UUID()), occ(200, session: UUID())]
        let (m, events) = match(fps: fps, occurrences: occs)

        let macro = PathToMacro.convert(match: m, events: events, config: PaveConfig())
        XCTAssertNotNil(macro)
        XCTAssertEqual(macro?.steps, [.app(bundleId: "com.apple.Safari"), .app(bundleId: "com.apple.mail")])
    }

    // MARK: unmappable kind anywhere -> nil

    func testUnmappableKindAnywhereReturnsNil() {
        let fps = [
            PaveFingerprint(kind: .appActivated, bundleID: "com.apple.Safari"),
            PaveFingerprint(kind: .fileTrashed),
        ]
        func occ(_ t: TimeInterval, session: UUID) -> [PaveEvent] {
            [ev(.appActivated, t, session: session, bundle: "com.apple.Safari"),
             ev(.fileTrashed, t + 5, session: session)]
        }
        let occs = [occ(0, session: UUID()), occ(100, session: UUID()), occ(200, session: UUID())]
        let (m, events) = match(fps: fps, occurrences: occs)

        let macro = PathToMacro.convert(match: m, events: events, config: PaveConfig())
        XCTAssertNil(macro, "fileTrashed has no step mapping, whole run stays unmapped")
    }

    func testMidRunFileCreatedIsNotConsumed() {
        // fileCreated appears after an appActivated, so it is not "leading" and
        // must not be silently absorbed even if a later move shares its hash.
        let fps = [
            PaveFingerprint(kind: .appActivated, bundleID: "com.apple.Finder"),
            PaveFingerprint(kind: .fileCreated, folder: "~/Downloads", fileExtension: "pdf"),
            PaveFingerprint(kind: .fileMoved, folder: "~/Finance", fileExtension: "pdf"),
        ]
        func occ(_ t: TimeInterval, session: UUID) -> [PaveEvent] {
            [ev(.appActivated, t, session: session, bundle: "com.apple.Finder"),
             ev(.fileCreated, t + 1, session: session, folder: "~/Downloads", ext: "pdf", hash: "x-\(t)"),
             ev(.fileMoved, t + 5, session: session, folder: "~/Finance", ext: "pdf", hash: "x-\(t)")]
        }
        let occs = [occ(0, session: UUID()), occ(100, session: UUID()), occ(200, session: UUID())]
        let (m, events) = match(fps: fps, occurrences: occs)

        let macro = PathToMacro.convert(match: m, events: events, config: PaveConfig())
        XCTAssertNil(macro, "a non-leading fileCreated must not be silently dropped")
    }
}
