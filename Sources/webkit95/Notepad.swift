import AppKit
import Webkit95Kit

/// View > Source: a Notepad style window, "<title> - Notepad", with the page HTML in a fixed
/// pitch font and Win95 scrollbars.
@MainActor
final class NotepadWindowController: NSObject, NSWindowDelegate {
    let window = Win95Window(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480))
    private let frameView = WindowFrameView()
    private let menuBar = MenuBarView()
    private let scroll = Win95ScrollView()
    let textView = PixelTextView()
    var onClose: (() -> Void)?

    init(title: String, text: String) {
        super.init()
        window.delegate = self
        window.contentView = frameView
        let full = "\(title) - Notepad"
        window.title = full
        frameView.titleBar.title = full
        frameView.titleBar.icon = .document
        frameView.titleBar.isActive = false
        window.onStateChange = { [weak self] in self?.frameView.titleBar.syncMaximizeGlyph() }
        menuBar.menus = Self.menus
        menuBar.onOpen = { [weak self] i in
            guard let self else { return }
            self.frameView.menuLayer.openBarMenu(i, bar: self.menuBar, menus: Self.menus)
        }
        frameView.menuLayer.onCommand = { [weak self] in self?.perform($0) }
        frameView.content.addSubview(menuBar)
        frameView.content.addSubview(scroll)
        PixelTextView.configure(textView)
        textView.font = Fonts.mono
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = Win95Color.white.ns
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.setAccessibilityIdentifier("notepad-text")
        scroll.showsHorizontal = true
        scroll.documentView = textView
        frameView.content.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: frameView.content, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        layout()
    }

    static let menus: [Menu] = [
        Menu(label: MenuLabel("&File"), entries: [.item(MenuItem(command: .close, label: MenuLabel("E&xit"), shortcut: .cmd("w"), isEnabled: true, check: .none))]),
        Menu(label: MenuLabel("&Edit"), entries: [
            .item(MenuItem(command: .copy, label: MenuLabel("&Copy"), shortcut: .cmd("c"), isEnabled: true, check: .none)),
            .item(MenuItem(command: .selectAll, label: MenuLabel("Select &All"), shortcut: .cmd("a"), isEnabled: true, check: .none)),
        ]),
        Menu(label: MenuLabel("&Search"), entries: []),
        Menu(label: MenuLabel("&Help"), entries: [.item(MenuItem(command: .about, label: MenuLabel("&About Notepad"), shortcut: nil, isEnabled: true, check: .none))]),
    ]

    private func layout() {
        let b = frameView.content.bounds
        menuBar.frame = NSRect(x: 0, y: 0, width: b.width, height: MenuBarView.height)
        scroll.frame = NSRect(x: 0, y: MenuBarView.height, width: b.width, height: b.height - MenuBarView.height)
        textView.minSize = NSSize(width: scroll.scrollView.contentSize.width, height: scroll.scrollView.contentSize.height)
    }

    func perform(_ command: Command) {
        switch command {
        case .close: window.win95Close()
        case .copy: textView.copy(nil)
        case .selectAll:
            window.makeFirstResponder(textView)
            textView.selectAll(nil)
        case .about:
            frameView.dialogLayer.present(DialogView.messageBox(kind: "about", title: "About Notepad", icon: .info,
                message: "webkit95 Notepad shows page source. Part of webkit95, an homage not affiliated with Microsoft.",
                buttons: [("ok", "OK")], defaultButton: "ok", cancelButton: nil) { _ in })
        default: break
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { frameView.titleBar.isActive = true }
    func windowDidResignKey(_ notification: Notification) { frameView.titleBar.isActive = false }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
