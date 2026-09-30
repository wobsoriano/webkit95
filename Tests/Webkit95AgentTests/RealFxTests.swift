import Darwin
import Foundation
import Testing

@testable import Webkit95Agent

/// Talks to the real `fx acp`, found the way the app finds it (login shell PATH probe). Needs fx
/// installed and a provider connected (fx, then /provider, or AI_GATEWAY_API_KEY, VERCEL_OIDC_TOKEN
/// and FX_PROVIDER in the environment). Uses `freeModel` unless WEBKIT95_AGENT_MODEL is set.
/// Run with `WEBKIT95_REAL_AGENT=1 swift test --filter RealFxTests`.
///
/// Sends only synthetic text from a scratch workspace holding two synthetic files, and never
/// approves a tool call.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["WEBKIT95_REAL_AGENT"] == "1"))
struct RealFxTests {
    /// Listed free on the AI Gateway (usage_update reported cost 0 USD). The gateway resolved it to
    /// inclusionai/ling-3.1-flash, which answered in 10 s to 150 s in the runs recorded in
    /// docs/fx-wire-capture.md, hence the long turn timeout.
    static let freeModel = "inclusionai/ling-3.1-flash-free"
    static let turnTimeout: Duration = .seconds(300)

    private func workspace(_ name: String) throws -> URL {
        let dir = try scratchDirectory("fx-\(name)")
        try "alpha\n".write(to: dir.appending(path: "synthetic-alpha.txt"), atomically: true, encoding: .utf8)
        try "beta\n".write(to: dir.appending(path: "synthetic-beta.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    /// A sibling of the workspace, so fx never sees its own home as a workspace file.
    private func home(for cwd: URL) -> URL {
        URL(filePath: cwd.path(percentEncoded: false).trimmingSuffix("/") + "-home", directoryHint: .isDirectory)
    }

    /// `ready` is emitted only after fx confirmed ask mode, so reaching it proves the mode switch.
    /// Everything before it (an error line, an exit) is collected so a failure shows what fx said.
    private func launch(_ cwd: URL) async throws -> Harness {
        let model = ProcessInfo.processInfo.environment[AgentConfig.modelEnvironmentKey] ?? Self.freeModel
        let harness = Harness.launch(try AgentConfig.fx(workingDirectory: cwd, model: model, home: home(for: cwd)))
        let seen = try await harness.events.until(timeout: Self.turnTimeout) {
            switch $0 {
            case .ready, .exited: true
            default: false
            }
        }
        seen.forEach { print("real fx: \($0)") }
        guard case .ready? = seen.last else {
            Issue.record("expected ready, got \(seen)")
            throw TimedOut(seen: seen)
        }
        return harness
    }

    /// Shuts down and proves no process that ran in the workspace survives.
    private func shutDown(_ harness: Harness, cwd: URL) async throws {
        let before = processes(in: cwd)
        #expect(!before.isEmpty, "fx acp was running in the workspace")
        harness.client.shutdown()
        #expect(try await harness.events.exited().last == .exited(reason: "shutdown"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(before.filter { kill($0, 0) == 0 } == [], "processes left from the agent")
        #expect(processes(in: cwd) == [], "processes left in the workspace")
        try? FileManager.default.removeItem(at: cwd)
        try? FileManager.default.removeItem(at: home(for: cwd))
    }

    /// Every process whose working directory is `cwd`, from `lsof -d cwd`.
    private func processes(in cwd: URL) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-d", "cwd", "-F", "pn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // lsof prints /private/var/..., which URL.resolvingSymlinksInPath() folds back to /var/...
        let path = cwd.path(percentEncoded: false)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let target = realpath(path, &buffer).map { String(cString: $0) } ?? path
        var pid: pid_t?
        var found: [pid_t] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p") { pid = pid_t(line.dropFirst()) }
            if line.hasPrefix("n"), let pid, String(line.dropFirst()).trimmingSuffix("/") == target.trimmingSuffix("/") {
                found.append(pid)
            }
        }
        return found
    }

    private func replyText(_ events: [AgentEvent]) -> String {
        events.compactMap { if case .messageChunk(let text) = $0 { text } else { nil } }.joined()
    }

    /// Also proves the isolated HOME: fx still finds its key, reports no skill catalog, and keeps its
    /// session in its own home rather than the user's ~/.fx.
    @Test func handshakeInAskModeAndASyntheticPrompt() async throws {
        let cwd = try workspace("pong")
        let userSessions = (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.fx/sessions"
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: userSessions)) ?? [])
        let harness = try await launch(cwd)
        harness.client.prompt("Reply with the single word pong and nothing else. Do not use any tools.", page: nil)
        let events = try await harness.events.turn(timeout: Self.turnTimeout)
        events.forEach { print("real fx: \($0)") }
        let reply = replyText(events)
        #expect(reply.lowercased().contains("pong"), "reply was \(reply)")
        #expect(!reply.contains("skill catalog") && !reply.contains("skill discovery"), "fx still read skills: \(reply)")
        #expect(events.last == .turnEnded(stopReason: "end_turn"))
        let own = (try? FileManager.default.contentsOfDirectory(atPath: home(for: cwd).path(percentEncoded: false) + "/.fx/sessions")) ?? []
        #expect(own.count == 1, "fx sessions in its own home: \(own)")
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: userSessions)) ?? [])
        #expect(after.subtracting(before).isEmpty, "fx wrote a session to ~/.fx: \(after.subtracting(before))")
        try await shutDown(harness, cwd: cwd)
    }

    /// A fresh session per answer, because a model that saw its command refused tends to reach for
    /// another tool next time instead of asking again.
    private func deniedCommandNeverRuns(answer: ([PermissionOption]) -> String?) async throws {
        let cwd = try workspace("deny")
        let harness = try await launch(cwd)
        harness.client.prompt("Use your shell tool to run exactly this command: ls -la", page: nil)
        let asked = try await harness.events.until(timeout: Self.turnTimeout) {
            switch $0 {
            case .permissionRequest, .turnEnded: true
            default: false
            }
        }
        asked.forEach { print("real fx: \($0)") }
        guard case .permissionRequest(let requestID, _, let detail, let options)? = asked.last else {
            Issue.record("fx ended the turn without asking to run the command")
            try await shutDown(harness, cwd: cwd)
            return
        }
        #expect(detail?.contains("ls") == true, "detail \(String(describing: detail))")
        #expect(Set(options.map(\.kind)).isSuperset(of: ["allow_once", "reject_once"]), "\(options)")
        let toolCallID = asked.reversed().compactMap { event -> String? in
            if case .toolCall(let id, _, _, _) = event { id } else { nil }
        }.first

        let held = try await harness.events.quiet(for: .seconds(5))
        held.forEach { print("real fx (while held): \($0)") }
        for event in held {
            switch event {
            case .turnEnded, .toolCallUpdate(_, "completed"?, _):
                Issue.record("turn moved on while the permission was unanswered: \(event)")
            default: break
            }
        }

        harness.client.resolvePermission(requestID: requestID, optionID: answer(options))
        let rest = try await harness.events.turn(timeout: Self.turnTimeout)
        rest.forEach { print("real fx: \($0)") }
        let finalStatus = rest.reversed().compactMap { event -> String? in
            if case .toolCallUpdate(toolCallID, let status?, _) = event { status } else { nil }
        }.first
        #expect(finalStatus != "completed", "the denied command ran")
        try await shutDown(harness, cwd: cwd)
    }

    @Test func permissionCancelledIsHeldThenDenied() async throws {
        try await deniedCommandNeverRuns { _ in nil }
    }

    @Test func permissionRejectedIsHeldThenDenied() async throws {
        try await deniedCommandNeverRuns { options in options.first { $0.kind == "reject_once" }?.optionID }
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
