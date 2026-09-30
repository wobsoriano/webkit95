import Foundation
import Testing
import Webkit95Agent
@testable import Webkit95Kit

@MainActor
final class FakeEngine: AgentEngine {
    var calls: [String] = []
    var prompts: [(String, PageContext?)] = []
    func start() { calls.append("start") }
    func prompt(_ text: String, page: PageContext?) { calls.append("prompt"); prompts.append((text, page)) }
    func cancel() { calls.append("cancel") }
    func resolvePermission(requestID: String, optionID: String?) { calls.append("resolve \(requestID) \(optionID ?? "nil")") }
    func shutdown() { calls.append("shutdown") }
}

@MainActor
final class FakeReader: PageReader {
    var requests: [Int] = []
    func readText(requestID: Int, maxChars: Int) { requests.append(requestID) }
}

@MainActor
final class ManualScheduler: Scheduler {
    var pending: [@MainActor () -> Void] = []
    func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) { pending.append(work) }
    func fire() { let p = pending; pending = []; p.forEach { $0() } }
}

@MainActor
@Suite struct ChatModelTests {
    let engine = FakeEngine()
    let reader = FakeReader()
    let scheduler = ManualScheduler()

    func ready() -> ChatModel {
        let chat = ChatModel(engine: engine, reader: reader, scheduler: scheduler)
        chat.startIfNeeded()
        chat.apply(.ready(agentName: "fx", sessionID: "s"), from: engine)
        return chat
    }

    @Test func startsOnceAndBecomesReady() {
        let chat = ChatModel(engine: engine, reader: reader, scheduler: scheduler)
        chat.startIfNeeded()
        #expect(chat.status == .starting)
        chat.startIfNeeded()
        #expect(engine.calls == ["start"])
        chat.apply(.ready(agentName: "fx", sessionID: "s"), from: engine)
        #expect(chat.status == .ready)
        #expect(chat.agentName == "fx")
    }

    @Test func cannotSendBeforeReadyOrBlank() {
        let chat = ChatModel(engine: engine, reader: reader, scheduler: scheduler)
        #expect(!chat.send("hi", page: nil))
        let r = ready()
        #expect(!r.send("   ", page: nil))
    }

