import AppKit
import WebKit
import Webkit95Kit

/// Menu bar, rebar, Explorer Bar with splitter, the sunken web view and the status bar, top to
/// bottom, sized from the window state.
final class BrowserLayoutView: FaceView {
    let menuBar = MenuBarView()
    let rebar = RebarView()
    let container = SunkenContainer()
    let splitter = SplitterView()
    let statusBar = StatusBarView()
    var explorer: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let explorer { addSubview(explorer) }
            needsLayout = true
        }
    }
    var explorerWidth: CGFloat = 260 { didSet { needsLayout = true } }
    var showsStatusBar = true { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [menuBar, rebar, container, splitter, statusBar] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        menuBar.frame = NSRect(x: 0, y: y, width: bounds.width, height: MenuBarView.height)
        y += MenuBarView.height
        let rh = rebar.preferredHeight
        rebar.isHidden = rh == 0
        rebar.frame = NSRect(x: 0, y: y, width: bounds.width, height: rh)
        y += rh
        let sh: CGFloat = showsStatusBar ? StatusBarView.height : 0
        statusBar.isHidden = !showsStatusBar
        statusBar.frame = NSRect(x: 0, y: bounds.height - sh, width: bounds.width, height: sh)
        let mainHeight = bounds.height - y - sh - (showsStatusBar ? 1 : 0)
        var x: CGFloat = 0
        if let explorer {
            let w = min(explorerWidth, max(bounds.width - 200, 120))
            explorer.frame = NSRect(x: 0, y: y, width: w, height: mainHeight)
            splitter.frame = NSRect(x: w, y: y, width: 4, height: mainHeight)
            splitter.isHidden = false
            x = w + 4
        } else {
            splitter.isHidden = true
        }
        container.frame = NSRect(x: x, y: y, width: bounds.width - x, height: mainHeight)
    }
}

