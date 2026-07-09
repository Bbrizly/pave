import Foundation

/// The inferred rename rule behind a set of repeated renames, if one holds.
/// `template` is a nameTemplate string for a renameFile step ({name}, {date},
/// {month}, {n}, plus literals).
public struct TemplateHypothesis: Equatable, Sendable {
    public let template: String
    public let confidence: Double

    public init(template: String, confidence: Double) {
        self.template = template
        self.confidence = confidence
    }
}

/// Guesses the rename template behind a repeated rename ritual. Deliberately a
/// checklist, not a clever learner: split names, find the constant literals,
/// and classify the one varying part as a date, a counter, or the old name. It
/// returns nil far more often than it guesses. Precision beats recall: a wrong
/// template silently corrupts filenames, so silence is the safe default.
public enum TemplateInferencer {

    /// A date format tried against the varying middle, and which token it maps
    /// to. Order matters: the most specific full date is tried first so a plain
    /// year-month never wins over a full day when both are present.
    private struct DateFormat {
        let pattern: String
        let token: String   // "{date}" or "{month}"
    }

    private static let dateFormats: [DateFormat] = [
        DateFormat(pattern: "yyyy-MM-dd", token: "{date}"),
        DateFormat(pattern: "yyyyMMdd", token: "{date}"),
        DateFormat(pattern: "MM-dd", token: "{date}"),
        DateFormat(pattern: "MMMM yyyy", token: "{month}"),
        DateFormat(pattern: "yyyy-MM", token: "{month}"),
    ]

    public static func infer(renames: [(previous: String, new: String, at: Date)],
                             config: PaveConfig) -> TemplateHypothesis? {
        // Require three occurrences. Two is technically enough for a pure {name}
        // or a pure date (the token pins the whole varying part), but the extra
        // sample is cheap insurance against a coincidence, so we keep one bar.
        guard renames.count >= 3 else { return nil }

        // Split every new name into stem + extension. The extension must be the
        // same literal across all of them, or there is no single template.
        var stems: [String] = []
        var prevStems: [String] = []
        var exts: Set<String> = []
        for r in renames {
            let (stem, ext) = split(r.new)
            stems.append(stem)
            prevStems.append(split(r.previous).stem)
            exts.insert(ext ?? "")
        }
        guard exts.count == 1 else { return nil }
        let extSuffix = exts.first.flatMap { $0.isEmpty ? nil : "." + $0 } ?? ""
        let times = renames.map { $0.at }
        let threshold = config.templateMinConfidence

        // No varying part at all: every new name is the same literal. A constant
        // rename ("always call it final.pdf") is a valid, fully precise rule.
        if Set(stems).count == 1 {
            return TemplateHypothesis(template: stems[0] + extSuffix, confidence: 1.0)
        }

        // (a) Dates first. Each format is tested independently by replacing the
        // rendered date inside each new stem with its token, then measuring how
        // many stems the resulting template reproduces exactly.
        var dateHits: [(template: String, confidence: Double)] = []
        for fmt in dateFormats {
            guard let hit = tryDate(stems: stems, times: times, fmt: fmt, extSuffix: extSuffix) else { continue }
            if hit.confidence >= threshold { dateHits.append(hit) }
        }
        if let winner = dateHits.first {
            return TemplateHypothesis(template: winner.template, confidence: winner.confidence)
        }

        // (b) Integer counter. Strip the common literal prefix and suffix, then
        // the varying middles must be integers marching by a constant step.
        if let hit = tryCounter(stems: stems, extSuffix: extSuffix) {
            return TemplateHypothesis(template: hit, confidence: 1.0)
        }

        // (c) The old name carried through. Each new stem must contain its own
        // previous stem, replaced by {name} to the same template everywhere.
        if let hit = tryName(stems: stems, prevStems: prevStems, extSuffix: extSuffix, threshold: threshold) {
            return TemplateHypothesis(template: hit.template, confidence: hit.confidence)
        }

        // (d) Nothing fit. Stay silent.
        return nil
    }

    // MARK: token detectors

