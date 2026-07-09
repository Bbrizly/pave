#if os(macOS)
import AppKit
import PaveKit

enum Sounds {
    private static let tick = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)
    private static let pop = NSSound(contentsOfFile: "/System/Library/Sounds/Pop.aiff", byReference: true)

    static func playTick() {
        tick?.stop()
        tick?.volume = 0.25
        tick?.play()
    }

    static func playFire() {
        pop?.stop()
        pop?.volume = 0.35
        pop?.play()
    }
}

/// Shared frosted-glass building blocks: a dark vibrancy view and a circular mask.
enum Frost {
    static func blur(_ frame: NSRect, material: NSVisualEffectView.Material = .hudWindow) -> NSVisualEffectView {
        let v = NSVisualEffectView(frame: frame)
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        v.wantsLayer = true
        return v
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
            label.textColor = NSColor.white.withAlphaComponent(0.95)
            label.maximumNumberOfLines = 4
            label.lineBreakMode = .byTruncatingTail
            label.sizeToFit()
            let padX: CGFloat = 18
            let padY: CGFloat = 12
            let w = min(label.frame.width + padX * 2, 560)
            let h = label.frame.height + padY * 2
            let size = NSSize(width: w, height: h)

            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let blur = Frost.blur(NSRect(origin: .zero, size: size))
            blur.layer?.cornerRadius = 12
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            blur.layer?.borderWidth = 1
            blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
            label.frame.origin = NSPoint(x: padX, y: (h - label.frame.height) / 2)
            blur.addSubview(label)
            p.contentView = blur

            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.midX - w / 2, y: f.minY + 96))
            }
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.18
                p.animator().alphaValue = 1
            }
            panel = p

            let work = DispatchWorkItem {
                guard let cur = panel else { return }
                NSAnimationContext.runAnimationGroup({ c in
                    c.duration = 0.25
                    cur.animator().alphaValue = 0
                }, completionHandler: {
                    cur.orderOut(nil)
                    if panel === cur { panel = nil }
                })
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
        }
    }
}

/// The wheel. A ring of icon wedges over a frosted dark disc, with a live center
/// hub that names the focused slice, a staggered spring bloom, and an accent glow
/// on the selection. Everything lives on a canvas far larger than the disc so the
/// glow and shadow never touch a window edge.
final class RadialView: NSView {
    static let baseCanvas: CGFloat = 380

    private let content = CALayer()
    private var wedges: [CAShapeLayer] = []
    private var icons: [CALayer] = []
    private var iconImages: [(normal: CGImage?, selected: CGImage?)] = []
    private var rim: CAShapeLayer?
    private var hub: CAShapeLayer?
    private var hubText: CATextLayer?

    // Tunables the controller sets from Settings before each show.
    var scale: CGFloat = 1
    var animSpeed: CGFloat = 1
    var bloom = true
    var glow = true

