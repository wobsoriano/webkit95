import AppKit
import Network
import WebKit
import Webkit95Agent
import Webkit95Kit

/// Development lever for scripts/smoke.sh and screenshots. Compiled into debug builds only, and
/// off unless WEBKIT95_CONTROL=1. Loopback only (port WEBKIT95_CONTROL_PORT, default 9395). Each
/// line is "<token> <command>", one JSON reply per line. The token is random per launch and
/// written with mode 0600 to WEBKIT95_CONTROL_TOKEN_FILE (default build/control.token next to
/// the app), so other users and web pages cannot drive the browser or approve an agent tool call.
/// Any process of this user can, so never enable it in normal use. Commands: see docs/control.md.
@MainActor
enum ControlServer {
    private static var listener: NWListener?
    private static var token = ""

    static func startIfEnabled() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard env["WEBKIT95_CONTROL"] == "1" else { return }
        let tokenFile = env["WEBKIT95_CONTROL_TOKEN_FILE"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("control.token")
        let fresh = ControlAuth.makeToken()
        guard writePrivately(fresh + "\n", to: tokenFile) else {
            log("control: cannot write the token to \(tokenFile.path), control socket stays off")
            return
        }
        token = fresh
        let port = NWEndpoint.Port(env["WEBKIT95_CONTROL_PORT"] ?? "9395") ?? 9395
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        guard let listener = try? NWListener(using: params) else {
            log("control: cannot listen on \(port)")
            return
        }
        listener.newConnectionHandler = { conn in
            MainActor.assumeIsolated {
                conn.start(queue: .main)
                receive(conn, buffer: Data())
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        log("control: listening on 127.0.0.1:\(port), token in \(tokenFile.path)")
        #endif
    }

    /// Mode 0600 from the moment the file exists. O_EXCL after the unlink, with O_NOFOLLOW, means
    /// a planted file or symlink is never written through.
    private static func writePrivately(_ text: String, to file: URL) -> Bool {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(file.path)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        return write(fd, bytes, bytes.count) == bytes.count
    }

    /// One client connection. Replies can arrive after the client half closed (js, click-element),
    /// so the connection is only cancelled once every command on it has answered.
    @MainActor private final class Client {
        let conn: NWConnection
        var buffer = Data()
        var pending = 0
        var ended = false
        init(_ conn: NWConnection) { self.conn = conn }

        func finishIfDone() {
            if ended && pending == 0 { conn.cancel() }
        }
    }

    private static func receive(_ conn: NWConnection, buffer: Data) {
        receive(Client(conn))
    }

    private static func receive(_ client: Client) {
        client.conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, _ in
            MainActor.assumeIsolated {
                if let data { client.buffer.append(data) }
                while let nl = client.buffer.firstIndex(of: 10) {
                    let line = String(decoding: client.buffer[client.buffer.startIndex..<nl], as: UTF8.self)
                    client.buffer.removeSubrange(client.buffer.startIndex...nl)
                    client.pending += 1
                    var answered = false
                    let reply: (String) -> Void = { text in
                        guard !answered else { return }
                        answered = true
                        client.conn.send(content: Data((text + "\n").utf8), completion: .contentProcessed { _ in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    client.pending -= 1
                                    client.finishIfDone()
                                }
                            }
                        })
                    }
                    guard let command = ControlAuth.command(in: line.trimmingCharacters(in: .whitespacesAndNewlines), token: token) else {
                        reply(json(["error": "unauthorized: every command starts with the token"]))
                        continue
                    }
                    handle(command, reply: reply)
                }
                if done || client.buffer.count > 65536 {
                    client.ended = true
                    client.finishIfDone()
                } else {
                    receive(client)
                }
            }
        }
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func handle(_ line: String, reply: @escaping (String) -> Void) {
        let app = App.shared
        var parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        var target = app.keyController ?? app.windows.last
        if let first = parts.first, first.hasPrefix("@"), let n = Int(first.dropFirst()) {
            guard app.windows.indices.contains(n) else { return reply(json(["error": "no window \(n)"])) }
            target = app.windows[n]
            parts = parts.count > 1 ? parts[1].split(separator: " ", maxSplits: 1).map(String.init) : []
        }
        let name = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        let ok = { reply(json(["ok": true])) }
        func fail(_ message: String) { reply(json(["error": message])) }

        switch name {
        case "state":
            reply(json(state()))
        case "navigate":
            guard let target else { return fail("no window") }
            target.go(arg)
            ok()
        case "press":
            guard let command = Command(id: arg) else { return fail("unknown command id \(arg)") }
            if command == .newWindow {
                let c = app.openWindow(url: Pages.homeURL)
                c.window.orderFront(nil)
                return ok()
            }
            guard let target else { return fail("no window") }
            guard target.isEnabled(command) || command == .close else { return fail("\(arg) is disabled") }
            target.perform(command)
            ok()
        case "js":
            guard let target else { return fail("no window") }
            target.webView.evaluateJavaScript(arg) { result, error in
                MainActor.assumeIsolated {
                    if let error { return fail("js: \(error.localizedDescription)") }
                    reply(json(["result": result.map(jsonable) ?? NSNull()]))
                }
            }
        case "dialog":
            // dialog <kind> <button id> [text for the focused field]
            let v = arg.split(separator: " ", maxSplits: 2).map(String.init)
            guard v.count >= 2, let target, let d = target.frameView.dialogLayer.dialog(kind: v[0]) else { return fail("no \(arg.split(separator: " ").first ?? "") dialog") }
            if v.count == 3, let field = firstField(in: d) { field.stringValue = v[2] }
            d.press(v[1])
            ok()
        case "dialog-key":
            guard let target, let d = target.frameView.dialogLayer.top else { return fail("no dialog") }
            let codes: [String: UInt16] = ["tab": 48, "return": 36, "escape": 53, "left": 123, "right": 124, "space": 49]
            guard let code = codes[arg] else { return fail("keys: tab return escape left right space") }
            d.window?.makeFirstResponder(d)
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: d.window?.windowNumber ?? 0,
                                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
                d.keyDown(with: e)
            }
            ok()
        case "click-element":
            // A real mouse click on the element matching the CSS selector, posted into this
            // window only (never the global event stream), so the page sees a user gesture.
            guard let target else { return fail("no window") }
            let js = "(() => { const e = document.querySelector(\(json(arg))); if (!e) return null; e.scrollIntoView({block: 'center'}); const r = e.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()"
            target.webView.evaluateJavaScript(js) { result, _ in
                MainActor.assumeIsolated {
                    guard let xy = result as? [Double], xy.count == 2 else { return fail("no element \(arg)") }
                    click(target, x: xy[0] * target.webView.pageZoom, y: xy[1] * target.webView.pageZoom)
                    ok()
                }
            }
        case "context-element":
            // A right click on the element, posted into the web view like click-element.
            guard let target else { return fail("no window") }
            let js = "(() => { const e = document.querySelector(\(json(arg))); if (!e) return null; const r = e.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()"
            target.webView.evaluateJavaScript(js) { result, _ in
                MainActor.assumeIsolated {
                    guard let xy = result as? [Double], xy.count == 2 else { return fail("no element \(arg)") }
                    rightClick(target, x: xy[0] * target.webView.pageZoom, y: xy[1] * target.webView.pageZoom)
                    ok()
                }
            }
        case "frame":
            // Screen rect (points, top left origin like accessibility) of a named part, for the
            // gated device QA script: menu:<index>, toolbar:<command id>, titlebar, close, maximize,
            // address, splitter, grip, dialog:<button id>, element:<css selector>.
            guard let target else { return fail("no window") }
            func screen(_ view: NSView, _ rect: NSRect) -> [Double] {
                let r = target.window.convertToScreen(view.convert(rect, to: nil))
                let top = (NSScreen.screens.first?.frame.maxY ?? 0) - r.maxY
                return [r.minX, top, r.width, r.height].map { Double($0) }
            }
            let lv = target.layoutView
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            switch parts.first ?? "" {
            case "menu":
                guard let i = Int(parts.last ?? ""), lv.menuBar.itemRects().indices.contains(i) else { return fail("menu:<index>") }
                reply(json(["frame": screen(lv.menuBar, lv.menuBar.itemRects()[i])]))
            case "toolbar":
                guard let command = Command(id: parts.last ?? ""), let b = lv.rebar.toolbar.buttons[command] else { return fail("toolbar:<command id>") }
                reply(json(["frame": screen(b, b.bounds)]))
            case "titlebar": reply(json(["frame": screen(target.frameView.titleBar, target.frameView.titleBar.bounds)]))
            case "close": reply(json(["frame": screen(target.frameView.titleBar.close, target.frameView.titleBar.close.bounds)]))
            case "maximize": reply(json(["frame": screen(target.frameView.titleBar.maximize, target.frameView.titleBar.maximize.bounds)]))
            case "address": reply(json(["frame": screen(lv.rebar.address.combo.field, lv.rebar.address.combo.field.bounds)]))
            case "splitter": reply(json(["frame": screen(lv.splitter, lv.splitter.bounds)]))
            case "grip": reply(json(["frame": screen(lv.statusBar, NSRect(x: lv.statusBar.bounds.width - 12, y: lv.statusBar.bounds.height - 12, width: 12, height: 12))]))
            case "window": reply(json(["frame": screen(target.frameView, target.frameView.bounds)]))
            case "dialog":
                guard let d = target.frameView.dialogLayer.top, let b = d.buttonView(parts.last ?? "") else { return fail("dialog:<button id>") }
                reply(json(["frame": screen(b, b.bounds)]))
            case "element":
                let js = "(() => { const e = document.querySelector(\(json(parts.last ?? ""))); if (!e) return null; e.scrollIntoView({block: 'center'}); const r = e.getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()"
                target.webView.evaluateJavaScript(js) { result, _ in
                    MainActor.assumeIsolated {
                        guard let r = result as? [Double], r.count == 4 else { return fail("no element") }
                        let z = target.webView.pageZoom
                        let wv = target.webView
                        let local = NSRect(x: r[0] * z, y: wv.isFlipped ? r[1] * z : wv.bounds.height - (r[1] + r[3]) * z, width: r[2] * z, height: r[3] * z)
                        reply(json(["frame": screen(wv, local)]))
                    }
                }
            default: fail("unknown part \(arg)")
            }
        case "menu-open":
            guard let target, let i = Int(arg) else { return fail("menu-open <index>") }
            target.layoutView.menuBar.onOpen?(i)
            ok()
        case "menu-press":
            guard let target, target.frameView.menuLayer.pressRow(arg) else { return fail("no row \(arg)") }
            ok()
        case "menu-close":
            target?.frameView.menuLayer.close()
            ok()
        case "address-list":
            guard let target else { return fail("no window") }
            target.layoutView.rebar.address.combo.dropButton.action?()
            ok()
        case "chat-send":
            guard let target else { return fail("no window") }
            target.setAssistant(open: true)
            guard let session = target.assistant, session.send(arg) else { return fail("chat is not ready: \(target.assistant?.chat.status.title ?? "closed")") }
            ok()
        case "chat-include":
            guard let target else { return fail("no window") }
            target.setAssistant(open: true)
            target.assistant?.includePage = arg == "on"
            ok()
        case "chat-stop":
            target?.assistant?.chat.stop()
            ok()
        case "chat-restart":
            target?.assistant?.restart()
            ok()
        case "chat-toggle":
            guard let id = Int(arg) else { return fail("chat-toggle <message id>") }
            target?.assistant?.chat.toggleExpanded(id)
            ok()
        case "permit":
            guard let target, let d = target.frameView.dialogLayer.dialog(kind: "permission") else { return fail("no permission dialog") }
            d.press(arg)
            ok()
        case "front":
            // Ordered in front of other apps' windows without activating webkit95, so a person's
            // typing keeps going where it was.
            guard let target else { return fail("no window") }
            target.window.orderFrontRegardless()
            ok()
        case "back":
            target?.window.orderBack(nil)
            ok()
        case "notepad-front":
            guard let n = app.notepads.last else { return fail("no notepad") }
            n.window.orderFrontRegardless()
            ok()
        case "resize":
            let v = arg.split(separator: "x").compactMap { Double($0) }
            guard let target, v.count == 2 else { return fail("resize WxH") }
            var f = target.window.frame
            f.origin.y += f.height - v[1]
            f.size = NSSize(width: v[0], height: v[1])
            target.window.setFrame(f, display: true)
            ok()
        case "maximize":
            target?.window.toggleMaximize()
            ok()
        case "close-window":
            target?.window.win95Close()
            ok()
        case "gallery":
            #if DEBUG
            Gallery.open().orderFrontRegardless()
            #endif
            ok()
        case "gallery-close":
            #if DEBUG
            Gallery.window?.close()
            #endif
            ok()
        case "quit":
            reply(json(["ok": true]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
        default:
            fail("unknown command \(name)")
        }
    }

    private static func click(_ c: BrowserWindowController, x: Double, y: Double) {
        let wv = c.webView
        let local = NSPoint(x: x, y: wv.isFlipped ? y : wv.bounds.height - y)
        let p = wv.convert(local, to: nil)
        // Straight to the web view: NSWindow would spend a click on a non key window activating it.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            if type == .leftMouseDown { wv.mouseDown(with: e) } else { wv.mouseUp(with: e) }
        }
    }

