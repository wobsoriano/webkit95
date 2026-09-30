import AppKit
import Webkit95Kit

/// The left Explorer Bar hosting the assistant: title strip, message list, "Include current
/// page", the edit field, Send and Stop, and a status line with Restart.
final class ExplorerBarView: FaceView, NSTextViewDelegate {
    let session: AssistantSession
    private let closeButton = Win95Button("", style: .titleBar, icon: .close)
    let list = Win95ScrollView()
    let transcript = PixelTextView()
    let includePage = Win95Checkbox("&Include current page", isOn: true)
    let inputBox = Win95ScrollView()
    let input = PixelTextView()
    let send = Win95Button("&Send")
    let stop = Win95Button("S&top")
    let restart = Win95Button("&Restart")
    private let status = Win95Label("")
    var onClose: (() -> Void)?

    init(session: AssistantSession) {
        self.session = session
        super.init(frame: .zero)
        setAccessibilityIdentifier("explorer-bar")
        addSubview(closeButton)
        closeButton.setAccessibilityLabel("Close Assistant")
        closeButton.action = { [weak self] in self?.onClose?() }

        for tv in [transcript, input] {
            PixelTextView.configure(tv)
            tv.drawsBackground = true
            tv.backgroundColor = Win95Color.white.ns
            tv.textContainerInset = NSSize(width: 3, height: 3)
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.textContainer?.widthTracksTextView = true
            tv.autoresizingMask = [.width]
        }
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.delegate = self
        transcript.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        transcript.setAccessibilityIdentifier("assistant-transcript")
        list.documentView = transcript
        addSubview(list)

        includePage.onChange = { [weak self] on in self?.session.includePage = on }
        addSubview(includePage)

        input.isEditable = true
        input.isRichText = false
        input.delegate = self
        input.setAccessibilityIdentifier("assistant-input")
        inputBox.documentView = input
        addSubview(inputBox)

        send.isDefault = true
        send.action = { [weak self] in self?.submit() }
        stop.action = { [weak self] in self?.session.chat.stop() }
        restart.action = { [weak self] in self?.session.restart() }
        for b in [send, stop, restart] { addSubview(b) }
        addSubview(status)
        session.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let titleHeight: CGFloat = 22

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        closeButton.frame = NSRect(x: w - 4 - 16, y: 4, width: 16, height: 14)
        let statusY = h - 22
        let buttonsY = statusY - 4 - 23
        let inputY = buttonsY - 6 - 60
        let checkY = inputY - 4 - 18
        list.frame = NSRect(x: 2, y: Self.titleHeight, width: w - 4, height: max(checkY - 4 - Self.titleHeight, 40))
        includePage.frame = NSRect(x: 4, y: checkY, width: w - 8, height: 18)
        inputBox.frame = NSRect(x: 2, y: inputY, width: w - 4, height: 60)
        send.frame = NSRect(x: w - 2 - 60 - 4 - 60, y: buttonsY, width: 60, height: 23)
        stop.frame = NSRect(x: w - 2 - 60, y: buttonsY, width: 60, height: 23)
        restart.frame = NSRect(x: 2, y: buttonsY, width: 64, height: 23)
        status.frame = NSRect(x: 4, y: statusY + 3, width: w - 8, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Draw.bevel(.thinRaised, NSRect(x: 0, y: 0, width: bounds.width, height: Self.titleHeight - 2))
        Draw.text("Assistant", at: NSPoint(x: 6, y: 2))
        Draw.bevel(.thinSunken, NSRect(x: 2, y: bounds.height - 20, width: bounds.width - 4, height: 20))
    }

    func submit() {
        let text = input.string
        if session.send(text) { input.string = "" }
    }

    func refresh() {
        let chat = session.chat!
        let atBottom = list.scrollView.contentView.bounds.maxY >= transcript.frame.height - 4
        transcript.textStorage?.setAttributedString(Self.render(chat.messages, agent: chat.agentName))
        transcript.sizeToFit()
        list.sync()
        if atBottom { list.scrollToBottom() }
        send.isEnabled = chat.canSend
        stop.isEnabled = chat.isWorking
        let unavailable: Bool = if case .unavailable = chat.status { true } else { false }
        restart.isHidden = !unavailable
        status.text = chat.status.title
        status.setAccessibilityIdentifier("assistant-status")
        needsDisplay = true
    }

    // Return sends, Shift+Return is a new line; the transcript's [+] expanders are links.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard textView === input, selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
        submit()
        return true
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let s = (link as? URL)?.absoluteString ?? link as? String, s.hasPrefix("webkit95-toggle:"), let id = Int(s.dropFirst("webkit95-toggle:".count)) else { return false }
        session.chat.toggleExpanded(id)
        return true
    }

