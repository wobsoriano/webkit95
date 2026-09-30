import AppKit
import WebKit
import Webkit95Agent
import Webkit95Kit

/// Adapts one AcpClient to the chat's engine protocol. Events hop to the main actor tagged
/// with this engine, so the chat can drop events from an engine it replaced.
@MainActor
final class AcpEngine: AgentEngine {
    private var client: AcpClient?
    private var configError: InvalidAgentModel?
    private let onEvent: @MainActor (AgentEvent, AcpEngine) -> Void

    init(onEvent: @escaping @MainActor (AgentEvent, AcpEngine) -> Void) {
        self.onEvent = onEvent
        do {
            let config = try AgentConfig.fromEnvironment()
            // DispatchQueue.main keeps wire order; separate Tasks would not promise it.
            client = AcpClient(config: config) { [weak self] event in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.deliver(event) }
                }
            }
        } catch {
            configError = error
        }
    }

    private func deliver(_ event: AgentEvent) { onEvent(event, self) }

    func start() {
        guard let configError else { client?.start(); return }
        // Async like the client's own events, so the chat is never re-entered from start().
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.deliver(.exited(reason: configError.description)) }
        }
    }
    func prompt(_ text: String, page: PageContext?) { client?.prompt(text, page: page) }
    func cancel() { client?.cancel() }
    func resolvePermission(requestID: String, optionID: String?) { client?.resolvePermission(requestID: requestID, optionID: optionID) }
    func shutdown() { client?.shutdown() }
}

/// One window's assistant: the chat model, the page reader over the window's web view, and the
/// permission dialog.
@MainActor
final class AssistantSession: PageReader, Scheduler {
    private(set) var chat: ChatModel!
    private weak var controller: BrowserWindowController?
    var includePage = true
    var onChange: (() -> Void)?
    private var shownPermission: String?
    /// For the control socket: the last page text read for a prompt.
    private(set) var lastPageRead: String?

    init(controller: BrowserWindowController) {
        self.controller = controller
        chat = ChatModel(engine: makeEngine(), reader: self, scheduler: self)
        chat.onChange = { [weak self] in self?.changed() }
    }

    private func makeEngine() -> AcpEngine {
        AcpEngine { [weak self] event, source in self?.chat.apply(event, from: source) }
    }

    func restart() {
        chat.restart(with: makeEngine())
    }

    func send(_ text: String) -> Bool {
        let page = includePage ? controller.flatMap { c in c.state.url.map { OpenPage(url: $0.absoluteString, title: c.state.title) } } : nil
        return chat.send(text, page: page)
    }

    func readText(requestID: Int, maxChars: Int) {
        guard let webView = controller?.webView else {
            chat.receivePageText(requestID: requestID, text: nil, url: nil)
            return
        }
        let js = "(() => { const t = document.body ? document.body.innerText : ''; return [location.href, t.slice(0, \(maxChars))]; })()"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            MainActor.assumeIsolated {
                let pair = result as? [Any]
                let text = pair?.count == 2 ? pair?[1] as? String : nil
                self?.lastPageRead = text
                self?.chat.receivePageText(requestID: requestID, text: text, url: pair?.first as? String)
            }
        }
    }

    func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }

    private func changed() {
        onChange?()
        showPermissionIfNeeded()
    }

    /// The agent is blocked until the user answers, so the box opens the Explorer Bar and cannot
    /// be missed: modal, warning icon, Reject is the default.
    private func showPermissionIfNeeded() {
        guard let controller else { return }
        guard let request = chat.permissions.first else {
            if shownPermission != nil { controller.frameView.dialogLayer.dialog(kind: "permission")?.close() }
            shownPermission = nil
            return
        }
        guard shownPermission != request.requestID else { return }
        if let stale = controller.frameView.dialogLayer.dialog(kind: "permission") { stale.close() }
        shownPermission = request.requestID
        if !controller.state.assistantOpen { controller.setAssistant(open: true) }
        let dialog = PermissionDialog(request: request) { [weak self] option in
            guard let self else { return }
            self.shownPermission = nil
            self.chat.resolve(request.requestID, optionID: option?.optionID)
        }
        controller.present(dialog)
    }
}

/// "Assistant needs permission": the agent's title and the full request in a read only box.
final class PermissionDialog: DialogView {
    let request: PermissionRequest

    init(request: PermissionRequest, answer: @escaping (PermissionOption?) -> Void) {
        self.request = request
        let width: CGFloat = 460, height: CGFloat = 300
        super.init(kind: "permission", title: "Assistant needs permission", size: NSSize(width: width, height: height))
        let icon = IconView(icon: .warning)
        icon.frame = NSRect(x: 12, y: 12, width: 32, height: 32)
        body.addSubview(icon)
        let intro = Win95Label("The assistant wants to run a tool. Read the full request before you allow it. Page text you shared can try to trick the assistant.")
        intro.wraps = true
        intro.frame = NSRect(x: 56, y: 10, width: width - 56 - 12, height: 48)
        body.addSubview(intro)
        let titleLabel = Win95Label(TitleBarView.truncate(request.title, width: width - 24))
        titleLabel.bold = true
        titleLabel.frame = NSRect(x: 12, y: 62, width: width - 24, height: 16)
        body.addSubview(titleLabel)
        let detailBox = Win95ScrollView()
        detailBox.showsHorizontal = false
        let text = PixelTextView()
        PixelTextView.configure(text)
        text.font = Fonts.mono
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = true
        text.backgroundColor = Win95Color.white.ns
        text.textContainerInset = NSSize(width: 2, height: 2)
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.string = request.detail?.isEmpty == false ? request.detail! : "(The agent sent no details for this request.)"
        text.setAccessibilityIdentifier("permission-detail")
        detailBox.frame = NSRect(x: 12, y: 82, width: width - 24, height: 150)
        detailBox.documentView = text
        body.addSubview(detailBox)
        let y = height - 23 - 12
        let reject = request.option(for: .reject)
        let once = request.option(for: .allowOnce)
        let session = request.option(for: .allowForSession)
        var order: [DialogFocus.Control] = [.field("detail")]
        register(.field("detail"), detailBox)
        if let session {
            addButton("session", "Allow for this &session", frame: NSRect(x: 12, y: y + 3, width: Draw.width("Allow for this session") + 12, height: 20), style: .small) { [weak self] in
                self?.close(); answer(session)
            }
            order.append(.button("session"))
        }
        if let once {
            addButton("once", "Allow &once", frame: NSRect(x: width - 12 - 75 - 6 - 80, y: y, width: 80, height: 23)) { [weak self] in
                self?.close(); answer(once)
            }
            order.append(.button("once"))
        }
        addButton("reject", "&Reject", frame: NSRect(x: width - 12 - 75, y: y, width: 75, height: 23)) { [weak self] in
            self?.close(); answer(reject)
        }
        order.append(.button("reject"))
        setFocusOrder(order, defaultButton: "reject", cancelButton: "reject", initial: .button("reject"))
    }

    required init?(coder: NSCoder) { fatalError() }
}