@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let window: Win95Window
    let frameView = WindowFrameView()
    let layoutView = BrowserLayoutView()
    let webView: BrowserWebView
    private(set) var state = BrowserWindowState() {
        didSet { if state != oldValue { render(old: oldValue) } }
    }
    private var observations: [NSKeyValueObservation] = []
    private var hoverURL = ""
    private var statusNote: String?
    private(set) var explorerView: ExplorerBarView?
    private(set) var assistant: AssistantSession?
    private var typedNavigation = false

    init(configuration: WKWebViewConfiguration, features: WKWindowFeatures?) {
        var size = NSSize(width: 900, height: 680)
        if let w = features?.width?.doubleValue, let h = features?.height?.doubleValue {
            size = NSSize(width: max(w + 16, 320), height: max(h + 150, 200))
        }
        window = Win95Window(contentRect: NSRect(origin: .zero, size: size))
        webView = BrowserWebView(frame: .zero, configuration: configuration)
        super.init()
        window.delegate = self
        window.contentView = frameView
        window.title = state.windowTitle
        window.onStateChange = { [weak self] in self?.frameView.titleBar.syncMaximizeGlyph() }
        frameView.content.addSubview(layoutView)
        frameView.content.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: frameView.content, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutView.frame = self?.frameView.content.bounds ?? .zero }
        }
        layoutView.container.content = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.onContextMenu = { [weak self] items, event in self?.showContextMenu(items, at: event) }
        wire()
        observe()
        render(old: nil)
    }

    var isModal: Bool { frameView.dialogLayer.hasModal }

    // MARK: wiring

    private func wire() {
        let menuLayer = frameView.menuLayer
        menuLayer.onCommand = { [weak self] in self?.perform($0) }
        layoutView.menuBar.onOpen = { [weak self] i in
            guard let self else { return }
            menuLayer.openBarMenu(i, bar: self.layoutView.menuBar, menus: self.layoutView.menuBar.menus)
        }
        layoutView.rebar.toolbar.onCommand = { [weak self] command, button in
            guard let self else { return }
            if command == .textLarger {
                let sizes = MenuModel.menus(self.menuContext)[2].entries.compactMap { e -> [MenuEntry]? in
                    if case let .submenu(m) = e, m.label.text == "Text Size" { return m.entries }
                    return nil
                }.first ?? []
                let origin = menuLayer.convert(NSPoint(x: button.bounds.minX, y: button.bounds.maxY), from: button)
                menuLayer.openMenu(sizes, at: origin)
            } else {
                self.perform(command)
            }
        }
        let combo = layoutView.rebar.address.combo
        combo.field.target = self
        combo.field.action = #selector(addressEntered)
        combo.dropButton.action = { [weak self] in
            guard let self else { return }
            let items = App.shared.history.entries
            let rect = menuLayer.convert(combo.bounds, from: combo)
            menuLayer.openList(items, below: rect) { [weak self] i in
                guard let self, items.indices.contains(i) else { return }
                combo.field.stringValue = items[i]
                self.go(items[i])
            }
        }
        layoutView.splitter.onDrag = { [weak self] delta in
            guard let self else { return }
            if delta.isNaN {
                self.dragStartWidth = nil
                return
            }
            let start = self.dragStartWidth ?? self.state.assistantWidth
            self.dragStartWidth = start
            self.state.setAssistantWidth(start + Double(delta))
        }
        frameView.dialogLayer.onChange = { [weak self] in
            guard let self else { return }
            self.frameView.titleBar.isActive = self.state.isKey && !self.isModal
            self.menusChanged()
        }
    }

    private var dragStartWidth: Double?

    private func observe() {
        observations = [
            webView.observe(\.title) { [weak self] wv, _ in MainActor.assumeIsolated { self?.state.title = wv.title ?? "" } },
            webView.observe(\.url) { [weak self] wv, _ in MainActor.assumeIsolated { self?.urlChanged(wv.url) } },
            webView.observe(\.isLoading) { [weak self] wv, _ in MainActor.assumeIsolated { self?.loadingChanged(wv.isLoading) } },
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in MainActor.assumeIsolated { self?.state.progress = wv.estimatedProgress } },
            webView.observe(\.canGoBack) { [weak self] wv, _ in MainActor.assumeIsolated { self?.state.canGoBack = wv.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] wv, _ in MainActor.assumeIsolated { self?.state.canGoForward = wv.canGoForward } },
        ]
    }

    private func urlChanged(_ url: URL?) {
        guard let url else { return }
        state.url = url
    }

    private func loadingChanged(_ loading: Bool) {
        state.isLoading = loading
        if loading {
            statusNote = nil
            hoverURL = ""
            if let url = webView.url { state.status = BrowserWindowState.openingStatus(url) }
        } else if state.status.hasPrefix("Opening page") {
            state.status = BrowserWindowState.doneStatus
        }
    }

    // MARK: rendering

    var menuContext: MenuContext {
        MenuContext(state: state, favorites: App.shared.favorites.items, modal: isModal)
    }

    func menusChanged() {
        layoutView.menuBar.menus = MenuModel.menus(menuContext)
    }

    private func render(old: BrowserWindowState?) {
        let s = state
        window.title = s.windowTitle
        frameView.titleBar.title = s.windowTitle
        frameView.titleBar.isActive = s.isKey && !isModal
        let rebar = layoutView.rebar
        rebar.showsToolbar = s.toolbarVisible
        rebar.showsAddress = s.addressBarVisible
        rebar.logo.isAnimating = s.isLoading
        let tb = rebar.toolbar.buttons
        tb[.back]?.isEnabled = s.canGoBack
        tb[.forward]?.isEnabled = s.canGoForward
        tb[.stop]?.isEnabled = s.isLoading
        tb[.print]?.isEnabled = s.url != nil
        tb[.toggleAssistant]?.isLatched = s.assistantOpen
        let field = rebar.address.combo.field
        if old?.url != s.url, field.currentEditor() == nil { field.stringValue = s.addressText }
        rebar.address.combo.icon = Pages.isHome(s.url) ? .app16 : (s.url?.scheme == "https" ? .lock : .page)
        renderStatusText()
        let status = layoutView.statusBar
        status.zone = s.zone
        status.showsProgress = s.isLoading
        status.progress.fraction = s.progress
        layoutView.showsStatusBar = s.statusBarVisible
        layoutView.explorerWidth = CGFloat(s.assistantWidth)
        if s.assistantOpen != (layoutView.explorer != nil) {
            layoutView.explorer = s.assistantOpen ? ensureExplorer() : nil
        }
        if old?.textSize != s.textSize { webView.pageZoom = s.textSize.pageZoom }
        if old == nil || old?.canGoBack != s.canGoBack || old?.canGoForward != s.canGoForward || old?.isLoading != s.isLoading
            || old?.url != s.url || old?.toolbarVisible != s.toolbarVisible || old?.statusBarVisible != s.statusBarVisible
            || old?.addressBarVisible != s.addressBarVisible || old?.assistantOpen != s.assistantOpen || old?.textSize != s.textSize {
            menusChanged()
        }
        layoutView.needsLayout = true
    }

    // MARK: navigation

    func load(_ url: URL) {
        state.url = url
        state.status = BrowserWindowState.openingStatus(url)
        webView.load(URLRequest(url: url))
    }

    @objc private func addressEntered() {
        let text = layoutView.rebar.address.combo.field.stringValue
        go(text)
    }

    func go(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        App.shared.recordTyped(trimmed)
        typedNavigation = true
        load(URLInput.resolve(trimmed))
        window.makeFirstResponder(webView)
    }

    func focusAddress() {
        guard state.addressBarVisible else {
            state.addressBarVisible = true
            layoutView.layoutSubtreeIfNeeded()
            return focusAddress()
        }
        let field = layoutView.rebar.address.combo.field
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    // MARK: commands

    func isEnabled(_ command: Command) -> Bool {
        MenuModel.isEnabled(command, menuContext)
    }

    private var contextItems: [NSMenuItem] = []

    private func showContextMenu(_ items: [NSMenuItem], at event: NSEvent) {
        contextItems = items
        var entries: [MenuEntry] = []
        for (i, item) in items.enumerated() where !item.isHidden {
            if item.isSeparatorItem {
                if let last = entries.last, last != .separator { entries.append(.separator) }
                continue
            }
            // Share and Services submenus stay out; they are macOS UI.
            guard item.submenu == nil, item.action != nil else { continue }
            entries.append(.item(MenuItem(command: .contextItem(i), label: MenuLabel(item.title.replacingOccurrences(of: "&", with: "&&")),
                                          shortcut: nil, isEnabled: item.isEnabled, check: item.state == .on ? .check : .none)))
        }
        while entries.last == .separator { entries.removeLast() }
        guard !entries.isEmpty else { return }
        let layer = frameView.menuLayer
        layer.openMenu(entries, at: layer.convert(event.locationInWindow, from: nil))
    }

    func perform(_ command: Command) {
        if case let .contextItem(i) = command {
            guard contextItems.indices.contains(i), let action = contextItems[i].action else { return }
            NSApp.sendAction(action, to: contextItems[i].target, from: contextItems[i])
            return
        }
        guard isEnabled(command) || command == .close else { return }
        switch command {
        case .newWindow: App.shared.perform(.newWindow, in: self)
        case .print: printPage()
        case .close: window.win95Close()
        case .cut: NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case .copy: NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case .paste: NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case .selectAll: NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case .find: showFind()
        case .toggleToolbar: state.toolbarVisible.toggle()
        case .toggleAddressBar: state.addressBarVisible.toggle()
        case .toggleStatusBar: state.statusBarVisible.toggle()
        case .toggleAssistant: setAssistant(open: !state.assistantOpen)
        case let .textSize(size): state.textSize = size
        case .textLarger: state.textSize = state.textSize.stepUp
        case .textSmaller: state.textSize = state.textSize.stepDown
        case .textReset: state.textSize = .medium
        case .stop:
            webView.stopLoading()
            state.status = BrowserWindowState.doneStatus
        case .refresh: webView.reload()
        case .viewSource: viewSource()
        case .back: webView.goBack()
        case .forward: webView.goForward()
        case .home: load(Pages.homeURL)
        case .search: load(URL(string: "https://duckduckgo.com/")!)
        case .focusAddress: focusAddress()
        case .addFavorite: showAddFavorite()
        case let .openFavorite(url): if let u = URL(string: url) { load(u) }
        case let .removeFavorite(url): App.shared.removeFavorite(url: url)
        case .about: showAbout()
        case .contextItem: break
        }
    }

    /// Escape, F5 and the menu layer's keys; Cmd shortcuts arrive through the macOS menu.
    func handleKey(_ event: NSEvent) -> Bool {
        if frameView.menuLayer.isOpen || frameView.dialogLayer.hasModal { return false }
        if frameView.dialogLayer.top != nil, window.firstResponder === frameView.dialogLayer.top { return false }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 53 where mods.isEmpty && state.isLoading:
            perform(.stop)
            return true
        case 96 where mods.isEmpty:
            perform(.refresh)
            return true
        default:
            return false
        }
    }

    private func printPage() {
        let op = webView.printOperation(with: NSPrintInfo.shared)
        op.showsPrintPanel = true
        op.run()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "data", "blob", "file", Pages.scheme].contains(scheme) {
            // mailto:, tel: and app links leave the browser only after a real click.
            if navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(), disposition.hasPrefix("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        App.shared.downloads.adopt(download, from: self)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        App.shared.downloads.adopt(download, from: self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        typedNavigation = false
        state.status = BrowserWindowState.doneStatus
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    private func loadFailed(_ error: Error) {
        let ns = error as NSError
        // Cancelled loads and loads that turned into downloads are not failures.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? state.url
        let address = failing?.absoluteString ?? ""
        state.status = "Cannot open \(address)"
        webView.loadHTMLString(Pages.error(url: address, reason: ns.localizedDescription), baseURL: failing)
        if typedNavigation {
            typedNavigation = false
            showMessage(kind: "error", title: "webkit95", icon: .error,
                        message: "webkit95 cannot open the Internet site \(address).\n\n\(ns.localizedDescription)")
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        state.status = "The page stopped working. Click Refresh to load it again."
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = App.shared.openWindow(url: nil, configuration: configuration, features: windowFeatures, near: window)
        popup.state.status = "Opening page \(navigationAction.request.url?.absoluteString ?? "")..."
        if window.isKeyWindow || NSApp.isActive {
            popup.window.makeKeyAndOrderFront(nil)
        } else {
            popup.window.orderFront(nil)
        }
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        window.win95Close()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            showMessage(kind: "alert", title: pageTitle(frame), icon: .warning, message: message) { _ in done.resume() }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let d = DialogView.messageBox(kind: "confirm", title: pageTitle(frame), icon: .question, message: message,
                                          buttons: [("ok", "OK"), ("cancel", "Cancel")], defaultButton: "ok", cancelButton: "cancel") { id in
                done.resume(returning: id == "ok")
            }
            present(d)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            present(Dialogs.prompt(title: pageTitle(frame), message: prompt, text: defaultText ?? "") { done.resume(returning: $0) })
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let what = switch type {
        case .camera: "your camera"
        case .microphone: "your microphone"
        case .cameraAndMicrophone: "your camera and microphone"
        @unknown default: "a media device"
        }
        let host = origin.port > 0 ? "\(origin.host):\(origin.port)" : origin.host
        return await withCheckedContinuation { (done: CheckedContinuation<WKPermissionDecision, Never>) in
            let d = DialogView.messageBox(kind: "media", title: "Security Warning", icon: .warning,
                                          message: "The site \(host) wants to use \(what).\n\nDo you want to allow this?",
                                          buttons: [("allow", "&Allow"), ("deny", "&Don't Allow")], defaultButton: "deny", cancelButton: "deny") { id in
                done.resume(returning: id == "allow" ? .grant : .deny)
            }
            present(d)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }

    private func pageTitle(_ frame: WKFrameInfo) -> String {
        let host = frame.securityOrigin.host
        return host.isEmpty ? "webkit95" : "Message from \(host)"
    }

    private func renderStatusText() {
        layoutView.statusBar.text = hoverURL.isEmpty ? (statusNote ?? state.status) : BrowserWindowState.shortcutStatus(hoverURL)
    }

    func downloadStatus(_ text: String) {
        statusNote = text
        renderStatusText()
    }

    // MARK: scripts

    func handleScript(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "hover":
            hoverURL = (body["url"] as? String) ?? ""
            renderStatusText()
        case "popupBlocked":
            statusNote = "Pop-up blocked. A new window needs a click."
            renderStatusText()
        default:
            break
        }
    }

    // MARK: dialogs

    func present(_ dialog: DialogView) {
        frameView.menuLayer.close()
        frameView.dialogLayer.present(dialog)
    }

    func showMessage(kind: String, title: String, icon: Icon, message: String, done: ((String) -> Void)? = nil) {
        present(DialogView.messageBox(kind: kind, title: title, icon: icon, message: message,
                                      buttons: [("ok", "OK")], defaultButton: "ok", cancelButton: nil) { done?($0) })
    }

    private func showAbout() {
        present(Dialogs.about())
    }

    private func showAddFavorite() {
        guard let url = state.url else { return }
        present(Dialogs.addFavorite(title: state.title.isEmpty ? url.absoluteString : state.title) { name in
            if let name { App.shared.addFavorite(title: name, url: url.absoluteString) }
        })
    }

    private func showFind() {
        if let existing = frameView.dialogLayer.dialog(kind: "find") {
            existing.takeFocus()
            return
        }
        state.findOpen = true
        present(Dialogs.find(state: state.find, next: { [weak self] find in
            self?.findNext(find)
        }, close: { [weak self] find in
            self?.state.find = find
            self?.state.findOpen = false
        }))
    }

    private func findNext(_ find: FindState) {
        state.find = find
        guard !find.query.isEmpty else { return }
        let config = WKFindConfiguration()
        config.caseSensitive = find.matchCase
        config.backwards = !find.searchDown
        config.wraps = true
        webView.find(find.query, configuration: config) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.find.lastFound = result.matchFound
                if !result.matchFound {
                    self.showMessage(kind: "find-none", title: "Find", icon: .info, message: "webkit95 has finished searching the page. The text \"\(find.query)\" was not found.")
                }
            }
        }
    }

    private func viewSource() {
        let title = state.title.isEmpty ? (state.url?.absoluteString ?? "Untitled") : state.title
        // The page's HTML as served, without the scrollbar style webkit95 injects.
        let js = """
        (() => {
          const root = document.documentElement.cloneNode(true);
          root.querySelector('#__webkit95_scrollbars')?.remove();
          const dt = document.doctype ? new XMLSerializer().serializeToString(document.doctype) + '\\n' : '';
          return dt + root.outerHTML;
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let n = App.shared.openNotepad(title: title, text: (result as? String) ?? "", near: self.window)
                n.window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: assistant

    func setAssistant(open: Bool) {
        state.assistantOpen = open
        if open { assistant?.chat.startIfNeeded() }
    }

    private func ensureExplorer() -> ExplorerBarView {
        if let explorerView { return explorerView }
        let session = AssistantSession(controller: self)
        assistant = session
        let view = ExplorerBarView(session: session)
        view.onClose = { [weak self] in self?.setAssistant(open: false) }
        explorerView = view
        session.chat.startIfNeeded()
        return view
    }

    func shutdownAgent() {
        assistant?.chat.shutdown()
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        state.isKey = true
        App.shared.rebuildMainMenu()
    }

    func windowDidResignKey(_ notification: Notification) {
        state.isKey = false
        frameView.menuLayer.close()
    }

    func windowWillClose(_ notification: Notification) {
        observations = []
        webView.stopLoading()
        shutdownAgent()
        App.shared.downloads.windowClosed(self)
        App.shared.windowClosed(self)
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard client is PixelTextField else { return nil }
        if fieldEditor == nil {
            let fe = PixelTextView()
            fe.isFieldEditor = true
            PixelTextView.configure(fe)
            fieldEditor = fe
        }
        return fieldEditor
    }

    private var fieldEditor: PixelTextView?
}
