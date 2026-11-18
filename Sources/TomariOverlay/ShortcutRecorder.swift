import AppKit
import TomariCore

/// A small panel that records the launcher's shortcut: press any key with ⌘, ⌃ or ⌥ (or an F-key alone) and it
/// becomes the shortcut, unless another app holds it. The current shortcut is let go while it records, so it can be
/// pressed again; Esc, Cancel or a click elsewhere keep the old one.
@MainActor
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    private static var current: ShortcutRecorder?
    private static let size = NSSize(width: 340, height: 160)

    private let window: KeyPanel
    private let hotKey: LauncherHotKey
    private let combo = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    private var saved = false

    static func show(for hotKey: LauncherHotKey) {
        current?.close()
        let recorder = ShortcutRecorder(hotKey: hotKey)
        current = recorder
        recorder.present()
    }

    private init(hotKey: LauncherHotKey) {
        self.hotKey = hotKey
        window = KeyPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.delegate = self
        window.onCancel = { [weak self] in self?.close() }

        let backdrop = RecorderView(frame: NSRect(origin: .zero, size: Self.size))
        backdrop.material = .popover
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 10
        backdrop.layer?.masksToBounds = true
        backdrop.onKey = { [weak self] event in self?.record(event) }
        backdrop.onFlags = { [weak self] flags in self?.showHeld(flags) }
        window.contentView = backdrop

        let title = NSTextField(labelWithString: "Press the new launcher shortcut")
        title.font = .boldSystemFont(ofSize: 13)
        combo.font = .systemFont(ofSize: 24, weight: .medium)
        combo.alignment = .center
        combo.stringValue = hotKey.shortcut?.title ?? "Off"
        combo.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 11)
        message.alignment = .center
        message.lineBreakMode = .byTruncatingTail
        showHint()

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelled))
        let standard = NSButton(title: "Use \(LauncherShortcut.standard.title)", target: self, action: #selector(useStandard))
        for button in [cancel, standard] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.refusesFirstResponder = true
        }

        for view in [title, combo, message, cancel, standard] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            backdrop.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 12),
            title.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            combo.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            combo.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            message.topAnchor.constraint(equalTo: combo.bottomAnchor, constant: 8),
            message.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 12),
            message.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -12),
            cancel.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -12),
            cancel.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -12),
            standard.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 12),
            standard.centerYAnchor.constraint(equalTo: cancel.centerYAnchor),
        ])
    }

    private func present() {
        hotKey.suspend() // so pressing the current shortcut reaches the recorder
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.maxY - visible.height * 0.3 - Self.size.height))
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
    }

    private func close() {
        window.delegate = nil
        window.orderOut(nil)
        if !saved { hotKey.apply() } // the old shortcut again
        if Self.current === self { Self.current = nil }
    }

    // MARK: Recording

    private func record(_ event: NSEvent) {
        let modifiers = Self.carbonModifiers(event.modifierFlags)
        if event.keyCode == 53 && modifiers == 0 { return close() } // Esc
        let shortcut = LauncherShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: event.charactersIgnoringModifiers ?? "")
        combo.stringValue = shortcut.title
        if let problem = shortcut.problem {
            combo.textColor = .secondaryLabelColor
            return showError(problem)
        }
        guard hotKey.set(shortcut) else {
            combo.textColor = .secondaryLabelColor
            return showError("Another app uses \(shortcut.title): try another")
        }
        saved = true
        combo.textColor = .labelColor
        message.textColor = .secondaryLabelColor
        message.stringValue = "Saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// The modifiers held so far, before a key completes the shortcut.
    private func showHeld(_ flags: NSEvent.ModifierFlags) {
        guard !saved else { return }
        let held = LauncherShortcut.symbols(Self.carbonModifiers(flags))
        guard !held.isEmpty else { return }
        combo.textColor = .secondaryLabelColor
        combo.stringValue = held + "…"
        showHint()
    }

    private func showHint() {
        message.textColor = .secondaryLabelColor
        message.stringValue = "⌘, ⌃ or ⌥ with a key, or an F-key · Esc cancels"
    }

    private func showError(_ text: String) {
        message.textColor = .systemRed
        message.stringValue = text
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= LauncherShortcut.command }
        if flags.contains(.shift) { modifiers |= LauncherShortcut.shift }
        if flags.contains(.option) { modifiers |= LauncherShortcut.option }
        if flags.contains(.control) { modifiers |= LauncherShortcut.control }
        return modifiers
    }

    @objc private func cancelled() {
        close()
    }

    @objc private func useStandard() {
        guard hotKey.set(.standard) else { return showError("Another app uses \(LauncherShortcut.standard.title)") }
        saved = true
        close()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// Takes every key press, ⌘ combinations included, before the window can act on it.
private final class RecorderView: NSVisualEffectView {
    var onKey: ((NSEvent) -> Void)?
    var onFlags: ((NSEvent.ModifierFlags) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKey?(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        onKey?(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        onFlags?(event.modifierFlags)
    }
}
