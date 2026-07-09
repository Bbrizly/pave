import Foundation

/// A live match: the prefix the user just finished, the continuation Pave
/// expects, and the evidence behind it. The offer layer turns this into a
/// "want me to finish this?" prompt, this module never acts on it.
public struct PathMatch: Equatable, Sendable {
    public let prefix: [PaveFingerprint]
    public let continuation: PathIndex.Continuation
    public let confidence: Double
    public let occurrences: Int
    public let run: RepeatedRun
    public let pathKey: String

    public init(prefix: [PaveFingerprint], continuation: PathIndex.Continuation,
                confidence: Double, occurrences: Int, run: RepeatedRun, pathKey: String) {
        self.prefix = prefix
        self.continuation = continuation
        self.confidence = confidence
        self.occurrences = occurrences
        self.run = run
        self.pathKey = pathKey
    }
}

/// The live side. Feed it events as they happen. When the tail of the recent
/// stream completes a known prefix whose best continuation clears the suggested
/// bar, it hands back a PathMatch. Otherwise nil.
///
/// Clock: injected per call as the `now:` argument on observe, matching
/// EventNormalizer. No timers, no polling, nothing stored about wall time
/// beyond the last event seen.
///
/// State is a short rolling window of recent fingerprints for the current
/// session. It resets when the session id changes or an idle gap passes, so a
/// path never bridges two unrelated sittings.
public final class PathMatcher {
    private let index: PathIndex
    private let suppression: SuppressionStore
    private let config: PaveConfig

    private var window: [PaveFingerprint] = []
    private var currentSession: UUID?
    private var sawFirstEvent = false
    private var lastEventTime: Date?

    public init(index: PathIndex, suppression: SuppressionStore, config: PaveConfig = PaveConfig()) {
        self.index = index
        self.suppression = suppression
        self.config = config
    }

    /// Ingest one live event. Returns a suggested match, or nil.
    public func observe(_ event: PaveEvent, at now: Date) -> PathMatch? {
        // Ignore Pave's own actions and system churn, same filter the index uses.
        guard PathIndex.keepable(event) else { return nil }

        // Reset the window on a new session or after an idle gap.
        let idleGap = config.sessionIdleMinutes * 60
        if !sawFirstEvent
            || event.sessionID != currentSession
            || (lastEventTime.map { now.timeIntervalSince($0) > idleGap } ?? false) {
            window.removeAll()
            currentSession = event.sessionID
        }
        sawFirstEvent = true
        lastEventTime = now

        window.append(PaveFingerprint(event: event))
        trimWindow()

        return bestMatch(now: now)
    }

    // MARK: matching

    private func bestMatch(now: Date) -> PathMatch? {
        let k = index.prefixLength
        guard window.count >= k else { return nil }

        var best: PathMatch?
        for prefix in index.prefixes where prefixMatchesTail(prefix) {
            guard let candidate = evaluate(prefix: prefix, now: now) else { continue }
            if best == nil
                || candidate.confidence > best!.confidence
                || (candidate.confidence == best!.confidence && candidate.occurrences > best!.occurrences) {
                best = candidate
            }
        }
        return best
    }

    /// Build a match for a prefix if its best continuation is suggested and the
    /// path is not suppressed. Confidence is a plain ratio: the winning
    /// continuation's occurrences over all continuations for the prefix.
    private func evaluate(prefix: [PaveFingerprint], now: Date) -> PathMatch? {
        let conts = index.continuations(after: prefix)
        guard let best = conts.max(by: { $0.occurrences < $1.occurrences }) else { return nil }

        let total = conts.reduce(0) { $0 + $1.occurrences }
        guard total > 0 else { return nil }
        let confidence = Double(best.occurrences) / Double(total)

        let full = prefix + best.remainder
        let tier = ConfidencePolicy.tier(occurrences: best.occurrences,
                                         confidence: confidence,
                                         sampleCount: total,
                                         runLength: full.count,
                                         isAppSwitchOnly: ConfidencePolicy.isAppSwitchOnly(full),
                                         config: config)
        guard tier == .suggested else { return nil }

        let key = SuppressionStore.pathKey(for: full)
        guard !suppression.isSuppressed(key, now: now) else { return nil }

        let run = RepeatedRun(fingerprints: full,
                              occurrences: best.occurrences,
                              lastSeen: best.lastSeen,
                              distinctDays: best.distinctDays)
        return PathMatch(prefix: prefix, continuation: best, confidence: confidence,
                         occurrences: best.occurrences, run: run, pathKey: key)
    }

    /// Does the prefix land on the tail of the window, ending at the newest
    /// event, allowing up to matchGapTolerance stranger events between its
    /// steps? Strangers before the first prefix step do not count.
    private func prefixMatchesTail(_ prefix: [PaveFingerprint]) -> Bool {
        guard let lastPrefix = prefix.last, let lastWindow = window.last else { return false }
        // The newest event must complete the prefix, else we are mid-gap.
        guard lastPrefix == lastWindow else { return false }

        var pi = prefix.count - 2
        var wi = window.count - 2
        var gaps = 0
        while pi >= 0 {
            if wi < 0 { return false }
            if window[wi] == prefix[pi] {
                pi -= 1
            } else {
                gaps += 1
                if gaps > config.matchGapTolerance { return false }
            }
            wi -= 1
        }
        return true
    }

    /// Keep only enough tail to test any prefix with its full gap budget.
    private func trimWindow() {
        let cap = max(1, config.matchPrefixLength + config.matchGapTolerance)
        if window.count > cap { window.removeFirst(window.count - cap) }
    }
}
