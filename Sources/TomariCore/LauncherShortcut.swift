import Foundation

/// The global shortcut that opens the launcher: any key with modifiers the user records, as Carbon's hot key API
/// names them.
public struct LauncherShortcut: Equatable, Sendable, Codable {
    /// The virtual key code, e.g. `kVK_Space` (49).
    public let keyCode: UInt32
    /// Carbon modifier masks, see `LauncherShortcut.command` and the others.
    public let modifiers: UInt32
    /// The key's character as the keyboard types it without modifiers, for the title; ignored for named keys.
    public let key: String

    public static let command: UInt32 = 0x100
    public static let shift: UInt32 = 0x200
    public static let option: UInt32 = 0x800
    public static let control: UInt32 = 0x1000

    /// What a new install uses: the usual key for a launcher.
    public static let standard = LauncherShortcut(keyCode: 49, modifiers: option, key: " ")
    /// The stored preference that turns the shortcut off.
    public static let off = "off"

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & (Self.command | Self.shift | Self.option | Self.control)
        self.key = key
    }

    /// The shortcut a stored preference names: nil when it is off, the standard one when unset or unreadable.
    public static func stored(_ value: String?) -> LauncherShortcut? {
        guard let value else { return standard }
        if value == off { return nil }
        guard let shortcut = try? JSONDecoder().decode(LauncherShortcut.self, from: Data(value.utf8)), shortcut.problem == nil else {
            return standard
        }
        return shortcut
    }

    /// The preference that stores this shortcut.
    public var stored: String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
    }

    /// Modifiers in the order macOS menus show them, then the key: "⌃⌥⌘T", "⌥Space".
    public var title: String {
        Self.symbols(modifiers) + keyName
    }

    /// Carbon modifier masks as macOS menus show them, in their order: "⌃⌥⇧⌘".
    public static func symbols(_ modifiers: UInt32) -> String {
        var text = ""
        if modifiers & control != 0 { text += "⌃" }
        if modifiers & option != 0 { text += "⌥" }
        if modifiers & shift != 0 { text += "⇧" }
        if modifiers & command != 0 { text += "⌘" }
        return text
    }

    /// Why this shortcut can't be the launcher's, or nil when it can.
    public var problem: String? {
        if Self.functionKeys[keyCode] != nil { return nil } // F-keys take no modifier at all
        if keyCode == 53 { return "Esc can't be the shortcut" }
        if modifiers & (Self.command | Self.control | Self.option) == 0 { return "Add ⌘, ⌃ or ⌥" }
        // ⌥ with a letter, number or symbol types a character, such as @ on a Spanish keyboard.
        if modifiers & (Self.command | Self.control) == 0 && Self.namedKeys[keyCode] == nil {
            return "⌥ with \(keyName) types a character: add ⌘ or ⌃"
        }
        return nil
    }

    private var keyName: String {
        if let name = Self.namedKeys[keyCode] ?? Self.functionKeys[keyCode] { return name }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.isEmpty ? "key \(keyCode)" : trimmed
    }

    /// Keys that type no character, by their `kVK_` code.
    private static let namedKeys: [UInt32: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    private static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}
