import Foundation
import Webkit95Agent

/// The side effects the chat asks of the agent. `AcpClient` implements it through an adapter in
/// the app; tests use a fake.
@MainActor
public protocol AgentEngine: AnyObject {
    func start()
    func prompt(_ text: String, page: PageContext?)
    func cancel()
    /// A nil option answers the request as cancelled.
    func resolvePermission(requestID: String, optionID: String?)
    func shutdown()
}

/// Reads the window's page text. The answer comes back through `ChatModel.receivePageText`
/// with the same request id.
@MainActor
public protocol PageReader: AnyObject {
    func readText(requestID: Int, maxChars: Int)
}

@MainActor
public protocol Scheduler: AnyObject {
    func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void)
}

/// The page on screen when the user sends with "Include current page" checked.
public struct OpenPage: Equatable, Sendable {
    public let url: String
    public let title: String

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }
}

public struct ToolCall: Equatable, Sendable {
    public let id: String
    public var title: String
    public let kind: String
    public var status: String
}

public struct PermissionRequest: Equatable, Sendable, Identifiable {
    public var id: String { requestID }
    public let requestID: String
    public let title: String
    public let detail: String?
    public let options: [PermissionOption]

    public init(requestID: String, title: String, detail: String?, options: [PermissionOption]) {
        self.requestID = requestID
        self.title = title
        self.detail = detail
        self.options = options
    }

    public enum Choice: Sendable {
        case reject, allowOnce, allowForSession
    }

    /// The agent's option for a dialog button, nil when the agent did not offer it.
    public func option(for choice: Choice) -> PermissionOption? {
        let kinds: [String] = switch choice {
        case .reject: ["reject_once", "reject_always"]
        case .allowOnce: ["allow_once"]
        case .allowForSession: ["allow_always"]
        }
        for kind in kinds {
            if let option = options.first(where: { $0.kind == kind }) { return option }
        }
        return nil
    }
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case user(String, page: OpenPage?)
        case assistant(String)
        case thought(String, expanded: Bool)
        /// fx's notes about the context it built, folded away so they never push the answer down.
        case diagnostics(String, expanded: Bool)
        case tool(ToolCall)
        case error(String)
        case notice(String)
    }

    public let id: Int
    public internal(set) var body: Body
}

@MainActor
public final class ChatModel {
    public enum Status: Equatable, Sendable {
        case idle
        case starting
        case ready
        case working
        case unavailable(String)

        public var title: String {
            switch self {
            case .idle: "Not started"
            case .starting: "Starting..."
            case .ready: "Ready"
            case .working: "Working..."
            // The reason goes into the transcript, where it wraps and can be copied.
            case .unavailable: "Unavailable"
            }
        }
    }

    /// How fx 0.0.12's own notes begin (from the strings in its binary). They stream as assistant
    /// text before the model runs. Deliberately narrow, so anything else stays an answer.
    static let fxDiagnosticStarts = [
        "[context] skill ", "[context] Skill ", "[context] project instruction", "[context] MCP ", "skill discovery warning: ",
    ]

    public static func isFxDiagnostic(_ chunk: String) -> Bool {
        fxDiagnosticStarts.contains { chunk.hasPrefix($0) }
    }

    public static let pageTextLimit = 8000
    /// A page that has not answered by then is sent as address and title only.
    public static let pageTextTimeout: Double = 4

    public private(set) var messages: [ChatMessage] = []
    public private(set) var status: Status = .idle
    /// The agent is blocked until each is answered; the dialog shows the first.
    public private(set) var permissions: [PermissionRequest] = []
    public private(set) var agentName = "Assistant"
    /// The context of the prompt most recently handed to the engine, for the control socket.
    public private(set) var lastSentPage: PageContext?
    /// Called after every change; the view redraws from the model.
    public var onChange: (() -> Void)?

    private var engine: AgentEngine
    private let reader: PageReader
    private let scheduler: Scheduler
    private var nextMessageID = 1
    private var lastRequestID = 0
    /// The prompt waiting for its page text. Status is already `working`, so nothing else can be
    /// sent meanwhile.
    private var waiting: (requestID: Int, text: String, page: OpenPage)?
    // Chunks target these ids rather than the last message, so a notice or error appended mid
    // turn never ends up above text that is still streaming into the reply.
    private var replyID: Int?
    private var thoughtID: Int?
    private var diagnosticsID: Int?
    /// Where the current turn's messages begin.
    private var turnStart = 0

    public init(engine: AgentEngine, reader: PageReader, scheduler: Scheduler) {
        self.engine = engine
        self.reader = reader
        self.scheduler = scheduler
    }

    public var canSend: Bool { status == .ready }
    public var isWorking: Bool { status == .working }

    /// Starts the agent the first time the Explorer Bar opens. Later calls do nothing unless it
    /// is gone.
    public func startIfNeeded() {
        switch status {
        case .idle: restart()
        case .starting, .ready, .working, .unavailable: break
        }
    }

    /// For the Restart button. An engine that exited cannot start again, so the owner passes a
    /// fresh one; events from the old one are ignored from then on.
    public func restart(with fresh: AgentEngine? = nil) {
        if let fresh {
            engine.shutdown()
            engine = fresh
        }
        endTurn()
        status = .starting
        changed()
        engine.start()
    }

