import Darwin
import Foundation
import Testing
import os

@testable import Webkit95Agent

let fakeAgentScript = URL(filePath: #filePath).deletingLastPathComponent()
    .appending(path: "Resources/fake_agent.py").path(percentEncoded: false)

func fakeConfig(_ arguments: String = "") -> AgentConfig {
    AgentConfig(
        command: ["/bin/sh", "-c", "exec python3 '\(fakeAgentScript)' \(arguments)"],
        workingDirectory: URL(filePath: NSTemporaryDirectory()))
}

/// A fake agent that appends every method it receives to a trace file.
struct TracedFake {
    let config: AgentConfig
    let trace: URL

    init(_ arguments: String = "", askConfirmTimeout: Duration = .seconds(10)) throws {
        trace = try scratchDirectory("trace").appending(path: "methods.txt")
        var config = fakeConfig("--trace '\(trace.path(percentEncoded: false))' \(arguments)")
        config.askConfirmTimeout = askConfirmTimeout
        self.config = config
    }

    var methods: [String] {
        ((try? String(contentsOf: trace, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: trace.deletingLastPathComponent())
    }
}

struct TimedOut: Error, CustomStringConvertible {
    var seen: [AgentEvent]
    var description: String { "timed out waiting for an agent event, saw \(seen)" }
}

/// Collects events from any thread and hands them out in order.
final class EventLog: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (events: [AgentEvent](), cursor: 0))

    func append(_ event: AgentEvent) {
        state.withLock { $0.events.append(event) }
    }

    var all: [AgentEvent] { state.withLock { $0.events } }

    func next(timeout: Duration = .seconds(10)) async throws -> AgentEvent {
        let deadline = ContinuousClock.now + timeout
        while true {
            let event: AgentEvent? = state.withLock { state in
                guard state.cursor < state.events.count else { return nil }
                state.cursor += 1
                return state.events[state.cursor - 1]
            }
            if let event { return event }
            guard ContinuousClock.now < deadline else { throw TimedOut(seen: all) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Events up to and including the first one matching `last`.
    func until(timeout: Duration = .seconds(10), _ last: (AgentEvent) -> Bool) async throws -> [AgentEvent] {
        var seen: [AgentEvent] = []
        while true {
            let event = try await next(timeout: timeout)
            seen.append(event)
            if last(event) { return seen }
        }
    }

    func turn(timeout: Duration = .seconds(10)) async throws -> [AgentEvent] {
        try await until(timeout: timeout) {
            if case .turnEnded = $0 { return true }
            return false
        }
    }

    func exited(timeout: Duration = .seconds(10)) async throws -> [AgentEvent] {
        try await until(timeout: timeout) {
            if case .exited = $0 { return true }
            return false
        }
    }

    /// Whatever arrives within `duration`.
    func quiet(for duration: Duration) async throws -> [AgentEvent] {
        try await Task.sleep(for: duration)
        return state.withLock { state in
            defer { state.cursor = state.events.count }
            return Array(state.events[state.cursor...])
        }
    }
}

struct Harness {
    let client: AcpClient
    let events: EventLog

    static func launch(_ config: AgentConfig) -> Harness {
        let events = EventLog()
        let client = AcpClient(config: config) { events.append($0) }
        client.start()
        return Harness(client: client, events: events)
    }

    static func ready(_ config: AgentConfig = fakeConfig()) async throws -> Harness {
        let harness = launch(config)
        #expect(try await harness.events.next() == .ready(agentName: "fake-agent", sessionID: "sess-1"))
        return harness
    }

    func turn(_ text: String, page: PageContext? = nil) async throws -> [AgentEvent] {
        client.prompt(text, page: page)
        return try await events.turn()
    }
}

func scratchDirectory(_ name: String) throws -> URL {
    let dir = URL(filePath: NSTemporaryDirectory())
        .appending(path: "webkit95-agent-\(name)-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func processGone(_ pid: pid_t, within timeout: Duration = .seconds(3)) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if kill(pid, 0) != 0 { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    return false
}

/// The agent's pid and the pid of a `sleep 300` helper it spawned.
func reportedPIDs(_ harness: Harness) async throws -> [pid_t] {
    let events = try await harness.turn("pids")
    guard case .messageChunk(let text) = events.first else {
        Issue.record("expected a pids chunk, got \(events)")
        return []
    }
    return text.split(separator: " ").compactMap { pid_t($0) }
}
