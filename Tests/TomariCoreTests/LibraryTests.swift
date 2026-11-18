import Foundation
import TomariCore

private func entry(_ name: String, cwd: String = "/Users/dev/tomari", agent: String? = nil) -> LibraryEntry {
    LibraryEntry(id: UUID().uuidString, name: name, cwd: cwd, lastActivityAt: now, pinned: false, agent: agent)
}

func libraryTests() {
    test("the library groups Claude first, then Codex, then others, each in its own order") {
        let a = entry("a"), b = entry("b", agent: "codex"), c = entry("c", agent: "claude"), d = entry("d", agent: "gemini")
        let groups = libraryGroups([b, a, d, c])
        expectEqual(groups.map(\.title), ["Claude", "Codex", "gemini"])
        expectEqual(groups.map(\.badge), [.claude, .codex, .other])
        expectEqual(groups[0].entries, [a, c])
        expectEqual(libraryGroups([b]).map(\.title), ["Codex"])
        expectEqual(libraryGroups([]).count, 0)
    }

    test("search matches every word in the name or folder, ignoring case and accents") {
        let e = entry("Diseñar carcasa STL", cwd: "/Users/dev/shy-planner")
        expect(e.matches(""), "empty")
        expect(e.matches("  "), "blank")
        expect(e.matches("disenar"), "accent")
        expect(e.matches("CARCASA stl"), "case, two words")
        expect(e.matches("shy carcasa"), "folder and name")
        expect(!e.matches("carcasa tomari"), "one word missing")
        expect(!e.matches("users"), "only the folder's last part counts")
        expectEqual(e.folder, "shy-planner")
    }

    test("decodes a library entry's agent, and one without is Claude Code's") {
        let json = #"{"type":"library","sessions":[{"id":"x","name":"n","cwd":"/c","lastActivityAt":0,"pinned":false,"agent":"codex"},{"id":"y","name":"m","cwd":"/c","lastActivityAt":0,"pinned":true}]}"#
        guard case .library(let entries)? = ServerMessage.parse(json) else { return expect(false, "not a library message") }
        expectEqual(entries.map(\.agent), ["codex", nil])
    }

    test("the menu cuts a long name or folder, so one entry can't widen the whole menu") {
        let long = entry("Mejorar el uso con sesiones de terminal sin la app de escritorio", cwd: "/Users/dev/scratch-2026-11-10-561164-extra")
        expectEqual(long.menuName.count, 34)
        expect(long.menuName.hasSuffix("…"), "name ellipsis")
        expectEqual(long.menuFolder.count, 16)
        expectEqual(entry("Short", cwd: "/x/tomari").menuName, "Short")
        expectEqual(entry("Short", cwd: "/x/tomari").menuFolder, "tomari")
        expectEqual(entry("two\n  lines").menuName, "two lines")
    }

    test("the browser opens on the preferred agent's tab, else the first, with the first session selected") {
        let a = entry("api"), b = entry("billing", agent: "codex")
        let browser = LibraryBrowser(entries: [a, b], preferredAgent: "codex")
        expectEqual(browser.agent, "codex")
        expectEqual(browser.selected, b)
        expectEqual(LibraryBrowser(entries: [a, b], preferredAgent: "gemini").agent, "claude")
        expectEqual(LibraryBrowser(entries: [b]).agent, "codex")
        let empty = LibraryBrowser(entries: [])
        expectEqual(empty.agent, nil)
        expectEqual(empty.selected, nil)
    }

    test("the browser filters the tab, counts matches in every tab, and keeps the selection in range") {
        let rows = [entry("alpha one"), entry("alpha two"), entry("beta")]
        var browser = LibraryBrowser(entries: rows + [entry("alpha codex", agent: "codex")])
        browser.search("alpha")
        expectEqual(browser.visible.map(\.name), ["alpha one", "alpha two"])
        expectEqual([browser.count(inTab: 0), browser.count(inTab: 1)], [2, 1])
        browser.move(by: 5)
        expectEqual(browser.selected?.name, "alpha two")
        browser.move(by: -9)
        expectEqual(browser.selected?.name, "alpha one")
        browser.select(row: 1)
        expectEqual(browser.selected?.name, "alpha two")
        browser.select(row: 7)
        expectEqual(browser.selected?.name, "alpha two")
        browser.search("zzz")
        expectEqual(browser.selected, nil)
        browser.move(by: 1)
        expectEqual(browser.selected, nil)
        browser.search("")
        browser.nextTab()
        expectEqual(browser.agent, "codex")
        expectEqual(browser.selected?.name, "alpha codex")
        browser.nextTab()
        expectEqual(browser.agent, "claude")
    }
}

