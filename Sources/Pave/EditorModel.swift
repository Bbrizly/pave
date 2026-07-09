#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import IOKit.hid
import PaveKit
import UniformTypeIdentifiers

final class EditorModel: ObservableObject {
    let store = Store()

    @Published var macros: [Macro] = []
    @Published var rings: [String: [RingSlice]] = [:]
    @Published var settings = Settings()
    @Published var axGranted = false
    @Published var inputGranted = false
    @Published var showOnboarding = false

    init() {
        load()
        refreshPermissions()
        showOnboarding = !axGranted
        installStartersIfFirstRun()
        // Recheck when the app comes forward (user returning from System Settings).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPermissions() }
    }

    func load() {
        macros = store.loadMacros()
        rings = store.loadRings()
        settings = store.loadSettings()
    }

    func save(_ m: Macro) {
        try? store.save(m)
        load()
        pokeAgent()
    }

    func delete(_ id: UUID) {
        store.delete(id)
        var changed = false
        for (ctx, ring) in rings {
            let filtered = ring.filter { $0.macro != id }
            if filtered.count != ring.count {
                rings[ctx] = filtered
                changed = true
            }
        }
        if changed { try? store.saveRings(rings) }
        load()
        pokeAgent()
    }

    func newMacro() -> Macro {
        let m = Macro(name: "New macro")
        try? store.save(m)
        load()
        return m
    }

    func saveRings() {
        try? store.saveRings(rings)
        load()
        pokeAgent()
    }

    func saveSettings() {
        try? store.saveSettings(settings)
        pokeAgent()
    }

    func pokeAgent() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.bbrizly.pave.reload"),
            object: nil, userInfo: nil, deliverImmediately: true)
    }

    func testRun(_ id: UUID) {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.bbrizly.pave.run"),
            object: id.uuidString, userInfo: nil, deliverImmediately: true)
    }

    /// Asks the agent to play the working menu-bar animation so the user can see it.
    func testIcon() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.bbrizly.pave.icontest"),
            object: nil, userInfo: nil, deliverImmediately: true)
    }

    func refreshPermissions() {
        axGranted = AXIsProcessTrusted()
        inputGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func launchAgent() {
        let sibling = (Bundle.main.bundlePath as NSString).deletingLastPathComponent + "/PaveAgent.app"
        for path in ["/Applications/PaveAgent.app", sibling]
        where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
            return
        }
        alert("Agent app not found. Run make install first.")
    }

    // MARK: starters (first run only: value inside 60 seconds)

    private func installStartersIfFirstRun() {
        if store.installStartersIfEmpty() { load() }
    }

    // MARK: import / export

    func importPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "pave") ?? .json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let result = try store.importFile(at: url)
            load()
            pokeAgent()
            if result.needsReview.isEmpty {
                alert("Imported \(result.imported) macros.")
            } else {
                alert("""
                Imported \(result.imported) macros.
                Disabled pending shell review: \(result.needsReview.joined(separator: ", ")).
                Open each one, read the script, then enable it. Imported shell steps are a malware vector.
                """)
            }
        } catch {
            alert("Import failed: \(error.localizedDescription)")
        }
    }

    func exportPanel() {
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: "pave") ?? .json]
        p.nameFieldStringValue = "macros.pave"
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            try store.exportAll(to: url)
        } catch {
            alert("Export failed: \(error.localizedDescription)")
        }
    }

    func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Pave"
        a.informativeText = text
        a.runModal()
    }
}
#endif