    private var canvas: CGFloat { Self.baseCanvas * scale }
    private var c: CGFloat { canvas / 2 }          // wheel center
    private var outerR: CGFloat { 138 * scale }
    private var innerR: CGFloat { 52 * scale }
    private var discR: CGFloat { 150 * scale }
    private var hubR: CGFloat { 46 * scale }
    private var iconR: CGFloat { 97 * scale }
    private let gap: CGFloat = 0.014               // angular padding = clean slice gaps

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.baseCanvas, height: Self.baseCanvas))
        wantsLayer = true
        layer?.masksToBounds = false
        content.masksToBounds = false
        layer?.addSublayer(content)
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    private var baseColor: CGColor { NSColor.white.withAlphaComponent(0.07).cgColor }
    private var hotColor: CGColor { NSColor.controlAccentColor.cgColor }

    private func symbolImage(_ name: String, color: NSColor) -> CGImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18 * scale, weight: .semibold)) else { return nil }
        let tinted = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return tinted.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The rim, hub, and hub label. Rebuilt each show since scale can change.
    private func buildChrome() {
        rim?.removeFromSuperlayer()
        hub?.removeFromSuperlayer()
        hubText?.removeFromSuperlayer()

        let r = CAShapeLayer()
        r.path = CGPath(ellipseIn: CGRect(x: c - discR, y: c - discR, width: discR * 2, height: discR * 2), transform: nil)
        r.fillColor = NSColor.clear.cgColor
        r.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        r.lineWidth = 1
        content.addSublayer(r)
        rim = r

        let h = CAShapeLayer()
        h.path = CGPath(ellipseIn: CGRect(x: c - hubR, y: c - hubR, width: hubR * 2, height: hubR * 2), transform: nil)
        h.fillColor = NSColor.black.withAlphaComponent(0.22).cgColor
        h.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        h.lineWidth = 1
        h.zPosition = 10
        content.addSublayer(h)
        hub = h

        let t = CATextLayer()
        t.fontSize = 12 * scale
        t.font = NSFont.systemFont(ofSize: 12 * scale, weight: .semibold)
        t.alignmentMode = .center
        t.isWrapped = true
        t.truncationMode = .end
        t.contentsScale = 2
        t.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        t.frame = CGRect(x: c - (hubR - 6 * scale), y: c - 16 * scale, width: (hubR - 6 * scale) * 2, height: 32 * scale)
        t.zPosition = 11
        content.addSublayer(t)
        hubText = t
    }

    func configure(slices: [(name: String, icon: String?)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wedges.forEach { $0.removeFromSuperlayer() }
        icons.forEach { $0.removeFromSuperlayer() }
        wedges = []
        icons = []
        iconImages = []
        content.frame = bounds
        buildChrome()
        defer { CATransaction.commit() }
        guard !slices.isEmpty else { selectInternal(nil, names: []); return }

        let per = 2 * CGFloat.pi / CGFloat(slices.count)
        let ctr = CGPoint(x: c, y: c)
        let iconHalf = 13 * scale
        for (i, slice) in slices.enumerated() {
            let mid = CGFloat.pi / 2 - CGFloat(i) * per
            let a0 = mid + per / 2 - gap
            let a1 = mid - per / 2 + gap
            let path = CGMutablePath()
            path.addArc(center: ctr, radius: outerR, startAngle: a0, endAngle: a1, clockwise: true)
            path.addArc(center: ctr, radius: innerR, startAngle: a1, endAngle: a0, clockwise: false)
            path.closeSubpath()

            let w = CAShapeLayer()
            w.path = path
            w.frame = bounds
            w.fillColor = baseColor
            w.strokeColor = NSColor.white.withAlphaComponent(0.06).cgColor
            w.lineWidth = 1
            content.addSublayer(w)
            wedges.append(w)

            let iconName = slice.icon ?? "sparkles"
            let normal = symbolImage(iconName, color: NSColor.white.withAlphaComponent(0.85))
            let selected = symbolImage(iconName, color: .white)
            iconImages.append((normal, selected))

            let iconLayer = CALayer()
            iconLayer.contents = normal
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.contentsScale = 2
            iconLayer.frame = CGRect(x: c + cos(mid) * iconR - iconHalf, y: c + sin(mid) * iconR - iconHalf,
                                     width: iconHalf * 2, height: iconHalf * 2)
            iconLayer.zPosition = 5
            content.addSublayer(iconLayer)
            icons.append(iconLayer)
        }
        selectInternal(nil, names: slices.map { $0.name })
    }

    func select(_ index: Int?, names: [String]) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.10 / Double(max(0.3, animSpeed)))
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        selectInternal(index, names: names)
        CATransaction.commit()
    }

    private func selectInternal(_ index: Int?, names: [String]) {
        for (j, w) in wedges.enumerated() {
            let hot = j == index
            w.fillColor = hot ? hotColor : baseColor
            let s: CGFloat = hot ? 1.05 : 1.0
            w.transform = CATransform3DMakeScale(s, s, 1)
            w.zPosition = hot ? 2 : 0
            w.shadowColor = hotColor
            w.shadowOpacity = (hot && glow) ? 0.55 : 0
            w.shadowRadius = 12 * scale
            w.shadowOffset = .zero
            w.strokeColor = (hot ? NSColor.white.withAlphaComponent(0.28)
                                 : NSColor.white.withAlphaComponent(0.06)).cgColor
            if j < icons.count {
                icons[j].contents = hot ? iconImages[j].selected : iconImages[j].normal
                let si: CGFloat = hot ? 1.14 : 1.0
                icons[j].transform = CATransform3DMakeScale(si, si, 1)
            }
        }
        hubText?.string = index.flatMap { $0 < names.count ? names[$0] : nil } ?? ""
        hub?.fillColor = (index == nil ? NSColor.black.withAlphaComponent(0.22)
                                       : NSColor.black.withAlphaComponent(0.32)).cgColor
    }

    /// Show animation. Bloom = staggered spring per wedge; off = a quick fade.
    /// animSpeed scales stiffness up and stagger down so higher feels snappier.
    func animateIn() {
        let spd = max(0.3, animSpeed)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = (bloom ? 0.14 : 0.09) / Double(spd)
        content.add(fade, forKey: "in-fade")

        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = bloom ? 0.92 : 0.98
        pop.toValue = 1
        pop.damping = 18
        pop.stiffness = (bloom ? 320 : 520) * spd
        pop.mass = 1
        pop.duration = pop.settlingDuration
        content.add(pop, forKey: "in-pop")

        guard bloom else { return }

        let now = CACurrentMediaTime()
        let step = 0.016 / Double(spd)
        for (i, w) in wedges.enumerated() {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.5
            spring.toValue = 1
            spring.damping = 15
            spring.stiffness = 360 * spd
            spring.mass = 1
            spring.duration = spring.settlingDuration
            spring.beginTime = now + Double(i) * step
            spring.fillMode = .backwards
            w.add(spring, forKey: "bloom")
        }
    }
}