    @Test func streamsIntoOneReplyEvenWithANoticeBetween() {
        let chat = ready()
        chat.send("hi", page: nil)
        chat.apply(.thoughtChunk("hm"), from: engine)
        chat.apply(.messageChunk("Hel"), from: engine)
        chat.apply(.error("warning"), from: engine)
        chat.apply(.messageChunk("lo"), from: engine)
        chat.apply(.thoughtChunk("m"), from: engine)
        #expect(chat.messages.map(\.body) == [
            .user("hi", page: nil), .thought("hmm", expanded: false), .assistant("Hello"), .error("warning"),
        ])
        chat.apply(.turnEnded(stopReason: "end_turn"), from: engine)
        #expect(chat.status == .ready)
    }

    @Test func aThoughtSplitsTheReplySoTheAnswerFollowsIt() {
        let chat = ready()
        chat.send("hi", page: nil)
        chat.apply(.messageChunk("Let me see."), from: engine)
        chat.apply(.thoughtChunk("The user wants pong"), from: engine)
        chat.apply(.messageChunk("po"), from: engine)
        chat.apply(.messageChunk("ng"), from: engine)
        #expect(chat.messages.map(\.body) == [
            .user("hi", page: nil), .assistant("Let me see."),
            .thought("The user wants pong", expanded: false), .assistant("pong"),
        ])
    }

    static let catalogLine = "[context] skill catalog shortened 104 descriptions: effective=20968 bytes source=compiled default\n"
    static let discoveryLine = "skill discovery warning: candidate \"/Users/u/.claude/skills/x\" was skipped because its metadata is invalid (unsupported_multiline)"

    @Test func fxDiagnosticsAreRecognizedByTheirOwnPrefixesOnly() {
        for line in [Self.catalogLine, Self.discoveryLine, "[context] project instructions omitted 2 source(s)", "[context] MCP search omitted 3 tool(s)", "[context] Skill content truncated"] {
            #expect(ChatModel.isFxDiagnostic(line), "\(line)")
        }
        for text in ["pong", "[context]", "[context] ", "[context] the page says", " [context] skill catalog", "Skill discovery warning: x", "The skill discovery warning: means", "", "\n[context] skill catalog"] {
            #expect(!ChatModel.isFxDiagnostic(text), "\(text)")
        }
    }

    @Test func fxDiagnosticsFoldIntoOneCollapsedItemAboveTheAnswer() {
        let chat = ready()
        chat.send("hi", page: nil)
        chat.apply(.messageChunk(Self.catalogLine), from: engine)
        chat.apply(.messageChunk(Self.discoveryLine), from: engine)
        chat.apply(.thoughtChunk("The user wants pong"), from: engine)
        chat.apply(.messageChunk("pong"), from: engine)
        #expect(chat.messages.map(\.body) == [
            .user("hi", page: nil), .diagnostics(Self.catalogLine + Self.discoveryLine, expanded: false),
            .thought("The user wants pong", expanded: false), .assistant("pong"),
        ])
        chat.apply(.turnEnded(stopReason: "end_turn"), from: engine)
        chat.send("again", page: nil)
        chat.apply(.messageChunk(Self.catalogLine), from: engine)
        chat.apply(.messageChunk("pong"), from: engine)
        #expect(chat.messages.suffix(3).map(\.body) == [
            .user("again", page: nil), .diagnostics(Self.catalogLine, expanded: false), .assistant("pong"),
        ])
    }

    @Test func textThatLooksLikeADiagnosticIsStillTheAnswerOnceTheModelSpoke() {
        let chat = ready()
        chat.send("a", page: nil)
        chat.apply(.messageChunk("Answer: "), from: engine)
        chat.apply(.messageChunk(Self.catalogLine), from: engine)
        #expect(chat.messages.last?.body == .assistant("Answer: " + Self.catalogLine))
        chat.apply(.turnEnded(stopReason: "end_turn"), from: engine)
        chat.send("b", page: nil)
        chat.apply(.thoughtChunk("quote fx"), from: engine)
        chat.apply(.messageChunk(Self.discoveryLine), from: engine)
        #expect(chat.messages.last?.body == .assistant(Self.discoveryLine))
        chat.apply(.turnEnded(stopReason: "end_turn"), from: engine)
        chat.send("c", page: nil)
        chat.apply(.toolCall(id: "t", title: "Read", kind: "read", status: "pending"), from: engine)
        chat.apply(.messageChunk(Self.catalogLine), from: engine)
        #expect(chat.messages.last?.body == .assistant(Self.catalogLine))
        #expect(!chat.messages.contains { if case .diagnostics = $0.body { true } else { false } })
    }

    @Test func aToolCallSplitsTheReply() {
        let chat = ready()
        chat.send("go", page: nil)
        chat.apply(.messageChunk("a"), from: engine)
        chat.apply(.toolCall(id: "t1", title: "Run ls", kind: "execute", status: "pending"), from: engine)
        chat.apply(.toolCallUpdate(id: "t1", status: "completed", title: nil), from: engine)
        chat.apply(.messageChunk("b"), from: engine)
        #expect(chat.messages.map(\.body) == [
            .user("go", page: nil), .assistant("a"),
            .tool(ToolCall(id: "t1", title: "Run ls", kind: "execute", status: "completed")), .assistant("b"),
        ])
    }

    @Test func pageTextReachesThePrompt() {
        let chat = ready()
        chat.send("summarize", page: OpenPage(url: "http://x/", title: "X"))
        #expect(engine.prompts.isEmpty)
        #expect(reader.requests == [1])
        chat.receivePageText(requestID: 1, text: String(repeating: "a", count: 9000), url: "http://x/final")
        #expect(engine.prompts.count == 1)
        #expect(engine.prompts[0].1?.text.count == ChatModel.pageTextLimit)
        #expect(engine.prompts[0].1?.url == "http://x/final")
        #expect(chat.lastSentPage?.title == "X")
        scheduler.fire()
        #expect(engine.prompts.count == 1)
    }

    @Test func slowPageFallsBackToAddressAndTitleWithANotice() {
        let chat = ready()
        chat.send("summarize", page: OpenPage(url: "http://x/", title: "X"))
        scheduler.fire()
        #expect(engine.prompts.count == 1)
        #expect(engine.prompts[0].1 == PageContext(url: "http://x/", title: "X", text: ""))
        if case .notice = chat.messages.last?.body {} else { Issue.record("no notice") }
        chat.receivePageText(requestID: 1, text: "late", url: nil)
        #expect(engine.prompts.count == 1)
    }

    @Test func permissionsQueueAndResolve() {
        let chat = ready()
        chat.send("tool", page: nil)
        let options = [
            PermissionOption(optionID: "a1", name: "Allow", kind: "allow_once"),
            PermissionOption(optionID: "a2", name: "Always", kind: "allow_always"),
            PermissionOption(optionID: "r1", name: "Reject", kind: "reject_once"),
        ]
        chat.apply(.permissionRequest(requestID: "p1", title: "Run ls", detail: "ls -la", options: options), from: engine)
        chat.apply(.permissionRequest(requestID: "p2", title: "Edit", detail: nil, options: options), from: engine)
        #expect(chat.permissions.map(\.requestID) == ["p1", "p2"])
        let first = chat.permissions[0]
        #expect(first.option(for: .reject)?.optionID == "r1")
        #expect(first.option(for: .allowOnce)?.optionID == "a1")
        #expect(first.option(for: .allowForSession)?.optionID == "a2")
        chat.resolve("p1", optionID: "r1")
        chat.resolve("p1", optionID: "a1")
        #expect(engine.calls.filter { $0.hasPrefix("resolve") } == ["resolve p1 r1"])
        chat.apply(.turnEnded(stopReason: "end_turn"), from: engine)
        #expect(chat.permissions.isEmpty)
    }

    @Test func missingSessionOptionIsNil() {
        let r = PermissionRequest(requestID: "p", title: "t", detail: nil, options: [PermissionOption(optionID: "o", name: "Allow", kind: "allow_once")])
        #expect(r.option(for: .allowForSession) == nil)
        #expect(r.option(for: .reject) == nil)
    }

    @Test func stopWhileWaitingForPageNeverPrompts() {
        let chat = ready()
        chat.send("x", page: OpenPage(url: "u", title: "t"))
        chat.stop()
        #expect(chat.status == .ready)
        chat.receivePageText(requestID: 1, text: "late", url: nil)
        scheduler.fire()
        #expect(engine.prompts.isEmpty)
    }

    @Test func stopDuringTurnCancels() {
        let chat = ready()
        chat.send("x", page: nil)
        chat.stop()
        #expect(engine.calls.last == "cancel")
        chat.apply(.turnEnded(stopReason: "cancelled"), from: engine)
        #expect(chat.messages.last?.body == .notice("Stopped"))
        #expect(chat.status == .ready)
    }

    @Test func exitMakesItUnavailableAndRestartIgnoresTheOldEngine() {
        let chat = ready()
        chat.apply(.exited(reason: "fx not found"), from: engine)
        #expect(chat.status == .unavailable("fx not found"))
        #expect(chat.status.title == "Unavailable")
        #expect(chat.messages.last?.body == .error("fx not found"))
        let fresh = FakeEngine()
        chat.restart(with: fresh)
        #expect(engine.calls.last == "shutdown")
        #expect(fresh.calls == ["start"])
        chat.apply(.exited(reason: "late"), from: engine)
        #expect(chat.status == .starting)
        chat.apply(.ready(agentName: "n", sessionID: "s2"), from: fresh)
        #expect(chat.status == .ready)
    }

    @Test func thoughtsToggle() {
        let chat = ready()
        chat.send("x", page: nil)
        chat.apply(.thoughtChunk("t"), from: engine)
        let id = chat.messages.last!.id
        chat.toggleExpanded(id)
        #expect(chat.messages.last?.body == .thought("t", expanded: true))
    }

    @Test func diagnosticsToggle() {
        let chat = ready()
        chat.send("x", page: nil)
        chat.apply(.messageChunk(Self.catalogLine), from: engine)
        let id = chat.messages.last!.id
        chat.toggleExpanded(id)
        #expect(chat.messages.last?.body == .diagnostics(Self.catalogLine, expanded: true))
        chat.toggleExpanded(id)
        #expect(chat.messages.last?.body == .diagnostics(Self.catalogLine, expanded: false))
    }
}
