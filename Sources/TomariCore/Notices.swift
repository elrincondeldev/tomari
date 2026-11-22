import Foundation

extension PermissionPrompt {
    /// "Bash", or "github: create_issue" for an MCP tool.
    public var toolTitle: String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.components(separatedBy: "__")
        return parts.count >= 3 ? "\(parts[1]): \(parts[2...].joined(separator: "__"))" : tool
    }

    /// What it asks, as a heading: "Allow Bash?", or "Claude asks" for questions.
    public var heading: String {
        guard let questions else { return "Allow \(toolTitle)?" }
        return questions.count > 1 ? "Claude asks \(questions.count) questions" : "Claude asks"
    }
}

/// A button on a notification, and what it answers.
public enum NoticeAction: Equatable, Sendable {
    case allow
    case always
    case deny
    /// The option at this index of a prompt's single question.
    case option(Int)

    public var identifier: String {
        switch self {
        case .allow: return "allow"
        case .always: return "always"
        case .deny: return "deny"
        case .option(let index): return "option.\(index)"
        }
    }

    public init?(identifier: String) {
        switch identifier {
        case "allow": self = .allow
        case "always": self = .always
        case "deny": self = .deny
        default:
            guard identifier.hasPrefix("option."), let index = Int(identifier.dropFirst("option.".count)), index >= 0 else { return nil }
            self = .option(index)
        }
    }

    /// The answer it sends for `request` of session `id`.
    public func message(session id: String, request: String) -> ClientMessage {
        switch self {
        case .allow: return .permission(id: id, request: request, allow: true)
        case .always: return .permission(id: id, request: request, allow: true, always: true)
        case .deny: return .permission(id: id, request: request, allow: false)
        case .option(let index): return .permission(id: id, request: request, allow: true, answers: [[index]])
        }
    }
}

/// A notification for a session waiting on the user, with buttons when the strip can answer it.
public struct Notice: Equatable, Sendable {
    public struct Button: Equatable, Sendable {
        public let action: NoticeAction
        public let title: String
    }

    public let sessionId: String
    /// The permission prompt its buttons answer; nil when it has none.
    public let requestId: String?
    public let title: String
    public let subtitle: String
    public let body: String
    public let buttons: [Button]

    /// Notifications show this many buttons; a question with more options is answered from the card instead.
    public static let maxOptions = 4

    /// `answers`: whether the strip answers prompts (the user's preference), so the notice offers buttons.
    public init(session: PanelSession, answers: Bool) {
        sessionId = session.id
        let prompt = answers ? session.permission.flatMap { $0.questions?.isEmpty == true ? nil : $0 } : nil
        requestId = prompt?.id
        guard let prompt else {
            title = session.hoverName
            subtitle = ""
            body = session.activity ?? (session.state == .needsPermission ? "Needs your permission" : "Waiting for you")
            buttons = []
            return
        }
        title = prompt.heading
        subtitle = session.hoverName
        if let questions = prompt.questions {
            body = questions.map(\.question).joined(separator: "\n")
            let question = questions.count == 1 ? questions[0] : nil
            if let question, !question.multiSelect, question.options.count <= Self.maxOptions {
                buttons = question.options.enumerated().map { Button(action: .option($0.offset), title: $0.element.label) }
            } else {
                buttons = [] // several answers to pick: the card
            }
        } else {
            body = prompt.detail
            buttons = [Button(action: .allow, title: "Allow")]
                + (prompt.always.map { _ in [Button(action: .always, title: "Always Allow")] } ?? [])
                + [Button(action: .deny, title: "Deny")]
        }
    }
}

/// Decides which sessions get a notification and which notifications are stale. A session gets one when it starts
/// waiting on the user, and a new one for each new permission prompt or question while it waits, unless the user
/// is looking at it (focused, with Terminal or the Claude desktop app in front; or started in the Codex app, with
/// that in front). Its notification is withdrawn once
/// it no longer waits, or waits on something else. Sessions already waiting when the overlay connects get none.
public struct NoticeTracker: Sendable {
    /// Per session, what its notification is about: the prompt's id, or when it started waiting.
    private var shown: [String: String] = [:]
    /// What each waiting session waits on, notified or not, so a session already waiting stays quiet.
    private var waiting: [String: String] = [:]

    public init() {}

    /// `initial`: these sessions come from a new connection's snapshot.
    public mutating func update(
        _ sessions: [PanelSession], initial: Bool, focusedId: String?, frontApp: FrontAppKind, answers: Bool
    ) -> (post: [Notice], withdraw: [String]) {
        var post: [Notice] = []
        var withdraw: [String] = []
        var nowWaiting: [String: String] = [:]
        for session in sessions where session.needsAttention && session.live {
            let key = session.permission?.id ?? "since \(session.stateSince.timeIntervalSince1970)"
            nowWaiting[session.id] = key
            guard !initial, waiting[session.id] != key else { continue }
            if frontApp.isLookingAt(session, focusedId: focusedId) { continue }
            shown[session.id] = key
            post.append(Notice(session: session, answers: answers))
        }
        for (id, key) in shown where nowWaiting[id] != key {
            shown[id] = nil
            withdraw.append(id)
        }
        waiting = nowWaiting
        return (post, withdraw.sorted())
    }

    /// Forgets a notification the user dismissed or answered.
    public mutating func forget(_ sessionId: String) {
        shown[sessionId] = nil
    }
}
