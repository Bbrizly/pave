#if os(macOS)
import AppKit
import ApplicationServices
import CoreAudio
import Foundation

/// Runs steps on the real machine. Called on the executor's background queue;
/// hops to main only where AppKit demands it.
public final class MacRunner: StepRunner {
    /// Agent injects its toast UI. macroctl injects print.
    public var toast: ((String) -> Void)?

    public init() {}

    public func run(_ step: Step) throws {
        switch step {
        case .app(let bundleId): try runApp(bundleId)
        case .open(let target): try runOpen(target)
        case .text(let s, let restore): runText(s, restore: restore)
        case .keys(let key, let mods): try runKeys(key, mods)
        case .shell(let script, let timeout, let showToast): try runShell(script, timeout: timeout, showToast: showToast)
        case .window(let action): try runWindow(action)
        case .system(let action): try runSystem(action)
        case .delay(let ms): Thread.sleep(forTimeInterval: Double(ms) / 1000)
        case .unknown(let t): throw RunError("unknown step type '\(t)'")
        }
    }

    // MARK: app

    private func runApp(_ bundleId: String) throws {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            DispatchQueue.main.sync { _ = running.activate(options: []) }
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            throw RunError("no app with bundle id \(bundleId)")
        }
        let sem = DispatchSemaphore(value: 0)
        var failure: String?
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            failure = err?.localizedDescription
            sem.signal()
        }
        sem.wait()
        if let failure { throw RunError(failure) }
    }

    // MARK: open

    private func runOpen(_ target: String) throws {
        if target.hasPrefix("/") || target.hasPrefix("~") {
            let path = (target as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                throw RunError("no such path: \(path)")
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let url = URL(string: target), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else {
            throw RunError("target must be a path or a URL: \(target)")
        }
    }

    // MARK: text (clipboard swap + Cmd-V, restore after 300ms)

    private func runText(_ s: String, restore: Bool) {
        let pb = NSPasteboard.general
        let old = restore ? pb.string(forType: .string) : nil
        pb.clearContents()
        pb.setString(s, forType: .string)
        postKey(9, flags: .maskCommand) // cmd-v
        if restore {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                let pb = NSPasteboard.general
                pb.clearContents()
                if let old { pb.setString(old, forType: .string) }
            }
        }
    }

    // MARK: keys

    private func runKeys(_ key: String, _ mods: [String]) throws {
        guard let code = KeyCodes.code(for: key) else {
            throw RunError("unknown key '\(key)'")
        }
        postKey(CGKeyCode(code), flags: CGEventFlags(rawValue: ModMask.mask(from: mods)))
    }

    private func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(8000)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: shell

    private func runShell(_ script: String, timeout: Double, showToast: Bool) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        let home = FileManager.default.homeDirectoryForCurrentUser
        p.currentDirectoryURL = home
        p.environment = [
            "HOME": home.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "USER": NSUserName(),
            "SHELL": "/bin/zsh",
            "LANG": "en_US.UTF-8",
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()

        let killer = DispatchWorkItem {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()

        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.split(separator: "\n").prefix(4).joined(separator: "\n")
        if showToast, !trimmed.isEmpty {
            DispatchQueue.main.async { self.toast?(trimmed) }
        }
        if p.terminationStatus != 0 {
            throw RunError("shell exited \(p.terminationStatus)" + (trimmed.isEmpty ? "" : ": \(trimmed)"))
        }
    }

    // MARK: window (AX on the frontmost focused window)

    private func runWindow(_ action: WindowAction) throws {
        try DispatchQueue.main.sync {
            guard let app = NSWorkspace.shared.frontmostApplication else {
                throw RunError("no frontmost app")
            }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var winRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef)
            guard err == .success, let winRef else {
                throw RunError("no focused window (is Accessibility granted?)")
            }
            let win = winRef as! AXUIElement

            let current = axFrame(of: win)
            let screen = NSScreen.screens.first {
                $0.frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: current.midX, y: current.midY))
            } ?? NSScreen.main ?? NSScreen.screens[0]
            let v = screen.visibleFrame

            let target: NSRect
            switch action {
            case .leftHalf: target = NSRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height)
            case .rightHalf: target = NSRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height)
            case .topHalf: target = NSRect(x: v.minX, y: v.midY, width: v.width, height: v.height / 2)
            case .bottomHalf: target = NSRect(x: v.minX, y: v.minY, width: v.width, height: v.height / 2)
            case .thirdLeft: target = NSRect(x: v.minX, y: v.minY, width: v.width / 3, height: v.height)
            case .thirdCenter: target = NSRect(x: v.minX + v.width / 3, y: v.minY, width: v.width / 3, height: v.height)
            case .thirdRight: target = NSRect(x: v.minX + 2 * v.width / 3, y: v.minY, width: v.width / 3, height: v.height)
            case .maximize: target = v
            case .nextDisplay:
                let screens = NSScreen.screens
                guard screens.count > 1 else { throw RunError("only one display") }
                let idx = screens.firstIndex(of: screen) ?? 0
                let next = screens[(idx + 1) % screens.count].visibleFrame
                let w = min(current.width, next.width)
                let h = min(current.height, next.height)
                target = NSRect(x: next.midX - w / 2, y: next.midY - h / 2, width: w, height: h)
            }
            setAXFrame(win, target)
        }
    }

    /// AX coordinates are top-left-origin global. Cocoa is bottom-left. Convert both ways.
    private func axFrame(of win: AXUIElement) -> NSRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
        var p = CGPoint.zero
        var s = CGSize.zero
        if let posRef, CFGetTypeID(posRef) == AXValueGetTypeID() {
            AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        }
        if let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        }
        let primaryH = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: p.x, y: primaryH - p.y - s.height, width: s.width, height: s.height)
    }

    private func setAXFrame(_ win: AXUIElement, _ r: NSRect) {
        let primaryH = NSScreen.screens.first?.frame.maxY ?? 0
        var pos = CGPoint(x: r.minX, y: primaryH - r.maxY)
        var size = CGSize(width: r.width, height: r.height)
        if let v = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
        }
        if let v = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
        }
    }

    // MARK: system

    private func runSystem(_ action: SystemAction) throws {
        switch action {
        case .volumeUp: postAux(0)
        case .volumeDown: postAux(1)
        case .muteToggle: postAux(7)
        case .brightnessUp: postAux(2)
        case .brightnessDown: postAux(3)
        case .micMuteToggle: try toggleMicMute()
        case .darkModeToggle: try toggleDarkMode()
        case .screenRecordToggle: postKey(23, flags: [.maskCommand, .maskShift]) // cmd-shift-5
        }
    }

    /// NX aux key press (volume, brightness, mute). The classic systemDefined subtype 8 trick.
    private func postAux(_ key: Int32) {
        func post(_ down: Bool) {
            let data1 = Int((Int(key) << 16) | ((down ? 0xa : 0xb) << 8))
            let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(true)
        post(false)
    }

    private func toggleMicMute() throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0 else {
            throw RunError("no default input device")
        }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &muteAddr) else {
            throw RunError("input device has no mute control")
        }
        var settable = DarwinBoolean(false)
        AudioObjectIsPropertySettable(device, &muteAddr, &settable)
        guard settable.boolValue else { throw RunError("mic mute not settable on this device") }
        var muted: UInt32 = 0
        var msize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &msize, &muted) == noErr else {
            throw RunError("could not read mic mute state")
        }
        var newVal: UInt32 = muted == 0 ? 1 : 0
        guard AudioObjectSetPropertyData(device, &muteAddr, 0, nil, msize, &newVal) == noErr else {
            throw RunError("could not set mic mute")
        }
        let msg = newVal == 1 ? "Mic muted" : "Mic live"
        DispatchQueue.main.async { self.toast?(msg) }
    }

    private func toggleDarkMode() throws {
        try DispatchQueue.main.sync {
            let src = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
            guard let script = NSAppleScript(source: src) else { throw RunError("bad script") }
            var errInfo: NSDictionary?
            script.executeAndReturnError(&errInfo)
            if let errInfo {
                let msg = errInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
                throw RunError("dark mode toggle failed (grant Automation permission): \(msg)")
            }
        }
    }
}
#endif
