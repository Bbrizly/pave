#if os(macOS)
import AppKit
import MacroEngineKit

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

/// The wheel. Prebuilt CALayer wedges with SF Symbol icons, a live center hub,
/// staggered spring bloom, and an accent glow on the selected slice.
final class RadialView: NSView {
    private let content = CALayer()
    private var wedges: [CAShapeLayer] = []
    private var icons: [CALayer] = []
    private var iconImages: [(normal: CGImage?, selected: CGImage?)] = []
    private var labels: [CATextLayer] = []
    private var hubText: CATextLayer!
    private let outerR: CGFloat = 140
    private let innerR: CGFloat = 36

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        wantsLayer = true
        layer?.masksToBounds = false

        content.frame = bounds
        content.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        content.position = CGPoint(x: 150, y: 150)
        content.shadowColor = NSColor.black.cgColor
        content.shadowOpacity = 0.30
        content.shadowRadius = 16
        content.shadowOffset = CGSize(width: 0, height: -4)
        layer?.addSublayer(content)

        let hub = CAShapeLayer()
        let hubPath = CGMutablePath()
        hubPath.addEllipse(in: CGRect(x: 150 - 28, y: 150 - 28, width: 56, height: 56))
        hub.path = hubPath
        hub.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        hub.strokeColor = NSColor.separatorColor.cgColor
        hub.lineWidth = 1
        hub.zPosition = 10
        content.addSublayer(hub)

        hubText = CATextLayer()
        hubText.fontSize = 10
        hubText.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        hubText.alignmentMode = .center
        hubText.isWrapped = true
        hubText.truncationMode = .end
        hubText.contentsScale = 2
        hubText.foregroundColor = NSColor.secondaryLabelColor.cgColor
        hubText.frame = CGRect(x: 150 - 26, y: 150 - 13, width: 52, height: 26)
        hubText.zPosition = 11
        content.addSublayer(hubText)
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    private var baseColor: CGColor { NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor }
    private var hotColor: CGColor { NSColor.controlAccentColor.cgColor }

    private func symbolImage(_ name: String, color: NSColor) -> CGImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) else { return nil }
        let tinted = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return tinted.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func configure(slices: [(name: String, icon: String?)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wedges.forEach { $0.removeFromSuperlayer() }
        icons.forEach { $0.removeFromSuperlayer() }
        labels.forEach { $0.removeFromSuperlayer() }
        wedges = []
        icons = []
        iconImages = []
        labels = []
        defer { CATransaction.commit() }
        guard !slices.isEmpty else { return }

        let per = 2 * CGFloat.pi / CGFloat(slices.count)
        let ctr = CGPoint(x: 150, y: 150)
        for (i, slice) in slices.enumerated() {
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
            w.lineWidth = 2 // reads as a clean gap between slices
            content.addSublayer(w)
            wedges.append(w)

            let iconName = slice.icon ?? "sparkles"
            let normal = symbolImage(iconName, color: .labelColor)
            let selected = symbolImage(iconName, color: .white)
            iconImages.append((normal, selected))
            let iconLayer = CALayer()
            iconLayer.contents = normal
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.contentsScale = 2
            let ir: CGFloat = 104
            iconLayer.frame = CGRect(x: 150 + cos(mid) * ir - 11, y: 150 + sin(mid) * ir - 11,
                                     width: 22, height: 22)
            iconLayer.zPosition = 5
            content.addSublayer(iconLayer)
            icons.append(iconLayer)

            let t = CATextLayer()
            t.string = slice.name
            t.fontSize = 11
            t.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            t.alignmentMode = .center
            t.isWrapped = true
            t.truncationMode = .end
            t.contentsScale = 2
            t.foregroundColor = NSColor.labelColor.cgColor
            t.zPosition = 5
            let lr: CGFloat = 70
            t.frame = CGRect(x: 150 + cos(mid) * lr - 35, y: 150 + sin(mid) * lr - 13,
                             width: 70, height: 26)
            content.addSublayer(t)
            labels.append(t)
        }
        selectInternal(nil, names: slices.map { $0.name })
    }

    private var currentNames: [String] = []

    func select(_ index: Int?, names: [String]) {
        currentNames = names
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        selectInternal(index, names: names)
        CATransaction.commit()
    }

    private func selectInternal(_ index: Int?, names: [String]) {
        currentNames = names
        for (j, w) in wedges.enumerated() {
            let hot = j == index
            w.fillColor = hot ? hotColor : baseColor
            let s: CGFloat = hot ? 1.06 : 1.0
            w.transform = CATransform3DMakeScale(s, s, 1)
            w.zPosition = hot ? 2 : 0
            w.shadowColor = hotColor
            w.shadowOpacity = hot ? 0.6 : 0
            w.shadowRadius = 10
            w.shadowOffset = .zero
            if j < icons.count {
                icons[j].contents = hot ? iconImages[j].selected : iconImages[j].normal
                let si: CGFloat = hot ? 1.12 : 1.0
                icons[j].transform = CATransform3DMakeScale(si, si, 1)
            }
            if j < labels.count {
                labels[j].foregroundColor = hot ? NSColor.white.cgColor : NSColor.labelColor.cgColor
            }
        }
        hubText.string = index.flatMap { $0 < names.count ? names[$0] : nil } ?? ""
    }

    /// Staggered spring bloom: each wedge pops in clockwise, 18ms apart.
    func animateIn() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        content.add(fade, forKey: "in-fade")

        let now = CACurrentMediaTime()
        for (i, w) in wedges.enumerated() {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.55
            spring.toValue = 1
            spring.damping = 16
            spring.stiffness = 380
            spring.mass = 1
            spring.duration = spring.settlingDuration
            spring.beginTime = now + Double(i) * 0.018
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
    private var slices: [RingSlice] = []
    private var selected: Int?
    private var center = CGPoint.zero

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
        let mouse = NSEvent.mouseLocation
        center = mouse
        panel.setFrame(NSRect(x: mouse.x - 150, y: mouse.y - 150, width: 300, height: 300),
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

    /// Mouse moved (via event tap). Selection by angle, 24pt deadzone = cancel.
    func updateFromMouse() {
        guard visibleFlag.get() else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - center.x
        let dy = m.y - center.y
        var newSel: Int?
        if hypot(dx, dy) >= 24, !slices.isEmpty {
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
