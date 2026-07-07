#if os(macOS)
import AppKit
import MacroEngineKit

enum Tick {
    private static let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)
    static func play() {
        sound?.stop()
        sound?.volume = 0.3
        sound?.play()
    }
}

enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String) {
        DispatchQueue.main.async {
            hideWork?.cancel()
            panel?.orderOut(nil)
            panel = nil

            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .white
            label.maximumNumberOfLines = 4
            label.lineBreakMode = .byTruncatingTail
            label.sizeToFit()
            let pad: CGFloat = 14
            let size = NSSize(width: min(label.frame.width + pad * 2, 560),
                              height: label.frame.height + pad * 1.2)
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let bg = NSView(frame: NSRect(origin: .zero, size: size))
            bg.wantsLayer = true
            bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
            bg.layer?.cornerRadius = 10
            label.frame.origin = NSPoint(x: pad, y: pad * 0.6)
            bg.addSubview(label)
            p.contentView = bg
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 80))
            }
            p.orderFrontRegardless()
            panel = p
            let work = DispatchWorkItem { panel?.orderOut(nil); panel = nil }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }
    }
}

/// The wheel. CALayer wedges on a container layer, spring in, hover pop.
final class RadialView: NSView {
    private let content = CALayer()
    private var wedges: [CAShapeLayer] = []
    private var texts: [CATextLayer] = []
    private let outerR: CGFloat = 140
    private let innerR: CGFloat = 34

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        wantsLayer = true
        content.frame = bounds
        content.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        content.position = CGPoint(x: 150, y: 150)
        layer?.addSublayer(content)

        let hole = CAShapeLayer()
        let holePath = CGMutablePath()
        holePath.addEllipse(in: CGRect(x: 150 - 22, y: 150 - 22, width: 44, height: 44))
        hole.path = holePath
        hole.fillColor = NSColor.black.withAlphaComponent(0.3).cgColor
        hole.zPosition = 10
        content.addSublayer(hole)
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    private var baseColor: CGColor { NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor }
    private var hotColor: CGColor { NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor }

    func configure(names: [String]) {
        wedges.forEach { $0.removeFromSuperlayer() }
        texts.forEach { $0.removeFromSuperlayer() }
        wedges = []
        texts = []
        guard !names.isEmpty else { return }

        let per = 2 * CGFloat.pi / CGFloat(names.count)
        let ctr = CGPoint(x: 150, y: 150)
        for (i, name) in names.enumerated() {
            let mid = CGFloat.pi / 2 - CGFloat(i) * per
            let a0 = mid + per / 2
            let a1 = mid - per / 2
            let path = CGMutablePath()
            path.addArc(center: ctr, radius: outerR, startAngle: a0, endAngle: a1, clockwise: true)
            path.addArc(center: ctr, radius: innerR, startAngle: a1, endAngle: a0, clockwise: false)
            path.closeSubpath()

            let w = CAShapeLayer()
            w.path = path
            w.frame = bounds
            w.fillColor = baseColor
            w.strokeColor = NSColor.separatorColor.cgColor
            w.lineWidth = 1
            content.addSublayer(w)
            wedges.append(w)

            let t = CATextLayer()
            t.string = name
            t.fontSize = 12
            t.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            t.alignmentMode = .center
            t.isWrapped = true
            t.truncationMode = .end
            t.contentsScale = 2
            t.foregroundColor = NSColor.labelColor.cgColor
            t.zPosition = 5
            let lr = (innerR + outerR) / 2
            t.frame = CGRect(x: 150 + cos(mid) * lr - 46, y: 150 + sin(mid) * lr - 14,
                             width: 92, height: 28)
            content.addSublayer(t)
            texts.append(t)
        }
        select(nil)
    }

    func select(_ index: Int?) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        for (j, w) in wedges.enumerated() {
            let hot = j == index
            w.fillColor = hot ? hotColor : baseColor
            let s: CGFloat = hot ? 1.05 : 1.0
            w.transform = CATransform3DMakeScale(s, s, 1)
        }
        CATransaction.commit()
    }

    func animateIn() {
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.7
        spring.toValue = 1
        spring.damping = 18
        spring.stiffness = 300
        spring.mass = 1
        spring.duration = spring.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.1
        content.add(spring, forKey: "in-scale")
        content.add(fade, forKey: "in-fade")
    }
}

