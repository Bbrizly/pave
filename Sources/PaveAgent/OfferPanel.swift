#if os(macOS)
import AppKit
import PaveKit

/// The offer moment: a quiet, non-activating panel that shows a detected
/// ritual and lets the user save it as a disabled draft macro, put it off,
/// or mute it for good. Mirrors Toast's frosted-panel construction (Radial.swift).
/// Owns only presentation and the auto-dismiss timer; every suppression
/// write and the actual macro save happen in the agent, which is the one
/// place holding the shared Store and SuppressionStore instances.
final class OfferPanel: NSObject {
    struct Offer {
        let match: PathMatch
        let macro: Macro
    }

    var onSave: (Offer) -> Void = { _ in }
    var onNotNow: (Offer) -> Void = { _ in }
    var onNever: (Offer) -> Void = { _ in }
    /// Timeout, not a decision: no suppression write beyond whatever
    /// recordOffered the caller already stamped at show time, so the same
    /// ritual can come back once its cooldown lapses instead of waiting out
    /// a week-long dismissal.
    var onAutoDismiss: (Offer) -> Void = { _ in }

    private(set) var current: Offer?

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

    private static let autoDismissSeconds: Double = 30
    private static let width: CGFloat = 360

    func show(match: PathMatch, macro: Macro) {
        dismissWork?.cancel()
        panel?.orderOut(nil)

        let offer = Offer(match: match, macro: macro)
        current = offer

        let all = match.run.plainEnglish()
        var lines = Array(all.prefix(4))
        if all.count > 4 { lines.append("…") }

        let padX: CGFloat = 18
        let padTop: CGFloat = 16
        let contentWidth = Self.width - padX * 2

        let title = NSTextField(labelWithString: "Pave noticed a routine (seen \(match.occurrences) times)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.maximumNumberOfLines = 2
        let titleHeight = height(of: title, width: contentWidth)
        title.frame = NSRect(x: padX, y: 0, width: contentWidth, height: titleHeight)

        let body = NSTextField(labelWithString: lines.joined(separator: "\n"))
        body.font = .systemFont(ofSize: 12, weight: .regular)
        body.textColor = NSColor.white.withAlphaComponent(0.82)
        body.maximumNumberOfLines = 5
        let bodyHeight = height(of: body, width: contentWidth)
        body.frame = NSRect(x: padX, y: 0, width: contentWidth, height: bodyHeight)

        let buttonRowHeight: CGFloat = 24
        let save = makeButton("Save draft macro", action: #selector(saveTapped), prominent: true)
        let notNow = makeButton("Not now", action: #selector(notNowTapped), prominent: false)
        let never = makeButton("Never for this", action: #selector(neverTapped), prominent: false)

        let gap: CGFloat = 10
        let bodyToTitleGap: CGFloat = 6
        let bodyToButtonsGap: CGFloat = 12
        let contentHeight = padTop + titleHeight + bodyToTitleGap + bodyHeight + bodyToButtonsGap + buttonRowHeight + padTop

        // Lay out bottom-up: buttons row, then body, then title, matching the
        // frame's y-up coordinate space.
        var x = padX
        for btn in [save, notNow, never] {
            btn.sizeToFit()
            var f = btn.frame
            f.origin = NSPoint(x: x, y: padTop)
            f.size.height = buttonRowHeight
            btn.frame = f
            x += f.width + gap
        }
        body.frame.origin.y = padTop + buttonRowHeight + bodyToButtonsGap
        title.frame.origin.y = body.frame.maxY + bodyToTitleGap

        let size = NSSize(width: Self.width, height: contentHeight)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let blur = Frost.blur(NSRect(origin: .zero, size: size))
        blur.layer?.cornerRadius = 14
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        blur.addSubview(title)
        blur.addSubview(body)
        blur.addSubview(save)
        blur.addSubview(notNow)
        blur.addSubview(never)
        p.contentView = blur

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 96))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            p.animator().alphaValue = 1
        }
        panel = p

        let work = DispatchWorkItem { [weak self] in self?.fireAutoDismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDismissSeconds, execute: work)
    }

    /// Hard close with no callback, used when a new offer replaces this one
    /// or the agent is tearing down. Does not count as any kind of decision.
    func close() {
        dismissWork?.cancel()
        dismissWork = nil
        current = nil
        let p = panel
        panel = nil
        guard let p else { return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    // MARK: actions

    @objc private func saveTapped() {
        guard let offer = current else { return }
        dismissWork?.cancel()
        close()
        onSave(offer)
    }

    @objc private func notNowTapped() {
        guard let offer = current else { return }
        dismissWork?.cancel()
        close()
        onNotNow(offer)
    }

    @objc private func neverTapped() {
        guard let offer = current else { return }
        dismissWork?.cancel()
        close()
        onNever(offer)
    }

    private func fireAutoDismiss() {
        guard let offer = current else { return }
        close()
        onAutoDismiss(offer)
    }

    // MARK: layout helpers

    private func height(of field: NSTextField, width: CGFloat) -> CGFloat {
        let cell = field.cell as? NSTextFieldCell
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let rect = cell?.drawingRect(forBounds: bounds) ?? bounds
        let size = field.attributedStringValue.boundingRect(
            with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(size.height) + 2
    }

    private func makeButton(_ title: String, action: Selector, prominent: Bool) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 11, weight: prominent ? .semibold : .regular)
        b.contentTintColor = prominent ? .controlAccentColor : .white
        return b
    }
}
#endif