    /// With a page, the prompt goes out once its text arrives, or without the text after
    /// `pageTextTimeout` or a failed read.
    @discardableResult
    public func send(_ text: String, page: OpenPage?) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !text.isEmpty else { return false }
        append(.user(text, page: page))
        turnStart = messages.count
        replyID = nil
        thoughtID = nil
        diagnosticsID = nil
        status = .working
        guard let page else {
            lastSentPage = nil
            engine.prompt(text, page: nil)
            changed()
            return true
        }
        lastRequestID += 1
        let id = lastRequestID
        waiting = (id, text, page)
        changed()
        reader.readText(requestID: id, maxChars: Self.pageTextLimit)
        scheduler.after(Self.pageTextTimeout) { [weak self] in
            self?.sendWithoutText(requestID: id, because: "it took too long")
        }
        return true
    }

    /// `text` nil means the page could not be read.
    public func receivePageText(requestID: Int, text: String?, url: String?) {
        guard let (id, prompt, page) = waiting, id == requestID else { return }
        guard let text else {
            sendWithoutText(requestID: id, because: "the page did not answer")
            return
        }
        waiting = nil
        let context = PageContext(url: url ?? page.url, title: page.title, text: String(text.prefix(Self.pageTextLimit)))
        lastSentPage = context
        engine.prompt(prompt, page: context)
        changed()
    }

    private func sendWithoutText(requestID: Int, because reason: String) {
        guard let (id, text, page) = waiting, id == requestID else { return }
        waiting = nil
        append(.notice("Could not read the page text (\(reason)), so only its address and title were sent."))
        let context = PageContext(url: page.url, title: page.title, text: "")
        lastSentPage = context
        engine.prompt(text, page: context)
        changed()
    }

    public func stop() {
        guard isWorking else { return }
        if waiting != nil {
            waiting = nil
            append(.notice("Stopped"))
            status = .ready
            changed()
            return
        }
        permissions = []
        engine.cancel()
        changed()
    }

    public func resolve(_ requestID: String, optionID: String?) {
        guard permissions.contains(where: { $0.requestID == requestID }) else { return }
        permissions.removeAll { $0.requestID == requestID }
        engine.resolvePermission(requestID: requestID, optionID: optionID)
        changed()
    }

    /// Opens or closes a Thinking or fx diagnostics item.
    public func toggleExpanded(_ id: Int) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        switch messages[i].body {
        case let .thought(text, expanded): messages[i].body = .thought(text, expanded: !expanded)
        case let .diagnostics(text, expanded): messages[i].body = .diagnostics(text, expanded: !expanded)
        default: return
        }
        changed()
    }

    public func shutdown() {
        engine.shutdown()
    }

    /// Events from an engine this model no longer uses are dropped.
    public func apply(_ event: AgentEvent, from source: AgentEngine) {
        guard source === engine else { return }
        switch event {
        case let .ready(name, _):
            agentName = name
            if status == .starting { status = .ready }
        case let .messageChunk(text):
            // fx sends its notes before the model runs, so once the model has said anything, every
            // chunk is its answer whatever it starts with.
            if !modelSpokeThisTurn, Self.isFxDiagnostic(text) {
                stream(text, into: &diagnosticsID) { .diagnostics($0, expanded: false) }
            } else {
                stream(text, into: &replyID) { .assistant($0) }
            }
        case let .thoughtChunk(text):
            // Text after a thought is a new reply, so the answer reads below the thinking it came from.
            replyID = nil
            stream(text, into: &thoughtID) { .thought($0, expanded: false) }
        case let .toolCall(id, title, kind, toolStatus):
            replyID = nil
            thoughtID = nil
            append(.tool(ToolCall(id: id, title: title, kind: kind, status: toolStatus)))
        case let .toolCallUpdate(id, toolStatus, title):
            guard let i = messages.lastIndex(where: { if case let .tool(call) = $0.body { call.id == id } else { false } }),
                  case var .tool(call) = messages[i].body else { return }
            if let toolStatus { call.status = toolStatus }
            if let title { call.title = title }
            messages[i].body = .tool(call)
        case let .permissionRequest(requestID, title, detail, options):
            permissions.append(PermissionRequest(requestID: requestID, title: title, detail: detail, options: options))
        case let .turnEnded(stopReason):
            if stopReason == "cancelled" { append(.notice("Stopped")) }
            endTurn()
            if status == .working { status = .ready }
        case let .error(message):
            append(.error(message))
        case let .exited(reason):
            endTurn()
            status = .unavailable(reason)
            append(.error(reason))
        }
        changed()
    }

    private func append(_ body: ChatMessage.Body) {
        messages.append(ChatMessage(id: nextMessageID, body: body))
        nextMessageID += 1
    }

    private func stream(_ text: String, into target: inout Int?, make: (String) -> ChatMessage.Body) {
        if let id = target, let i = messages.lastIndex(where: { $0.id == id }) {
            switch messages[i].body {
            case let .assistant(old): messages[i].body = .assistant(old + text)
            case let .thought(old, expanded): messages[i].body = .thought(old + text, expanded: expanded)
            case let .diagnostics(old, expanded): messages[i].body = .diagnostics(old + text, expanded: expanded)
            default: break
            }
        } else {
            append(make(text))
            target = nextMessageID - 1
        }
    }

    private var modelSpokeThisTurn: Bool {
        messages[turnStart...].contains {
            switch $0.body {
            case .assistant, .thought, .tool: true
            case .user, .diagnostics, .error, .notice: false
            }
        }
    }

    private func endTurn() {
        replyID = nil
        thoughtID = nil
        diagnosticsID = nil
        permissions = []
        waiting = nil
    }

    private func changed() { onChange?() }
}
