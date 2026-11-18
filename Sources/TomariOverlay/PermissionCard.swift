import AppKit
import TomariCore

/// The card a click on a creature waiting for permission opens: what the session asks to run, in full, with
/// Allow, Deny, and Open to answer in the session itself. Claude keeps its own dialog up meanwhile, and the
/// first answer on either side wins. It takes the keyboard without activating Tomari: Return allows, Esc closes
/// without answering. It closes on an answer, a click elsewhere, or once the request is answered in Claude.
@MainActor
final class PermissionCard: NSObject, NSWindowDelegate {
    private static var current: PermissionCard?

    private static let width: CGFloat = 380
    private static let maxDetailHeight: CGFloat = 220
    private static let gap: CGFloat = 8
    private static let pad: CGFloat = 12

    private let window: KeyPanel
    private let sessionId: String
    private let prompt: PermissionPrompt
    private let send: (ClientMessage) -> Void

    /// Shows the card for `session`'s prompt beside `anchor` (its creature, in screen coordinates).
    static func show(for session: PanelSession, prompt: PermissionPrompt, beside anchor: NSRect, edge: ScreenEdge, send: @escaping (ClientMessage) -> Void) {
        current?.close()
        let card = PermissionCard(session: session, prompt: prompt, send: send)
        current = card
        card.present(beside: anchor, edge: edge)
    }

    /// Closes the card once its request is no longer waiting: answered in Claude, or the session moved on.
    static func sync(with sessions: [String: PanelSession]) {
        guard let card = current else { return }
        if sessions[card.sessionId]?.permission?.id != card.prompt.id { card.close() }
    }

    private init(session: PanelSession, prompt: PermissionPrompt, send: @escaping (ClientMessage) -> Void) {
        sessionId = session.id
        self.prompt = prompt
        self.send = send
        window = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        build(session: session)
    }

    private func build(session: PanelSession) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .utilityWindow
        window.delegate = self
        window.onCancel = { [weak self] in self?.close() }

        let title = NSTextField(labelWithString: "Allow \(Self.toolName(prompt.tool))?")
        title.font = .boldSystemFont(ofSize: 13)
        let subtitle = NSTextField(labelWithString: session.hoverName)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let text = NSTextView()
        text.string = prompt.detail
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        let detailWidth = Self.width - 2 * Self.pad
        text.textContainer?.containerSize = NSSize(width: detailWidth - 4, height: .greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.frame = NSRect(x: 0, y: 0, width: detailWidth - 4, height: 10)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let textHeight = (text.layoutManager?.usedRect(for: text.textContainer!).height ?? 16) + 12
        let detailHeight = min(max(textHeight, 30), Self.maxDetailHeight)

        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = textHeight > detailHeight
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5)
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.masksToBounds = true

        let open = NSButton(title: "Open", target: self, action: #selector(openSession))
        open.toolTip = "Answer in the session itself"
        let deny = NSButton(title: "Deny", target: self, action: #selector(denied))
        let allow = NSButton(title: "Allow", target: self, action: #selector(allowed))
        allow.keyEquivalent = "\r"
        for button in [open, deny, allow] { button.bezelStyle = .rounded }

        let height = Self.pad + 18 + 2 + 15 + 8 + detailHeight + 10 + 28 + Self.pad
        let backdrop = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        backdrop.material = .popover
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 10
        backdrop.layer?.masksToBounds = true
        window.contentView = backdrop
        window.setContentSize(backdrop.frame.size)

        for view in [title, subtitle, scroll, open, deny, allow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            backdrop.addSubview(view)
        }
        let pad = Self.pad
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: pad),
            title.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: pad),
            title.trailingAnchor.constraint(lessThanOrEqualTo: backdrop.trailingAnchor, constant: -pad),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: backdrop.trailingAnchor, constant: -pad),
            scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -pad),
            scroll.heightAnchor.constraint(equalToConstant: detailHeight),
            open.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: pad),
            open.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -pad),
            allow.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -pad),
            allow.centerYAnchor.constraint(equalTo: open.centerYAnchor),
            deny.trailingAnchor.constraint(equalTo: allow.leadingAnchor, constant: -8),
            deny.centerYAnchor.constraint(equalTo: open.centerYAnchor),
        ])
    }

    /// "Bash", or "github: create_issue" for an MCP tool.
    private static func toolName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.components(separatedBy: "__")
        return parts.count >= 3 ? "\(parts[1]): \(parts[2...].joined(separator: "__"))" : tool
    }

    private func present(beside anchor: NSRect, edge: ScreenEdge) {
        let size = window.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor.insetBy(dx: -1000, dy: -1000)
        let x = edge == .right ? anchor.minX - Self.gap - size.width : anchor.maxX + Self.gap
        // Centered on the creature where it fits, else kept on screen.
        let y = min(max(anchor.midY - size.height / 2, visible.minY + Self.gap), visible.maxY - size.height - Self.gap)
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window.delegate = nil
        window.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    @objc private func allowed() { answer(true) }

    @objc private func denied() { answer(false) }

    private func answer(_ allow: Bool) {
        close()
        send(.permission(id: sessionId, request: prompt.id, allow: allow))
    }

    @objc private func openSession() {
        close()
        send(.open(id: sessionId))
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
