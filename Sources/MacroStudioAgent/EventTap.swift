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
/// passes untouched. The callback does lookup + dispatch + return, nothing else.
final class EventTap {
    var holdKeyCode: Int64 = 54
    var onHotkey: ((Int64, UInt64) -> Bool)?      // tap thread; true = swallow
    var onRadialKey: ((Int64) -> Bool)?           // tap thread; true = swallow
    var onHoldDown: (() -> Void)?                 // main
    var onHoldUp: (() -> Void)?                   // main

    private(set) var started = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdIsDown = false
    private var watchdog: Timer?

    private var holdKeyIsModifier: Bool {
        // left/right shift, control, option, command, fn
        [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(Int(holdKeyCode))
    }

    @discardableResult
    func start() -> Bool {
        guard !started else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

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
            if holdKeyIsModifier, code == holdKeyCode {
                holdIsDown.toggle()
                let down = holdIsDown
                DispatchQueue.main.async { down ? self.onHoldDown?() : self.onHoldUp?() }
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
