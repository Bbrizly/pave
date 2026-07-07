#if os(macOS)
import AppKit
import Foundation
import MacroEngineKit

/// Tiny thread-safe box for values shared between the tap thread and main.
final class Locked<T> {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
}

/// One session CGEventTap. Matched hotkeys are swallowed; everything else
/// passes untouched. While the radial is up, mouse moves and clicks route
/// through here too: one reliable pipe instead of NSEvent global monitors,
/// which macOS delivers only when it feels like it.
final class EventTap {
    var holdKeyCode: Int64 = 54
    var onHotkey: ((Int64, UInt64) -> Bool)?      // tap thread; true = swallow
    var onRadialKey: ((Int64) -> Bool)?           // tap thread; true = swallow
    var onHoldDown: (() -> Void)?                 // main
    var onHoldUp: (() -> Void)?                   // main
    var onRadialMouseMoved: (() -> Void)?         // main
    var onRadialClick: (() -> Void)?              // main
    var radialVisible: () -> Bool = { false }     // tap thread, must be cheap

    private(set) var started = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdIsDown = false
    private var watchdog: Timer?

    /// The modifier flag bit a hold keycode maps to, nil for normal keys.
    private func modifierBit(for code: Int64) -> CGEventFlags? {
        switch code {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    private var holdKeyIsModifier: Bool { modifierBit(for: holdKeyCode) != nil }

    @discardableResult
    func start() -> Bool {
        guard !started else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<EventTap>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        started = true

        // macOS silently disables slow taps. Re-enable and log.
        watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, let t = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: t) {
                CGEvent.tapEnable(tap: t, enable: true)
                NSLog("MacroStudio: event tap re-enabled by watchdog")
            }
        }
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            // Read the actual flag state instead of toggling a counter.
            // A toggle desyncs forever after one missed event (tap restart,
            // secure input); the flag bit is ground truth on every event.
            if code == holdKeyCode, let bit = modifierBit(for: code) {
                let down = event.flags.contains(bit)
                if down != holdIsDown {
                    holdIsDown = down
                    DispatchQueue.main.async { down ? self.onHoldDown?() : self.onHoldUp?() }
                }
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if !holdKeyIsModifier, code == holdKeyCode {
                if !holdIsDown {
                    holdIsDown = true
                    DispatchQueue.main.async { self.onHoldDown?() }
                }
                return nil // swallow, including autorepeat
            }
            if let radial = onRadialKey, radial(code) { return nil }
            let mods = event.flags.rawValue & ModMask.relevant
            if onHotkey?(code, mods) == true { return nil }
            return Unmanaged.passUnretained(event)

        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if !holdKeyIsModifier, code == holdKeyCode, holdIsDown {
                holdIsDown = false
                DispatchQueue.main.async { self.onHoldUp?() }
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .mouseMoved:
            if radialVisible() {
                DispatchQueue.main.async { self.onRadialMouseMoved?() }
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown:
            if radialVisible() {
                DispatchQueue.main.async { self.onRadialClick?() }
                return nil // never click through the wheel
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// Watches a directory fd for writes, debounced 200ms. No polling.
final class DirWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    init?(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
#endif
