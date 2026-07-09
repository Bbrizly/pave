import XCTest
@testable import PaveKit

/// A tiny runner that dispatches the two file steps to FileOps, the same way
/// MacRunner does. Lets the end-to-end executor test run on Linux too.
private final class FileStepRunner: StepRunner {
    func run(_ step: Step) throws {
        switch step {
        case .moveFile(let m, let dest, let over):
            try FileOps.runMove(m, destination: dest, overwrite: over)
        case .renameFile(let m, let tmpl):
            try FileOps.runRename(m, nameTemplate: tmpl)
        default: break
        }
    }
}

final class FileStepTests: XCTestCase {
    private let fm = FileManager.default

    private func tempDir() -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("file-step-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a file and stamp its modification date so "newest" is deterministic.
    @discardableResult
    private func write(_ name: String, in dir: URL, mtime: Date, body: String = "x") -> URL {
        let url = dir.appendingPathComponent(name)
        try? body.data(using: .utf8)!.write(to: url)
        try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    private func roundTrip(_ step: Step) throws -> Step {
        let data = try JSONEncoder().encode([step])
        return try JSONDecoder().decode([Step].self, from: data)[0]
    }

    private let fixedToday: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 10
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    // MARK: codec

    func testMoveFileRoundTripAllFields() throws {
        let step = Step.moveFile(
            matcher: FileMatcher(folder: "~/Downloads", ext: "pdf", which: .newest),
            destination: "~/Finance/statement.pdf",
            overwrite: true)
        XCTAssertEqual(try roundTrip(step), step)
    }

    func testRenameFileRoundTripAllFields() throws {
        let step = Step.renameFile(
            matcher: FileMatcher(folder: "~/Downloads", ext: nil),
            nameTemplate: "{name}-{date}.{ext}")
        XCTAssertEqual(try roundTrip(step), step)
    }

    func testMoveFileOverwriteDefaultsFalse() throws {
        let json = #"[{"type":"moveFile","matcher":{"folder":"~/Downloads"},"destination":"~/x"}]"#
        let step = try JSONDecoder().decode([Step].self, from: Data(json.utf8))[0]
        XCTAssertEqual(step, .moveFile(
            matcher: FileMatcher(folder: "~/Downloads"), destination: "~/x", overwrite: false))
    }

    func testFileMatcherEncodesExtensionKeyAndWhichString() throws {
        let m = FileMatcher(folder: "~/D", ext: "pdf")
        let data = try JSONEncoder().encode(m)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["extension"] as? String, "pdf")
        XCTAssertEqual(obj["which"] as? String, "newest")
        XCTAssertNil(obj["ext"])
    }

    func testFileMatcherUnknownWhichFallsBackToNewest() throws {
        let json = #"{"folder":"x","which":"oldest"}"#
        let m = try JSONDecoder().decode(FileMatcher.self, from: Data(json.utf8))
        XCTAssertEqual(m.which, .newest)
    }

    // MARK: malformed -> unknown + disabled

    func testMalformedMoveFileBecomesUnknown() throws {
        // missing destination
        let json = #"[{"type":"moveFile","matcher":{"folder":"~/Downloads"}}]"#
        let step = try JSONDecoder().decode([Step].self, from: Data(json.utf8))[0]
        XCTAssertTrue(step.isUnknown)
    }

    func testMalformedMoveFileMissingMatcherBecomesUnknown() throws {
        let json = #"[{"type":"moveFile","destination":"~/x"}]"#
        let step = try JSONDecoder().decode([Step].self, from: Data(json.utf8))[0]
        XCTAssertTrue(step.isUnknown)
    }

    func testMalformedRenameFileBecomesUnknown() throws {
        let json = #"[{"type":"renameFile","matcher":{"folder":"~/Downloads"}}]"#
        let step = try JSONDecoder().decode([Step].self, from: Data(json.utf8))[0]
        XCTAssertTrue(step.isUnknown)
    }

    func testMacroWithMalformedFileStepIsDisabled() throws {
        let json = """
        {"id":"6F9B2C6E-1111-2222-3333-444455556666",
         "steps":[{"type":"moveFile","matcher":{"folder":"~/Downloads"}}]}
        """
        let m = try JSONDecoder().decode(Macro.self, from: Data(json.utf8))
        XCTAssertTrue(m.hasUnknownSteps)
    }

    // MARK: template resolution

    func testTemplateDateAndMonth() {
        let (name, usedN) = FileOps.renderTemplate(
            "{name}-{date}-{month}.{ext}", stem: "report", ext: "pdf",
            dir: tempDir(), today: fixedToday)
        XCTAssertEqual(name, "report-2026-07-10-July 2026.pdf")
        XCTAssertFalse(usedN)
    }

    func testTemplateUnknownTokenLeftLiteral() {
        let (name, _) = FileOps.renderTemplate(
            "{foo}-{name}", stem: "doc", ext: "txt", dir: tempDir(), today: fixedToday)
        XCTAssertEqual(name, "{foo}-doc")
    }

    func testTemplateNPicksSmallestFreeInteger() {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        write("file-1.txt", in: dir, mtime: Date())
        write("file-2.txt", in: dir, mtime: Date())
        let (name, usedN) = FileOps.renderTemplate(
            "file-{n}.txt", stem: "x", ext: "txt", dir: dir, today: fixedToday)
        XCTAssertEqual(name, "file-3.txt")
        XCTAssertTrue(usedN)
    }

    func testTemplateNIsOneWhenNoCollision() {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let (name, usedN) = FileOps.renderTemplate(
            "file-{n}.txt", stem: "x", ext: "txt", dir: dir, today: fixedToday)
        XCTAssertEqual(name, "file-1.txt")
        XCTAssertTrue(usedN)
    }

    // MARK: matcher resolution

    func testResolveNewestByModDate() {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        write("old.txt", in: dir, mtime: Date(timeIntervalSince1970: 1000))
        let newer = write("new.txt", in: dir, mtime: Date(timeIntervalSince1970: 2000))
        let hit = FileOps.resolveNewest(FileMatcher(folder: dir.path))
        XCTAssertEqual(hit?.lastPathComponent, newer.lastPathComponent)
    }

    func testResolveNewestHonorsExtension() {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let pdf = write("a.pdf", in: dir, mtime: Date(timeIntervalSince1970: 1000))
        write("b.txt", in: dir, mtime: Date(timeIntervalSince1970: 2000)) // newer, wrong ext
        let hit = FileOps.resolveNewest(FileMatcher(folder: dir.path, ext: "pdf"))
        XCTAssertEqual(hit?.lastPathComponent, pdf.lastPathComponent)
    }

    func testResolveNewestNoMatchIsNil() {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        write("b.txt", in: dir, mtime: Date())
        XCTAssertNil(FileOps.resolveNewest(FileMatcher(folder: dir.path, ext: "pdf")))
    }

    // MARK: move

    func testMoveNoMatchFailsCleanly() {
        let src = tempDir()
        let dst = tempDir()
        defer { try? fm.removeItem(at: src); try? fm.removeItem(at: dst) }
        XCTAssertThrowsError(try FileOps.runMove(
            FileMatcher(folder: src.path, ext: "pdf"),
            destination: dst.appendingPathComponent("out.pdf").path, overwrite: false)) { err in
            XCTAssertTrue("\(err)".contains("no .pdf"))
        }
    }

    func testMoveSucceeds() throws {
        let src = tempDir()
        let dst = tempDir()
        defer { try? fm.removeItem(at: src); try? fm.removeItem(at: dst) }
        let file = write("a.txt", in: src, mtime: Date())
        let out = dst.appendingPathComponent("moved.txt")
        try FileOps.runMove(FileMatcher(folder: src.path), destination: out.path, overwrite: false)
        XCTAssertTrue(fm.fileExists(atPath: out.path))
        XCTAssertFalse(fm.fileExists(atPath: file.path))
    }

    func testMoveIntoExistingFolderKeepsName() throws {
        let src = tempDir()
        let dst = tempDir()
        defer { try? fm.removeItem(at: src); try? fm.removeItem(at: dst) }
        write("a.txt", in: src, mtime: Date())
        try FileOps.runMove(FileMatcher(folder: src.path), destination: dst.path, overwrite: false)
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("a.txt").path))
    }

    func testMoveNoClobberFailsWhenDestExists() {
        let src = tempDir()
        let dst = tempDir()
        defer { try? fm.removeItem(at: src); try? fm.removeItem(at: dst) }
        write("a.txt", in: src, mtime: Date())
        write("out.txt", in: dst, mtime: Date(), body: "keep me")
        let out = dst.appendingPathComponent("out.txt")
        XCTAssertThrowsError(try FileOps.runMove(
            FileMatcher(folder: src.path), destination: out.path, overwrite: false)) { err in
            XCTAssertTrue("\(err)".contains("already exists"))
        }
        // destination is untouched, source still there
        XCTAssertEqual(try? String(contentsOf: out, encoding: .utf8), "keep me")
        XCTAssertTrue(fm.fileExists(atPath: src.appendingPathComponent("a.txt").path))
    }

    func testMoveOverwriteReplacesFile() throws {
        let src = tempDir()
        let dst = tempDir()
        defer { try? fm.removeItem(at: src); try? fm.removeItem(at: dst) }
        write("a.txt", in: src, mtime: Date(), body: "new content")
        write("out.txt", in: dst, mtime: Date(), body: "old content")
        let out = dst.appendingPathComponent("out.txt")
        try FileOps.runMove(FileMatcher(folder: src.path), destination: out.path, overwrite: true)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "new content")
        XCTAssertFalse(fm.fileExists(atPath: src.appendingPathComponent("a.txt").path))
    }

    func testMoveOverwriteRefusesToReplaceFolder() {
        let src = tempDir()
        let dst = tempDir()
        defer { try? fm.removeItem(at: src); try? fm.removeItem(at: dst) }
        write("a.txt", in: src, mtime: Date())
        // The destination path resolves onto a folder that already holds a
        // subdirectory named exactly like the source file. Even with overwrite
        // on, a folder must never be replaced.
        let clash = dst.appendingPathComponent("a.txt")
        try? fm.createDirectory(at: clash, withIntermediateDirectories: true)
        XCTAssertThrowsError(try FileOps.runMove(
            FileMatcher(folder: src.path), destination: dst.path, overwrite: true)) { err in
            XCTAssertTrue("\(err)".contains("folder"))
        }
        // The clashing folder still exists and the source file is untouched.
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: clash.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(fm.fileExists(atPath: src.appendingPathComponent("a.txt").path))
    }

    // MARK: rename

    func testRenameSucceeds() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        write("scan001.pdf", in: dir, mtime: fixedToday)
        try FileOps.runRename(
            FileMatcher(folder: dir.path, ext: "pdf"), nameTemplate: "invoice-{date}.{ext}")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("invoice-2026-07-10.pdf").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("scan001.pdf").path))
    }

    func testRenameNoClobberFailsWithoutNToken() {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        write("a.txt", in: dir, mtime: Date(timeIntervalSince1970: 2000))
        write("taken.txt", in: dir, mtime: Date(timeIntervalSince1970: 1000), body: "keep")
        XCTAssertThrowsError(try FileOps.runRename(
            FileMatcher(folder: dir.path), nameTemplate: "taken.txt")) { err in
            XCTAssertTrue("\(err)".contains("already exists"))
        }
        XCTAssertEqual(
            try? String(contentsOf: dir.appendingPathComponent("taken.txt"), encoding: .utf8), "keep")
    }

    func testRenameWithNTokenAvoidsCollision() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        write("a.txt", in: dir, mtime: Date(timeIntervalSince1970: 2000))
        write("doc-1.txt", in: dir, mtime: Date(timeIntervalSince1970: 1000), body: "keep")
        try FileOps.runRename(FileMatcher(folder: dir.path), nameTemplate: "doc-{n}.txt")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("doc-2.txt").path))
        // Existing doc-1.txt untouched.
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("doc-1.txt"), encoding: .utf8), "keep")
    }

    // MARK: executor end to end

    func testExecutorRunsMoveFileEndToEnd() {
        let src = tempDir()
        let dst = tempDir()
        defer { try? fm.removeItem(at: src); try? fm.removeItem(at: dst) }
        write("report.pdf", in: src, mtime: Date())
        let out = dst.appendingPathComponent("report.pdf")
        let macro = Macro(name: "File it", steps: [
            .moveFile(matcher: FileMatcher(folder: src.path, ext: "pdf"),
                      destination: out.path, overwrite: false),
        ])
        let done = expectation(description: "done")
        Executor().run(macro, with: FileStepRunner()) { result in
            if case .failure(let e) = result { XCTFail("should succeed: \(e)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(fm.fileExists(atPath: out.path))
        XCTAssertFalse(fm.fileExists(atPath: src.appendingPathComponent("report.pdf").path))
    }
}
