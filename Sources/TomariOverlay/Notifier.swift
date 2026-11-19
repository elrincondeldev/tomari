import AppKit
import TomariCore
import UserNotifications

/// macOS notifications for sessions waiting on the user, with Allow, Always Allow and Deny, or a question's options,
/// as buttons when the strip can answer them. Clicking one shows the card beside its creature, or opens the
/// session. Only in the app bundle: macOS has no notifications for a bare executable, such as `swift run`.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter?
    private var tracker = NoticeTracker()
    /// Each delivered notice's category, by session id: categories are global, so the set is kept whole.
    private var categories: [String: UNNotificationCategory] = [:]
    private var pending: DispatchWorkItem?
    private var authorized: Bool?

    /// Sends a notification's answer.
    var send: (ClientMessage) -> Void = { _ in }
    /// A click on a notification itself: shows the session's card, or opens it.
    var onClick: (String) -> Void = { _ in }

    /// A prompt arrives as two messages, the state and then the prompt, so the notice waits for the second.
    private static let settle: TimeInterval = 0.4

    override init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self
    }

    var available: Bool { center != nil }

    /// Asks macOS once, when the preference is on; the system remembers the answer.
    func authorize() {
        guard let center, Preferences.notifyWhenWaiting, authorized == nil else { return }
        center.requestAuthorization(options: [.alert]) { granted, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.authorized = granted } }
        }
    }

    /// Called after each change to the sessions; `initial` for a new connection's snapshot.
    func sessionsChanged(_ list: SessionList, initial: Bool, front: FrontAppKind) {
        guard center != nil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.update(Array(list.sessions.values), initial: initial, focusedId: list.focusedId, front: front) }
        }
        pending = work
        // The snapshot is applied at once, so sessions already waiting are known before the next change.
        if initial { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work) }
    }

    private func update(_ sessions: [PanelSession], initial: Bool, focusedId: String?, front: FrontAppKind) {
        let enabled = Preferences.notifyWhenWaiting
        let (post, withdraw) = tracker.update(sessions, initial: initial || !enabled, focusedId: focusedId, frontApp: front, answers: Preferences.answerPermissions)
        if !withdraw.isEmpty { remove(withdraw) }
        guard enabled else { return }
        for notice in post { deliver(notice) }
    }

    private func deliver(_ notice: Notice) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.threadIdentifier = notice.sessionId
        content.userInfo = ["session": notice.sessionId, "request": notice.requestId ?? ""]
        if !notice.buttons.isEmpty {
            let identifier = "tomari.\(notice.sessionId).\(notice.requestId ?? "")"
            let actions = notice.buttons.map { button in
                UNNotificationAction(identifier: button.action.identifier, title: button.title, options: button.action == .deny ? [.destructive] : [])
            }
            categories[notice.sessionId] = UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [])
            center.setNotificationCategories(Set(categories.values))
            content.categoryIdentifier = identifier
        } else if categories.removeValue(forKey: notice.sessionId) != nil {
            center.setNotificationCategories(Set(categories.values))
        }
        // One per session: a new prompt replaces the last.
        center.add(UNNotificationRequest(identifier: notice.sessionId, content: content, trigger: nil))
    }

    private func remove(_ sessionIds: [String]) {
        center?.removeDeliveredNotifications(withIdentifiers: sessionIds)
        if sessionIds.contains(where: { categories.removeValue(forKey: $0) != nil }) {
            center?.setNotificationCategories(Set(categories.values))
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Tomari never counts as the app in front, but say so anyway: show it as a banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let session = info["session"] as? String else { return }
        let request = info["request"] as? String ?? ""
        let identifier = response.actionIdentifier
        await MainActor.run {
            tracker.forget(session)
            if let action = NoticeAction(identifier: identifier), !request.isEmpty {
                send(action.message(session: session, request: request))
            } else if identifier == UNNotificationDefaultActionIdentifier {
                onClick(session)
            }
        }
    }
}
