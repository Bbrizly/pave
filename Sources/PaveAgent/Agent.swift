#if os(macOS)
import AppKit
import ApplicationServices
import PaveKit
import os
import ServiceManagement

@main
enum AgentApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AgentDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AgentDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    /// Self-heal: every menu open retries the tap, so granting Accessibility
    /// then clicking the icon is enough. No relaunch, no reload hunting.
    func menuWillOpen(_ menu: NSMenu) {
        if !tap.started, tap.start() {
            Toast.show("Pave is live. Hold the radial key.")
        }
        updateTapStatus()
    }

    private let store = Store()
    private let executor = Executor()
    private let runner = MacRunner()
    private let tap = EventTap()
    private let coordinator = PaveObservationCoordinator()
    private var radial: RadialController!
    private var statusItem: NSStatusItem!
    private var iconAnimator: IconAnimator!
    private var watchers: [DirWatcher] = []
    private var macros: [Macro] = []
    private var settings = Settings()

    private let offerPanel = OfferPanel()
    /// The most recent offer the user has not explicitly acted on. Survives
    /// an auto-dismiss (that's a timeout, not a decision) so "Last Offer" in
    /// the menu can bring it back; cleared the moment Save/Not now/Never fires.
    private var pendingOffer: OfferPanel.Offer?

    /// Shared small panel for recall ("you have a macro for this") and the
    /// auto-run graduation offer ("run this automatically?"). Both are a
    /// title plus a couple of buttons, so they share one instance and one
    /// visual style instead of the richer OfferPanel used for drafts.
    private let actionPanel = ActionPanel()

    private let regBox = Locked(Registry())
    private let frontBundle = Locked<String?>(nil)
    private let enabledBox = Locked(true)
    private var holdWork: DispatchWorkItem?

    private let signposter = OSSignposter(subsystem: "com.bbrizly.pave", category: "latency")
    private lazy var statusLogoImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appIcon = NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = appIcon
        }
        runner.toast = { Toast.show($0) }
        store.installStartersIfEmpty()
        wireOfferPanel()
        coordinator.onOffer = { [weak self] match, macro in
            self?.presentOffer(match: match, macro: macro)
        }
        coordinator.onGraduated = { [weak self] match, macro in
            self?.handleGraduated(match: match, macro: macro)
        }
        coordinator.onRecall = { [weak self] macroID, macroName, _ in
            self?.presentRecall(macroID: macroID, macroName: macroName)
        }
        coordinator.onRecordingEnded = { [weak self] events, auto in
            self?.finishRecording(events: events, auto: auto)
        }
        coordinator.start()

        radial = RadialController(onFire: { [weak self] id in
            guard let self, let m = self.macros.first(where: { $0.id == id }) else { return }
            self.run(macro: m)
        })

        frontBundle.set(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontBundle.set(app?.bundleIdentifier)
        }

        wireTap()
        reload()

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !tap.start() {
            Toast.show("Pave is blocked. Grant Accessibility to PaveAgent (menu bar icon has a shortcut), then reopen the menu.")
        }

        watchers = [
            DirWatcher(url: store.root) { [weak self] in self?.reload() },
            DirWatcher(url: store.macrosDir) { [weak self] in self?.reload() },
        ].compactMap { $0 }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name("com.bbrizly.pave.reload"),
                        object: nil, queue: .main) { [weak self] _ in self?.reload() }
        dnc.addObserver(forName: NSNotification.Name("com.bbrizly.pave.run"),
                        object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let s = note.object as? String,
                  let id = UUID(uuidString: s),
                  let m = self.macros.first(where: { $0.id == id }) else { return }
            self.run(macro: m)
        }
        dnc.addObserver(forName: NSNotification.Name("com.bbrizly.pave.icontest"),
                        object: nil, queue: .main) { [weak self] _ in self?.runIconTest() }

        buildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    /// Settings "Test" button: play the working animation, then settle to idle.
    /// Because the state change lands while working is looping, `finishFullLoop`
    /// makes it complete the current loop before settling, exactly the behavior
    /// this is meant to demonstrate.
    private func runIconTest() {
        guard settings.icon.enabled else {
            Toast.show("Turn on the hand animation in Settings first.")
            return
        }
        iconAnimator?.setState(.working)
        let dur = max(0.5, settings.icon.testDurationSec)
        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { [weak self] in
            self?.iconAnimator?.setState(.idle)
        }
        Toast.show("Testing the working animation…")
    }

    /// Sets the animated state on the main thread when the icon is enabled and the
    /// engine isn't blocked. Safe to call from executor completion (background).
    private func setIcon(_ s: IconAnimator.State) {
        guard settings.icon.enabled, tap.started else { return }
        if Thread.isMainThread { iconAnimator?.setState(s) }
        else { DispatchQueue.main.async { [weak self] in self?.iconAnimator?.setState(s) } }
    }

    private func wireTap() {
        tap.onHotkey = { [weak self] code, mods in
            guard let self, self.enabledBox.get() else { return false }
            let state = self.signposter.beginInterval("hotkey")
            defer { self.signposter.endInterval("hotkey", state) }
            guard let m = self.regBox.get().match(
                keyCode: Int(code), mods: mods, frontApp: self.frontBundle.get()) else { return false }
            DispatchQueue.main.async { self.run(macro: m) }
            return true
        }
        tap.onRadialKey = { [weak self] code in
            self?.radial.handleKey(code) ?? false
        }
        tap.radialVisible = { [weak self] in
            self?.radial.visibleFlag.get() ?? false
        }
        tap.onRadialMouseMoved = { [weak self] in
            self?.radial.updateFromMouse()
        }
        tap.onRadialClick = { [weak self] in
            self?.radial.clickFire()
        }
        tap.onHoldDown = { [weak self] in
            guard let self, self.enabledBox.get() else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.radial.show(forApp: self.frontBundle.get())
            }
            self.holdWork = work
            // Configurable hold threshold so plain taps of the hold key pass through.
            let delay = Double(max(0, self.settings.holdDelayMs)) / 1000
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        tap.onHoldUp = { [weak self] in
            guard let self else { return }
            self.holdWork?.cancel()
            self.holdWork = nil
            self.radial.holdReleased()
        }
    }

    private func reload() {
        macros = store.loadMacros()
        coordinator.reloadMacros(macros)
        let reg = Registry(macros: macros)
        regBox.set(reg)
        if !reg.conflicts.isEmpty {
            Toast.show("Hotkey conflict: \(reg.conflicts[0])")
        }
        settings = store.loadSettings()
        tap.holdKeyCode = Int64(settings.holdKeyCode)

        var rings = store.loadRings()
        let byId = Dictionary(macros.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (ctx, ring) in rings {
            rings[ctx] = ring.map { slice in
                var s = slice
                if let id = s.macro, let m = byId[id] {
                    if s.label.isEmpty { s.label = m.name }
                    if s.icon == nil { s.icon = Self.defaultIcon(for: m) }
                }
                if s.icon == nil, s.submenu != nil { s.icon = "ellipsis.circle" }
                return s
            }
        }
        radial.rings = rings
        radial.settings = settings
        iconAnimator?.update(config: settings.icon)
        updateTapStatus()
    }

    /// A slice with no explicit icon borrows one from its macro's first step.
    private static func defaultIcon(for macro: Macro) -> String {
        switch macro.steps.first {
        case .app: return "app.fill"
        case .open: return "folder.fill"
        case .text: return "text.cursor"
        case .keys: return "keyboard.fill"
        case .shell: return "terminal.fill"
        case .window: return "macwindow"
        case .system: return "gearshape.fill"
        case .delay: return "clock.fill"
        default: return "sparkles"
        }
    }

    /// `userInitiated` separates a hotkey/radial/menu/panel Run from a run
    /// the auto-run gate fired on its own. Only a user-initiated success
    /// bumps the graduation counter (GraduationStore.recordConfirmedRun), so
    /// auto-run itself can never inflate the count that got it approved.
    private func run(macro: Macro, userInitiated: Bool = true) {
        coordinator.recordMacro(start: true, id: macro.id)
        let started = executor.run(macro, with: runner) { [weak self] result in
            self?.coordinator.recordMacro(start: false, id: macro.id)
            if case .failure(.busy) = result {
                DispatchQueue.main.async { NSSound.beep() }   // another macro is mid-flight; leave its hand alone
                return
            }
            self?.setIcon(.idle)   // finishFullLoop lets the hand complete its loop first
            switch result {
            case .success:
                if userInitiated, let origin = macro.paveOrigin {
                    self?.coordinator.graduationStore.recordConfirmedRun(origin, at: Date())
                }
            case .failure(let err):
                Toast.show("\(macro.name): \(err.description)")
            }
        }
        if started { setIcon(.working) }
    }

    // MARK: offers

    private func wireOfferPanel() {
        offerPanel.onSave = { [weak self] offer in self?.saveOffer(offer) }
        offerPanel.onNotNow = { [weak self] offer in self?.dismissOffer(offer) }
        offerPanel.onNever = { [weak self] offer in self?.neverOffer(offer) }
        offerPanel.onAutoDismiss = { [weak self] _ in
            self?.setIcon(.idle)
            // pendingOffer is intentionally left set: a timeout is not a
            // decision, "Last Offer" can still bring this one back.
        }
    }

    /// Shows the offer panel and stamps the cooldown. Called both for a
    /// fresh match from the coordinator and for reopening via "Last Offer".
    private func presentOffer(match: PathMatch, macro: Macro) {
        pendingOffer = OfferPanel.Offer(match: match, macro: macro)
        coordinator.suppressionStore.recordOffered(match.pathKey, at: Date())
        offerPanel.show(match: match, macro: macro)
        setIcon(.alert)
        updateLastOfferItem()
    }

    private func saveOffer(_ offer: OfferPanel.Offer) {
        do {
            try store.save(offer.macro)
            // Store writes into macrosDir; the agent's own DirWatcher on that
            // folder already calls reload() on the write (see `watchers`
            // below), so the radial/registry pick the draft up with no extra
            // poke. The editor, if already open, only reloads on its macro
            // list view's onAppear, not live: it needs a re-visit or reopen
            // to show a draft saved this way. That gap is pre-existing and
            // outside this lane (Sources/Pave).
            Toast.show("Saved. Review it in the editor.")
        } catch {
            Toast.show("Could not save the draft macro: \(error.localizedDescription)")
        }
        pendingOffer = nil
        setIcon(.idle)
        updateLastOfferItem()
    }

    private func dismissOffer(_ offer: OfferPanel.Offer) {
        coordinator.suppressionStore.recordDismissed(offer.match.pathKey, at: Date())
        pendingOffer = nil
        setIcon(.idle)
        updateLastOfferItem()
    }

    private func neverOffer(_ offer: OfferPanel.Offer) {
        coordinator.suppressionStore.recordNeverAsk(offer.match.pathKey)
        pendingOffer = nil
        setIcon(.idle)
        updateLastOfferItem()
    }

    @objc private func reopenLastOffer() {
        guard let offer = pendingOffer else {
            Toast.show("No pending offer.")
            return
        }
        presentOffer(match: offer.match, macro: offer.macro)
    }

    // MARK: recall

    /// Recall: asks whether to run a macro whose anchor just matched.
    /// Never runs anything on its own, only "Run" does, and that run is
    /// user-initiated so it also counts toward the macro's graduation, same
    /// as any other manual run.
    private func presentRecall(macroID: UUID, macroName: String) {
        guard let macro = macros.first(where: { $0.id == macroID }) else { return }
        let key = "recall:\(macroID.uuidString)"
        actionPanel.show(title: "You have a macro for this: \(macroName)", actions: [
            ActionPanel.Action(title: "Run", prominent: true) { [weak self] in
                self?.coordinator.suppressionStore.recordOffered(key, at: Date())
                self?.run(macro: macro)
            },
            ActionPanel.Action(title: "Not now", prominent: false) { [weak self] in
                self?.coordinator.suppressionStore.recordDismissed(key, at: Date())
            },
            ActionPanel.Action(title: "Don't remind me", prominent: false) { [weak self] in
                self?.coordinator.suppressionStore.recordNeverAsk(key)
            },
        ], autoDismiss: { [weak self] in
            // Timeout, not a decision, but recall still starts the normal
            // offer cooldown so the reminder does not repeat every few
            // seconds while the same ritual is still under way.
            self?.coordinator.suppressionStore.recordOffered(key, at: Date())
            self?.setIcon(.idle)
        })
        setIcon(.alert)
    }

    // MARK: Watch This (record a routine)

    private static let recordSettleSeconds: Double = 0.6

    @objc private func toggleWatchThis() {
        if coordinator.isRecording {
            coordinator.stopRecording()
        } else {
            coordinator.startRecording()
            watchThisItem.title = "Stop Watching"
            setIcon(.alert)
            Toast.show("Recording your routine. Do the steps now, then Stop Watching.")
        }
    }

    /// Coordinator hands back the raw capture; this turns it into a saved
    /// draft or reports why it could not. `auto` means the cap stopped the
    /// capture, not the user, so an extra toast explains that before the
    /// normal save/failure toast.
    private func finishRecording(events: [PaveEvent], auto: Bool) {
        watchThisItem.title = "Watch This (record a routine)"
        if auto {
            Toast.show("Watch This stopped automatically (hit the recording cap).")
        }
        guard let macro = RecordConverter.convert(events: events, config: coordinator.config) else {
            Toast.show("Could not build a macro from that (need at least 2 clear steps).")
            setIcon(.idle)
            return
        }
        do {
            // Store writes into macrosDir; the agent's own DirWatcher on that
            // folder calls reload() on the write, so the draft is live with
            // no extra poke, same as saveOffer() above.
            try store.save(macro)
            Toast.show("Recorded draft saved: \(macro.name). Review it in the editor.")
        } catch {
            Toast.show("Could not save the recorded draft: \(error.localizedDescription)")
        }
        setIcon(.working)   // working -> idle settle, mirrors runIconTest()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recordSettleSeconds) { [weak self] in
            self?.setIcon(.idle)
        }
    }

    // MARK: auto-run

    /// Auto-run's three gates, checked here in order: (a) the master
    /// config.autoRunEnabled switch, (b) GraduationStore.isAutoRunApproved,
    /// (c) every step of the macro is in the safe whitelist. Fires only once
    /// a live path completes AND a macro already exists for it, wired via
    /// coordinator.onGraduated above.
    private func handleGraduated(match _: PathMatch, macro: Macro) {
        guard let origin = macro.paveOrigin else { return }
        let allSafe = macro.steps.allSatisfy(Self.isAutoRunSafeStep)
        guard coordinator.autoRunEnabled, allSafe else { return }

        if coordinator.graduationStore.isAutoRunApproved(origin) {
            autoRun(macro: macro)
            return
        }
        guard coordinator.graduationStore.eligibleForAutoRunOffer(origin),
              !coordinator.suppressionStore.isSuppressed("autorun:" + origin, now: Date())
        else { return }
        presentAutoRunOffer(origin: origin, macro: macro)
    }

    /// Runs a macro Pave decided on its own, with both auto-run gates
    /// already cleared. Never counts toward graduation (that would let
    /// auto-run inflate the count that got it approved in the first place)
    /// and never touches suppression: this is not an offer, there is
    /// nothing to cool down.
    private func autoRun(macro: Macro) {
        Toast.show("Pave auto-ran: \(macro.name)")
        run(macro: macro, userInitiated: false)
    }

    private func presentAutoRunOffer(origin: String, macro: Macro) {
        actionPanel.show(title: "Run \"\(macro.name)\" automatically from now on?", actions: [
            ActionPanel.Action(title: "Approve", prominent: true) { [weak self] in
                self?.coordinator.graduationStore.approveAutoRun(origin, at: Date())
            },
            ActionPanel.Action(title: "Not now", prominent: false) {
                // No suppression write: a plain timeout, the offer can come
                // back next time this path repeats and still qualifies.
            },
            ActionPanel.Action(title: "Never", prominent: false) { [weak self] in
                self?.coordinator.graduationStore.revokeAutoRun(origin)
                self?.coordinator.suppressionStore.recordNeverAsk("autorun:" + origin)
            },
        ], autoDismiss: { [weak self] in
            self?.setIcon(.idle)
        })
        setIcon(.alert)
    }

    /// Gate (c): app, open, delay, moveFile, renameFile only. A shell, keys,
    /// text, window, or system step disqualifies the whole macro from ever
    /// running unattended, no matter how many times it was confirmed.
    /// Exhaustive over Step on purpose: a new step case must be triaged here
    /// before it can silently become auto-runnable.
    private static func isAutoRunSafeStep(_ step: Step) -> Bool {
        switch step {
        case .app, .open, .delay, .moveFile, .renameFile: return true
        case .text, .keys, .shell, .window, .system, .unknown: return false
        }
    }

    private func updateLastOfferItem() {
        guard let lastOfferItem else { return }
        lastOfferItem.isEnabled = pendingOffer != nil
    }

    // MARK: menu bar

    private var enabledItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var tapStatusItem: NSMenuItem!
    private var permsItem: NSMenuItem!
    private var observationStatusItem: NSMenuItem!
    private var pauseObservationItem: NSMenuItem!
    private var watchThisItem: NSMenuItem!
    private var autoRunItem: NSMenuItem!
    private var lastOfferItem: NSMenuItem!

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        iconAnimator = IconAnimator(button: statusItem.button, config: settings.icon)

        let menu = NSMenu()
        menu.delegate = self

        tapStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        tapStatusItem.isEnabled = false
        menu.addItem(tapStatusItem)

        permsItem = NSMenuItem(title: "Open Accessibility Settings",
                               action: #selector(openAccessibility), keyEquivalent: "")
        permsItem.target = self
        menu.addItem(permsItem)

        menu.addItem(.separator())

        observationStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        observationStatusItem.isEnabled = false
        menu.addItem(observationStatusItem)

        pauseObservationItem = NSMenuItem(title: "Pause Observation", action: #selector(toggleObservation), keyEquivalent: "")
        pauseObservationItem.target = self
        menu.addItem(pauseObservationItem)

        watchThisItem = NSMenuItem(title: "Watch This (record a routine)",
                                   action: #selector(toggleWatchThis), keyEquivalent: "")
        watchThisItem.target = self
        menu.addItem(watchThisItem)

        autoRunItem = NSMenuItem(title: "Allow Auto-Run", action: #selector(toggleAutoRun), keyEquivalent: "")
        autoRunItem.target = self
        autoRunItem.state = coordinator.autoRunEnabled ? .on : .off
        menu.addItem(autoRunItem)

        lastOfferItem = NSMenuItem(title: "Last Offer…", action: #selector(reopenLastOffer), keyEquivalent: "")
        lastOfferItem.target = self
        lastOfferItem.isEnabled = false
        menu.addItem(lastOfferItem)

        menu.addItem(.separator())

        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = .on
        menu.addItem(enabledItem)

        let showRadial = NSMenuItem(title: "Show Radial", action: #selector(showRadialClicked), keyEquivalent: "")
        showRadial.target = self
        menu.addItem(showRadial)

        let editor = NSMenuItem(title: "Open Editor", action: #selector(openEditor), keyEquivalent: "")
        editor.target = self
        menu.addItem(editor)

        let reloadItem = NSMenuItem(title: "Reload", action: #selector(reloadClicked), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateTapStatus()
    }

    private func updateTapStatus() {
        // Can be called from reload() before the menu is built; bail until it is.
        guard let tapStatusItem, let permsItem else { return }
        if let observationStatusItem, let pauseObservationItem {
            observationStatusItem.title = coordinator.statusLine()
            pauseObservationItem.title = coordinator.isPaused ? "Resume Observation" : "Pause Observation"
        }
        let ok = tap.started
        tapStatusItem.title = ok
            ? "Engine running (\(macros.count) macros). Hold the radial key."
            : "BLOCKED: grant Accessibility to PaveAgent"
        permsItem.isHidden = ok

        if settings.icon.enabled {
            // The hand animator owns the icon. Blocked = warning glyph, animator paused.
            if ok {
                if iconAnimator?.state != .working { iconAnimator?.setState(.idle) }
            } else {
                iconAnimator?.stopAnimating()
                statusItem.button?.image = NSImage(
                    systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Pave")
            }
        } else if let logo = statusLogoImage {
            statusItem.button?.image = logo
        } else {
            statusItem.button?.image = NSImage(
                systemSymbolName: ok ? "circle.grid.cross" : "exclamationmark.triangle",
                accessibilityDescription: "Pave")
        }
    }

    @objc private func showRadialClicked() {
        radial.show(forApp: nil)
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleEnabled() {
        let now = !enabledBox.get()
        enabledBox.set(now)
        enabledItem.state = now ? .on : .off
    }

    @objc private func toggleObservation() {
        if coordinator.isPaused {
            coordinator.resume()
        } else {
            coordinator.pause()
        }
        updateTapStatus()
    }

    /// Gate (a): the master auto-run switch. Writes straight to pave.json
    /// (the same file the coordinator loaded PaveConfig from at launch) and
    /// updates the coordinator's in-memory flag immediately, so the gate
    /// takes effect on the very next match instead of waiting for the
    /// DirWatcher's debounce.
    @objc private func toggleAutoRun() {
        let url = store.root.appendingPathComponent("pave.json")
        var cfg = PaveConfig.load(from: url)
        cfg.autoRunEnabled.toggle()
        do {
            try cfg.save(to: url)
            coordinator.autoRunEnabled = cfg.autoRunEnabled
            autoRunItem.state = cfg.autoRunEnabled ? .on : .off
            Toast.show(cfg.autoRunEnabled
                ? "Auto-run allowed for macros you have approved."
                : "Auto-run turned off.")
        } catch {
            Toast.show("Could not save the auto-run setting: \(error.localizedDescription)")
        }
    }

    @objc private func reloadClicked() {
        reload()
        if !tap.started, !tap.start() {
            Toast.show("Event tap still blocked. Check Accessibility in System Settings.")
        } else {
            Toast.show("Reloaded \(macros.count) macros")
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Toast.show("Login item: \(error.localizedDescription)")
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openEditor() {
        let sibling = (Bundle.main.bundlePath as NSString).deletingLastPathComponent + "/Pave.app"
        for path in ["/Applications/Pave.app", sibling]
        where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
            return
        }
        Toast.show("Editor not found. Run make install.")
    }
}
#else
@main
enum AgentApp {
    static func main() { print("PaveAgent runs on macOS only.") }
}
#endif