func launcherTests() {
    test("the launcher lists the strip first: waiting sessions by longest wait, then the rest by latest change") {
        let done = session(name: "done", state: .done, stateSince: now.addingTimeInterval(-60))
        let working = session(name: "working", state: .working, stateSince: now.addingTimeInterval(-10))
        let asked = session(name: "asked", state: .needsInput, stateSince: now.addingTimeInterval(-30))
        let permission = session(name: "permission", state: .needsPermission, stateSince: now.addingTimeInterval(-300), agent: "codex")
        expectEqual([done, working, asked, permission].launcherOrder.map(\.name), ["permission", "asked", "working", "done"])

        let groups = libraryGroups([entry("a"), entry("b", agent: "codex")], onStrip: [done, permission])
        expectEqual(groups.map(\.title), ["On strip", "Claude", "Codex"])
        expectEqual(groups[0].agent, LibraryGroup.onStrip)
        expect(groups[0].badge == nil, "the strip's tab has no single agent")
        expectEqual(groups[0].entries.map(\.name), ["permission", "done"])
        expectEqual(groups[0].entries[0].agent, "codex")
        expectEqual(groups[0].entries[0].lastActivityAt, permission.stateSince)
        expectEqual(libraryGroups([entry("a")]).map(\.title), ["Claude"])
    }

    test("the launcher opens on the strip's tab, and the + without it") {
        let strip = [session(name: "s", state: .working)]
        let launcher = LibraryBrowser(entries: [entry("a")], onStrip: strip, preferredAgent: LibraryGroup.onStrip)
        expectEqual(launcher.agent, LibraryGroup.onStrip)
        expectEqual(launcher.selected?.name, "s")
        let plus = LibraryBrowser(entries: [entry("a")], preferredAgent: LibraryGroup.onStrip)
        expectEqual(plus.agent, "claude")
        let empty = LibraryBrowser(entries: [entry("a")], onStrip: [], preferredAgent: LibraryGroup.onStrip)
        expectEqual(empty.agent, "claude")
    }
}

func launcherShortcutTests() {
    let option = LauncherShortcut.option, command = LauncherShortcut.command, control = LauncherShortcut.control, shift = LauncherShortcut.shift

    test("the launcher's shortcut defaults to ⌥Space, and a stored one or off is kept") {
        expectEqual(LauncherShortcut.stored(nil), .standard)
        expectEqual(LauncherShortcut.standard.title, "⌥Space")
        expectEqual(LauncherShortcut.stored("off"), nil)
        let recorded = LauncherShortcut(keyCode: 40, modifiers: control | option, key: "k")
        expectEqual(LauncherShortcut.stored(recorded.stored), recorded)
        expectEqual(LauncherShortcut.stored("optionSpace"), .standard) // unreadable, e.g. older
        expectEqual(LauncherShortcut.stored(LauncherShortcut(keyCode: 0, modifiers: 0, key: "a").stored), .standard) // invalid
    }

    test("the title lists modifiers in menu order, then the key") {
        expectEqual(LauncherShortcut(keyCode: 17, modifiers: command | option | control | shift, key: "t").title, "⌃⌥⇧⌘T")
        expectEqual(LauncherShortcut(keyCode: 126, modifiers: control, key: "").title, "⌃↑")
        expectEqual(LauncherShortcut(keyCode: 96, modifiers: 0, key: "").title, "F5")
        expectEqual(LauncherShortcut(keyCode: 31, modifiers: command | 0x80, key: "o").modifiers, command) // other bits dropped
    }

    test("a shortcut needs ⌘, ⌃ or ⌥, and ⌥ alone only with a key that types nothing") {
        expect(LauncherShortcut(keyCode: 17, modifiers: control | option, key: "t").problem == nil, "⌃⌥T")
        expect(LauncherShortcut(keyCode: 49, modifiers: option, key: " ").problem == nil, "⌥Space")
        expect(LauncherShortcut(keyCode: 122, modifiers: 0, key: "").problem == nil, "F1 alone")
        expect(LauncherShortcut(keyCode: 0, modifiers: 0, key: "a").problem != nil, "a")
        expect(LauncherShortcut(keyCode: 0, modifiers: shift, key: "a").problem != nil, "⇧A")
        expect(LauncherShortcut(keyCode: 19, modifiers: option, key: "2").problem?.contains("types a character") == true, "⌥2 is @ in Spanish")
        expect(LauncherShortcut(keyCode: 53, modifiers: command, key: "").problem != nil, "⌘Esc")
    }
}