/// Owns the panel, selection state, and firing. Never activates the agent,
/// never blocks input. Mouse and keys arrive via the event tap; this class
/// only runs on main.
final class RadialController {
    var settings = Settings()
    var rings: [String: [RingSlice]] = [:]
    var onFire: (UUID) -> Void

    let visibleFlag = Locked(false)

    private let panel: NSPanel
    private let view = RadialView()
    private let container = NSView()
    private let blur: NSVisualEffectView
    private let shadowLayer = CAShapeLayer()
    private var slices: [RingSlice] = []
    private var selected: Int?
    private var center = CGPoint.zero

    init(onFire: @escaping (UUID) -> Void) {
        self.onFire = onFire
        let sz = RadialView.baseCanvas
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: sz, height: sz),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        // Unmasked container: the blur disc is clipped to a circle, but the wheel
        // (with its accent glow) sits on top unmasked so nothing gets cut off.
        container.frame = NSRect(x: 0, y: 0, width: sz, height: sz)
        container.wantsLayer = true
        container.layer?.masksToBounds = false

        shadowLayer.fillColor = NSColor.black.withAlphaComponent(0.28).cgColor
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.42
        shadowLayer.shadowOffset = CGSize(width: 0, height: -6)
        shadowLayer.zPosition = -1
        container.layer?.addSublayer(shadowLayer)

        // A square vibrancy view rounded into a perfect circle: reliable across
        // appearances, no mask-image stretch quirks.
        blur = Frost.blur(NSRect(x: 0, y: 0, width: sz, height: sz))
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        container.addSubview(blur)
        container.addSubview(view)

