import XCTest
@testable import PaveKit

final class ReportTests: XCTestCase {
    private let base: TimeInterval = 2_000_000

    private func ev(_ kind: PaveEventKind, _ t: TimeInterval,
                    bundle: String? = nil, folder: String? = nil, ext: String? = nil) -> PaveEvent {
        PaveEvent(timestamp: Date(timeIntervalSince1970: base + t), kind: kind,
                  bundleID: bundle, folder: folder, fileExtension: ext,
                  subjectHash: PaveHash.stable("file-\(t)"))
    }

    // The ritual: Create pdf in Downloads, Move it to Finance, switch to Numbers,
    // rename an xlsx. Three times across two days, with noise and an app-switch
    // chain that must be excluded.
    private func ritual(_ start: TimeInterval) -> [PaveEvent] {
        [ev(.fileCreated, start + 0, folder: "~/Downloads", ext: "pdf"),
         ev(.fileMoved, start + 10, folder: "~/Finance", ext: "pdf"),
         ev(.appActivated, start + 20, bundle: "com.apple.Numbers"),
         ev(.fileRenamed, start + 30, folder: "~/Finance", ext: "xlsx")]
    }

    private func appChain(_ start: TimeInterval) -> [PaveEvent] {
        [ev(.appActivated, start + 0, bundle: "com.apple.Safari"),
         ev(.appActivated, start + 1, bundle: "com.apple.Mail"),
         ev(.appActivated, start + 2, bundle: "com.apple.Notes")]
    }

    func testSurfacesTheRitualOnly() {
        var events: [PaveEvent] = []
        events += ritual(0)
        events.append(ev(.fileTrashed, 100, folder: "~/Music"))
        events += ritual(200)
        events.append(ev(.fileTrashed, 300, folder: "~/Pictures"))
        events += ritual(86_400)                    // second day
        events.append(ev(.fileTrashed, 400))
        events += appChain(500)
        events.append(ev(.fileTrashed, 600, folder: "~/Videos"))
        events += appChain(700)
        events.append(ev(.fileTrashed, 800))
        events += appChain(900)

        let runs = ReportBuilder.build(from: events)

        XCTAssertEqual(runs.count, 1, "only the mixed ritual should surface")
        let run = runs[0]
        XCTAssertEqual(run.occurrences, 3)
        XCTAssertEqual(run.distinctDays, 2)
        XCTAssertEqual(run.fingerprints, [
            PaveFingerprint(kind: .fileCreated, folder: "~/Downloads", fileExtension: "pdf"),
            PaveFingerprint(kind: .fileMoved, folder: "~/Finance", fileExtension: "pdf"),
            PaveFingerprint(kind: .appActivated, bundleID: "com.apple.Numbers"),
            PaveFingerprint(kind: .fileRenamed, folder: "~/Finance", fileExtension: "xlsx"),
        ])
    }

    func testPlainEnglishTemplate() {
        let run = ReportBuilder.build(from: ritual(0) + [ev(.fileTrashed, 90)]
                                      + ritual(200) + [ev(.fileTrashed, 290)]
                                      + ritual(400))
        XCTAssertEqual(run.count, 1)
        XCTAssertEqual(run[0].plainEnglish(), [
            "Created a .pdf in Downloads",
            "Moved a .pdf to Finance",
            "Switched to Numbers",
            "Renamed a .xlsx in Finance",
        ])
    }

    func testBelowThresholdSurfacesNothing() {
        let events = ritual(0) + ritual(200)   // only twice, min occurrences is 3
        XCTAssertTrue(ReportBuilder.build(from: events).isEmpty)
    }
}
