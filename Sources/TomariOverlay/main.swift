import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var link: AgentLink?
    private var strip: StripController?
    private var menuBar: MenuBar?
    private let hotKey = LauncherHotKey()
    private let notifier = Notifier()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let link = AgentLink()
        let strip = StripController(link: link)
        LauncherHotKey.onPress = { [weak strip] in strip?.toggleLauncher() }
        hotKey.apply()
        notifier.send = { [weak link] message in link?.send(message) }
        notifier.onClick = { [weak strip] id in strip?.answerOrOpen(id) }
        link.notifier = notifier
        notifier.authorize()
        menuBar = MenuBar(link: link, strip: strip, hotKey: hotKey, notifier: notifier)
        self.link = link
        self.strip = strip
        link.start()
    }
}

guard SingleInstance.claim() else {
    FileHandle.standardError.write(Data("tomari-overlay is already running\n".utf8))
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // No Dock icon or menu: releases run it from Tomari.app, an agent app (LSUIElement), and `swift run` bare.
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