        panel.contentView = container
    }

    /// Size every layer for the current scale. Cheap, run each show.
    private func layout(scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let canvas = RadialView.baseCanvas * scale
        let discR = 150 * scale
        let ctr = canvas / 2
        let discRect = CGRect(x: ctr - discR, y: ctr - discR, width: discR * 2, height: discR * 2)
        let discPath = CGPath(ellipseIn: discRect, transform: nil)

        container.frame = NSRect(x: 0, y: 0, width: canvas, height: canvas)
        shadowLayer.path = discPath
        shadowLayer.shadowPath = discPath
        shadowLayer.shadowRadius = 26 * scale
        blur.frame = discRect
        blur.layer?.cornerRadius = discR
        view.frame = NSRect(x: 0, y: 0, width: canvas, height: canvas)
        CATransaction.commit()
    }

    func show(forApp bundleId: String?) {
        guard !visibleFlag.get() else { return }
        var ring = bundleId.flatMap { rings[$0] } ?? []
        if ring.isEmpty { ring = rings["global"] ?? [] }
        guard !ring.isEmpty else {
            Toast.show("Radial: no ring configured yet. Open the editor.")
            return
        }
        // Pull the current look/feel from settings.
        let scale = CGFloat(min(1.2, max(0.6, settings.radialScale)))
        view.scale = scale
        view.animSpeed = CGFloat(min(2.0, max(0.5, settings.radialAnimSpeed)))
        view.bloom = settings.radialBloom
        view.glow = settings.radialGlow
        layout(scale: scale)

        let mouse = NSEvent.mouseLocation
        center = mouse
        let half = RadialView.baseCanvas * scale / 2
        panel.setFrame(NSRect(x: mouse.x - half, y: mouse.y - half,
                              width: RadialView.baseCanvas * scale, height: RadialView.baseCanvas * scale),
                       display: false)
        present(Array(ring.prefix(8)))
        visibleFlag.set(true)
    }

    private func present(_ s: [RingSlice]) {
        slices = s
        selected = nil
        view.configure(slices: s.map { ($0.label, $0.icon) })
        panel.orderFrontRegardless()
        view.animateIn()
    }

    /// Mouse moved (via event tap). Selection by angle, inner deadzone = cancel.
    func updateFromMouse() {
        guard visibleFlag.get() else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - center.x
        let dy = m.y - center.y
        var newSel: Int?
        if hypot(dx, dy) >= 30, !slices.isEmpty {
            let per = 2 * CGFloat.pi / CGFloat(slices.count)
            var a = CGFloat.pi / 2 - atan2(dy, dx) + per / 2 // clockwise from top
            while a < 0 { a += 2 * .pi }
            newSel = Int(a.truncatingRemainder(dividingBy: 2 * .pi) / per) % slices.count
        }
        if newSel != selected {
            selected = newSel
            view.select(newSel, names: slices.map { $0.label })
            if settings.tickSound, newSel != nil { Sounds.playTick() }
        }
    }

    /// Called on the tap thread. Arrows, Return, Escape are the wheel's keys.
    /// Any other key means the user is typing a shortcut: get out of the way.
    func handleKey(_ code: Int64) -> Bool {
        guard visibleFlag.get() else { return false }
        guard [123, 124, 125, 126, 36, 53].contains(Int(code)) else {
            DispatchQueue.main.async { self.hide() }
            return false
        }
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
        view.select(next, names: slices.map { $0.label })
        if settings.tickSound { Sounds.playTick() }
    }

    func holdReleased() {
        guard visibleFlag.get() else { return }
        if settings.releaseToFire { fire() }
        // Click mode keeps the wheel open until a click, Return, or Escape.
    }

    /// A click always resolves the wheel, in both fire modes. This is also
    /// how submenus stay usable after the hold key was released.
    func clickFire() {
        fire()
    }

    private func fire() {
        guard visibleFlag.get() else { return }
        guard let i = selected, i < slices.count else {
            hide() // center or nothing = cancel
            return
        }
        let s = slices[i]
        if let sub = s.submenu, !sub.isEmpty {
            if settings.tickSound { Sounds.playTick() }
            present(Array(sub.prefix(8))) // one level deep, no more
            return
        }
        hide()
        if settings.tickSound { Sounds.playFire() }
        if let id = s.macro { onFire(id) }
    }

    func hide() {
        visibleFlag.set(false)
        panel.orderOut(nil)
        selected = nil
    }
}
#endif
