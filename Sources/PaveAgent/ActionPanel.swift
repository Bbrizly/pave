#if os(macOS)
import AppKit

/// Shared small frosted-panel primitive: one title line and a row of action
/// buttons. Used for recall ("you have a macro for this") and the auto-run
/// graduation offer ("run this automatically?"). OfferPanel keeps its own
/// richer layout (title + multi-line plain-English body) since it has more
/// to show; this one is for a single sentence plus a couple of buttons, so
/// both moments share one visual style instead of drifting apart.
final class ActionPanel: NSObject {
    struct Action {
        let title: String
        let prominent: Bool
        let handler: () -> Void
    }

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    private var actions: [Action] = []
    private var autoDismissHandler: (() -> Void)?

    private static let autoDismissSeconds: Double = 30
    private static let width: CGFloat = 340

    /// Shows `text` with a row of buttons built from `actions`. Exactly one
    /// handler ever fires: the tapped button's, or `autoDismiss` after 30s of
    /// no answer. Calling show() again (a new moment arriving) replaces
    /// whatever is currently up with no callback for the one it replaced,
    /// same as OfferPanel's close().
    func show(title text: String, actions: [Action], autoDismiss: @escaping () -> Void) {
        dismissWork?.cancel()
        panel?.orderOut(nil)

        self.actions = actions
        self.autoDismissHandler = autoDismiss

        let padX: CGFloat = 18
        let padTop: CGFloat = 16
        let contentWidth = Self.width - padX * 2

        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.maximumNumberOfLines = 3
        let titleHeight = height(of: title, width: contentWidth)
        title.frame = NSRect(x: padX, y: 0, width: contentWidth, height: titleHeight)

        let buttonRowHeight: CGFloat = 24
        var buttons: [NSButton] = []
        for (i, action) in actions.enumerated() {
            let b = makeButton(action.title, prominent: action.prominent)
            b.tag = i
            b.target = self
            b.action = #selector(buttonTapped(_:))
            buttons.append(b)
        }

        let gap: CGFloat = 10
        let titleToButtonsGap: CGFloat = 12
        let contentHeight = padTop + titleHeight + titleToButtonsGap + buttonRowHeight + padTop

        // Lay out bottom-up: buttons row, then title, matching the frame's
        // y-up coordinate space (same order OfferPanel uses).
        var x = padX
        for btn in buttons {
            btn.sizeToFit()
            var f = btn.frame
            f.origin = NSPoint(x: x, y: padTop)
            f.size.height = buttonRowHeight
            btn.frame = f
            x += f.width + gap
        }
        title.frame.origin.y = padTop + buttonRowHeight + titleToButtonsGap

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
        buttons.forEach { blur.addSubview($0) }
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

    /// Hard close with no callback. Used when a new moment replaces this one.
    func close() {
        dismissWork?.cancel()
        dismissWork = nil
        actions = []
        autoDismissHandler = nil
        let p = panel
        panel = nil
        guard let p else { return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    // MARK: actions

    @objc private func buttonTapped(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        let handler = actions[sender.tag].handler
        dismissWork?.cancel()
        close()
        handler()
    }

    private func fireAutoDismiss() {
        guard let handler = autoDismissHandler else { return }
        close()
        handler()
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

    private func makeButton(_ title: String, prominent: Bool) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 11, weight: prominent ? .semibold : .regular)
        b.contentTintColor = prominent ? .controlAccentColor : .white
        return b
    }
}
#endif
