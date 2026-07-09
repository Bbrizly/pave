import XCTest
@testable import PaveKit

final class NormalizerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func stat(_ id: UInt64, _ name: String) -> FileStat {
        FileStat(fileID: id, name: name)
    }

    func testRenameInference() {
        let n = EventNormalizer()
        _ = n.ingest(.folderChanged(folder: "~/Documents", snapshot: [stat(1, "a.txt")]), at: t0)
        let out = n.ingest(.folderChanged(folder: "~/Documents", snapshot: [stat(1, "b.txt")]), at: t0.addingTimeInterval(1))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, .fileRenamed)
        XCTAssertEqual(out.first?.reliability, 0.75)
        XCTAssertEqual(out.first?.fileExtension, "txt")
    }

    func testMovePairing() {
        let n = EventNormalizer()
        _ = n.ingest(.folderChanged(folder: "A", snapshot: [stat(5, "x.pdf")]), at: t0)
        let removed = n.ingest(.folderChanged(folder: "A", snapshot: []), at: t0.addingTimeInterval(0.5))
        XCTAssertTrue(removed.isEmpty, "removal is held, not emitted yet")
        let out = n.ingest(.folderChanged(folder: "B", snapshot: [stat(5, "x.pdf")]), at: t0.addingTimeInterval(1))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, .fileMoved)
        XCTAssertEqual(out.first?.folder, "B")
        XCTAssertEqual(out.first?.reliability, 0.75)
    }

    func testUnpairedRemovalBecomesTrashed() {
        let n = EventNormalizer()
        _ = n.ingest(.folderChanged(folder: "A", snapshot: [stat(7, "y.pdf")]), at: t0)
        _ = n.ingest(.folderChanged(folder: "A", snapshot: []), at: t0.addingTimeInterval(0.5))
        // Later ingest past the window flushes the held removal as trashed.
        let out = n.ingest(.appLaunched(bundleID: "com.apple.Finder"), at: t0.addingTimeInterval(5))
        let trashed = out.filter { $0.kind == .fileTrashed }
        XCTAssertEqual(trashed.count, 1)
        XCTAssertEqual(trashed.first?.folder, "A")
    }

    func testRenameCapturesBothNames() {
        let n = EventNormalizer()
        let created = n.ingest(.folderChanged(folder: "~/Documents", snapshot: [stat(1, "a.txt")]), at: t0)
        XCTAssertEqual(created.first?.rawName, "a.txt")
        XCTAssertNil(created.first?.previousName, "a fresh file has no previous name")
        let out = n.ingest(.folderChanged(folder: "~/Documents", snapshot: [stat(1, "b.txt")]),
                           at: t0.addingTimeInterval(1))
        XCTAssertEqual(out.first?.kind, .fileRenamed)
        XCTAssertEqual(out.first?.rawName, "b.txt")
        XCTAssertEqual(out.first?.previousName, "a.txt")
    }

    func testNamesOffKeepsThemNil() {
        var cfg = PaveConfig()
        cfg.storeFileNames = false
        let n = EventNormalizer(config: cfg)
        let created = n.ingest(.folderChanged(folder: "~/Documents", snapshot: [stat(1, "a.txt")]), at: t0)
        XCTAssertNil(created.first?.rawName)
        let out = n.ingest(.folderChanged(folder: "~/Documents", snapshot: [stat(1, "b.txt")]),
                           at: t0.addingTimeInterval(1))
        XCTAssertEqual(out.first?.kind, .fileRenamed)
        XCTAssertNil(out.first?.rawName, "name storage off means no raw name")
        XCTAssertNil(out.first?.previousName, "name storage off means no previous name")
    }

    func testBurstCollapse() {
        let n = EventNormalizer()
        let snap = (1...25).map { stat(UInt64($0), "f\($0).txt") }
        let out = n.ingest(.folderChanged(folder: "C", snapshot: snap), at: t0)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, .bulkChange)
        XCTAssertEqual(out.first?.folder, "C")
    }

    func testActivationDedupe() {
        let n = EventNormalizer()
        let a = n.ingest(.appActivated(bundleID: "com.x"), at: t0)
        let b = n.ingest(.appActivated(bundleID: "com.x"), at: t0.addingTimeInterval(1))
        let c = n.ingest(.appActivated(bundleID: "com.x"), at: t0.addingTimeInterval(3))
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 0)
        XCTAssertEqual(c.count, 1)
    }

    func testExclusionFiltering() {
        let n = EventNormalizer()
        let a = n.ingest(.folderChanged(folder: "~/Downloads", snapshot: [stat(9, "big.crdownload")]), at: t0)
        XCTAssertTrue(a.isEmpty)
        let b = n.ingest(.folderChanged(folder: "~/.Trash", snapshot: [stat(10, "x.pdf")]), at: t0)
        XCTAssertTrue(b.isEmpty)
    }

    func testSessionRotationOnIdle() {
        let n = EventNormalizer()
        let e1 = n.ingest(.appLaunched(bundleID: "com.a"), at: t0)
        let same = n.ingest(.appLaunched(bundleID: "com.b"), at: t0.addingTimeInterval(60))
        // Idle is measured from the last event (t0+60), so go well past 15 min.
        let after = n.ingest(.appLaunched(bundleID: "com.c"), at: t0.addingTimeInterval(60 + 16 * 60))
        XCTAssertEqual(e1.first?.sessionID, same.first?.sessionID)
        XCTAssertNotEqual(e1.first?.sessionID, after.first?.sessionID)
    }

    func testLockedTagsSystemOrigin() {
        let n = EventNormalizer()
        let locked = n.ingest(.screenLocked, at: t0)
        XCTAssertTrue(locked.isEmpty)
        let out = n.ingest(.appLaunched(bundleID: "com.a"), at: t0.addingTimeInterval(1))
        XCTAssertEqual(out.first?.origin, .system)
        let unlocked = n.ingest(.screenUnlocked, at: t0.addingTimeInterval(2))
        XCTAssertTrue(unlocked.isEmpty)
        let out2 = n.ingest(.appLaunched(bundleID: "com.b"), at: t0.addingTimeInterval(3))
        XCTAssertEqual(out2.first?.origin, .user)
    }
}