    private static func tryDate(stems: [String], times: [Date], fmt: DateFormat,
                                extSuffix: String) -> (template: String, confidence: Double)? {
        var templates: [String] = []
        for (i, stem) in stems.enumerated() {
            let rendered = format(times[i], fmt.pattern)
            guard !rendered.isEmpty, let range = stem.range(of: rendered) else { continue }
            templates.append(stem.replacingCharacters(in: range, with: fmt.token))
        }
        guard !templates.isEmpty else { return nil }
        // The winning template is the most common one produced above. Confidence
        // is how many of ALL occurrences it reproduces once the token is filled.
        guard let candidate = mostCommon(templates) else { return nil }
        var reproduced = 0
        for (i, stem) in stems.enumerated() {
            let rendered = candidate.replacingOccurrences(of: fmt.token, with: format(times[i], fmt.pattern))
            if rendered == stem { reproduced += 1 }
        }
        return (candidate + extSuffix, Double(reproduced) / Double(stems.count))
    }

    private static func tryCounter(stems: [String], extSuffix: String) -> String? {
        let prefix = commonPrefix(stems)
        let suffix = commonSuffix(stems, avoiding: prefix.count)
        var values: [Int] = []
        for stem in stems {
            let middle = String(stem.dropFirst(prefix.count).dropLast(suffix.count))
            guard !middle.isEmpty, middle.allSatisfy({ $0.isNumber }), let v = Int(middle) else { return nil }
            values.append(v)
        }
        // Need a genuine progression: at least two distinct values and a single
        // constant, non-zero step across the run in occurrence order.
        guard Set(values).count >= 2 else { return nil }
        let step = values[1] - values[0]
        guard step != 0 else { return nil }
        for i in 1..<values.count where values[i] - values[i - 1] != step { return nil }
        return prefix + "{n}" + suffix + extSuffix
    }

    private static func tryName(stems: [String], prevStems: [String], extSuffix: String,
                                threshold: Double) -> (template: String, confidence: Double)? {
        var templates: [String] = []
        for (i, stem) in stems.enumerated() {
            let prev = prevStems[i]
            guard !prev.isEmpty, let range = stem.range(of: prev) else { continue }
            templates.append(stem.replacingCharacters(in: range, with: "{name}"))
        }
        guard let candidate = mostCommon(templates), candidate.contains("{name}") else { return nil }
        var reproduced = 0
        for (i, stem) in stems.enumerated() {
            if candidate.replacingOccurrences(of: "{name}", with: prevStems[i]) == stem { reproduced += 1 }
        }
        let confidence = Double(reproduced) / Double(stems.count)
        guard confidence >= threshold else { return nil }
        return (candidate + extSuffix, confidence)
    }

    // MARK: helpers

    private static func split(_ name: String) -> (stem: String, ext: String?) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, nil) }
        let ext = String(name[name.index(after: dot)...])
        return (String(name[..<dot]), ext.isEmpty ? nil : ext)
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = pattern
        return df.string(from: date)
    }

    private static func mostCommon(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
    }

    private static func commonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first else { return "" }
        for s in strings.dropFirst() {
            prefix = String(zip(prefix, s).prefix { $0.0 == $0.1 }.map { $0.0 })
            if prefix.isEmpty { break }
        }
        return prefix
    }

    /// Common suffix, but never overlapping the already-claimed prefix, so a
    /// short string cannot be counted from both ends.
    private static func commonSuffix(_ strings: [String], avoiding prefixLen: Int) -> String {
        guard let first = strings.first else { return "" }
        var suffix = Array(first.reversed())
        for s in strings.dropFirst() {
            let rev = Array(s.reversed())
            var i = 0
            while i < suffix.count, i < rev.count, suffix[i] == rev[i] { i += 1 }
            suffix = Array(suffix.prefix(i))
            if suffix.isEmpty { break }
        }
        // Cap the suffix so prefix + suffix never exceeds the shortest string.
        let shortest = strings.map { $0.count }.min() ?? 0
        let maxSuffix = max(0, shortest - prefixLen)
        return String(suffix.prefix(maxSuffix).reversed())
    }
}
