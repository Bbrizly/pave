import XCTest
@testable import PaveKit

#if canImport(SQLite3)
import SQLite3

final class LedgerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pave-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var dbURL: URL { dir.appendingPathComponent("events.sqlite") }

    private func event(_ kind: PaveEventKind = .fileCreated, at t: TimeInterval) -> PaveEvent {
        PaveEvent(timestamp: Date(timeIntervalSince1970: t), kind: kind,
                  bundleID: "com.test", folder: "~/Downloads", fileExtension: "pdf",
                  subjectHash: PaveHash.stable("f-\(t)"))
    }

    private var wideRange: Range<Date> {
        Date(timeIntervalSince1970: 0)..<Date(timeIntervalSince1970: 10_000_000_000)
    }

    func testRoundTrip() {
        let led = PaveLedger(url: dbURL)
        let events = [event(at: 100), event(.fileMoved, at: 200), event(.appActivated, at: 300)]
        for e in events { led.append(e) }
        led.flush()
        let back = led.events(in: wideRange, limit: 100)
        XCTAssertEqual(Set(back.map { $0.id }), Set(events.map { $0.id }))
        XCTAssertEqual(back.map { $0.kind }, [.fileCreated, .fileMoved, .appActivated])
    }

    func testBatchingFlush() {
        var cfg = PaveConfig()
        cfg.flushBatchSize = 3
        let fixed = Date(timeIntervalSince1970: 5_000)
        let led = PaveLedger(url: dbURL, config: cfg, now: { fixed })
        led.append(event(at: 1)); led.append(event(at: 2))
        XCTAssertEqual(led.events(in: wideRange, limit: 100).count, 0, "buffered, not flushed")
        led.append(event(at: 3))
        XCTAssertEqual(led.events(in: wideRange, limit: 100).count, 3, "batch size reached, auto-flushed")
    }

    func testPrune() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let led = PaveLedger(url: dbURL)
        led.append(event(at: now.timeIntervalSince1970 - 40 * 86_400))   // old
        led.append(event(at: now.timeIntervalSince1970))                 // fresh
        led.flush()
        led.prune(now: now, retentionDays: 30)
        XCTAssertEqual(led.events(in: wideRange, limit: 100).count, 1)
    }

    func testEventsByIDsReturnsOrderedSubset() {
        let led = PaveLedger(url: dbURL)
        let a = event(.fileCreated, at: 300)
        let b = event(.fileRenamed, at: 100)
        let c = event(.fileMoved, at: 200)
        let unrelated = event(.appActivated, at: 50)
        for e in [a, b, c, unrelated] { led.append(e) }
        led.flush()

        let back = led.events(ids: [a.id, b.id, c.id])
        XCTAssertEqual(back.map { $0.id }, [b.id, c.id, a.id], "ordered by timestamp, not request order")
        XCTAssertFalse(back.contains { $0.id == unrelated.id })
    }

    func testEventsByIDsChunksLargeRequests() {
        let led = PaveLedger(url: dbURL)
        var ids: [UUID] = []
        for i in 0..<450 {
            let e = event(.fileCreated, at: TimeInterval(i))
            ids.append(e.id)
            led.append(e)
        }
        led.flush()
        XCTAssertEqual(led.events(ids: ids).count, 450, "IN-clause chunking must not drop rows")
    }

    func testEventsByIDsIgnoresMissingIDs() {
        let led = PaveLedger(url: dbURL)
        let e = event(.fileCreated, at: 100)
        led.append(e)
        led.flush()
        let back = led.events(ids: [e.id, UUID()])
        XCTAssertEqual(back.map { $0.id }, [e.id])
    }

    func testCountsByKind() {
        let led = PaveLedger(url: dbURL)
        led.append(event(.fileCreated, at: 100))
        led.append(event(.fileCreated, at: 110))
        led.append(event(.appActivated, at: 120))
        led.flush()
        let counts = led.counts(byKindSince: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(counts[.fileCreated], 2)
        XCTAssertEqual(counts[.appActivated], 1)
    }

    func testDeleteAll() {
        let led = PaveLedger(url: dbURL)
        led.append(event(at: 100)); led.flush()
        led.deleteAll()
        XCTAssertEqual(led.stats().rows, 0)
    }

    func testStats() {
        let led = PaveLedger(url: dbURL)
        for i in 0..<5 { led.append(event(at: TimeInterval(i))) }
        led.flush()
        let s = led.stats()
        XCTAssertEqual(s.rows, 5)
        XCTAssertGreaterThan(s.dbBytes, 0)
        XCTAssertNotNil(s.lastWrite)
    }

    func testMigrationFromV1AddsNameColumns() throws {
        // Hand-build a v1-shaped db: the old schema with no name columns,
        // user_version=1, and one row. Then open it with PaveLedger and confirm
        // the migration added the columns, kept the old row (names null), and
        // that a new event with names round-trips.
        let oldID = "11111111-1111-1111-1111-111111111111"
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &handle), SQLITE_OK)
        let v1 = """
        CREATE TABLE pave_events (
            id TEXT PRIMARY KEY, timestamp REAL NOT NULL, kind TEXT NOT NULL,
            origin_type TEXT NOT NULL, origin_id TEXT, bundle_id TEXT, folder TEXT,
            file_extension TEXT, subject_hash TEXT, reliability REAL NOT NULL, session_id TEXT);
        PRAGMA user_version=1;
        INSERT INTO pave_events (id, timestamp, kind, origin_type, folder, reliability)
        VALUES ('\(oldID)', 100.0, 'fileCreated', 'user', '~/Downloads', 1.0);
        """
        XCTAssertEqual(sqlite3_exec(handle, v1, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let led = PaveLedger(url: dbURL)
        let named = PaveEvent(timestamp: Date(timeIntervalSince1970: 200), kind: .fileRenamed,
                              folder: "~/Downloads", fileExtension: "pdf", subjectHash: "h",
                              rawName: "new.pdf", previousName: "old.pdf")
        led.append(named)
        led.flush()

        let back = led.events(in: wideRange, limit: 100)
        XCTAssertEqual(back.count, 2, "old row survived the migration")
        let old = back.first { $0.id.uuidString == oldID.uppercased() }
        XCTAssertNotNil(old)
        XCTAssertNil(old?.rawName, "pre-existing row has no name")
        XCTAssertNil(old?.previousName)
        let fresh = back.first { $0.id == named.id }
        XCTAssertEqual(fresh?.rawName, "new.pdf", "migration made the name columns writable")
        XCTAssertEqual(fresh?.previousName, "old.pdf")
    }

    func testCorruptFileRecovery() throws {
        try Data("not a database".utf8).write(to: dbURL)
        let led = PaveLedger(url: dbURL)
        led.append(event(at: 100)); led.flush()
        XCTAssertEqual(led.stats().rows, 1, "recovered and usable after corruption")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.contains(".corrupt-") }, "corrupt db moved aside")
    }
}

#endif
