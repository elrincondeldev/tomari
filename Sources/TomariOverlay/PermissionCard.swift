import AppKit
import TomariCore

/// The card a click on a creature waiting on the user opens. For a permission: what the session asks to run, in
/// full, with Allow, Always (the rule Claude suggests, when it suggests one), Deny, and Open to answer in the
/// session itself. For a question: each question with its options, and Answer. Claude keeps its own dialog up
/// meanwhile, and the first answer on either side wins. It takes the keyboard without activating Tomari: Return
/// allows or answers, number keys pick the options of a single question, Esc closes without answering. It closes
/// on an answer, a click elsewhere, or once the request is answered in Claude.
@MainActor
final class PermissionCard: NSObject, NSWindowDelegate {
    private static var current: PermissionCard?

    private static let width: CGFloat = 380
    private static let maxDetailHeight: CGFloat = 220
    private static let maxQuestionsHeight: CGFloat = 420
    private static let gap: CGFloat = 8
    private static let pad: CGFloat = 12

    private let window: CardPanel
    private let sessionId: String
    private let prompt: PermissionPrompt
    private let send: (ClientMessage) -> Void
    /// Per question, its option buttons: radio buttons, or checkboxes where several may be chosen.
    private var choices: [[NSButton]] = []
    private var answerButton: NSButton?

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
        window = CardPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
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
        window.onNumber = { [weak self] n in self?.pick(n) ?? false }

        let inner = Self.width - 2 * Self.pad
        let questions = prompt.questions ?? []
        let title = label(questions.isEmpty ? "Allow \(Self.toolName(prompt.tool))?" : (questions.count == 1 ? "Claude asks" : "Claude asks \(questions.count) questions"), size: 13, bold: true)
        let subtitle = label(session.hoverName, size: 11, color: .secondaryLabelColor)
        subtitle.lineBreakMode = .byTruncatingTail