    private static func rightClick(_ c: BrowserWindowController, x: Double, y: Double) {
        let wv = c.webView
        let p = wv.convert(NSPoint(x: x, y: wv.isFlipped ? y : wv.bounds.height - y), to: nil)
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            if type == .rightMouseDown { wv.rightMouseDown(with: e) } else { wv.rightMouseUp(with: e) }
        }
    }

    private static func firstField(in view: NSView) -> NSTextField? {
        for sub in view.subviews {
            if let f = sub as? PixelTextField { return f }
            if let f = firstField(in: sub) { return f }
        }
        return nil
    }

    private static func jsonable(_ value: Any) -> Any {
        if JSONSerialization.isValidJSONObject([value]) { return value }
        return String(describing: value)
    }

    private static func state() -> [String: Any] {
        let app = App.shared
        return [
            "active": NSApp.isActive,
            "windows": app.windows.enumerated().map { i, c in windowState(i, c) },
            "notepads": app.notepads.map { ["title": $0.window.title, "length": $0.textView.string.count, "visible": $0.window.isVisible] },
            "downloads": app.downloads.summary,
            "favorites": app.favorites.items.map { ["title": $0.title, "url": $0.url] },
            "history": app.history.entries,
            "declutter": [
                "apiCalls": app.declutter.apiCalls,
                "consented": app.declutter.hasConsent,
                "sites": app.declutter.sites.hosts,
                "templates": app.declutter.cache.entries.count,
            ] as [String: Any],
        ]
    }

    private static func windowState(_ i: Int, _ c: BrowserWindowController) -> [String: Any] {
        let s = c.state
        var out: [String: Any] = [
            "index": i,
            "title": s.title,
            "windowTitle": s.windowTitle,
            "titleBar": c.frameView.titleBar.title,
            "url": s.url?.absoluteString ?? "",
            "address": c.layoutView.rebar.address.combo.field.stringValue,
            "loading": s.isLoading,
            "progress": s.progress,
            "canGoBack": s.canGoBack,
            "canGoForward": s.canGoForward,
            "status": c.layoutView.statusBar.text,
            "zone": s.zone.title,
            "key": c.window.isKeyWindow,
            "firstResponder": c.window.firstResponder.map { String(describing: type(of: $0)) } ?? "",
            "visible": c.window.isVisible,
            "textSize": s.textSize.title,
            "pageZoom": c.webView.pageZoom,
            "toolbar": s.toolbarVisible,
            "addressBar": s.addressBarVisible,
            "statusBar": s.statusBarVisible,
            "assistantOpen": s.assistantOpen,
            "assistantWidth": s.assistantWidth,
            "logoFrame": c.layoutView.rebar.logo.currentFrame,
            "menu": c.frameView.menuLayer.openDescription ?? NSNull(),
            "dialogs": c.frameView.dialogLayer.dialogs.map { d -> [String: Any] in
                var info: [String: Any] = ["kind": d.kind, "title": d.titleBar.title, "modal": d.isModal, "default": d.focus.effectiveDefault ?? ""]
                if case let .button(id)? = d.focus.focused { info["focus"] = id } else { info["focus"] = String(describing: d.focus.focused) }
                if let p = d as? PermissionDialog {
                    info["detail"] = p.request.detail ?? ""
                    info["buttons"] = ["session", "once", "reject"].filter { p.buttonView($0) != nil }
                }
                if let dl = d as? DownloadDialog { info["received"] = dl.received }
                if let message = d.message { info["message"] = message }
                return info
            },
            "frame": NSStringFromRect(c.window.frame),
            "declutter": declutterState(c),
            "find": ["open": s.findOpen, "query": s.find.query, "found": s.find.lastFound.map { $0 as Any } ?? NSNull()],
        ]
        if let e = c.explorerView {
            out["explorerLayout"] = [
                "transcript": NSStringFromRect(e.transcript.frame),
                "clip": NSStringFromRect(e.list.scrollView.contentView.frame),
                "container": NSStringFromSize(e.transcript.textContainer?.size ?? .zero),
            ]
        }
        if let session = c.assistant {
            let chat = session.chat!
            out["chat"] = [
                "status": chat.status.title,
                "restartVisible": c.explorerView.map { !$0.restart.isHidden } ?? false,
                "agent": chat.agentName,
                "includePage": session.includePage,
                "messages": chat.messages.map(messageState),
                "permissions": chat.permissions.map { ["id": $0.requestID, "title": $0.title, "detail": $0.detail ?? ""] },
                "lastSentPage": chat.lastSentPage.map { ["url": $0.url, "title": $0.title, "textLength": $0.text.count, "text": String($0.text.prefix(200))] } ?? NSNull(),
            ] as [String: Any]
        }
        return out
    }

    private static func declutterState(_ c: BrowserWindowController) -> [String: Any] {
        let phase = switch c.state.declutter {
        case .idle: "idle"
        case .running: "running"
        case .applied: "applied"
        }
        let r = c.declutter.report
        var last: [String: Any] = [
            "candidates": r.candidates.map { ["id": $0.id, "selector": $0.selector.raw, "tag": $0.tag, "position": $0.position, "signals": String($0.signals.prefix(80))] },
            "fromCache": r.fromCache,
            "status": r.status,
            "rules": r.rules.map { ["selector": $0.selector.raw, "choice": $0.choice.rawValue] },
        ]
        if let result = r.result {
            last["requestBytes"] = result.requestBytes
            last["responseBytes"] = result.responseBytes
            last["latencyMs"] = Int(result.latency.components.seconds * 1000 + result.latency.components.attoseconds / 1_000_000_000_000_000)
            last["model"] = result.response.model ?? NSNull()
            last["inputTokens"] = result.response.usage?.inputTokens ?? NSNull()
            last["outputTokens"] = result.response.usage?.outputTokens ?? NSNull()
            last["ignoredIDs"] = result.response.ignoredIDs.count
            last["decisions"] = result.response.decisions.map { d -> [String: Any] in
                ["id": d.candidateID, "choice": d.choice.rawValue, "probability": d.probability ?? NSNull(), "confidence": d.confidence ?? NSNull()]
            }
        }
        if let review = r.review {
            last["verdicts"] = review.verdicts.map { ["selector": $0.rule.selector.raw, "verdict": DeclutterDebugTable.describe($0.kind)] }
            last["areaFraction"] = review.areaFraction.isFinite ? review.areaFraction : -1
            last["textFraction"] = review.textFraction.isFinite ? review.textFraction : -1
            // The measurement (no page text) travels only with WEBKIT95_DECLUTTER_DEBUG=1.
            if let measure = r.measure, let data = try? JSONEncoder().encode(measure),
                let object = try? JSONSerialization.jsonObject(with: data) {
                last["measure"] = object
                last["table"] = DeclutterDebugTable.lines(review, measure: measure)
            }
        }
        return ["phase": phase, "auto": c.state.autoDeclutter, "last": last]
    }

    private static func messageState(_ m: ChatMessage) -> [String: Any] {
        switch m.body {
        case let .user(text, page): ["id": m.id, "kind": "user", "text": text, "page": page?.url ?? ""]
        case let .assistant(text): ["id": m.id, "kind": "assistant", "text": text]
        case let .thought(text, expanded): ["id": m.id, "kind": "thought", "text": text, "expanded": expanded]
        case let .diagnostics(text, expanded): ["id": m.id, "kind": "diagnostics", "text": text, "expanded": expanded]
        case let .tool(call): ["id": m.id, "kind": "tool", "text": call.title, "status": call.status]
        case let .error(text): ["id": m.id, "kind": "error", "text": text]
        case let .notice(text): ["id": m.id, "kind": "notice", "text": text]
        }
    }
}
