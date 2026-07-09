import Foundation

/// A prefix-to-continuation index built from one ledger window. Offline and
/// cheap to rebuild: hand it events, get back a lookup of "after these first
/// k steps, here is what usually followed". The live matcher reads it, it
/// never mutates.
///
/// Build rules mirror ReportBuilder: macro-origin and system events and
/// bulkChange are dropped, events are split by session, and only contiguous
/// runs inside a session count. A run is keyed as prefix (first k fingerprints)
/// plus remainder (the rest). Nested continuations from one physical ritual
/// (the length-3 slice of a length-4 run) are collapsed into the longer one.
public struct PathIndex: Sendable {

    /// One thing that followed a prefix, with how often and when it was seen.
    /// occurrenceEventIDs holds the concrete event ids per occurrence so a later
    /// stage can recover the real events and turn the path into a macro.
    public struct Continuation: Equatable, Sendable {
        public let remainder: [PaveFingerprint]
        public let occurrences: Int
        public let lastSeen: Date
        public let distinctDays: Int
        public let occurrenceEventIDs: [[UUID]]

        public init(remainder: [PaveFingerprint], occurrences: Int,
                    lastSeen: Date, distinctDays: Int,
                    occurrenceEventIDs: [[UUID]]) {
            self.remainder = remainder
            self.occurrences = occurrences
            self.lastSeen = lastSeen
            self.distinctDays = distinctDays
            self.occurrenceEventIDs = occurrenceEventIDs
        }
    }

    private let table: [[PaveFingerprint]: [Continuation]]

    /// The prefix length this index was built for. The matcher keys off it.
    public let prefixLength: Int

    private init(table: [[PaveFingerprint]: [Continuation]], prefixLength: Int) {
        self.table = table
        self.prefixLength = prefixLength
    }

    /// Every indexed prefix. The matcher walks these against its live window.
    public var prefixes: [[PaveFingerprint]] { Array(table.keys) }

    /// Continuations seen after a prefix, most seen first. Empty if unknown.
    public func continuations(after prefix: [PaveFingerprint]) -> [Continuation] {
        (table[prefix] ?? []).sorted { $0.occurrences > $1.occurrences }
    }

    // MARK: build

    public static func build(from events: [PaveEvent], config: PaveConfig = PaveConfig()) -> PathIndex {
        let k = max(1, config.matchPrefixLength)
        let minLen = k + 1                         // need at least one remainder step
        let maxLen = max(minLen, config.reportMaxLength)

        // Drop Pave's own actions and system churn, same as ReportBuilder.
        let kept = events.filter { keepable($0) }.sorted { $0.timestamp < $1.timestamp }

        // Split into sessions, preserving order. nil session is its own bucket.
        var sessions: [String: [PaveEvent]] = [:]
        for e in kept {
            let key = e.sessionID?.uuidString ?? "nil"
            sessions[key, default: []].append(e)
        }

        // Count every contiguous run, keyed by its full fingerprint sequence.
        var acc: [[PaveFingerprint]: Accum] = [:]
        for (_, seq) in sessions {
            let fps = seq.map { PaveFingerprint(event: $0) }
            let ids = seq.map { $0.id }
            let times = seq.map { $0.timestamp }
            let n = fps.count
            guard n >= minLen else { continue }
            for i in 0...(n - minLen) {
                let top = min(maxLen, n - i)
                guard top >= minLen else { continue }
                for length in minLen...top {
                    let run = Array(fps[i..<i + length])
                    let runIDs = Array(ids[i..<i + length])
                    let start = times[i]
                    let end = times[i + length - 1]
                    acc[run, default: Accum()].add(start: start, end: end, ids: runIDs)
                }
            }
        }

        // Split each full run into prefix + remainder, group by prefix.
        var table: [[PaveFingerprint]: [Continuation]] = [:]
        for (run, a) in acc {
            let prefix = Array(run[0..<k])
            let remainder = Array(run[k...])
            let c = Continuation(remainder: remainder,
                                 occurrences: a.ids.count,
                                 lastSeen: a.last,
                                 distinctDays: a.days.count,
                                 occurrenceEventIDs: a.ids)
            table[prefix, default: []].append(c)
        }

        // Collapse nested continuations: a shorter remainder that is the head of
        // a longer one and was seen exactly as often came from the same ritual.
        // Keep the longer, more informative one.
        for (prefix, conts) in table {
            table[prefix] = conts.filter { c in
                !conts.contains { other in
                    other.remainder.count > c.remainder.count
                        && other.occurrences == c.occurrences
                        && isHead(c.remainder, of: other.remainder)
                }
            }
        }

        return PathIndex(table: table, prefixLength: k)
    }

    // MARK: helpers

    private struct Accum {
        var last = Date.distantPast
        var days: Set<Int> = []
        var ids: [[UUID]] = []
        mutating func add(start: Date, end: Date, ids runIDs: [UUID]) {
            if end > last { last = end }
            days.insert(Int((start.timeIntervalSince1970 / 86_400).rounded(.down)))
            ids.append(runIDs)
        }
    }

    /// Keep user-caused file and app work. Drop macro-origin (Pave's own runs),
    /// system events (screen locked), and collapsed bulk changes.
    static func keepable(_ e: PaveEvent) -> Bool {
        if case .user = e.origin {} else { return false }
        return e.kind != .bulkChange
    }

    private static func isHead(_ short: [PaveFingerprint], of long: [PaveFingerprint]) -> Bool {
        guard short.count < long.count else { return false }
        return Array(long[0..<short.count]) == short
    }
}