    // MARK: transcript

    static func render(_ messages: [ChatMessage], agent: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let plain = Draw.attributes(Fonts.ui, .black)
        let gray = Draw.attributes(Fonts.ui, .gray)
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 6
        para.minimumLineHeight = Fonts.lineHeight
        para.maximumLineHeight = Fonts.lineHeight
        func line(_ s: NSAttributedString) {
            let m = NSMutableAttributedString(attributedString: s)
            m.append(NSAttributedString(string: "\n", attributes: plain))
            m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
            out.append(m)
        }
        func expander(_ title: String, _ text: String, expanded: Bool, id: Int) {
            let m = NSMutableAttributedString(attachment: iconAttachment(expanded ? .expandMinus : .expandPlus))
            m.addAttribute(.link, value: "webkit95-toggle:\(id)", range: NSRange(location: 0, length: m.length))
            m.append(NSAttributedString(string: " " + title, attributes: gray))
            if expanded { m.append(NSAttributedString(string: "\n" + text, attributes: gray)) }
            line(m)
        }
        for message in messages {
            switch message.body {
            case let .user(text, page):
                let m = NSMutableAttributedString(attachment: boldAttachment("You:"))
                m.append(NSAttributedString(string: " " + text, attributes: plain))
                if let page {
                    m.append(NSAttributedString(string: "\n(with page: \(page.title.isEmpty ? page.url : page.title))", attributes: gray))
                }
                line(m)
            case let .assistant(text):
                line(NSAttributedString(string: text, attributes: plain))
            case let .thought(text, expanded):
                expander("Thinking", text, expanded: expanded, id: message.id)
            case let .diagnostics(text, expanded):
                expander("fx diagnostics", text.trimmingCharacters(in: .whitespacesAndNewlines), expanded: expanded, id: message.id)
            case let .tool(call):
                let m = NSMutableAttributedString(attachment: iconAttachment(.tool))
                m.append(NSAttributedString(string: " \(call.title) - \(statusText(call.status))", attributes: plain))
                line(m)
            case let .error(text):
                let m = NSMutableAttributedString(attachment: iconAttachment(.error, small: true))
                m.append(NSAttributedString(string: " " + text, attributes: Draw.attributes(Fonts.ui, .maroon)))
                line(m)
            case let .notice(text):
                line(NSAttributedString(string: text, attributes: gray))
            }
        }
        return out
    }

    static func statusText(_ status: String) -> String {
        switch status {
        case "pending": "Waiting"
        case "in_progress": "Running"
        case "completed": "Done"
        case "failed": "Failed"
        default: status
        }
    }

    private static func iconAttachment(_ icon: Icon, small: Bool = false) -> NSTextAttachment {
        let a = NSTextAttachment()
        var art = icon.art
        if small && art.width > 16 {
            art = PixelArt(stride(from: 0, to: art.height, by: 2).map { y in
                String(stride(from: 0, to: art.width, by: 2).map { x in Array(art.rows[y])[x] })
            })
        }
        let img = PixelImages.image(art)
        a.image = img
        a.bounds = NSRect(x: 0, y: -3, width: img.size.width, height: img.size.height)
        return a
    }

    /// Bold text as a crisp image, since the pixel font has no bold cut.
    private static func boldAttachment(_ text: String) -> NSTextAttachment {
        let w = Draw.width(text, bold: true)
        let img = NSImage(size: NSSize(width: w, height: Fonts.lineHeight), flipped: true) { _ in
            Draw.text(text, at: .zero, bold: true)
            return true
        }
        let a = NSTextAttachment()
        a.image = img
        a.bounds = NSRect(x: 0, y: -3, width: w, height: Fonts.lineHeight)
        return a
    }
}
