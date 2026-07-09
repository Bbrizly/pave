#if os(macOS)
import AppKit
import PaveKit

/// Drives the menu-bar status icon through three states:
///   idle    a single static resting hand (no timer, ~0% CPU)
///   alert   the resting hand plus a small badge dot (static)
///   working the 12 hand frames animate in a loop
///
/// Only `working` animates. When the state changes while `working` is playing,
/// the current loop finishes before switching (config `finishFullLoop`), so the
/// animation never cuts mid-gesture. The timer is self-terminating: it exists
/// only while working is on screen, honoring the app's "nothing polls" rule.
///
/// The agent owns the blocked/permission case: it calls `stopAnimating()` and
/// draws its own warning glyph, then `setState(.idle)` once access is granted.
final class IconAnimator {
    enum State: Equatable { case idle, alert, working }

    private weak var button: NSStatusBarButton?
    private var config: IconConfig

    private var frames: [NSImage] = []     // working frames, sized + template/color per config
    private var idleImage: NSImage?        // static idle
    private var alertImage: NSImage?       // static idle + badge dot

    private(set) var state: State = .idle
    private var pending: State?            // state change waiting for the loop boundary
    private var timer: Timer?
    private var frameIndex = 0

    init(button: NSStatusBarButton?, config: IconConfig) {
        self.button = button
        self.config = config
        rebuild()
        applyStatic(.idle)
    }

    // MARK: config

    /// Re-read config live (called on settings reload). Rebuilds images and, if
    /// mid-animation, restarts working with the new speed/style.
    func update(config: IconConfig) {
        self.config = config
        let wasWorking = (state == .working && timer != nil)
        rebuild()
        if wasWorking { startWorking() } else { applyStatic(state) }
    }

    private func rebuild() {
        let isTemplate = config.renderStyle != "color"
        let b64 = isTemplate ? HandFrames.template : HandFrames.color
        let h = CGFloat(min(max(config.pointHeight, 10), 28))
        frames = b64.compactMap { decode($0, template: isTemplate, height: h) }
        let idleIdx = frames.isEmpty ? 0 : min(max(0, config.idleFrameIndex), frames.count - 1)
        idleImage = frames.isEmpty ? nil : frames[idleIdx]
        alertImage = idleImage.map { addDot(to: $0, template: isTemplate) }
    }

    private func decode(_ b64: String, template: Bool, height: CGFloat) -> NSImage? {
        guard let data = Data(base64Encoded: b64),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        let pw = CGFloat(rep.pixelsWide), ph = CGFloat(rep.pixelsHigh)
        let w = height * (pw / max(1, ph))
        let img = NSImage(size: NSSize(width: w, height: height))
        img.addRepresentation(rep)
        img.size = NSSize(width: w, height: height)
        img.isTemplate = template
        return img
    }

    /// Adds a small badge dot to the top-right. In template mode the dot is
    /// tinted with the icon; in color mode it uses the system accent color.
    private func addDot(to base: NSImage, template: Bool) -> NSImage {
        guard config.showAlertDot else { return base }
        let size = base.size
        let out = NSImage(size: size)
        out.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        let r = max(3, size.height * 0.24)
        let rect = NSRect(x: size.width - r, y: size.height - r, width: r, height: r)
        (template ? NSColor.black : NSColor.controlAccentColor).setFill()
        NSBezierPath(ovalIn: rect).fill()
        out.unlockFocus()
        out.isTemplate = template
        return out
    }

    // MARK: state machine

    func setState(_ new: State) {
        guard config.enabled else { return }

        if state == .working, timer != nil {
            // Working is animating. Never cut mid-loop.
            if new == .working { pending = nil; return }
            if config.finishFullLoop {
                pending = new                       // applied when the loop wraps (see tick)
            } else {
                stopTimer(); pending = nil
                if new == .working { startWorking() } else { applyStatic(new) }
            }
            return
        }

        // Static state (idle/alert) or non-animating working: switch immediately.
        pending = nil
        if new == .working { startWorking() } else { applyStatic(new) }
    }

    /// Stops driving the icon so the agent can show its own glyph (e.g. blocked).
    func stopAnimating() { stopTimer(); pending = nil }

    // MARK: rendering

    private func applyStatic(_ s: State) {
        state = s
        stopTimer()
        switch s {
        case .idle:    button?.image = idleImage
        case .alert:   button?.image = alertImage ?? idleImage
        case .working: button?.image = frames.last ?? idleImage   // static "busy" frame
        }
    }

    private func startWorking() {
        state = .working
        pending = nil
        guard config.animateWorking, frames.count > 1 else { applyStatic(.working); return }
        frameIndex = 0
        button?.image = frames[0]
        stopTimer()
        let fps = min(24, max(6, config.workingFPS))
        let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // keep animating even during menu tracking
        timer = t
    }

    private func tick() {
        guard frames.count > 1 else { return }
        frameIndex += 1
        if frameIndex >= frames.count {
            frameIndex = 0
            if let p = pending {                 // loop finished → honor the queued change
                pending = nil
                if p == .working { button?.image = frames[0] }   // keep looping
                else { applyStatic(p) }
                return
            }
        }
        button?.image = frames[frameIndex]
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
}
#endif
