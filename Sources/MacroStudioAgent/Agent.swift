#if os(macOS)
import AppKit
import ApplicationServices
import MacroEngineKit
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
            Toast.show("Macro Studio is live. Hold the radial key.")
        }
        updateTapStatus()
    }

    private let store = Store()
    private let executor = Executor()
    private let runner = MacRunner()
    private let tap = EventTap()
    private var radial: RadialController!
    private var statusItem: NSStatusItem!
    private var watchers: [DirWatcher] = []
    private var macros: [Macro] = []
    private var settings = Settings()

    private let regBox = Locked(Registry())
    private let frontBundle = Locked<String?>(nil)
    private let enabledBox = Locked(true)
    private var holdWork: DispatchWorkItem?

    private let signposter = OSSignposter(subsystem: "com.bbrizly.macrostudio", category: "latency")

    func applicationDidFinishLaunching(_ notification: Notification) {
        runner.toast = { Toast.show($0) }
        store.installStartersIfEmpty()

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
            Toast.show("Macro Studio is blocked. Grant Accessibility to MacroStudioAgent (menu bar icon has a shortcut), then reopen the menu.")
        }

        watchers = [
            DirWatcher(url: store.root) { [weak self] in self?.reload() },
            DirWatcher(url: store.macrosDir) { [weak self] in self?.reload() },
        ].compactMap { $0 }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name("com.bbrizly.macrostudio.reload"),
                        object: nil, queue: .main) { [weak self] _ in self?.reload() }
        dnc.addObserver(forName: NSNotification.Name("com.bbrizly.macrostudio.run"),
                        object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let s = note.object as? String,
                  let id = UUID(uuidString: s),
                  let m = self.macros.first(where: { $0.id == id }) else { return }
            self.run(macro: m)
        }

        buildMenu()
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
        tap.onHoldDown = { [weak self] in
            guard let self, self.enabledBox.get() else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.radial.show(forApp: self.frontBundle.get())
            }
            self.holdWork = work
            // 150ms hold threshold so plain taps of the hold key pass through.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
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
                if s.label.isEmpty, let id = s.macro, let m = byId[id] { s.label = m.name }
                return s
            }
        }
        radial.rings = rings
        radial.settings = settings
    }

    private func run(macro: Macro) {
        executor.run(macro, with: runner) { result in
            if case .failure(let err) = result {
                if case .busy = err {
                    DispatchQueue.main.async { NSSound.beep() }
                } else {
                    Toast.show("\(macro.name): \(err.description)")
                }
            }
        }
    }

    // MARK: menu bar

    private var enabledItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var tapStatusItem: NSMenuItem!
    private var permsItem: NSMenuItem!

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

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
        let ok = tap.started
        tapStatusItem.title = ok
            ? "Engine running (\(macros.count) macros). Hold the radial key."
            : "BLOCKED: grant Accessibility to MacroStudioAgent"
        permsItem.isHidden = ok
        statusItem.button?.image = NSImage(
            systemSymbolName: ok ? "circle.grid.cross" : "exclamationmark.triangle",
            accessibilityDescription: "Macro Studio")
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
        let sibling = (Bundle.main.bundlePath as NSString).deletingLastPathComponent + "/Macro Studio.app"
        for path in ["/Applications/Macro Studio.app", sibling]
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
    static func main() { print("MacroStudioAgent runs on macOS only.") }
}
#endif
