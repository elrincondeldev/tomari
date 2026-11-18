import Foundation
import TomariCore

private func waiting(_ prompt: PermissionPrompt?, state: SessionState = .needsPermission, since: Date = now) -> PanelSession {
    var s = session(name: "api", state: state, activity: "Bash: npm test", stateSince: since)
    s.permission = prompt
    return s
}

func noticeTests() {
    let bash = PermissionPrompt(id: "r1", tool: "Bash", detail: "npm test")
    let color = PromptQuestion(question: "Which color?", header: "Color", options: [.init(label: "Red"), .init(label: "Blue")])

    test("a permission notice says what it asks and offers Allow, Always Allow when Claude suggests a rule, and Deny") {
        let plain = Notice(session: waiting(bash), answers: true)
        expectEqual(plain.title, "Allow Bash?")
        expectEqual(plain.subtitle, "api · Claude")
        expectEqual(plain.body, "npm test")
        expectEqual(plain.requestId, "r1")
        expectEqual(plain.buttons.map(\.action), [.allow, .deny])
        var always = bash
        always.always = "Bash(npm test:*) in this project"
        expectEqual(Notice(session: waiting(always), answers: true).buttons.map(\.action), [.allow, .always, .deny])
        expectEqual(PermissionPrompt(id: "r", tool: "mcp__github__create_issue", detail: "").heading, "Allow github: create_issue?")
    }

    test("a question's options are its buttons, unless it takes several answers or has too many options") {
        let one = Notice(session: waiting(PermissionPrompt(id: "q", tool: "AskUserQuestion", detail: "", questions: [color]), state: .needsInput), answers: true)
        expectEqual(one.title, "Claude asks")
        expectEqual(one.body, "Which color?")
        expectEqual(one.buttons.map(\.title), ["Red", "Blue"])
        expectEqual(one.buttons.map(\.action), [.option(0), .option(1)])
        var multi = color
        multi.multiSelect = true
        let several = Notice(session: waiting(PermissionPrompt(id: "q", tool: "AskUserQuestion", detail: "", questions: [color, multi])), answers: true)
        expectEqual(several.title, "Claude asks 2 questions")
        expectEqual(several.buttons, [])
        let many = PromptQuestion(question: "Which?", header: "", options: (1...5).map { .init(label: "\($0)") })
        expectEqual(Notice(session: waiting(PermissionPrompt(id: "q", tool: "AskUserQuestion", detail: "", questions: [many])), answers: true).buttons, [])
    }

    test("without a prompt to answer, or with answering off, the notice only says the session waits") {
        let codex = Notice(session: waiting(nil), answers: true)
        expectEqual(codex.title, "api · Claude")
        expectEqual(codex.body, "Bash: npm test")
        expectEqual(codex.buttons, [])
        expectEqual(codex.requestId, nil)
        expectEqual(Notice(session: waiting(bash), answers: false).buttons, [])
        expectEqual(Notice(session: waiting(PermissionPrompt(id: "q", tool: "AskUserQuestion", detail: "", questions: [])), answers: true).buttons, [])
    }

    test("buttons map to their identifiers and the answers they send") {
        for action in [NoticeAction.allow, .always, .deny, .option(3)] {
            expectEqual(NoticeAction(identifier: action.identifier), action)
        }
        expectEqual(NoticeAction(identifier: "option.x"), nil)
        expectEqual(NoticeAction(identifier: "com.apple.UNNotificationDefaultActionIdentifier"), nil)
        expectEqual(NoticeAction.always.message(session: "s", request: "r"), .permission(id: "s", request: "r", allow: true, always: true))
        expectEqual(NoticeAction.option(1).message(session: "s", request: "r"), .permission(id: "s", request: "r", allow: true, answers: [[1]]))
        expectEqual(NoticeAction.deny.message(session: "s", request: "r"), .permission(id: "s", request: "r", allow: false))
    }

    test("a session notifies when it starts waiting and for each new prompt, and its notice goes once it moves on") {
        var tracker = NoticeTracker()
        func update(_ sessions: [PanelSession], initial: Bool = false, focused: String? = nil, front: FrontAppKind = .other) -> ([String], [String]) {
            let result = tracker.update(sessions, initial: initial, focusedId: focused, frontApp: front, answers: true)
            return (result.post.map { $0.requestId ?? $0.sessionId }, result.withdraw)
        }
        let working = session(name: "w", state: .working)
        var asking = waiting(nil)
        asking.id = working.id
        var prompted = asking
        prompted.permission = bash
        var next = prompted
        next.permission = PermissionPrompt(id: "r2", tool: "Bash", detail: "git push")

        expectEqual(update([working]).0, [])
        expectEqual(update([asking]).0, [working.id]) // waiting, no prompt yet
        expectEqual(update([prompted]).0, ["r1"]) // the prompt replaces it
        expectEqual(update([prompted]).0, []) // nothing new
        let second = update([next])
        expectEqual(second.0, ["r2"])
        expectEqual(second.1, [])
        expectEqual(update([working]).1, [working.id])
        expectEqual(update([working]).1, [])
    }

    test("no notice for sessions already waiting at connect, or for the one the user is looking at") {
        var tracker = NoticeTracker()
        let asking = waiting(bash)
        expectEqual(tracker.update([asking], initial: true, focusedId: nil, frontApp: .other, answers: true).post, [])
        expectEqual(tracker.update([asking], initial: false, focusedId: nil, frontApp: .other, answers: true).post, [])

        var other = NoticeTracker()
        let fresh = waiting(bash)
        expectEqual(other.update([fresh], initial: false, focusedId: fresh.id, frontApp: .desktop, answers: true).post, [])
        var elsewhere = NoticeTracker()
        expectEqual(elsewhere.update([fresh], initial: false, focusedId: fresh.id, frontApp: .other, answers: true).post.count, 1)
        var closed = waiting(bash)
        closed.live = false
        var gone = NoticeTracker()
        expectEqual(gone.update([closed], initial: false, focusedId: nil, frontApp: .other, answers: true).post, [])
    }
}
