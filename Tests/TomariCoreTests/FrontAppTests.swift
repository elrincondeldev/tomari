import Foundation
import TomariCore

func frontAppTests() {
    test("Terminal, the Claude desktop app and everything else map to their kinds") {
        expectEqual(FrontAppKind(bundleId: "com.apple.Terminal"), .terminal)
        expectEqual(FrontAppKind(bundleId: "com.anthropic.claudefordesktop"), .desktop)
        expectEqual(FrontAppKind(bundleId: "com.openai.codex"), .codex)
        expectEqual(FrontAppKind(bundleId: "com.apple.Safari"), .other)
        expectEqual(FrontAppKind(bundleId: "com.apple.Terminal.helper"), .other)
        expectEqual(FrontAppKind(bundleId: nil), .other)
    }

    test("Terminal and the Claude desktop app show sessions, other apps do not") {
        expect(FrontAppKind.terminal.showsSessions, "terminal")
        expect(FrontAppKind.desktop.showsSessions, "desktop")
        expect(!FrontAppKind.other.showsSessions, "other")
        expect(!FrontAppKind.codex.showsSessions, "the Codex app does not say which thread it shows")
    }

    test("the agent is told the Codex app is another app, and every other kind as itself") {
        expectEqual(FrontAppKind.codex.reportedToAgent, .other)
        expectEqual(FrontAppKind.terminal.reportedToAgent, .terminal)
        expectEqual(FrontAppKind.desktop.reportedToAgent, .desktop)
        expectEqual(FrontAppKind.other.reportedToAgent, .other)
    }

    test("Terminal and the desktop app mean the focused session is seen; the Codex app means the Codex sessions it started") {
        let focused = session(agent: nil)
        let inApp = session(agent: "codex", startedInCodexApp: true)
        let cli = session(agent: "codex")
        expect(FrontAppKind.terminal.isLookingAt(focused, focusedId: focused.id), "focused in Terminal")
        expect(FrontAppKind.desktop.isLookingAt(focused, focusedId: focused.id), "focused in the desktop app")
        expect(!FrontAppKind.terminal.isLookingAt(focused, focusedId: nil), "not focused")
        expect(!FrontAppKind.other.isLookingAt(focused, focusedId: focused.id), "another app in front")
        expect(FrontAppKind.codex.isLookingAt(inApp, focusedId: nil), "started in the Codex app")
        expect(!FrontAppKind.codex.isLookingAt(cli, focusedId: cli.id), "started in the CLI, even if focused")
        expect(!FrontAppKind.codex.isLookingAt(focused, focusedId: focused.id), "a Claude session, even if focused")
        expect(!FrontAppKind.terminal.isLookingAt(inApp, focusedId: nil), "a thread of the Codex app while Terminal is in front")
    }

    test("the reporter sends the first kind and then only changes") {
        var reporter = FrontAppReporter()
        expectEqual(reporter.next(.other), .other)
        expectEqual(reporter.next(.other), nil)
        expectEqual(reporter.next(.terminal), .terminal)
        expectEqual(reporter.next(.terminal), nil)
        expectEqual(reporter.next(.other), .other)
    }

    test("after a reconnect the reporter sends the current kind again") {
        var reporter = FrontAppReporter()
        _ = reporter.next(.terminal)
        reporter.reset()
        expectEqual(reporter.next(.terminal), .terminal)
    }

    test("frontApp encodes its kind and names no session") {
        expectEqual(ClientMessage.frontApp(.terminal).json, #"{"app":"terminal","type":"frontApp"}"#)
        expectEqual(ClientMessage.frontApp(.desktop).json, #"{"app":"desktop","type":"frontApp"}"#)
        expectEqual(ClientMessage.frontApp(.other).json, #"{"app":"other","type":"frontApp"}"#)
        expectEqual(ClientMessage.frontApp(.other).sessionId, nil)
    }
}
