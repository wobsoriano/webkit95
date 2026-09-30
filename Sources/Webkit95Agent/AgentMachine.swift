import Foundation

/// Everything the client reacts to, from the public API and from the child alike. One inbox
/// carries all of them, so the order the machine sees is the order events come out.
enum Input: Sendable {
    case start
    case prompt(String, PageContext?)
    case cancel
    case resolvePermission(requestID: String, optionID: String?)
    case shutdown(graceful: Bool)
    /// The client object is gone. The runtime stops once the machine has exited.
    case released
    /// nil when the child is running, else why it could not be launched.
    case launched(failure: String?)
    case message(JSONValue)
    case stderrLine(String)
    /// The child was reaped and its stdout and stderr drained.
    case childExited(status: String)
    case stopDeadline
    /// The agent's time to confirm the ask mode request `requestID` is up.
    case askDeadline(requestID: Int)
}

enum Effect: Equatable {
    case emit(AgentEvent)
    case send(JSONValue)
    case closeStdin
    case signal(Int32)
    case scheduleStopDeadline
    case scheduleAskDeadline(requestID: Int)
    case launch
}

/// How a session selects ask mode, from what session/new advertised.
enum AskSwitch: Equatable {
    case setMode
    case configOption(id: String)
}

/// The client's whole protocol state. Pure: `step` returns effects for the runtime to perform.
///
/// Page text is untrusted input to an agent that runs tools, so the session is held in fx's ask
/// mode: nothing is prompted until the agent confirms ask, and a session that leaves ask is
/// switched back once, then killed.
struct AgentMachine {
    enum Phase {
        case idle
        case starting(Handshake)
        case ready(Session)
        case prompting(Session, Turn)
        /// The child is being killed. Exited follows once it is reaped.
        case failed(Failure)
        /// Shutdown was requested. `exited(reason: "shutdown")` follows the reap or the deadlines.
        case stopping(killed: Bool)
        case exited
    }

    enum Handshake {
        case launching
        case initializing(requestID: Int)
        case creatingSession(requestID: Int, agentName: String)
        case confirmingAsk(requestID: Int, agentName: String, Session)
    }

    struct Session {
        var id: String
        var askSwitch: AskSwitch
        var reassert: Reassert = .unused
    }

    /// Switching back to ask after the agent reported another mode, allowed once per session.
    enum Reassert: Equatable {
        case unused
        case pending(requestID: Int)
        case spent
    }

    struct Turn {
        var requestID: Int
        /// Our request id to the agent's JSON-RPC id, for requests the user has not answered.
        var permissions: [String: JSONValue] = [:]
        /// Every field seen for each tool call, because a permission request may carry only the id.
        var toolCalls: [String: [String: JSONValue]] = [:]
    }

    struct Failure {
        var why: String
        /// Replaces the exit status as the exit reason, for failures the user can act on.
        var userMessage: String?
    }

    static let stderrTailLines = 20
    static let noProvider = "fx has no provider connected. Run fx in a terminal and type /provider."
    static let noAskMode = "fx offered no ask mode, so the assistant is off. Update fx, then click Restart."
    static let askNotConfirmed = "fx did not switch to ask mode, so the assistant is off. Click Restart to try again."
    static let leftAskMode = "fx left ask mode, so the assistant stopped. Click Restart to start over."

    private(set) var phase: Phase = .idle
    let workingDirectory: String
    private var nextRequestID = 1
    private var permissionsIssued = 0
    private var stderrTail: [String] = []

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    var hasExited: Bool {
        if case .exited = phase { return true }
        return false
    }

    private var session: Session? {
        switch phase {
        case .ready(let session), .prompting(let session, _): session
        default: nil
        }
    }

