import AppKit
import WebKit
import Webkit95Kit

/// App wide state: the windows, favorites, typed address history and the start page counter.
@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = App()

    let supportDir = SupportDirectory.resolve()
    private(set) var windows: [BrowserWindowController] = []
    private(set) var notepads: [NotepadWindowController] = []
    private(set) var favorites = Favorites()
    private(set) var history = AddressHistory()
    private var hits = 0
    private var favoritesFile: JSONFile<Favorites> { JSONFile(supportDir.appendingPathComponent("favorites.json")) }
    private var historyFile: JSONFile<AddressHistory> { JSONFile(supportDir.appendingPathComponent("typed-addresses.json")) }
    private var hitsFile: JSONFile<Int> { JSONFile(supportDir.appendingPathComponent("hits.json")) }
    let downloads = Downloads()
    private(set) lazy var declutter = DeclutterService(supportDir: supportDir)

    /// ~/Downloads, or WEBKIT95_DOWNLOAD_DIR in debug builds so tests never touch the real one.
    var downloadDirectory: URL {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["WEBKIT95_DOWNLOAD_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.register()
        favorites = favoritesFile.load() ?? Favorites()
        history = historyFile.load() ?? AddressHistory()
        hits = hitsFile.load() ?? 0
        WebConfig.home.page = { [weak self] in
            guard let self else { return "" }
            self.hits += 1
            try? self.hitsFile.save(self.hits)
            return Pages.home(favorites: self.favorites.items, hits: self.hits)
        }
        WebConfig.bridge.route = { [weak self] webView, body in
            self?.controller(for: webView)?.handleScript(body)
        }
        rebuildMainMenu()
        installKeyMonitor()
        ControlServer.startIfEnabled()
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let start = args.first.map(URLInput.resolve) ?? Pages.homeURL
        let first = openWindow(url: start)
        // Scripts launch in the background; a normal launch comes to the front.
        if ProcessInfo.processInfo.environment["WEBKIT95_BACKGROUND"] == "1" {
            first.window.orderFront(nil)
        } else {
            first.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        for w in windows { w.shutdownAgent() }
        downloads.cancelAll()
    }

    // MARK: windows

    @discardableResult
    func openWindow(url: URL?, configuration: WKWebViewConfiguration? = nil, features: WKWindowFeatures? = nil, near: NSWindow? = nil) -> BrowserWindowController {
        let c = BrowserWindowController(configuration: configuration ?? WebConfig.make(), features: features)
        windows.append(c)
        if let near {
            c.window.setFrameTopLeftPoint(NSPoint(x: near.frame.minX + 24, y: near.frame.maxY - 24))
        } else if let last = windows.dropLast().last {
            c.window.setFrameTopLeftPoint(NSPoint(x: last.window.frame.minX + 24, y: last.window.frame.maxY - 24))
        } else {
            c.window.center()
        }
        if let url { c.load(url) }
        return c
    }

    func windowClosed(_ c: BrowserWindowController) {
        windows.removeAll { $0 === c }
    }

    func openNotepad(title: String, text: String, near: NSWindow?) -> NotepadWindowController {
        let n = NotepadWindowController(title: title, text: text)
        notepads.append(n)
        if let near { n.window.setFrameTopLeftPoint(NSPoint(x: near.frame.minX + 40, y: near.frame.maxY - 40)) }
        n.onClose = { [weak self, weak n] in self?.notepads.removeAll { $0 === n } }
        return n
    }

    func controller(for webView: WKWebView) -> BrowserWindowController? {
        windows.first { $0.webView === webView }
    }

    var keyController: BrowserWindowController? {
        windows.first { $0.window.isKeyWindow } ?? windows.first { $0.window.isMainWindow } ?? windows.last
    }

    // MARK: stores

    func addFavorite(title: String, url: String) {
        favorites.add(title: title, url: url)
        saveFavorites()
    }

    func removeFavorite(url: String) {
        favorites.remove(url: url)
        saveFavorites()
    }

    private func saveFavorites() {
        do { try favoritesFile.save(favorites) } catch { log("favorites: \(error)") }
        windows.forEach { $0.menusChanged() }
        rebuildMainMenu()
    }

    func recordTyped(_ address: String) {
        history.record(address)
        do { try historyFile.save(history) } catch { log("history: \(error)") }
    }

    // MARK: macOS menu bar, built from the same MenuModel table as the in window menus

    func rebuildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "webkit95")
        appMenu.addItem(withTitle: "About webkit95", action: #selector(macAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide webkit95", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit webkit95", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let ctx = MenuContext(state: keyController?.state ?? BrowserWindowState(), favorites: favorites.items)
        for menu in MenuModel.menus(ctx) {
            let item = NSMenuItem()
            let sub = NSMenu(title: menu.label.text)
            sub.autoenablesItems = false
            sub.delegate = self
            fill(sub, menu.entries)
            item.submenu = sub
            main.addItem(item)
        }
        // Alternate keys that have no row of their own.
        if let view = main.items.first(where: { $0.submenu?.title == "View" })?.submenu {
            for (shortcut, command) in MenuModel.shortcutsWithoutRows(ctx) {
                guard let item = macItem(title: command.id, command: command, shortcut: shortcut, enabled: true) else { continue }
                item.isHidden = true
                item.allowsKeyEquivalentWhenHidden = true
                view.addItem(item)
            }
        }
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    private func fill(_ menu: NSMenu, _ entries: [MenuEntry]) {
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case let .item(item):
                if let mi = macItem(title: item.label.text, command: item.command, shortcut: item.shortcut, enabled: item.isEnabled) {
                    mi.isEnabled = item.isEnabled || !showingEnabledState
                    mi.state = item.check == .none ? .off : .on
                    menu.addItem(mi)
                }
            case let .submenu(sub):
                let mi = NSMenuItem(title: sub.label.text, action: nil, keyEquivalent: "")
                let m = NSMenu(title: sub.label.text)
                m.autoenablesItems = false
                fill(m, sub.entries)
                mi.submenu = m
                mi.isEnabled = entry.isEnabled
                menu.addItem(mi)
            }
        }
    }

    private func macItem(title: String, command: Command, shortcut: Shortcut?, enabled: Bool) -> NSMenuItem? {
        let item = NSMenuItem(title: title, action: #selector(macCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command.id
        item.isEnabled = true
        // Escape and F5 stay with the window's key handling, so pages and dialogs still get them.
        if let shortcut, shortcut.modifiers.contains(.command), case let .character(c) = shortcut.key {
            item.keyEquivalent = String(c)
            var mask: NSEvent.ModifierFlags = [.command]
            if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
            if shortcut.modifiers.contains(.option) { mask.insert(.option) }
            item.keyEquivalentModifierMask = mask
        }
        return item
    }

    private var showingEnabledState = false

    func menuNeedsUpdate(_ menu: NSMenu) {
        showingEnabledState = true
        defer { showingEnabledState = false }
        let ctx = MenuContext(state: keyController?.state ?? BrowserWindowState(), favorites: favorites.items, modal: keyController?.isModal ?? false)
        guard let model = MenuModel.menus(ctx).first(where: { $0.label.text == menu.title }) else { return }
        let hidden = menu.items.filter(\.isHidden)
        menu.removeAllItems()
        fill(menu, model.entries)
        hidden.forEach(menu.addItem)
    }

    // Rows keep their key equivalents live between openings; the window checks enabled state
    // itself when a command arrives.
    func menuDidClose(_ menu: NSMenu) {
        func enable(_ m: NSMenu) {
            for item in m.items {
                item.isEnabled = true
                if let sub = item.submenu { enable(sub) }
            }
        }
        enable(menu)
    }

    @objc private func macCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let command = Command(id: id) else { return }
        if command != .newWindow, let notepad = notepads.first(where: { $0.window.isKeyWindow }) {
            notepad.perform(command)
            return
        }
        perform(command, in: keyController)
    }

    @objc private func macAbout() { perform(.about, in: keyController) }

    func perform(_ command: Command, in controller: BrowserWindowController?) {
        switch command {
        case .newWindow:
            let c = openWindow(url: Pages.homeURL)
            c.window.makeKeyAndOrderFront(nil)
        default:
            if let controller {
                controller.perform(command)
            } else if command == .about || command == .home {
                openWindow(url: Pages.homeURL).window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: keys the macOS menu does not carry

    private var keyMonitor: Any?

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                App.shared.windows.first { $0.window === event.window }?.handleKey(event) ?? false
            }
            return handled ? nil : event
        }
    }
}
