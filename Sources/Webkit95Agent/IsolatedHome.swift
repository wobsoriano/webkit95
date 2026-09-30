import Darwin
import Foundation

/// The private HOME fx runs with. fx loads skills and instructions from the user's home
/// (~/.claude/skills, ~/.codex, ~/.agents and more) and sends a catalog of them to the model with
/// every request, so it gets a home that holds only what it needs (docs/agent-notes.md).
enum IsolatedHome {
    enum Entry: Equatable {
        case directory
        case link(to: String)
    }

    /// fx refuses a symlinked `.fx` (durable_path_unsafe), so fx keeps its own sessions here. The
    /// Security framework finds the login keychain, where fx stores its API key, through HOME.
    static func layout(realHome: String) -> [(path: String, entry: Entry)] {
        [
            ("", .directory),
            (".fx", .directory),
            ("Library", .directory),
            ("Library/Keychains", .link(to: (realHome as NSString).appendingPathComponent("Library/Keychains"))),
        ]
    }

    /// Creates what is missing and leaves everything else alone. nil when the home matches the layout.
    static func prepare(_ home: URL, realHome: String) -> LaunchFailure? {
        let root = home.path(percentEncoded: false)
        do {
            try FileManager.default.createDirectory(atPath: (root as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        } catch {
            return LaunchFailure("could not create the assistant's private fx home at \(root): \(error.localizedDescription)")
        }
        for (path, entry) in layout(realHome: realHome) {
            let full = path.isEmpty ? root : (root as NSString).appendingPathComponent(path)
            if let problem = ensure(full, entry) {
                return LaunchFailure("The assistant's private fx home is not as expected: \(full) \(problem). Move it aside, then press Restart.")
            }
        }
        return nil
    }

    private static func ensure(_ path: String, _ entry: Entry) -> String? {
        var info = stat()
        let exists = lstat(path, &info) == 0
        let kind = info.st_mode & S_IFMT
        switch entry {
        case .directory:
            if !exists {
                guard mkdir(path, 0o700) == 0 else { return "could not be created (\(String(cString: strerror(errno))))" }
                return nil
            }
            guard kind == S_IFDIR else { return kind == S_IFLNK ? "is a symlink, fx needs a real directory" : "is not a directory" }
            chmod(path, 0o700)
            return nil
        case .link(let target):
            if !exists {
                guard symlink(target, path) == 0 else { return "could not be linked (\(String(cString: strerror(errno))))" }
                return nil
            }
            guard kind == S_IFLNK else { return "should be a symlink to \(target) but is a real \(kind == S_IFDIR ? "directory" : "file")" }
            let current = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
            return current == target ? nil : "points to \(current ?? "an unreadable target"), not \(target)"
        }
    }
}
