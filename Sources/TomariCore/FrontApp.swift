import Foundation

/// What the overlay tells the agent is in front, so the agent only asks Terminal about its tabs while it is.
public enum FrontAppKind: String, Equatable, Sendable {
    case terminal
    case desktop
    case codex
    case other

    public init(bundleId: String?) {
        switch bundleId {
        case "com.apple.Terminal": self = .terminal
        case "com.anthropic.claudefordesktop": self = .desktop
        case "com.openai.codex": self = .codex
        default: self = .other
        }
    }

    /// Whether the focused session is on screen in this app: Terminal for CLI sessions, the desktop app for its own.
    public var showsSessions: Bool { self == .terminal || self == .desktop }

    /// What the agent is told. It only tells Terminal and the desktop app apart from everything else, so the Codex
    /// app, which only the overlay needs to know about, is reported as another app.
    public var reportedToAgent: FrontAppKind { self == .codex ? .other : self }

    /// Whether the user may be looking at `session` now, so it needs no chime or notification. Terminal and the Claude
    /// desktop app go by the focused session. The Codex app does not say which thread it shows, so while it is in
    /// front every Codex session that started there counts as seen.
    public func isLookingAt(_ session: PanelSession, focusedId: String?) -> Bool {
        if self == .codex { return session.agent == "codex" && session.startedInCodexApp }
        return showsSessions && session.id == focusedId
    }
}

/// Lets a kind through only when it differs from the one last sent on this connection.
public struct FrontAppReporter: Sendable {
    private var sent: FrontAppKind?

    public init() {}

    /// The kind to send, or nil if the agent already has it.
    public mutating func next(_ kind: FrontAppKind) -> FrontAppKind? {
        guard kind != sent else { return nil }
        sent = kind
        return kind
    }

    /// A new connection starts knowing nothing.
    public mutating func reset() {
        sent = nil
    }
}
