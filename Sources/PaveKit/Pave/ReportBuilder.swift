import Foundation

/// A repeated ritual: a contiguous run of fingerprints that recurs. This is the
/// gate instrument, not a predictor. It only counts and describes, never acts.
public struct RepeatedRun: Equatable, Sendable {
    public let fingerprints: [PaveFingerprint]
    public let occurrences: Int
    public let lastSeen: Date
    public let distinctDays: Int

    public init(fingerprints: [PaveFingerprint], occurrences: Int,
                lastSeen: Date, distinctDays: Int) {
        self.fingerprints = fingerprints
        self.occurrences = occurrences
        self.lastSeen = lastSeen
        self.distinctDays = distinctDays
    }

    /// One plain-English line per step, from a fixed template table.
    public func plainEnglish() -> [String] {
        fingerprints.map { ReportBuilder.render($0) }
    }
}

/// Finds repeated contiguous fingerprint runs. Simple n-gram counting, no gap
/// tolerance by design. Nested shorter runs are dropped in favour of the
/// longest run that contains them. Pure app-activation chains are excluded.
public enum ReportBuilder {

    public static func build(from events: [PaveEvent], config: PaveConfig = PaveConfig()) -> [RepeatedRun] {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        let fps = sorted.map { PaveFingerprint(event: $0) }
        let times = sorted.map { $0.timestamp }
        let n = fps.count
        guard n >= config.reportMinLength else { return [] }

        let maxLen = min(config.reportMaxLength, n)
        var runs: [RepeatedRun] = []

        for length in config.reportMinLength...maxLen {
            // Group every start index by its n-gram key.
            var groups: [[PaveFingerprint]: [Int]] = [:]
            for i in 0...(n - length) {
                let key = Array(fps[i..<i + length])
                groups[key, default: []].append(i)
            }
            for (key, starts) in groups {
                if isAllAppActivation(key) { continue }
                // Non-overlapping occurrences only.
                var chosen: [Int] = []
                var lastEnd = -1
                for s in starts.sorted() where s > lastEnd {
                    chosen.append(s); lastEnd = s + length - 1
                }
                guard chosen.count >= config.reportMinOccurrences else { continue }
                let starts0 = chosen.map { times[$0] }
                let ends = chosen.map { times[$0 + length - 1] }
                let days = Set(starts0.map { Int(($0.timeIntervalSince1970 / 86_400).rounded(.down)) })
                runs.append(RepeatedRun(fingerprints: key,
                                        occurrences: chosen.count,
                                        lastSeen: ends.max() ?? times[0],
                                        distinctDays: days.count))
            }
        }

        return dedupeNested(runs)
    }

    /// Drop a run when a longer kept run contains it and recurs at least as often.
    private static func dedupeNested(_ runs: [RepeatedRun]) -> [RepeatedRun] {
        let byLengthDesc = runs.sorted { $0.fingerprints.count > $1.fingerprints.count }
        var kept: [RepeatedRun] = []
        for run in byLengthDesc {
            let covered = kept.contains { longer in
                longer.fingerprints.count > run.fingerprints.count
                    && longer.occurrences >= run.occurrences
                    && contains(longer.fingerprints, run.fingerprints)
            }
            if !covered { kept.append(run) }
        }
        return kept.sorted {
            if $0.occurrences != $1.occurrences { return $0.occurrences > $1.occurrences }
            return $0.fingerprints.count > $1.fingerprints.count
        }
    }

    private static func contains(_ haystack: [PaveFingerprint], _ needle: [PaveFingerprint]) -> Bool {
        guard needle.count <= haystack.count, !needle.isEmpty else { return false }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<i + needle.count]) == needle {
            return true
        }
        return false
    }

    private static func isAllAppActivation(_ key: [PaveFingerprint]) -> Bool {
        key.allSatisfy { $0.kind == .appActivated }
    }

    // MARK: template table

    static func render(_ f: PaveFingerprint) -> String {
        let file = f.fileExtension.map { ".\($0)" }.map { "a \($0)" } ?? "a file"
        let loc = f.folder.map(lastComponent) ?? "a folder"
        let app = f.bundleID.map(appName) ?? "an app"
        switch f.kind {
        case .fileCreated:  return "Created \(file) in \(loc)"
        case .fileRenamed:  return "Renamed \(file) in \(loc)"
        case .fileMoved:    return "Moved \(file) to \(loc)"
        case .fileTrashed:  return "Trashed \(file) in \(loc)"
        case .appLaunched:  return "Launched \(app)"
        case .appActivated: return "Switched to \(app)"
        case .appTerminated: return "Quit \(app)"
        case .macroStarted:  return "Ran a macro"
        case .macroFinished: return "Finished a macro"
        case .bulkChange:    return "Bulk change in \(loc)"
        }
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func appName(_ bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