    mutating func step(_ input: Input) -> [Effect] {
        switch input {
        case .start:
            guard case .idle = phase else { return [] }
            phase = .starting(.launching)
            return [.launch]
        case .prompt(let text, let page):
            return prompt(text, page: page)
        case .cancel:
            guard case .prompting(let session, var turn) = phase else { return [] }
            // The cancel goes first so the agent reads its permission replies as part of it.
            let effects = [.send(Wire.cancel(sessionID: session.id))] + cancelAll(&turn)
            phase = .prompting(session, turn)
            return effects
        case .resolvePermission(let requestID, let optionID):
            guard case .prompting(let session, var turn) = phase,
                let wireID = turn.permissions.removeValue(forKey: requestID)
            else { return [.emit(.error("no pending permission request \(requestID)"))] }
            phase = .prompting(session, turn)
            return [.send(Wire.permissionOutcome(id: wireID, optionID: optionID))]
        case .shutdown(let graceful):
            return shutdown(graceful: graceful)
        case .released:
            return []
        case .launched(let failure):
            return launched(failure: failure)
        case .message(let message):
            return receive(message)
        case .stderrLine(let line):
            stderrTail.append(line)
            if stderrTail.count > Self.stderrTailLines { stderrTail.removeFirst() }
            return []
        case .childExited(let status):
            return childExited(status: status)
        case .stopDeadline:
            guard case .stopping(let killed) = phase else { return [] }
            if killed { return exit("shutdown") }
            phase = .stopping(killed: true)
            return [.signal(SIGKILL), .scheduleStopDeadline]
        case .askDeadline(let id):
            if case .starting(.confirmingAsk(id, _, _)) = phase {
                return fail("fx did not answer the ask mode request", userMessage: Self.askNotConfirmed)
            }
            guard session?.reassert == .pending(requestID: id) else { return [] }
            return fail("fx did not answer the request to switch back to ask mode", userMessage: Self.leftAskMode)
        }
    }

    private mutating func prompt(_ text: String, page: PageContext?) -> [Effect] {
        let message: String
        switch phase {
        case .ready(let session) where session.reassert.isPending:
            message = "the agent is switching back to ask mode, try again in a moment"
        case .ready(let session):
            let id = takeRequestID()
            phase = .prompting(session, Turn(requestID: id))
            return [.send(Wire.prompt(id: id, sessionID: session.id, text: text, page: page))]
        // Rejected, not queued: a queued prompt would be answered against a turn the user has
        // not finished reading, and the UI already knows the turn state.
        case .prompting: message = "the agent is still answering, cancel or wait for turn_ended"
        case .idle, .starting: message = "the agent is still starting"
        case .failed(let failure): message = "the agent failed to start: \(failure.userMessage ?? failure.why)"
        case .stopping, .exited: message = "the agent has exited"
        }
        return [.emit(.error(message))]
    }

    private mutating func shutdown(graceful: Bool) -> [Effect] {
        var effects: [Effect] = []
        switch phase {
        case .idle:
            return exit("shutdown")
        case .exited:
            return []
        case .stopping(let killed):
            guard !graceful, !killed else { return [] }
            phase = .stopping(killed: true)
            return [.signal(SIGKILL)]
        case .prompting(let session, var turn):
            effects = [.send(Wire.cancel(sessionID: session.id))] + cancelAll(&turn)
        case .starting, .ready, .failed:
            break
        }
        phase = .stopping(killed: !graceful)
        return effects + [.closeStdin, .signal(graceful ? SIGTERM : SIGKILL), .scheduleStopDeadline]
    }

    private mutating func launched(failure: String?) -> [Effect] {
        switch (phase, failure) {
        case (.starting(.launching), let failure?):
            return exit(failure)
        case (.starting(.launching), nil):
            let id = takeRequestID()
            phase = .starting(.initializing(requestID: id))
            return [.send(Wire.initialize(id: id))]
        case (.stopping, _?):
            return exit("shutdown")
        case (.stopping, nil):
            phase = .stopping(killed: true)
            return [.signal(SIGKILL)]
        case (.exited, nil):
            return [.signal(SIGKILL)]
        default:
            return []
        }
    }

