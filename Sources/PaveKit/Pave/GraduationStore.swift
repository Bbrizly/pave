import Foundation

/// Tracks how far a learned macro is along the road to auto-run. Two things per
/// origin key: how many times the user confirmed the run, and whether they
/// approved unattended auto-run. Small JSON at an injected url, tolerant decode:
/// a corrupt or partial file starts fresh, it never throws at a caller.
///
/// Auto-run has two gates the agent must clear, not one: the per-macro approval
/// here AND the master config.autoRunEnabled switch. This store knows nothing
/// about the master switch on purpose, so a stale approval can never bypass it.
public final class GraduationStore {

    private struct State: Codable {
        var confirmedRuns: [String: Int] = [:]   // originKey -> confirmed count
        var approved: [String: Date] = [:]        // originKey -> approved at

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            confirmedRuns = (try? c.decodeIfPresent([String: Int].self, forKey: .confirmedRuns) ?? [:]) ?? [:]
            approved = (try? c.decodeIfPresent([String: Date].self, forKey: .approved) ?? [:]) ?? [:]
        }
    }

    private let url: URL
    private let config: PaveConfig
    private var state: State

    public init(url: URL, config: PaveConfig = PaveConfig()) {
        self.url = url
        self.config = config
        self.state = GraduationStore.load(url)
    }

    /// The user confirmed one run of this macro. Bumps the count.
    public func recordConfirmedRun(_ originKey: String, at now: Date) {
        state.confirmedRuns[originKey, default: 0] += 1
        save()
    }

    /// How many confirmed runs this origin has logged.
    public func confirmedRuns(_ originKey: String) -> Int {
        state.confirmedRuns[originKey] ?? 0
    }

    /// The user approved unattended auto-run for this origin.
    public func approveAutoRun(_ originKey: String, at now: Date) {
        state.approved[originKey] = now
        save()
    }

    /// Take back auto-run approval. The confirmed-run count is left intact.
    public func revokeAutoRun(_ originKey: String) {
        state.approved[originKey] = nil
        save()
    }

    /// True when this origin has a standing auto-run approval.
    public func isAutoRunApproved(_ originKey: String) -> Bool {
        state.approved[originKey] != nil
    }

    /// True when the macro has earned enough confirmed runs to be offered
    /// auto-run and is not already approved. This is only the offer gate: the
    /// agent must still honor config.autoRunEnabled before acting.
    public func eligibleForAutoRunOffer(_ originKey: String) -> Bool {
        confirmedRuns(originKey) >= config.paveAfterConfirmedRuns && !isAutoRunApproved(originKey)
    }

    // MARK: persistence

    private static func load(_ url: URL) -> State {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(State.self, from: data)
        else { return State() }
        return s
    }

    private func save() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
