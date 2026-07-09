import Foundation

#if canImport(SQLite3)
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local append-only ledger of PaveEvents on a raw SQLite (WAL) database.
/// All work runs on one serial queue, never on the main thread. Append buffers
/// and flushes by size or age; it never throws to the caller on the hot path.
/// The owner MUST call flush() on shutdown or idle to persist the tail.
public final class PaveLedger {
    public let url: URL
    private let config: PaveConfig
    private let now: () -> Date
    private let queue = DispatchQueue(label: "pave.ledger")

    private var db: OpaquePointer?
    private var buffer: [PaveEvent] = []
    private var firstBufferedAt: Date?

    private var _lastError: String?
    private var _lastWrite: Date?
    private var _droppedEvents: Int = 0

    private static let bufferCap = 10_000

    public init(url: URL, config: PaveConfig = PaveConfig(), now: @escaping () -> Date = { Date() }) {
        self.url = url
        self.config = config
        self.now = now
        queue.sync { self.openDB() }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public var lastError: String? { queue.sync { _lastError } }

    // MARK: append and flush

    public func append(_ e: PaveEvent) {
        queue.async {
            self.buffer.append(e)
            if self.firstBufferedAt == nil { self.firstBufferedAt = self.now() }
            if self.buffer.count > Self.bufferCap {
                let over = self.buffer.count - Self.bufferCap
                self.buffer.removeFirst(over)
                self._droppedEvents += over
            }
            let age = self.now().timeIntervalSince(self.firstBufferedAt ?? self.now())
            if self.buffer.count >= self.config.flushBatchSize || age >= self.config.flushMaxLatencySeconds {
                self._flush()
            }
        }
    }

    public func flush() { queue.sync { self._flush() } }

    private func _flush() {
        guard !buffer.isEmpty, let db else { return }
        let sql = """
        INSERT OR REPLACE INTO pave_events
        (id, timestamp, kind, origin_type, origin_id, bundle_id, folder,
         file_extension, subject_hash, reliability, session_id, raw_name, previous_name)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        guard sqlite3_exec(db, "BEGIN;", nil, nil, nil) == SQLITE_OK else {
            _lastError = lastMessage(); return
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            _lastError = lastMessage()
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return
        }
        var ok = true
        for e in buffer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindEvent(stmt, e)
            if sqlite3_step(stmt) != SQLITE_DONE { ok = false; _lastError = lastMessage(); break }
        }
        sqlite3_finalize(stmt)
        if ok && sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK {
            buffer.removeAll()
            firstBufferedAt = nil
            _lastWrite = now()
        } else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            // Keep the buffer; the next append retries.
        }
    }

    // MARK: reads

    public func events(in range: Range<Date>, limit: Int) -> [PaveEvent] {
        queue.sync {
            guard let db else { return [] }
            let sql = """
            SELECT id, timestamp, kind, origin_type, origin_id, bundle_id, folder,
                   file_extension, subject_hash, reliability, session_id, raw_name, previous_name
            FROM pave_events WHERE timestamp >= ? AND timestamp < ?
            ORDER BY timestamp ASC LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                _lastError = lastMessage(); return []
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, range.lowerBound.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, range.upperBound.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(limit))
            var out: [PaveEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(readEvent(stmt)) }
            return out
        }
    }

    /// Fetch specific events by id, ordered by timestamp. Chunks the IN
    /// clause so a large occurrence set never builds one giant statement.
    /// Missing ids are just absent from the result, never an error.
    public func events(ids: [UUID]) -> [PaveEvent] {
        queue.sync {
            guard let db, !ids.isEmpty else { return [] }
            var out: [PaveEvent] = []
            for chunk in ids.chunked(into: 200) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let sql = """
                SELECT id, timestamp, kind, origin_type, origin_id, bundle_id, folder,
                       file_extension, subject_hash, reliability, session_id, raw_name, previous_name
                FROM pave_events WHERE id IN (\(placeholders))
                ORDER BY timestamp ASC;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    _lastError = lastMessage(); continue
                }
                for (i, id) in chunk.enumerated() {
                    bindText(stmt, Int32(i + 1), id.uuidString)
                }
                while sqlite3_step(stmt) == SQLITE_ROW { out.append(readEvent(stmt)) }
                sqlite3_finalize(stmt)
            }
            return out.sorted { $0.timestamp < $1.timestamp }
        }
    }

    public func counts(byKindSince since: Date) -> [PaveEventKind: Int] {
        queue.sync {
            guard let db else { return [:] }
            let sql = "SELECT kind, COUNT(*) FROM pave_events WHERE timestamp >= ? GROUP BY kind;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                _lastError = lastMessage(); return [:]
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
            var out: [PaveEventKind: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let raw = columnText(stmt, 0), let k = PaveEventKind(rawValue: raw) {
                    out[k] = Int(sqlite3_column_int(stmt, 1))
                }
            }
            return out
        }
    }

    // MARK: maintenance

    public func prune(now nowDate: Date, retentionDays: Int) {
        queue.sync {
            guard let db else { return }
            let cutoff = nowDate.timeIntervalSince1970 - Double(retentionDays) * 86_400
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM pave_events WHERE timestamp < ?;", -1, &stmt, nil) == SQLITE_OK else {
                _lastError = lastMessage(); return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            if sqlite3_step(stmt) != SQLITE_DONE { _lastError = lastMessage() }
        }
    }

    public func deleteAll() {
        queue.sync {
            buffer.removeAll()
            firstBufferedAt = nil
            _droppedEvents = 0
            guard let db else { return }
            if sqlite3_exec(db, "DELETE FROM pave_events;", nil, nil, nil) != SQLITE_OK {
                _lastError = lastMessage()
            }
        }
    }

    public func stats() -> (rows: Int, dbBytes: Int64, lastWrite: Date?, droppedEvents: Int) {
        queue.sync {
            var rows = 0
            if let db {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM pave_events;", -1, &stmt, nil) == SQLITE_OK {
                    if sqlite3_step(stmt) == SQLITE_ROW { rows = Int(sqlite3_column_int(stmt, 0)) }
                }
                sqlite3_finalize(stmt)
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attrs?[.size] as? Int64) ?? 0
            return (rows, bytes, _lastWrite, _droppedEvents)
        }
    }

    // MARK: open and recover

    private func openDB() {
        if !tryOpen() {
            let aside = url.path + ".corrupt-\(Int(now().timeIntervalSince1970))"
            try? FileManager.default.moveItem(atPath: url.path, toPath: aside)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            _ = tryOpen()
        }
    }

    private func tryOpen() -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        sqlite3_busy_timeout(handle, 1000)
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        // Sanity: a garbage file fails here with NOTADB, which triggers recovery.
        if sqlite3_exec(handle, "SELECT COUNT(*) FROM sqlite_master;", nil, nil, nil) != SQLITE_OK {
            sqlite3_close(handle); return false
        }
        // The v1 base table. user_version is not set here on purpose: migrate()
        // owns it, so reopening a v2 db never clobbers its version back to 1.
        let schema = """
        CREATE TABLE IF NOT EXISTS pave_events (
            id TEXT PRIMARY KEY, timestamp REAL NOT NULL, kind TEXT NOT NULL,
            origin_type TEXT NOT NULL, origin_id TEXT, bundle_id TEXT, folder TEXT,
            file_extension TEXT, subject_hash TEXT, reliability REAL NOT NULL, session_id TEXT);
        CREATE INDEX IF NOT EXISTS idx_events_signature ON pave_events(kind, bundle_id);
        CREATE INDEX IF NOT EXISTS idx_events_time ON pave_events(timestamp);
        CREATE INDEX IF NOT EXISTS idx_events_session ON pave_events(session_id, timestamp);
        """
        if sqlite3_exec(handle, schema, nil, nil, nil) != SQLITE_OK {
            sqlite3_close(handle); return false
        }
        if !migrate(handle) {
            sqlite3_close(handle); return false
        }
        db = handle
        return true
    }

    /// Stepwise schema migration keyed on PRAGMA user_version. Each step is
    /// forward-only and idempotent across the version gate, so a fresh db and an
    /// old v1 db both land on the newest shape. Never destructive.
    private func migrate(_ handle: OpaquePointer) -> Bool {
        var version = userVersion(handle)
        // A brand-new db reports 0 but the CREATE above just built the v1 table.
        if version < 1 {
            guard setUserVersion(handle, 1) else { return false }
            version = 1
        }
        // v1 -> v2: raw filename evidence columns. Existing rows stay null.
        if version < 2 {
            guard sqlite3_exec(handle, "ALTER TABLE pave_events ADD COLUMN raw_name TEXT;", nil, nil, nil) == SQLITE_OK,
                  sqlite3_exec(handle, "ALTER TABLE pave_events ADD COLUMN previous_name TEXT;", nil, nil, nil) == SQLITE_OK,
                  setUserVersion(handle, 2) else { return false }
            version = 2
        }
        return true
    }

    private func userVersion(_ handle: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// PRAGMA cannot bind a parameter, so the integer is interpolated. It is our
    /// own small constant, never user input, so no injection surface.
    private func setUserVersion(_ handle: OpaquePointer, _ v: Int) -> Bool {
        sqlite3_exec(handle, "PRAGMA user_version=\(v);", nil, nil, nil) == SQLITE_OK
    }

    // MARK: row bind and read

    private func bindEvent(_ stmt: OpaquePointer?, _ e: PaveEvent) {
        bindText(stmt, 1, e.id.uuidString)
        sqlite3_bind_double(stmt, 2, e.timestamp.timeIntervalSince1970)
        bindText(stmt, 3, e.kind.rawValue)
        switch e.origin {
        case .user: bindText(stmt, 4, "user"); sqlite3_bind_null(stmt, 5)
        case .system: bindText(stmt, 4, "system"); sqlite3_bind_null(stmt, 5)
        case .macro(let id): bindText(stmt, 4, "macro"); bindText(stmt, 5, id.uuidString)
        }
        bindText(stmt, 6, e.bundleID)
        bindText(stmt, 7, e.folder)
        bindText(stmt, 8, e.fileExtension)
        bindText(stmt, 9, e.subjectHash)
        sqlite3_bind_double(stmt, 10, e.reliability)
        bindText(stmt, 11, e.sessionID?.uuidString)
        bindText(stmt, 12, e.rawName)
        bindText(stmt, 13, e.previousName)
    }

    private func readEvent(_ stmt: OpaquePointer?) -> PaveEvent {
        let id = columnText(stmt, 0).flatMap { UUID(uuidString: $0) } ?? UUID()
        let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let kind = columnText(stmt, 2).flatMap(PaveEventKind.init(rawValue:)) ?? .bulkChange
        let origin: PaveEventOrigin
        switch columnText(stmt, 3) {
        case "system": origin = .system
        case "macro": origin = columnText(stmt, 4).flatMap { UUID(uuidString: $0) }.map(PaveEventOrigin.macro) ?? .user
        default: origin = .user
        }
        return PaveEvent(id: id, timestamp: ts, kind: kind, origin: origin,
                         bundleID: columnText(stmt, 5), folder: columnText(stmt, 6),
                         fileExtension: columnText(stmt, 7), subjectHash: columnText(stmt, 8),
                         reliability: sqlite3_column_double(stmt, 9),
                         sessionID: columnText(stmt, 10).flatMap { UUID(uuidString: $0) },
                         rawName: columnText(stmt, 11), previousName: columnText(stmt, 12))
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, idx) }
    }

    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }

    private func lastMessage() -> String {
        guard let db, let m = sqlite3_errmsg(db) else { return "unknown sqlite error" }
        return String(cString: m)
    }
}

private extension Array {
    /// Splits into pieces of at most `size`, last piece may be shorter.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
#endif
