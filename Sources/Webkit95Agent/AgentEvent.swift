import Foundation

/// The page the user is looking at, sent ahead of their message.
public struct PageContext: Sendable, Equatable, Codable {
    public var url: String
    public var title: String
    public var text: String

    public init(url: String, title: String, text: String) {
        self.url = url
        self.title = title
        self.text = text
    }
}

public struct PermissionOption: Sendable, Equatable {
    public var optionID: String
    public var name: String
    /// The ACP wire name, for example `allow_once` or `reject_once`.
    public var kind: String

    public init(optionID: String, name: String, kind: String) {
        self.optionID = optionID
        self.name = name
        self.kind = kind
    }
}

/// Everything the UI hears from the agent.
public enum AgentEvent: Sendable, Equatable {
    case ready(agentName: String, sessionID: String)
    case messageChunk(String)
    case thoughtChunk(String)
    case toolCall(id: String, title: String, kind: String, status: String)
    /// ACP makes every field of a tool call update optional.
    case toolCallUpdate(id: String, status: String?, title: String?)
    /// `detail` is the tool call's raw input as the user should read it before allowing it.
    case permissionRequest(requestID: String, title: String, detail: String?, options: [PermissionOption])
    case turnEnded(stopReason: String)
    case error(String)
    /// Terminal. Emitted exactly once per client.
    case exited(reason: String)
}