    private mutating func receive(_ message: JSONValue) -> [Effect] {
        // The agent is being killed for a reason the user already sees, so nothing it still says counts.
        if case .failed = phase { return [] }
        let id = message["id"]
        switch (message["method"]?.string, id) {
        case ("session/request_permission"?, let id?):
            return permissionAsked(id: id, params: message["params"] ?? .null)
        case (let method?, let id?):
            return [.send(Wire.methodNotFound(id: id, method: method))]
        case ("session/update"?, nil):
            let update = message["params"]?["update"] ?? .null
            if let mode = Wire.reportedMode(update) { return modeReported(mode) }
            rememberToolCall(update)
            return Wire.event(fromUpdate: update).map { [.emit($0)] } ?? []
        case (_?, nil):
            return []
        case (nil, .int(let id)?):
            return response(id: id, result: message["result"], error: message["error"])
        case (nil, _):
            return []
        }
    }

    private mutating func response(id: Int, result: JSONValue?, error: JSONValue?) -> [Effect] {
        let failure = error.map { $0["message"]?.string ?? $0.serialized() }
        let auth = error.map(Wire.isAuthFailure) == true ? Self.noProvider : nil
        switch phase {
        case .starting(.initializing(id)):
            if let failure { return fail("initialize failed: \(failure)", userMessage: auth) }
            let agentName = result?["agentInfo"]?["name"]?.string ?? "agent"
            let next = takeRequestID()
            phase = .starting(.creatingSession(requestID: next, agentName: agentName))
            return [.send(Wire.newSession(id: next, cwd: workingDirectory))]
        case .starting(.creatingSession(id, let agentName)):
            if let failure { return fail("session/new failed: \(failure)", userMessage: auth) }
            guard let sessionID = result?["sessionId"]?.string else {
                return fail("session/new failed: the response has no sessionId")
            }
            guard let askSwitch = Wire.askSwitch(result) else {
                return fail("session/new offered no ask mode", userMessage: Self.noAskMode)
            }
            let session = Session(id: sessionID, askSwitch: askSwitch)
            let next = takeRequestID()
            phase = .starting(.confirmingAsk(requestID: next, agentName: agentName, session))
            return [.send(Wire.selectAsk(id: next, sessionID: sessionID, via: askSwitch)), .scheduleAskDeadline(requestID: next)]
        case .starting(.confirmingAsk(id, let agentName, let session)):
            if let failure { return fail("ask mode was refused: \(failure)", userMessage: auth ?? Self.askNotConfirmed) }
            guard Wire.confirmsAsk(result, via: session.askSwitch) else {
                return fail("the agent did not confirm ask mode", userMessage: Self.askNotConfirmed)
            }
            phase = .ready(session)
            return [.emit(.ready(agentName: agentName, sessionID: session.id))]
        case .ready(var session) where session.reassert == .pending(requestID: id):
            if let refusal = reassertRefusal(session, result: result, failure: failure) { return refusal }
            session.reassert = .spent
            phase = .ready(session)
            return []
        case .prompting(var session, let turn) where session.reassert == .pending(requestID: id):
            if let refusal = reassertRefusal(session, result: result, failure: failure) { return refusal }
            session.reassert = .spent
            phase = .prompting(session, turn)
            return []
        case .prompting(let session, var turn) where turn.requestID == id:
            if let failure, let auth { return fail("prompt failed: \(failure)", userMessage: auth) }
            var effects = cancelAll(&turn)
            let stopReason: String
            if let failure {
                effects.append(.emit(.error("prompt failed: \(failure)")))
                stopReason = "error"
            } else {
                stopReason = result?["stopReason"]?.string ?? "end_turn"
            }
            phase = .ready(session)
            return effects + [.emit(.turnEnded(stopReason: stopReason))]
        default:
            return []
        }
    }

    private mutating func reassertRefusal(_ session: Session, result: JSONValue?, failure: String?) -> [Effect]? {
        if let failure { return fail("switching back to ask mode was refused: \(failure)", userMessage: Self.leftAskMode) }
        guard Wire.confirmsAsk(result, via: session.askSwitch) else {
            return fail("the agent did not confirm the switch back to ask mode", userMessage: Self.leftAskMode)
        }
        return nil
    }

