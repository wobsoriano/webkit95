import Darwin
import Foundation
import os

struct Spawned {
    var pid: pid_t
    var stdin: Int32?
    var stdout: Int32
    var stderr: Int32?
}

/// posix_spawn rather than Foundation's Process, which cannot put the child in its own process
/// group. The group lets one killpg reach every helper the agent starts.
func spawnInOwnGroup(
    path: String, argv: [String], environment: [String: String], cwd: String?,
    pipeStdin: Bool, pipeStderr: Bool
) throws(SpawnError) -> Spawned {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }

    var parentEnds: [Int32] = []
    var childEnds: [Int32] = []
    defer { childEnds.forEach { close($0) } }
    func makePipe(childFD: Int32, childReads: Bool) throws(SpawnError) -> Int32 {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw SpawnError(errno: errno) }
        // Close on exec so a child some other thread spawns cannot hold our pipes open.
        fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        let (child, parent) = childReads ? (fds[0], fds[1]) : (fds[1], fds[0])
        childEnds.append(child)
        parentEnds.append(parent)
        posix_spawn_file_actions_adddup2(&actions, child, childFD)
        return parent
    }

    let stdinFD: Int32?
    let stdoutFD: Int32
    let stderrFD: Int32?
    do {
        stdinFD = pipeStdin ? try makePipe(childFD: 0, childReads: true) : nil
        stdoutFD = try makePipe(childFD: 1, childReads: false)
        stderrFD = pipeStderr ? try makePipe(childFD: 2, childReads: false) : nil
    } catch {
        parentEnds.forEach { close($0) }
        throw error
    }
    if !pipeStdin { posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) }
    if !pipeStderr { posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) }
    if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }

    var allSignals = sigset_t()
    var noSignals = sigset_t()
    sigfillset(&allSignals)
    sigemptyset(&noSignals)
    posix_spawnattr_setsigdefault(&attributes, &allSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    posix_spawnattr_setpgroup(&attributes, 0)
    let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
    posix_spawnattr_setflags(&attributes, Int16(flags))

    let cArgv = argv.map { strdup($0) } + [nil]
    let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (cArgv + cEnv).forEach { free($0) } }
    var pid = pid_t()
    let result = posix_spawn(&pid, path, &actions, &attributes, cArgv, cEnv)
    guard result == 0 else {
        parentEnds.forEach { close($0) }
        throw SpawnError(errno: result)
    }
    return Spawned(pid: pid, stdin: stdinFD, stdout: stdoutFD, stderr: stderrFD)
}

struct SpawnError: Error, CustomStringConvertible {
    var errno: Int32
    var description: String { String(cString: strerror(errno)) }
}

/// The running agent. Signals go to its whole process group and stop once it is reaped, so a
/// recycled pid is never hit.
final class Child: Sendable {
    let pid: pid_t
    private let running = OSAllocatedUnfairLock(initialState: true)
    /// Only touched on `writer`, the lock just proves that to the compiler.
    private let stdin: OSAllocatedUnfairLock<Int32?>
    private let writer = DispatchQueue(label: "webkit95.agent.stdin")

    init(pid: pid_t, stdin: Int32) {
        self.pid = pid
        _ = fcntl(stdin, F_SETNOSIGPIPE, 1)
        self.stdin = OSAllocatedUnfairLock(initialState: stdin)
    }

    func signalGroup(_ signal: Int32) {
        running.withLock { running in
            if running { _ = killpg(pid, signal) }
        }
    }

    func send(_ message: JSONValue) {
        let bytes = Array((message.serialized() + "\n").utf8)
        writer.async { [stdin] in
            stdin.withLock { fd in
                guard let fd else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { return }
                    offset += written
                }
            }
        }
    }

    func closeStdin() {
        writer.async { [stdin] in
            stdin.withLock { fd in
                if let open = fd { close(open) }
                fd = nil
            }
        }
    }

    /// Blocks until the child exits, then kills whatever is left of its group and reaps it.
    func reap() -> String {
        var info = siginfo_t()
        // WNOWAIT keeps the zombie, and with it the pid and group id, until the sweep is done.
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
        running.withLock { running in
            running = false
            _ = killpg(pid, SIGKILL)
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        closeStdin()
        let signal = status & 0x7f
        return signal == 0 ? "agent exited (exit status: \((status >> 8) & 0xff))" : "agent exited (signal: \(signal))"
    }
}

/// Holds the current child so `deinit` can kill it synchronously from any thread.
final class ChildSlot: Sendable {
    private let lock = OSAllocatedUnfairLock<Child?>(initialState: nil)
    var child: Child? { lock.withLock { $0 } }
    func set(_ child: Child) { lock.withLock { $0 = child } }
}

/// Reads `fd` to EOF on its own thread, framing lines. Closes `fd` when done.
func readLines(_ fd: Int32, done: DispatchGroup, onLine: @escaping @Sendable (Data) -> Void) {
    done.enter()
    Thread.detachNewThread {
        var framer = LineFramer()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            framer.push(Data(buffer[0..<count])).forEach(onLine)
        }
        framer.finish().map(onLine)
        close(fd)
        done.leave()
    }
}
