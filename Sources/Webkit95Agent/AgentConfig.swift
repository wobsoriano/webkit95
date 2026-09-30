import Darwin
import Foundation

public struct AgentConfig: Sendable, Equatable {
    public static let commandEnvironmentKey = "WEBKIT95_AGENT_COMMAND"
    /// An fx model id, passed as `fx acp --model <id>`.
    public static let modelEnvironmentKey = "WEBKIT95_AGENT_MODEL"
    /// "1" gives the `WEBKIT95_AGENT_COMMAND` agent the isolated HOME too. fx always gets it.
    public static let isolateHomeEnvironmentKey = "WEBKIT95_AGENT_ISOLATE_HOME"
    public static let fxNotFound =
        "fx not found. Install it with: curl -fsSL https://fx.sh/setup.sh | bash, then connect a provider by running fx and typing /provider."

    /// argv. A program without a slash is looked up at `start()` on the login shell PATH followed
    /// by the usual user install dirs, because a GUI app's own PATH lacks them.
    public var command: [String]
    /// The child's working directory. fx takes it as the workspace.
    public var workingDirectory: URL
    /// Added to the app's environment for the child.
    public var environment: [String: String]
    /// The child's HOME, prepared by `IsolatedHome` before launch. nil keeps the app's HOME.
    public var isolatedHome: URL?
    /// Where a bare program name is looked up. nil probes the login shell. Tests pin it.
    var searchDirectories: [URL]?
    /// How long the agent has to confirm ask mode before the client gives up on it.
    var askConfirmTimeout: Duration = .seconds(10)

    public init(command: [String], workingDirectory: URL, environment: [String: String] = [:]) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// `fx acp` in the per user workspace with the model from `WEBKIT95_AGENT_MODEL`, unless
    /// `WEBKIT95_AGENT_COMMAND` holds a shell command to run instead. Creates the workspace.
    public static func fromEnvironment() throws(InvalidAgentModel) -> AgentConfig {
        try fromEnvironment(ProcessInfo.processInfo.environment)
    }

    /// Spawned directly rather than through `zsh -lc`, because anything a shell profile prints to
    /// stdout would land in the ACP stream.
    public static func fx(workingDirectory: URL, model: String?, home: URL) throws(InvalidAgentModel) -> AgentConfig {
        var command = ["fx", "acp"]
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            guard isPlainModelID(model) else { throw InvalidAgentModel() }
            command += ["--model", model]
        }
        // fx runs a new session in its configured permission mode until the client selects one, so
        // an inherited full-access setting must not cover the moments before session/set_mode.
        var config = AgentConfig(command: command, workingDirectory: workingDirectory, environment: ["FX_PERMISSION_MODE": "ask"])
        config.isolatedHome = home
        return config
    }

    /// A leading dash would read as an fx flag.
    static func isPlainModelID(_ model: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/:@+-")
        return model.count <= 200 && model.first != "-" && model.allSatisfy(allowed.contains)
    }

    static func fromEnvironment(_ env: [String: String]) throws(InvalidAgentModel) -> AgentConfig {
        let home = env["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let fxHome = home.appending(path: "Library/Application Support/webkit95/fx-home")
        // fx also reads skills from every folder above its workspace, so a workspace anywhere under
        // the user's home would hand it ~/.claude/skills again (docs/agent-notes.md).
        let temp = env["TMPDIR"].map { URL(filePath: $0, directoryHint: .isDirectory) } ?? URL(filePath: NSTemporaryDirectory())
        let workspace = temp.appending(path: "webkit95-agent-workspace")
        // A failure here surfaces as the launch failing to enter the directory.
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let command = env[commandEnvironmentKey], !command.trimmingCharacters(in: .whitespaces).isEmpty {
            // No login profile, so nothing a profile prints can land on the protocol's stdout.
            var config = AgentConfig(command: ["/bin/sh", "-c", "exec \(command)"], workingDirectory: workspace)
            if env[isolateHomeEnvironmentKey] == "1" { config.isolatedHome = fxHome }
            return config
        }
        return try fx(workingDirectory: workspace, model: env[modelEnvironmentKey], home: fxHome)
    }
}

/// The value is left out of the message on purpose: it came from the environment.
public struct InvalidAgentModel: Error, Equatable, CustomStringConvertible {
    public var description: String {
        "WEBKIT95_AGENT_MODEL must be one fx model id such as provider/model, with no spaces or shell characters."
    }
}