        var body: [NSView] = [title, subtitle]
        var buttons: [NSButton] = []
        let open = button("Open", #selector(openSession))
        open.toolTip = "Answer in the session itself"

        if questions.isEmpty {
            body.append(detailView(width: inner))
            let deny = button("Deny", #selector(denied))
            let allow = button("Allow", #selector(allowed))
            allow.keyEquivalent = "\r"
            if let always = prompt.always {
                let note = label("Always allows \(always)", size: 11, color: .secondaryLabelColor, wraps: true, width: inner)
                body.append(note)
                let alwaysButton = button("Always", #selector(allowedAlways))
                alwaysButton.toolTip = "Allow, and from now on \(always)"
                buttons = [open, deny, alwaysButton, allow]
            } else {
                buttons = [open, deny, allow]
            }
        } else {
            body.append(questionsView(questions, width: inner))
            let answer = button("Answer", #selector(answered))
            answer.keyEquivalent = "\r"
            answer.isEnabled = false
            answerButton = answer
            buttons = [open, answer]
        }

        // Open stands apart on the left; the answers sit together on the right.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [open, spacer] + buttons.filter { $0 !== open })
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fill
        body.append(row)

        let stack = NSStackView(views: body)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(2, after: title)
        stack.edgeInsets = NSEdgeInsets(top: Self.pad, left: Self.pad, bottom: Self.pad, right: Self.pad)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in body where view !== title && view !== subtitle {
            view.widthAnchor.constraint(equalToConstant: inner).isActive = true
        }

        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 10
        backdrop.layer?.masksToBounds = true
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor),
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        window.contentView = backdrop
        window.setContentSize(NSSize(width: Self.width, height: stack.fittingSize.height))
    }

    /// The command, file, URL or input, in monospace, scrolling past `maxDetailHeight`.
    private func detailView(width: CGFloat) -> NSView {
        let text = NSTextView()
        text.string = prompt.detail
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.textContainer?.containerSize = NSSize(width: width - 4, height: .greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.frame = NSRect(x: 0, y: 0, width: width - 4, height: 10)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let textHeight = (text.layoutManager?.usedRect(for: text.textContainer!).height ?? 16) + 12
        let height = min(max(textHeight, 30), Self.maxDetailHeight)

        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = textHeight > height
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5)
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.masksToBounds = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    /// Each question, then its options with their descriptions; scrolls past `maxQuestionsHeight`.
    private func questionsView(_ questions: [PromptQuestion], width: CGFloat) -> NSView {
        var views: [NSView] = []
        let single = questions.count == 1
        for (q, question) in questions.enumerated() {
            let heading = question.header.isEmpty ? question.question : "\(question.header): \(question.question)"
            views.append(label(heading, size: 12, bold: true, wraps: true, width: width))
            // A stack of its own per question: AppKit groups radio buttons that share a superview.
            var group: [NSView] = []
            var buttons: [NSButton] = []
            for (n, option) in question.options.enumerated() {
                let title = single && n < 9 ? "\(n + 1). \(option.label)" : option.label
                let choice = question.multiSelect
                    ? NSButton(checkboxWithTitle: title, target: self, action: #selector(chose(_:)))
                    : NSButton(radioButtonWithTitle: title, target: self, action: #selector(chose(_:)))
                choice.tag = q
                buttons.append(choice)
                group.append(choice)
                if !option.description.isEmpty {
                    let note = label(option.description, size: 11, color: .secondaryLabelColor, wraps: true, width: width - 20)
                    let indented = NSStackView(views: [note])
                    indented.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
                    group.append(indented)
                }
            }
            let options = NSStackView(views: group)
            options.orientation = .vertical
            options.alignment = .leading
            options.spacing = 4
            views.append(options)
            choices.append(buttons)
            if q < questions.count - 1 { views.append(NSView(frame: NSRect(x: 0, y: 0, width: width, height: 4))) }
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        let height = stack.fittingSize.height
        guard height > Self.maxQuestionsHeight else { return stack }

        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
        ])
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: Self.maxQuestionsHeight).isActive = true
        return scroll
    }

    private func label(_ text: String, size: CGFloat, bold: Bool = false, color: NSColor = .labelColor, wraps: Bool = false, width: CGFloat = 0) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        field.textColor = color
        field.isSelectable = false
        if wraps { field.preferredMaxLayoutWidth = width }
        return field
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
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

    // MARK: Answers

    @objc private func allowed() { answer(.permission(id: sessionId, request: prompt.id, allow: true)) }

    @objc private func allowedAlways() { answer(.permission(id: sessionId, request: prompt.id, allow: true, always: true)) }

    @objc private func denied() { answer(.permission(id: sessionId, request: prompt.id, allow: false)) }

    @objc private func answered() {
        guard let picks = chosen else { return }
        answer(.permission(id: sessionId, request: prompt.id, allow: true, answers: picks))
    }

    private func answer(_ message: ClientMessage) {
        close()
        send(message)
    }

    @objc private func openSession() {
        close()
        send(.open(id: sessionId))
    }

    /// The chosen option indexes per question, once every question has at least one.
    private var chosen: [[Int]]? {
        let picks = choices.map { buttons in buttons.indices.filter { buttons[$0].state == .on } }
        return picks.allSatisfy { !$0.isEmpty } ? picks : nil
    }

    @objc private func chose(_ sender: NSButton) {
        let question = sender.tag
        if !(prompt.questions?[question].multiSelect ?? false) {
            for other in choices[question] where other !== sender { other.state = .off }
        }
        answerButton?.isEnabled = chosen != nil
    }

    /// Number keys pick the options of a single question; a single-choice one is answered at once.
    private func pick(_ number: Int) -> Bool {
        guard choices.count == 1, let options = choices.first, number >= 1, number <= options.count else { return false }
        let option = options[number - 1]
        let multi = prompt.questions?.first?.multiSelect ?? false
        option.state = multi && option.state == .on ? .off : .on
        chose(option)
        if !multi { answered() }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// A key panel that also hands number keys to the card.
private final class CardPanel: KeyPanel {
    var onNumber: ((Int) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if plain, let typed = event.charactersIgnoringModifiers, let number = Int(typed), onNumber?(number) == true { return }
        super.keyDown(with: event)
    }
}

/// Lays out top-down, so a scrolled stack starts at its first question.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
