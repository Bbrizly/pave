import Foundation

/// How sure Pave is about a path. The ladder is deliberately short.
///  - none: not worth a word.
///  - discovered: a real repeated ritual, shown in the Activity pane only.
///  - suggested: safe to offer to finish for the user.
///
/// There is no auto-run tier here on purpose. Graduating a path to "run it
/// without asking" is a later, human-decided stage, not a threshold this
/// module gets to cross on its own.
public enum PathTier: Sendable {
    case none
    case discovered
    case suggested
}

/// The confidence ladder. Pure functions over config, no state, no clock.
/// Precision beats recall: every gate errs toward silence.
public enum ConfidencePolicy {

    /// Where a candidate path lands on the ladder.
    /// - occurrences: how many times the winning continuation was seen.
    /// - confidence: winning continuation's share of all continuations (0…1).
    /// - sampleCount: total continuations seen for the prefix (the denominator).
    /// - runLength: full path length in steps (prefix + remainder).
    /// - isAppSwitchOnly: every step is just an app switch, so finishing it saves nothing.
    public static func tier(occurrences: Int,
                            confidence: Double,
                            sampleCount: Int,
                            runLength: Int,
                            isAppSwitchOnly: Bool,
                            config: PaveConfig = PaveConfig()) -> PathTier {
        // App-switch-only rituals can never clear even discovered. "You often
        // open Finder after Safari" is true and useless.
        if isAppSwitchOnly { return .none }
        // Nonsense inputs stay silent.
        if sampleCount <= 0 || occurrences <= 0 { return .none }

        let isDiscovered = occurrences >= config.discoveredMinOccurrences
            && runLength >= config.suggestMinLength
        guard isDiscovered else { return .none }

        let isSuggested = confidence >= config.suggestConfidence
            && occurrences >= config.suggestMinOccurrences
        return isSuggested ? .suggested : .discovered
    }

    /// True when every step is an app launch, activate, or quit. Such a run
    /// carries no file work to finish, so it is value-gated out of discovery.
    public static func isAppSwitchOnly(_ fingerprints: [PaveFingerprint]) -> Bool {
        guard !fingerprints.isEmpty else { return false }
        return fingerprints.allSatisfy {
            $0.kind == .appActivated || $0.kind == .appLaunched || $0.kind == .appTerminated
        }
    }
}
