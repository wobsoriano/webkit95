import Foundation
import Testing

@testable import Webkit95Agent

/// The fake agent starts in code (fx's auto) like fx does. These prove the client never prompts
/// before ask is confirmed and fails closed when it cannot be.
@Suite struct AskModeTests {
    private func failsClosed(
        _ arguments: String, askConfirmTimeout: Duration = .seconds(10), error: String, exitReason: String
    ) async throws {
        let fake = try TracedFake(arguments, askConfirmTimeout: askConfirmTimeout)
        defer { fake.remove() }
        let harness = Harness.launch(fake.config)
        harness.client.prompt("stream", page: nil)
        #expect(try await harness.events.next() == .error("the agent is still starting"))
        #expect(try await harness.events.exited() == [.error(error), .exited(reason: exitReason)])
        harness.client.prompt("stream", page: nil)
        #expect(try await harness.events.next() == .error("the agent has exited"))
        #expect(!fake.methods.contains("session/prompt"), "\(fake.methods)")
    }

    @Test func askIsSelectedAndConfirmedBeforeTheFirstPrompt() async throws {
        let fake = try TracedFake()
        defer { fake.remove() }
        let harness = try await Harness.ready(fake.config)
        #expect(fake.methods == ["initialize", "session/new", "session/set_mode"])
        #expect(try await harness.turn("mode") == [.messageChunk("mode:ask"), .turnEnded(stopReason: "end_turn")])
        #expect(fake.methods == ["initialize", "session/new", "session/set_mode", "session/prompt"])
    }

    @Test func askIsSelectedThroughTheModeConfigOption() async throws {
        let fake = try TracedFake("--config-mode")
        defer { fake.remove() }
        let harness = try await Harness.ready(fake.config)
        #expect(try await harness.turn("mode") == [.messageChunk("mode:ask"), .turnEnded(stopReason: "end_turn")])
        #expect(fake.methods == ["initialize", "session/new", "session/set_config_option", "session/prompt"])
    }

    @Test func failsClosedWhenAskIsNotAdvertised() async throws {
        try await failsClosed("--no-ask", error: "session/new offered no ask mode", exitReason: AgentMachine.noAskMode)
    }

    @Test func failsClosedWhenNoModesAreAdvertised() async throws {
        try await failsClosed("--no-modes", error: "session/new offered no ask mode", exitReason: AgentMachine.noAskMode)
    }

    @Test func failsClosedWhenAskIsRefused() async throws {
        try await failsClosed(
            "--refuse-mode", error: "ask mode was refused: mode change not allowed", exitReason: AgentMachine.askNotConfirmed)
    }

    @Test func failsClosedWhenAskIsNeverConfirmed() async throws {
        try await failsClosed(
            "--silent-mode", askConfirmTimeout: .milliseconds(300), error: "fx did not answer the ask mode request",
            exitReason: AgentMachine.askNotConfirmed)
    }

    @Test func leavingAskStopsTheTurnThenAskIsSelectedAgainOnce() async throws {
        let fake = try TracedFake()
        defer { fake.remove() }
        let harness = try await Harness.ready(fake.config)
        #expect(
            try await harness.turn("flip") == [
                .error("the agent left ask mode, so this turn was stopped"), .messageChunk("flipped"),
                .turnEnded(stopReason: "cancelled"),
            ])
        #expect(try await harness.events.quiet(for: .milliseconds(300)) == [])
        #expect(try await harness.turn("mode") == [.messageChunk("mode:ask"), .turnEnded(stopReason: "end_turn")])

        harness.client.prompt("flip", page: nil)
        let events = try await harness.events.exited()
        #expect(events == [.error("the agent left ask mode again"), .exited(reason: AgentMachine.leftAskMode)])
        #expect(fake.methods.filter { $0 == "session/set_mode" }.count == 2)
        #expect(!fake.methods.contains { $0.hasPrefix("prompt-in-") }, "\(fake.methods)")
    }

    @Test func failsClosedWhenSwitchingBackIsRefused() async throws {
        let fake = try TracedFake("--refuse-reassert")
        defer { fake.remove() }
        let harness = try await Harness.ready(fake.config)
        harness.client.prompt("flip", page: nil)
        let events = try await harness.events.exited()
        #expect(
            events == [
                .error("the agent left ask mode, so this turn was stopped"), .messageChunk("flipped"),
                .turnEnded(stopReason: "cancelled"),
                .error("switching back to ask mode was refused: mode change not allowed"),
                .exited(reason: AgentMachine.leftAskMode),
            ])
        #expect(fake.methods.filter { $0 == "session/prompt" }.count == 1)
    }

    @Test func authRequiredAtSessionNewSaysToConnectAProvider() async throws {
        try await failsClosed(
            "--auth-session", error: "session/new failed: Authentication required", exitReason: AgentMachine.noProvider)
    }

    @Test func aProviderErrorOnStderrDuringStartSaysToConnectAProvider() async throws {
        let harness = Harness.launch(fakeConfig("--auth-exit"))
        #expect(try await harness.events.next() == .exited(reason: AgentMachine.noProvider))
    }

    @Test func aProviderErrorFromAPromptSaysToConnectAProvider() async throws {
        let harness = try await Harness.ready()
        harness.client.prompt("authfail", page: nil)
        #expect(
            try await harness.events.exited() == [
                .error("prompt failed: No provider credentials found"), .exited(reason: AgentMachine.noProvider),
            ])
    }
}
