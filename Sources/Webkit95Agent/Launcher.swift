import Darwin
import Foundation

/// A launch with every lookup done, ready to spawn.
struct Resolved: Equatable {
    var path: String
    var argv: [String]
    var environment: [String: String]
}

enum Launcher {
    static let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
    /// `.local/bin` is where the fx installer puts fx unless FX_INSTALL_DIR says otherwise.
    static let fallbackHomeDirectories = [".local/bin", ".bun/bin", ".cargo/bin"]
    static let systemDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static func resolve(
        _ config: AgentConfig, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<Resolved, LaunchFailure> {
        guard let program = config.command.first, !program.isEmpty else {
            return .failure(LaunchFailure("the agent command is empty"))
        }
        var environment = baseEnvironment
        var path = program
        if !program.contains("/") {
            let dirs = config.searchDirectories?.map { $0.path(percentEncoded: false) }
                ?? searchDirectories(loginPath: LoginShell.cachedPath, home: baseEnvironment["HOME"] ?? NSHomeDirectory())
            guard let found = dirs.lazy.map({ ($0 as NSString).appendingPathComponent(program) }).first(where: isExecutable)
            else { return .failure(LaunchFailure(program == "fx" ? AgentConfig.fxNotFound : "\(program) not found")) }
            path = found
            environment["PATH"] = unique(dirs + systemDirectories).joined(separator: ":")
        }
        environment.merge(config.environment) { _, override in override }
        if let home = config.isolatedHome { environment["HOME"] = home.path(percentEncoded: false) }
        return .success(Resolved(path: path, argv: config.command, environment: environment))
    }

    static func searchDirectories(loginPath: String?, home: String) -> [String] {
        let login = loginPath?.split(separator: ":").map(String.init) ?? []
        let homeDirs = fallbackHomeDirectories.map { (home as NSString).appendingPathComponent($0) }
        return unique(login + fallbackDirectories + homeDirs)
    }

    private static func unique(_ dirs: [String]) -> [String] {
        var seen = Set<String>()
        return dirs.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && access(path, X_OK) == 0
    }

    /// Spawns the agent and wires its streams into `inbox`. Runs off the inbox because the PATH
    /// probe can take seconds.
    static func launch(_ config: AgentConfig, slot: ChildSlot, inbox: AsyncStream<Input>.Continuation) {
        let resolved: Resolved
        switch resolve(config) {
        case .success(let value): resolved = value
        case .failure(let failure):
            inbox.yield(.launched(failure: failure.reason))
            return
        }
        if let home = config.isolatedHome,
            let failure = IsolatedHome.prepare(home, realHome: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
        {
            inbox.yield(.launched(failure: failure.reason))
            return
        }
        let spawned: Spawned
        do {
            spawned = try spawnInOwnGroup(
                path: resolved.path, argv: resolved.argv, environment: resolved.environment,
                cwd: config.workingDirectory.path(percentEncoded: false), pipeStdin: true, pipeStderr: true)
        } catch {
            let command = resolved.argv.joined(separator: " ")
            inbox.yield(.launched(failure: "could not launch agent \(command): \(error)"))
            return
        }
        guard let stdin = spawned.stdin, let stderr = spawned.stderr else {
            inbox.yield(.launched(failure: "agent stdio was not captured"))
            return
        }
        let child = Child(pid: spawned.pid, stdin: stdin)
        slot.set(child)
        inbox.yield(.launched(failure: nil))

        let streams = DispatchGroup()
        readLines(spawned.stdout, done: streams) { line in
            // A malformed line is dropped. The agent's next valid message still gets through.
            if let message = JSONValue.parse(line) { inbox.yield(.message(message)) }
        }
        readLines(stderr, done: streams) { line in
            inbox.yield(.stderrLine(String(decoding: line, as: UTF8.self)))
        }
        Thread.detachNewThread {
            let status = child.reap()
            // A process that left the group could hold the pipes open, so the drain is bounded.
            _ = streams.wait(timeout: .now() + .milliseconds(500))
            inbox.yield(.childExited(status: status))
        }
    }
}

struct LaunchFailure: Error, Equatable {
    var reason: String
    init(_ reason: String) { self.reason = reason }
}

enum LoginShell {
    static let timeout: Duration = .seconds(4)
    /// Probed once per process, on first use.
    static let cachedPath: String? = probePath()

    /// The PATH an interactive login zsh ends up with, so both .zprofile and .zshrc edits apply.
    /// nil when the shell fails, hangs past `timeout`, or never prints the markers.
    static func probePath(environment overrides: [String: String] = [:], timeout: Duration = timeout) -> String? {
        probe(expression: "\"$PATH\"", environment: overrides, timeout: timeout)
    }

    /// What `expression`, a zsh word, expands to in an interactive login zsh. nil when the shell
    /// fails, hangs past `timeout`, never prints the markers, or the expansion is empty.
    static func probe(expression: String, environment overrides: [String: String] = [:], timeout: Duration = timeout)
        -> String?
    {
        let nonce = "\(getpid())_\(UInt64.random(in: 0...UInt64.max))"
        // The markers carry a nonce so nothing a profile prints can pass for the answer.
        let begin = "__WEBKIT95_PATH_BEGIN_\(nonce)__"
        let end = "__WEBKIT95_PATH_END_\(nonce)__"
        var environment = ProcessInfo.processInfo.environment
        environment.merge(overrides) { _, override in override }
        guard
            let spawned = try? spawnInOwnGroup(
                path: "/bin/zsh", argv: ["/bin/zsh", "-lic", "printf '%s%s%s' '\(begin)' \(expression) '\(end)'"],
                environment: environment, cwd: nil, pipeStdin: false, pipeStderr: false)
        else { return nil }
        let deadline = ContinuousClock.now + timeout
        var output = Data()
        var found: String?
        var buffer = [UInt8](repeating: 0, count: 4096)
        while found == nil {
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { break }
            var poller = pollfd(fd: spawned.stdout, events: Int16(POLLIN), revents: 0)
            let millis = Int32(left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000) + 1
            let ready = poll(&poller, 1, millis)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break }
            let count = buffer.withUnsafeMutableBytes { read(spawned.stdout, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            output.append(contentsOf: buffer[0..<count])
            found = between(String(decoding: output, as: UTF8.self), begin: begin, end: end)
        }
        // The answer is in hand or overdue, either way nothing the profile still runs matters.
        killpg(spawned.pid, SIGKILL)
        close(spawned.stdout)
        var status: Int32 = 0
        while waitpid(spawned.pid, &status, 0) < 0 && errno == EINTR {}
        return found?.isEmpty == false ? found : nil
    }

    static func between(_ text: String, begin: String, end: String) -> String? {
        guard let start = text.range(of: begin, options: .backwards),
            let stop = text.range(of: end, range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<stop.lowerBound])
    }
}

/// Reads environment variables a person set in their shell profile, for an app launched from the
/// Dock that never ran that profile.
public enum LoginShellVariable {
    /// The value of the first of `names` that the login shell has set and non empty. nil when none
    /// is, when `names` is empty, or when any name is not an uppercase shell identifier.
    public static func probe(_ names: [String], environment: [String: String] = [:], timeout: Duration = .seconds(4))
        -> String?
    {
        guard !names.isEmpty, names.allSatisfy(isName) else { return nil }
        let expansion = names.reversed().reduce("") { inner, name in "${\(name):-\(inner)}" }
        return LoginShell.probe(expression: "\"\(expansion)\"", environment: environment, timeout: timeout)
    }

    private static func isName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || ("A"..."Z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }
}
