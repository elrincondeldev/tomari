import Foundation

/// The + menu's sessions under one agent's heading, or the launcher's sessions on the strip.
public struct LibraryGroup: Equatable, Sendable {
    /// "claude", "codex", another agent's name, or `LibraryGroup.onStrip`.
    public let agent: String
    /// Nil for the strip's group, which holds every agent's sessions.
    public let badge: AgentBadge?
    public let title: String
    public let entries: [LibraryEntry]

    /// The launcher's first tab: the sessions on the strip.
    public static let onStrip = "strip"
    /// The launcher's last tab: the folders sessions ran in, to start a new one there.
    public static let newSession = "new"
}

/// The folders sessions ran in, each once, the most recently used first: where the launcher starts new sessions.
/// Each is an entry named after its folder, with the folder as its id.
public func projectFolders(_ entries: [LibraryEntry], onStrip: [PanelSession] = [], limit: Int = 60) -> [LibraryEntry] {
    var latest: [String: Date] = [:]
    for entry in entries + onStrip.map(LibraryEntry.init) where entry.cwd.hasPrefix("/") {
        latest[entry.cwd] = max(latest[entry.cwd] ?? .distantPast, entry.lastActivityAt)
    }
    return latest
        .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        .prefix(limit)
        .map { LibraryEntry(id: $0.key, name: ($0.key as NSString).lastPathComponent, cwd: $0.key, lastActivityAt: $0.value, pinned: false) }
}

extension LibraryEntry {
    /// A session on the strip, as the launcher lists it.
    public init(_ session: PanelSession) {
        self.init(id: session.id, name: session.name, cwd: session.cwd, lastActivityAt: session.stateSince, pinned: session.pinned, agent: session.agent)
    }
}

extension Array where Element == PanelSession {
    /// The order the launcher lists the strip's sessions in: those waiting for you first, the longest wait first,
    /// then the others, the most recent change first.
    public var launcherOrder: [PanelSession] {
        let waiting = filter(\.needsAttention).sorted { ($0.stateSince, $0.id) < ($1.stateSince, $1.id) }
        let others = filter { !$0.needsAttention }.sorted { $0.stateSince != $1.stateSince ? $0.stateSince > $1.stateSince : $0.id < $1.id }
        return waiting + others
    }
}

extension LibraryEntry {
    /// The last component of the folder the session ran in.
    public var folder: String {
        (cwd as NSString).lastPathComponent
    }

    /// The name as the + menu shows it: cut so a long one doesn't widen the whole menu.
    public var menuName: String { shortened(name, to: 34) }

    /// The folder as the + menu shows it, after the name.
    public var menuFolder: String { shortened(folder, to: 16) }

    /// Whether every word of `query` is in the session's name or folder, ignoring case and accents.
    /// An empty query matches everything.
    public func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = "\(name) \(folder)"
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// `text` on one line, cut to `limit` characters with an ellipsis at the end.
func shortened(_ text: String, to limit: Int) -> String {
    let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return line.count <= limit ? line : line.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
}

/// The strip's sessions when given any, in the launcher's order; then Claude Code's sessions, then Codex's, then any
/// other agent's, each keeping the order it was given in; then `projects`, the launcher's folders for a new
/// session, when given any. An agent with no sessions has no group.
public func libraryGroups(_ entries: [LibraryEntry], onStrip: [PanelSession] = [], projects: [LibraryEntry] = []) -> [LibraryGroup] {
    var order: [String] = ["claude", "codex"]
    var byAgent: [String: [LibraryEntry]] = [:]
    for entry in entries {
        let agent = entry.agent ?? "claude"
        if !order.contains(agent) { order.append(agent) }
        byAgent[agent, default: []].append(entry)
    }
    let strip = onStrip.isEmpty ? [] : [LibraryGroup(agent: LibraryGroup.onStrip, badge: nil, title: "On strip", entries: onStrip.launcherOrder.map(LibraryEntry.init))]
    let new = projects.isEmpty ? [] : [LibraryGroup(agent: LibraryGroup.newSession, badge: nil, title: "New", entries: projects)]
    return strip + order.compactMap { agent in
        guard let entries = byAgent[agent], !entries.isEmpty else { return nil }
        let title = agent == "claude" ? "Claude" : agent == "codex" ? "Codex" : agent
        return LibraryGroup(agent: agent, badge: AgentBadge(agent: agent), title: title, entries: entries)
    } + new
}

/// What the + panel shows: one tab per agent, the sessions of the chosen tab that match the search, and which of
/// them is selected for Return. Pure, so the panel only draws it.
public struct LibraryBrowser: Equatable, Sendable {
    public let groups: [LibraryGroup]
    public private(set) var tab: Int
    public private(set) var query = ""
    /// Index into `visible`; nil when nothing matches.
    public private(set) var selection: Int?

    /// Opens on `preferredAgent`'s tab when it has sessions, else on the first. `onStrip`, for the launcher, adds
    /// a first tab with the strip's sessions, and `projects` a last one with folders to start a new session in.
    public init(entries: [LibraryEntry], onStrip: [PanelSession] = [], projects: [LibraryEntry] = [], preferredAgent: String? = nil) {
        groups = libraryGroups(entries, onStrip: onStrip, projects: projects)
        tab = groups.firstIndex { $0.agent == preferredAgent } ?? 0
        selection = nil
        resetSelection()
    }

    public var agent: String? { groups.indices.contains(tab) ? groups[tab].agent : nil }

    /// The chosen tab's sessions that match the search, most recent first.
    public var visible: [LibraryEntry] { matches(inTab: tab) }

    public var selected: LibraryEntry? { selection.map { visible[$0] } }

    /// How many sessions of a tab match the search: its label, so a match in the other tab shows.
    public func count(inTab index: Int) -> Int { matches(inTab: index).count }

    public mutating func select(tab index: Int) {
        guard groups.indices.contains(index) else { return }
        tab = index
        resetSelection()
    }

    /// The next tab, wrapping around.
    public mutating func nextTab() {
        guard !groups.isEmpty else { return }
        select(tab: (tab + 1) % groups.count)
    }

    public mutating func search(_ text: String) {
        query = text
        resetSelection()
    }

    /// Moves the selection by `delta` rows, stopping at either end.
    public mutating func move(by delta: Int) {
        let count = visible.count
        guard count > 0 else { return selection = nil }
        selection = min(max((selection ?? 0) + delta, 0), count - 1)
    }

    public mutating func select(row: Int) {
        if visible.indices.contains(row) { selection = row }
    }

    private func matches(inTab index: Int) -> [LibraryEntry] {
        guard groups.indices.contains(index) else { return [] }
        return groups[index].entries.filter { $0.matches(query) }
    }

    private mutating func resetSelection() {
        selection = visible.isEmpty ? nil : 0
    }
}
