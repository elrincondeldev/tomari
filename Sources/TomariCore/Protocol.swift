import Foundation

// Mirrors shared/protocol.ts; keep the two in step.

public let panelPort = 7778

public enum SessionState: String, CaseIterable, Sendable, Decodable {
    case idle // started, no prompt yet
    case working
    case needsPermission = "needs_permission"
    case needsInput = "needs_input"
    case compacting
    case done
    case error
    case ended // process gone; the session itself can be reopened

    /// Unknown states from a newer agent read as idle instead of failing the whole message.
    public init(from decoder: Decoder) throws {
        self = SessionState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .idle
    }
}

public struct SessionIcon: Equatable, Sendable, Decodable {
    public var character: String
    public var color: String

    public init(character: String, color: String) {
        self.character = character
        self.color = color
    }

    public static let `default` = SessionIcon(character: "default", color: "#d97757")

    /// The colors a session's creature can take, offered in its right-click menu.
    public static let palette: [(name: String, color: String)] = [
        ("Orange", "#ff6b1a"), ("Clay", "#d97757"), ("Yellow", "#ffd23f"), ("Green", "#4cd964"), ("Cyan", "#3ccfe6"),
        ("Blue", "#4f7cff"), ("Purple", "#a66cff"), ("Pink", "#ff5fa2"), ("White", "#e8e8e8"),
    ]
}

/// One of the questions Claude asks with AskUserQuestion: answered with one of its options, or several if `multiSelect`.
public struct PromptQuestion: Equatable, Sendable, Decodable {
    public struct Option: Equatable, Sendable, Decodable {
        public var label: String
        public var description: String

        public init(label: String, description: String = "") {
            self.label = label
            self.description = description
        }
    }

    public var question: String
    /// A short label, e.g. "Framework".
    public var header: String
    public var options: [Option]
    public var multiSelect: Bool

    public init(question: String, header: String, options: [Option], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// A permission prompt the strip can answer, while Claude Code waits on it.
public struct PermissionPrompt: Equatable, Sendable, Decodable {
    /// Names this request in the answer.
    public var id: String
    /// e.g. "Bash", "Edit", "mcp__github__create_issue", "AskUserQuestion".
    public var tool: String
    /// What it asks to do, in full: the command, file, URL or input.
    public var detail: String
    /// What "always allow" adds, e.g. "Bash(npm test:*) in this project"; nil when there is nothing to offer.
    public var always: String?
    /// For AskUserQuestion: the questions to answer, in order, instead of allowing or denying.
    public var questions: [PromptQuestion]?

    public init(id: String, tool: String, detail: String, always: String? = nil, questions: [PromptQuestion]? = nil) {
        self.id = id
        self.tool = tool
        self.detail = detail
        self.always = always
        self.questions = questions
    }

    private enum Keys: String, CodingKey { case id, tool, detail, always, questions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            tool: try c.decode(String.self, forKey: .tool),
            detail: try c.decode(String.self, forKey: .detail),
            always: try? c.decodeIfPresent(String.self, forKey: .always),
            // Questions this version can't read leave a prompt it can only open, never answer wrongly.
            questions: c.contains(.questions) ? ((try? c.decode([PromptQuestion].self, forKey: .questions)) ?? []) : nil
        )
    }
}

public struct PanelSession: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var cwd: String
    public var state: SessionState
    public var activity: String?
    /// The Claude process is running.
    public var live: Bool
    public var stateSince: Date
    public var pinned: Bool
    public var position: Int?
    public var icon: SessionIcon
    /// "interactive" or "background" (run by the Claude daemon, no terminal of its own); nil until the agent knows.
    public var kind: String?
    /// The coding agent running the session, such as "codex"; nil means Claude Code.
    public var agent: String?
    /// A Codex session that the Codex app started, as opposed to the Codex CLI.
    public var startedInCodexApp: Bool
    /// The permission prompt the session waits on that the strip can answer; nil when none.
    public var permission: PermissionPrompt?

    public init(
        id: String, name: String, cwd: String, state: SessionState, activity: String?, live: Bool,
        stateSince: Date, pinned: Bool, position: Int?, icon: SessionIcon, kind: String? = nil, agent: String? = nil,
        startedInCodexApp: Bool = false, permission: PermissionPrompt? = nil
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.state = state
        self.activity = activity
        self.live = live
        self.stateSince = stateSince
        self.pinned = pinned
        self.position = position
        self.icon = icon
        self.kind = kind
        self.agent = agent
        self.startedInCodexApp = startedInCodexApp
        self.permission = permission
    }
}

extension PanelSession: Decodable {
    private enum Keys: String, CodingKey {
        case id, name, cwd, state, activity, live, stateSince, pinned, position, icon, kind, agent, inCodexApp, permission
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let stateSinceEpochMs = try c.decode(Double.self, forKey: .stateSince)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            cwd: try c.decode(String.self, forKey: .cwd),
            state: try c.decode(SessionState.self, forKey: .state),
            activity: try c.decodeIfPresent(String.self, forKey: .activity),
            live: try c.decode(Bool.self, forKey: .live),
            stateSince: Date(timeIntervalSince1970: stateSinceEpochMs / 1000),
            pinned: try c.decode(Bool.self, forKey: .pinned),
            position: try c.decodeIfPresent(Int.self, forKey: .position),
            icon: try c.decode(SessionIcon.self, forKey: .icon),
            kind: try? c.decodeIfPresent(String.self, forKey: .kind),
            agent: try? c.decodeIfPresent(String.self, forKey: .agent),
            startedInCodexApp: (try? c.decodeIfPresent(Bool.self, forKey: .inCodexApp)) ?? false,
            permission: try? c.decodeIfPresent(PermissionPrompt.self, forKey: .permission)
        )
    }
}