/// Owns the panel, selection state, and firing. Never activates the agent,
/// never blocks input. Selection by pointer angle or arrow keys.
final class RadialController {
    var settings = Settings()
    var rings: [String: [RingSlice]] = [:]
    var onFire: (UUID) -> Void

    let visibleFlag = Locked(false)

    private let panel: NSPanel
    private let view = RadialView()
    private var slices: [RingSlice] = []
    private var selected: Int?
    private var center = CGPoint.zero
    private var monitors: [Any] = []

    init(onFire: @escaping (UUID) -> Void) {
        self.onFire = onFire
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
    }

    func show(forApp bundleId: String?) {
        guard !visibleFlag.get() else { return }
        var ring = bundleId.flatMap { rings[$0] } ?? []
        if ring.isEmpty { ring = rings["global"] ?? [] }
        guard !ring.isEmpty else {
            Toast.show("Radial: no ring configured yet. Open the editor.")
            return
        }
        present(Array(ring.prefix(8)))
    }

    private func present(_ s: [RingSlice]) {
        slices = s
        selected = nil
        let firstShow = !visibleFlag.get()
        if firstShow {
            let mouse = NSEvent.mouseLocation
            center = mouse
            panel.setFrame(NSRect(x: mouse.x - 150, y: mouse.y - 150, width: 300, height: 300),
                           display: false)
        }
        view.configure(names: s.map { $0.label })
        panel.orderFrontRegardless()
        view.animateIn()
        guard firstShow else { return }
        visibleFlag.set(true)
        if let mm = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged],
                                                      handler: { [weak self] _ in self?.trackMouse() }) {
            monitors.append(mm)
        }
        if !settings.releaseToFire {
            if let cm = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown],
                                                          handler: { [weak self] _ in self?.fire() }) {
                monitors.append(cm)
            }
        }
    }

    private func trackMouse() {
        let m = NSEvent.mouseLocation
        let dx = m.x - center.x
        let dy = m.y - center.y
        var newSel: Int?
        if hypot(dx, dy) >= 24, !slices.isEmpty {
            let per = 2 * CGFloat.pi / CGFloat(slices.count)
            var a = CGFloat.pi / 2 - atan2(dy, dx) + per / 2 // clockwise from top, snapped
            while a < 0 { a += 2 * .pi }
            newSel = Int(a.truncatingRemainder(dividingBy: 2 * .pi) / per) % slices.count
        }
        if newSel != selected {
            selected = newSel
            view.select(newSel)
            if settings.tickSound, newSel != nil { Tick.play() }
        }
    }

    /// Called on the tap thread. Swallows arrows, return, escape while visible.
    func handleKey(_ code: Int64) -> Bool {
        guard visibleFlag.get() else { return false }
        guard [123, 124, 125, 126, 36, 53].contains(Int(code)) else { return false }
        DispatchQueue.main.async {
            switch code {
            case 123, 126: self.stepSelection(-1)
            case 124, 125: self.stepSelection(1)
            case 36: self.fire()
            case 53: self.hide()
            default: break
            }
        }
        return true
    }

    private func stepSelection(_ d: Int) {
        guard !slices.isEmpty else { return }
        let base = selected ?? (d > 0 ? -1 : 0)
        let next = (base + d + slices.count) % slices.count
        selected = next
        view.select(next)
        if settings.tickSound { Tick.play() }
    }

    func holdReleased() {
        guard visibleFlag.get() else { return }
        if settings.releaseToFire { fire() }
    }

    private func fire() {
        guard visibleFlag.get() else { return }
        guard let i = selected, i < slices.count else {
            hide() // center or nothing = cancel
            return
        }
        let s = slices[i]
        if let sub = s.submenu, !sub.isEmpty {
            present(Array(sub.prefix(8))) // one level deep, no more
            return
        }
        hide()
        if let id = s.macro { onFire(id) }
    }

    func hide() {
        visibleFlag.set(false)
        panel.orderOut(nil)
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        selected = nil
    }
}
#endif