    /// Any mode but ask ends the turn at once, since the agent may already be running tools
    /// without asking. The first time, ask is selected again; after that the agent is killed.
    private mutating func modeReported(_ mode: String) -> [Effect] {
        guard mode != Wire.askModeID, var session else { return [] }
        switch session.reassert {
        case .pending:
            return []
        case .spent:
            return fail("the agent left ask mode again", userMessage: Self.leftAskMode)
        case .unused:
            let id = takeRequestID()
            session.reassert = .pending(requestID: id)
            var effects: [Effect] = []
            if case .prompting(_, var turn) = phase {
                effects = [.send(Wire.cancel(sessionID: session.id))] + cancelAll(&turn)
                    + [.emit(.error("the agent left ask mode, so this turn was stopped"))]
                phase = .prompting(session, turn)
            } else {
                phase = .ready(session)
            }
            return effects + [
                .send(Wire.selectAsk(id: id, sessionID: session.id, via: session.askSwitch)),
                .scheduleAskDeadline(requestID: id),
            ]
        }
    }

    private mutating func rememberToolCall(_ update: JSONValue) {
        guard case .prompting(let session, var turn) = phase,
            ["tool_call", "tool_call_update"].contains(update["sessionUpdate"]?.string),
            let id = update["toolCallId"]?.string, case .object(let fields) = update
        else { return }
        turn.toolCalls[id, default: [:]].merge(fields.filter { $0.value != .null }) { _, new in new }
        phase = .prompting(session, turn)
    }

    private mutating func permissionAsked(id: JSONValue, params: JSONValue) -> [Effect] {
        guard case .prompting(let session, var turn) = phase else {
            return [.send(Wire.permissionOutcome(id: id, optionID: nil))]
        }
        permissionsIssued += 1
        let requestID = "perm-\(permissionsIssued)"
        turn.permissions[requestID] = id
        phase = .prompting(session, turn)
        var toolCall = params["toolCall"]?["toolCallId"]?.string.flatMap { turn.toolCalls[$0] } ?? [:]
        if case .object(let fields)? = params["toolCall"] {
            toolCall.merge(fields.filter { $0.value != .null }) { _, new in new }
        }
        return [
            .emit(
                .permissionRequest(
                    requestID: requestID,
                    title: toolCall["title"]?.string ?? "Permission requested",
                    detail: Wire.permissionDetail(.object(toolCall)),
                    options: Wire.options(params["options"])))
        ]
    }

    private mutating func childExited(status: String) -> [Effect] {
        var reason = status
        if !stderrTail.isEmpty {
            reason += "\nstderr:\n" + stderrTail.joined(separator: "\n")
        }
        switch phase {
        case .exited: return []
        case .stopping: return exit("shutdown")
        case .failed(let failure): return exit(failure.userMessage ?? "\(failure.why); \(reason)")
        case .starting where Wire.mentionsAuth(stderrTail.joined(separator: "\n")): return exit(Self.noProvider)
        default: return exit(reason)
        }
    }

    /// Kills the agent. A running turn is cancelled first, and its permission requests with it.
    private mutating func fail(_ why: String, userMessage: String? = nil) -> [Effect] {
        var effects: [Effect] = []
        if case .prompting(let session, var turn) = phase {
            effects = [.send(Wire.cancel(sessionID: session.id))] + cancelAll(&turn)
        }
        phase = .failed(Failure(why: why, userMessage: userMessage))
        return effects + [.emit(.error(why)), .signal(SIGKILL)]
    }

    private mutating func exit(_ reason: String) -> [Effect] {
        phase = .exited
        return [.emit(.exited(reason: reason))]
    }

    private func cancelAll(_ turn: inout Turn) -> [Effect] {
        let effects = turn.permissions.values.map { Effect.send(Wire.permissionOutcome(id: $0, optionID: nil)) }
        turn.permissions = [:]
        return effects
    }

    private mutating func takeRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }
}

extension AgentMachine.Reassert {
    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}
