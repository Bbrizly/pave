import XCTest
@testable import PaveKit

final class TemplateInferencerTests: XCTestCase {

    /// Build a UTC date at midnight, matching the inferencer's own formatter.
    private func day(_ s: String) -> Date {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)!
    }

    private func rn(_ previous: String, _ new: String, _ at: Date) -> (previous: String, new: String, at: Date) {
        (previous: previous, new: new, at: at)
    }

    func testFullDateTemplate() {
        let renames = [
            rn("scan.pdf", "Statement 2026-05-01.pdf", day("2026-05-01")),
            rn("scan.pdf", "Statement 2026-06-01.pdf", day("2026-06-01")),
            rn("scan.pdf", "Statement 2026-07-01.pdf", day("2026-07-01")),
        ]
        let h = TemplateInferencer.infer(renames: renames, config: PaveConfig())
        XCTAssertEqual(h?.template, "Statement {date}.pdf")
        XCTAssertEqual(h?.confidence, 1.0)
    }

    func testCounterTemplate() {
        let base = day("2026-01-01")
        let renames = [
            rn("a.pdf", "invoice-1.pdf", base),
            rn("a.pdf", "invoice-2.pdf", base.addingTimeInterval(86_400)),
            rn("a.pdf", "invoice-3.pdf", base.addingTimeInterval(2 * 86_400)),
        ]
        let h = TemplateInferencer.infer(renames: renames, config: PaveConfig())
        XCTAssertEqual(h?.template, "invoice-{n}.pdf")
        XCTAssertEqual(h?.confidence, 1.0)
    }

    func testNameCarriedThrough() {
        let base = day("2026-01-01")
        let renames = [
            rn("report.pdf", "report-final.pdf", base),
            rn("summary.pdf", "summary-final.pdf", base),
            rn("notes.pdf", "notes-final.pdf", base),
        ]
        let h = TemplateInferencer.infer(renames: renames, config: PaveConfig())
        XCTAssertEqual(h?.template, "{name}-final.pdf")
        XCTAssertEqual(h?.confidence, 1.0)
    }

    func testConstantRename() {
        let base = day("2026-01-01")
        let renames = [
            rn("aaa.pdf", "final.pdf", base),
            rn("bbb.pdf", "final.pdf", base),
            rn("ccc.pdf", "final.pdf", base),
        ]
        let h = TemplateInferencer.infer(renames: renames, config: PaveConfig())
        XCTAssertEqual(h?.template, "final.pdf")
    }

    func testTwoOccurrencesRejected() {
        let base = day("2026-01-01")
        let renames = [
            rn("a.pdf", "invoice-1.pdf", base),
            rn("a.pdf", "invoice-2.pdf", base.addingTimeInterval(86_400)),
        ]
        XCTAssertNil(TemplateInferencer.infer(renames: renames, config: PaveConfig()),
                     "fewer than three occurrences is not enough evidence")
    }

    func testNoPatternReturnsNil() {
        let base = day("2026-01-01")
        let renames = [
            rn("q.pdf", "aaa.pdf", base),
            rn("w.pdf", "bbb.pdf", base),
            rn("e.pdf", "xyz.pdf", base),
        ]
        XCTAssertNil(TemplateInferencer.infer(renames: renames, config: PaveConfig()),
                     "unrelated names must not produce a template")
    }

    func testMixedExtensionsReturnsNil() {
        let base = day("2026-01-01")
        let renames = [
            rn("a.txt", "file-1.txt", base),
            rn("a.pdf", "file-2.pdf", base.addingTimeInterval(86_400)),
            rn("a.pdf", "file-3.pdf", base.addingTimeInterval(2 * 86_400)),
        ]
        XCTAssertNil(TemplateInferencer.infer(renames: renames, config: PaveConfig()),
                     "a single template cannot span two extensions")
    }

    func testNoiseBelowThresholdReturnsNil() {
        // Two of three fit "{name}-final", the third does not. 2/3 is under 0.9.
        let base = day("2026-01-01")
        let renames = [
            rn("report.pdf", "report-final.pdf", base),
            rn("summary.pdf", "summary-final.pdf", base),
            rn("notes.pdf", "random.pdf", base),
        ]
        XCTAssertNil(TemplateInferencer.infer(renames: renames, config: PaveConfig()),
                     "confidence below templateMinConfidence must fail closed")
    }
}
