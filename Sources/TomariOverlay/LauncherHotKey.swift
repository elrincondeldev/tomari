import Carbon.HIToolbox
import TomariCore

/// The launcher's global shortcut, through Carbon's hot key API: it needs no Accessibility permission, and the
/// key press goes to Tomari alone, never to the app in front.
@MainActor
final class LauncherHotKey {
    private static let preferenceKey = "launcherShortcut"
    /// 'TMRI'
    private static let signature: OSType = 0x544D_5249

    /// What the shortcut does; set once, before `apply()`.
    static var onPress: (() -> Void)?

    private var registered: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// The shortcut in the preferences failed to register: another app holds it.
    private(set) var unavailable = false

    /// The shortcut the user chose, or nil when it is off.
    var shortcut: LauncherShortcut? {
        LauncherShortcut.stored(Preferences.store.string(forKey: Self.preferenceKey))
    }

    /// Registers the chosen shortcut, replacing the one registered before; also retries one another app held.
    func apply() {
        suspend()
        unavailable = false
        guard let shortcut else { return }
        if !register(shortcut) {
            unavailable = true
            print("launcher shortcut \(shortcut.title) is in use by another app")
        }
    }

    /// Lets go of the shortcut, so a recorder can take its keys.
    func suspend() {
        if let registered { UnregisterEventHotKey(registered) }
        registered = nil
    }

    /// Makes `shortcut` the launcher's when it registers, or turns the shortcut off with nil. False, keeping
    /// nothing registered, when another app holds it.
    @discardableResult
    func set(_ shortcut: LauncherShortcut?) -> Bool {
        suspend()
        if let shortcut, !register(shortcut) { return false }
        Preferences.store.set(shortcut?.stored ?? LauncherShortcut.off, forKey: Self.preferenceKey)
        unavailable = false
        return true
    }

    private func register(_ shortcut: LauncherShortcut) -> Bool {
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        registered = ref
        return true
    }

    private func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            // Carbon calls this on the main thread.
            MainActor.assumeIsolated { LauncherHotKey.onPress?() }
            return noErr
        }, 1, &pressed, nil, &handler)
    }
}
