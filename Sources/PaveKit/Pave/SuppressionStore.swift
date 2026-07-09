import Foundation

/// Offer hygiene. Remembers which paths were offered, dismissed, or muted so
/// Pave never nags. Small JSON file at an injected url. Tolerant decode: a
/// corrupt or partial file starts fresh, it never throws at a caller.
///
/// A path is identified by a stable hash of its full fingerprint sequence, so
/// the same ritual maps to the same key across rebuilds and restarts.
public final class SuppressionStore {

    private struct State: Codable {
        var offered: [String: Date] = [:]     // pathKey -> last offered
        var dismissed: [String: Date] = [:]   // pathKey -> last dismissed
        var neverAsk: [String] = []           // pathKeys the user muted for good

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            offered = (try? c.decodeIfPresent([String: Date].self, forKey: .offered) ?? [:]) ?? [:]
            dismissed = (try? c.decodeIfPresent([String: Date].self, forKey: .dismissed) ?? [:]) ?? [:]
            neverAsk = (try? c.decodeIfPresent([String].self, forKey: .neverAsk) ?? []) ?? []
        }
    }

    private let url: URL
    private let config: PaveConfig
    private var state: State

    public init(url: URL, config: PaveConfig = PaveConfig()) {
        self.url = url
        self.config = config
        self.state = SuppressionStore.load(url)
    }

    /// Stable key for a whole path. Reuses PaveHash so it matches everywhere.
    public static func pathKey(for fingerprints: [PaveFingerprint]) -> String {
        let joined = fingerprints.map {
            [$0.kind.rawValue, $0.bundleID ?? "", $0.folder ?? "", $0.fileExtension ?? ""]
                .joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
        return PaveHash.stable(joined)
    }

    /// Stamp that this path was just offered. Starts the cooldown.
    public func recordOffered(_ pathKey: String, at now: Date) {
        state.offered[pathKey] = now
        save()
    }

    /// The user said not now. Suppress this path for the dismissal window.
    public func recordDismissed(_ pathKey: String, at now: Date) {
        state.dismissed[pathKey] = now
        save()
    }

    /// The user muted this path for good.
    public func recordNeverAsk(_ pathKey: String) {
        if !state.neverAsk.contains(pathKey) { state.neverAsk.append(pathKey) }
        save()
    }

    /// True when this path must not be offered right now.
    public func isSuppressed(_ pathKey: String, now: Date) -> Bool {
        if state.neverAsk.contains(pathKey) { return true }
        if let d = state.dismissed[pathKey],
           now.timeIntervalSince(d) < config.dismissalSuppressDays * 86_400 { return true }
        if let o = state.offered[pathKey],
           now.timeIntervalSince(o) < config.offerCooldownHours * 3_600 { return true }
        return false
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