/// A desktop-app session that can be pinned, running or not.
public struct LibraryEntry: Equatable, Sendable, Decodable {
    public var id: String
    public var name: String
    public var cwd: String
    public var lastActivityAt: Date
    public var pinned: Bool
    /// The coding agent running the session, such as "codex"; nil means Claude Code.
    public var agent: String?

    public init(id: String, name: String, cwd: String, lastActivityAt: Date, pinned: Bool, agent: String? = nil) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.lastActivityAt = lastActivityAt
        self.pinned = pinned
        self.agent = agent
    }

    private enum Keys: String, CodingKey { case id, name, cwd, lastActivityAt, pinned, agent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let lastActivityEpochMs = try c.decode(Double.self, forKey: .lastActivityAt)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            cwd: try c.decode(String.self, forKey: .cwd),
            lastActivityAt: Date(timeIntervalSince1970: lastActivityEpochMs / 1000),
            pinned: try c.decode(Bool.self, forKey: .pinned),
            agent: try? c.decodeIfPresent(String.self, forKey: .agent)
        )
    }
}

public enum ServerMessage: Equatable, Sendable {
    case snapshot(sessions: [PanelSession], focusedId: String?)
    case session(PanelSession)
    case removed(id: String)
    /// The session in front in the desktop app.
    case focus(id: String?)
    case error(message: String)
    /// Reply to a library request, most recent first.
    case library([LibraryEntry])

    /// Nil for malformed or unknown messages.
    public static func parse(_ text: String) -> ServerMessage? {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        guard let type = try? decoder.decode(Envelope.self, from: data).type else { return nil }
        switch type {
        case "snapshot":
            guard let m = try? decoder.decode(Snapshot.self, from: data) else { return nil }
            return .snapshot(sessions: m.sessions.compactMap(\.value), focusedId: m.focusedId)
        case "session":
            return (try? decoder.decode(SessionChange.self, from: data)).map { .session($0.session) }
        case "removed":
            return (try? decoder.decode(Removed.self, from: data)).map { .removed(id: $0.id) }
        case "focus":
            return (try? decoder.decode(Focus.self, from: data)).map { .focus(id: $0.id) }
        case "error":
            return (try? decoder.decode(Failure.self, from: data)).map { .error(message: $0.message) }
        case "library":
            return (try? decoder.decode(Library.self, from: data)).map { .library($0.sessions.compactMap(\.value)) }
        default:
            return nil
        }
    }

    private struct Envelope: Decodable { let type: String }
    private struct Snapshot: Decodable { let sessions: [Lenient<PanelSession>]; let focusedId: String? }
    private struct SessionChange: Decodable { let session: PanelSession }
    private struct Removed: Decodable { let id: String }
    private struct Focus: Decodable { let id: String? }
    private struct Failure: Decodable { let message: String }
    private struct Library: Decodable { let sessions: [Lenient<LibraryEntry>] }
}

/// Lets one unreadable session be skipped instead of failing the whole snapshot.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

public enum ClientMessage: Equatable, Sendable {
    case open(id: String)
    case pin(id: String, pinned: Bool)
    /// The agent stores icons with pins, so this also pins the session, and unpinning resets its icon.
    case icon(id: String, icon: SessionIcon)
    /// Asks for the desktop sessions that can be pinned; answered with `ServerMessage.library`.
    case library
    /// Opens a shell, without Claude, in a new Terminal.app tab.
    case terminal
    /// Starts a new session of `agent` ("claude" or "codex") in `cwd`, a folder some session ran in.
    case newSession(cwd: String, agent: String)
    /// Stops a live background session; its conversation is kept.
    case stop(id: String)
    /// Sent on connect and whenever the app in front changes kind.
    case frontApp(FrontAppKind)
    /// Answers the session's permission prompt `request`: `always` also adds the rule its `always` names, and
    /// `answers`, for a prompt with questions, holds the indexes of the chosen options, per question, in order.
    case permission(id: String, request: String, allow: Bool, always: Bool = false, answers: [[Int]]? = nil)

    public var sessionId: String? {
        switch self {
        case .open(let id), .pin(let id, _), .icon(let id, _), .stop(let id), .permission(let id, _, _, _, _): return id
        case .library, .terminal, .frontApp, .newSession: return nil
        }
    }

    public var json: String {
        let object: [String: Any]
        switch self {
        case .open(let id):
            object = ["type": "open", "id": id]
        case .pin(let id, let pinned):
            object = ["type": "pin", "id": id, "pinned": pinned]
        case .icon(let id, let icon):
            object = ["type": "icon", "id": id, "icon": ["character": icon.character, "color": icon.color]]
        case .library:
            object = ["type": "library"]
        case .terminal:
            object = ["type": "terminal"]
        case .stop(let id):
            object = ["type": "stop", "id": id]
        case .newSession(let cwd, let agent):
            object = ["type": "new", "cwd": cwd, "agent": agent]
        case .frontApp(let kind):
            object = ["type": "frontApp", "app": kind.rawValue]
        case .permission(let id, let request, let allow, let always, let answers):
            var answer: [String: Any] = ["type": "permission", "id": id, "request": request, "allow": allow]
            if always { answer["always"] = true }
            if let answers { answer["answers"] = answers }
            object = answer
        }
        let body = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: body, as: UTF8.self)
    }
}
