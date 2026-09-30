import Darwin
import Foundation

/// One agent process and its single ACP session. Every method returns immediately and may be
/// called from any thread. Events reach `onEvent` in wire order from the client's own task,
/// never from inside a method call.
public final class AcpClient: Sendable {
    private let inbox: AsyncStream<Input>.Continuation
    private let slot = ChildSlot()

    public init(config: AgentConfig, onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        let (stream, inbox) = AsyncStream<Input>.makeStream()
        self.inbox = inbox
        let slot = slot
        Task.detached {
            var machine = AgentMachine(workingDirectory: config.workingDirectory.path(percentEncoded: false))
            var released = false
            for await input in stream {
                if case .released = input { released = true }
                for effect in machine.step(input) {
                    switch effect {
                    case .emit(let event): onEvent(event)
                    case .send(let message): slot.child?.send(message)
                    case .closeStdin: slot.child?.closeStdin()
                    case .signal(let signal): slot.child?.signalGroup(signal)
                    case .scheduleAskDeadline(let requestID):
                        let delay = config.askConfirmTimeout.components
                        DispatchQueue.global().asyncAfter(
                            deadline: .now() + .seconds(Int(delay.seconds)) + .nanoseconds(Int(delay.attoseconds / 1_000_000_000))
                        ) {
                            inbox.yield(.askDeadline(requestID: requestID))
                        }
                    case .scheduleStopDeadline:
                        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                            inbox.yield(.stopDeadline)
                        }
                    case .launch:
                        Thread.detachNewThread { Launcher.launch(config, slot: slot, inbox: inbox) }
                    }
                }
                if released && machine.hasExited { break }
            }
            inbox.finish()
        }
    }

    deinit {
        inbox.yield(.shutdown(graceful: false))
        inbox.yield(.released)
        // Also kill right here, in case the app is quitting and the client task never runs again.
        slot.child?.signalGroup(SIGKILL)
    }

    /// Spawns the agent and runs the handshake. `ready` or `exited` follows. Later calls do nothing.
    public func start() { inbox.yield(.start) }

    /// Rejected with an `error` event unless the agent is ready and no turn is running.
    public func prompt(_ text: String, page: PageContext?) { inbox.yield(.prompt(text, page)) }

    /// Cancels the running turn and answers its pending permission requests as cancelled.
    public func cancel() { inbox.yield(.cancel) }

    /// `optionID` nil answers the request as cancelled.
    public func resolvePermission(requestID: String, optionID: String?) {
        inbox.yield(.resolvePermission(requestID: requestID, optionID: optionID))
    }

    /// Asks the agent to stop, kills its process group if it has not within two seconds, then
    /// emits `exited(reason: "shutdown")`. Idempotent.
    public func shutdown() { inbox.yield(.shutdown(graceful: true)) }
}
