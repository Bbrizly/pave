#if os(macOS)
import Foundation
import PaveKit

/// Owns the observation pipeline end to end: raw signals in, PaveEvents out,
/// ledger on disk. Normalizing and appending always happens on `queue`, never
/// on main and never on the event-tap thread, so a burst of file or app
/// activity can never stall the hotkey path.
final class PaveObservationCoordinator {
    private let store = Store()
    let config: PaveConfig
    private let normalizer: EventNormalizer
    private let ledger: PaveLedger
    private let suppression: SuppressionStore
    private let graduation: GraduationStore
    private var matcher: PathMatcher
    private let queue = DispatchQueue(label: "com.bbrizly.pave.observation")

    private var appObserver: ApplicationObserver?
    private var fileObserver: FileSystemObserver?
    private let fileObservationError = Locked<String?>(nil)
    private var eventsSinceRebuild = 0

    private static let pausedKey = "pave.observation.paused"

    private(set) var isRunning = false

    var isPaused: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pausedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pausedKey) }
    }

    /// Fired on the main queue whenever a live path completes and converts
    /// cleanly to a macro. Never fired for a match that fails to convert:
    /// the offer surface only ever sees something it can actually save.
    var onOffer: ((PathMatch, Macro) -> Void)?

    /// Fired on the main queue whenever a live path completes AND a macro
    /// already exists for it (its paveOrigin equals the match's pathKey).
    /// This is the auto-run/graduation entry point, a different moment than
    /// onOffer: there is nothing new to draft here, the agent just has to
    /// decide whether to run the existing macro or ask about approving it.
    var onGraduated: ((PathMatch, Macro) -> Void)?

    /// Fired on the main queue whenever an anchor matches a live user-origin
    /// event and that anchor's recall cooldown is clear. Recall never runs
    /// anything itself; this is only ever a prompt.
    var onRecall: ((UUID, String, PaveEvent) -> Void)?

    /// Fired on the main queue when a Watch-This capture window ends, either
    /// because the agent called stopRecording() or because the event/time cap
    /// forced it (`auto`). Hands back everything captured so the agent can
    /// run RecordConverter and decide what to do with the result.
    var onRecordingEnded: (([PaveEvent], Bool) -> Void)?

    /// The one suppression store the live matcher reads. The offer surface
    /// records offered/dismissed/neverAsk on this exact instance so the
    /// change is visible to the matcher immediately, not just on next launch.
    var suppressionStore: SuppressionStore { suppression }

    /// The one graduation store tracking confirmed-run counts and auto-run
    /// approvals. Shared the same way suppressionStore is.
    var graduationStore: GraduationStore { graduation }

    /// One enabled macro with an anchor, cached for the live recall check.
    private struct AnchorEntry {
        let anchor: AnchorSpec
        let macroID: UUID
        let macroName: String
    }

    // Both rebuilt together from the agent's reload(): the recall anchor
    // list and the paveOrigin -> macro lookup auto-run needs. Locked because
    // the agent writes them from main while ingest() reads them on `queue`.
    private let anchors = Locked<[AnchorEntry]>([])
    private let macrosByOrigin = Locked<[String: Macro]>([:])

    // Master auto-run switch, gate (a). Mirrors config.autoRunEnabled but
    // kept as its own in-memory flag so the agent's menu toggle takes effect
    // immediately instead of waiting on a config reload round trip.
    private let autoRunEnabledFlag: Locked<Bool>
    var autoRunEnabled: Bool {
        get { autoRunEnabledFlag.get() }
        set { autoRunEnabledFlag.set(newValue) }
    }

    // MARK: Watch-This capture state, `queue`-confined.
    private var captureStart: Date?
    private var captureEvents: [PaveEvent] = []
    private let capturingFlag = Locked(false)
    private static let captureEventCap = 500
    private static let captureDurationCap: TimeInterval = 600   // 10 minutes

    /// True while a Watch-This capture window is open. Safe to read from
    /// main; only ever written on `queue`.
    var isRecording: Bool { capturingFlag.get() }

    init() {
        let configURL = store.root.appendingPathComponent("pave.json")
        let dbURL = store.root.appendingPathComponent("pave.sqlite")
        let cfg = PaveConfig.load(from: configURL)
        config = cfg
        normalizer = EventNormalizer(config: cfg)
        ledger = PaveLedger(url: dbURL, config: cfg, now: { Date() })
        suppression = SuppressionStore(url: store.root.appendingPathComponent("pave-suppression.json"), config: cfg)
        graduation = GraduationStore(url: store.root.appendingPathComponent("pave-graduation.json"), config: cfg)
        autoRunEnabledFlag = Locked(cfg.autoRunEnabled)
        // Empty until start() rebuilds from the ledger. A live event arriving
        // before that (unlikely: the rebuild is queued first) just misses a match.
        matcher = PathMatcher(index: PathIndex.build(from: [], config: cfg), suppression: suppression, config: cfg)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let retentionDays = config.retentionDays
        queue.async { [weak self] in
            guard let self else { return }
            self.ledger.prune(now: Date(), retentionDays: retentionDays)
            self.rebuildIndex()
        }

        let apps = ApplicationObserver { [weak self] raw in self?.ingest(raw) }
        apps.start()
        appObserver = apps

        let files = FileSystemObserver(
            folders: config.watchedFolders,
            onChange: { [weak self] raw in self?.ingest(raw) },
            onError: { [weak self] message in self?.fileObservationError.set(message) }
        )
        files.start()
        fileObserver = files
    }

    func stop() {
        guard isRunning else { return }
        appObserver?.stop()
        fileObserver?.stop()
        appObserver = nil
        fileObserver = nil
        queue.sync { self.ledger.flush() }
        isRunning = false
    }

    func pause() { isPaused = true }
    func resume() { isPaused = false }

    /// Refreshes the recall anchor list and the paveOrigin lookup auto-run
    /// needs, from the macro set the agent just (re)loaded off disk. Call
    /// this from the agent's reload(), so both app launch and every hot
    /// reload keep these current with no extra plumbing.
    func reloadMacros(_ macros: [Macro]) {
        let entries = macros.compactMap { m -> AnchorEntry? in
            guard m.enabled, let a = m.anchor else { return nil }
            return AnchorEntry(anchor: a, macroID: m.id, macroName: m.name)
        }
        var origins: [String: Macro] = [:]
        for m in macros {
            guard let origin = m.paveOrigin else { continue }
            origins[origin] = m
        }
        anchors.set(entries)
        macrosByOrigin.set(origins)
    }

    // MARK: Watch This

    /// Starts a capture window. Any events left over from a prior window that
    /// was never stopped are discarded first.
    func startRecording() {
        queue.async { [weak self] in
            guard let self else { return }
            self.captureStart = Date()
            self.captureEvents = []
            self.capturingFlag.set(true)
        }
    }

    /// Ends the capture window and posts what was collected via
    /// onRecordingEnded. A no-op (no callback) if no capture was in progress.
    func stopRecording() {
        queue.async { [weak self] in
            guard let self, self.captureStart != nil else { return }
            self.endCapture(auto: false)
        }
    }

    /// Runs on `queue`. Clears capture state and posts the result to main.
    private func endCapture(auto: Bool) {
        let events = captureEvents
        captureStart = nil
        captureEvents = []
        capturingFlag.set(false)
        DispatchQueue.main.async { [weak self] in
            self?.onRecordingEnded?(events, auto)
        }
    }

    /// Tags engine-driven macro runs so future consumers of the ledger never
    /// mistake a macro's own effects for user behavior.
    func recordMacro(start: Bool, id: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            let event = PaveEvent(timestamp: Date(), kind: start ? .macroStarted : .macroFinished,
                                  origin: .macro(id))
            self.ledger.append(event)
        }
    }

    /// One line for the menu: run state, paused state, events recorded
    /// today, and any observer failure. Never throws, never blocks longer
    /// than a local sqlite read.
    func statusLine() -> String {
        var parts: [String] = []
        if !isRunning {
            parts.append("stopped")
        } else if isPaused {
            parts.append("paused")
        } else {
            parts.append("running")
        }
        if isRecording { parts.append("recording your routine") }
        parts.append("\(eventsToday()) events today")
        if let err = fileObservationError.get() {
            parts.append(err)
        }
        return "Pave observation: " + parts.joined(separator: ", ")
    }

    private func eventsToday() -> Int {
        let start = Calendar.current.startOfDay(for: Date())
        return ledger.counts(byKindSince: start).values.reduce(0, +)
    }

    private func ingest(_ raw: RawChange) {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.isPaused {
                let now = Date()
                for event in self.normalizer.ingest(raw, at: now) {
                    self.ledger.append(event)
                    self.eventsSinceRebuild += 1
                    // Only the user's own actions feed the live matcher, the
                    // recall check, and a Watch-This capture. Macro and
                    // system-origin events (e.g. while locked) never do, same
                    // filter PathIndex.keepable applies when building.
                    if case .user = event.origin {
                        self.checkAnchors(event, now: now)
                        if let match = self.matcher.observe(event, at: now) {
                            self.handle(match)
                        }
                        if self.captureStart != nil {
                            self.captureEvents.append(event)
                            self.checkCaptureCap(now: now)
                        }
                    }
                }
                if self.eventsSinceRebuild >= self.config.rebuildEveryEvents {
                    self.rebuildIndex()
                }
            }
            // Flush going into lock so nothing sits unpersisted in memory
            // while the machine is untouched. No timer: this is event-driven.
            if case .screenLocked = raw {
                self.ledger.flush()
            }
        }
    }

    /// Recall: a tiny loop over enabled macros with an anchor, checked on
    /// every user-origin event. Fires at most once per event, only when the
    /// anchor matches and its own cooldown ("recall:<id>") is clear. Runs on
    /// `queue`.
    private func checkAnchors(_ event: PaveEvent, now: Date) {
        for entry in anchors.get() {
            guard entry.anchor.matches(event) else { continue }
            let key = "recall:\(entry.macroID.uuidString)"
            guard !suppression.isSuppressed(key, now: now) else { continue }
            DispatchQueue.main.async { [weak self] in
                self?.onRecall?(entry.macroID, entry.macroName, event)
            }
            return
        }
    }

    /// Auto-stops a Watch-This capture once it hits the event or time cap.
    /// Purely event-driven (checked only when a new event lands), so an idle
    /// capture with no activity can outlive the time cap in wall-clock terms;
    /// that is an acceptable trade against adding a timer for it. Runs on
    /// `queue`.
    private func checkCaptureCap(now: Date) {
        guard let start = captureStart else { return }
        let overEvents = captureEvents.count >= Self.captureEventCap
        let overTime = now.timeIntervalSince(start) >= Self.captureDurationCap
        guard overEvents || overTime else { return }
        endCapture(auto: true)
    }

    /// Rebuilds the PathIndex from the last N days of ledger events and hands
    /// the live matcher a fresh instance over it. Runs on `queue`. Rebuilding
    /// replaces the matcher entirely, so a ritual mid-flight exactly when the
    /// 500th event lands can miss its match; the same ritual repeating is the
    /// gate here, so a single missed window is an acceptable cost for staying
    /// cheap and explicit (matches PathIndex's own "rebuild is cheap" design).
    private func rebuildIndex() {
        let since = Date().addingTimeInterval(-Double(PaveDefaults.pathIndexWindowDays) * 86_400)
        let events = ledger.events(in: since..<Date.distantFuture, limit: PaveDefaults.pathIndexEventLimit)
        let index = PathIndex.build(from: events, config: config)
        matcher = PathMatcher(index: index, suppression: suppression, config: config)
        eventsSinceRebuild = 0
    }

    /// A live match completed. Fetch its occurrences' real events and try to
    /// convert to a macro; only a successful conversion reaches the offer
    /// surface. A match that fails to convert is silently dropped, never
    /// recorded as offered, so the same ritual can still surface later once
    /// it becomes mappable (e.g. after a rename step drops out of the run).
    private func handle(_ match: PathMatch) {
        // A path that already has a saved macro (an earlier accepted offer,
        // or a Watch-This recording) goes to the auto-run/graduation moment
        // instead of drafting a duplicate. A brand-new path with no macro yet
        // falls through to the normal "save a draft" offer below.
        if let macro = macrosByOrigin.get()[match.pathKey] {
            DispatchQueue.main.async { [weak self] in
                self?.onGraduated?(match, macro)
            }
            return
        }

        let ids = match.continuation.occurrenceEventIDs.flatMap { $0 }
        let events = ledger.events(ids: ids)
        guard let macro = PathToMacro.convert(match: match, events: events, config: config) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onOffer?(match, macro)
        }
    }
}
#endif
