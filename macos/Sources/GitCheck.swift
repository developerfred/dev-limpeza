import Foundation

/// What git says about the project a cache belongs to. Source code is never touched by this app;
/// this tells the user whether the project looks like live work or holds versioned files inside the cache.
struct GitInfo: Equatable, Codable {
    enum State: String, Codable { case notRepo, unknown, repo }
    var state: State = .unknown
    /// Git tracks files inside the cache folder itself: removing it would delete versioned files.
    var trackedInside = false
    /// Uncommitted or untracked changes in the project folder.
    var dirty = false
    /// Commits not on the upstream branch; -1 when there is no upstream but the branch has commits.
    var unpushed = 0

    /// Reasons to look twice before removing: live work or versioned content.
    var needsAttention: Bool { state == .repo && (trackedInside || dirty || unpushed != 0) }
}

enum GitCheck {
    /// Never the /usr/bin/git shim: without developer tools installed it pops up an install dialog.
    static func gitPath() -> String? {
        let fm = FileManager.default
        var candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git",
                          "/Library/Developer/CommandLineTools/usr/bin/git",
                          "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        if fm.fileExists(atPath: "/Library/Developer/CommandLineTools") { candidates.append("/usr/bin/git") }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Runs git read-only in `dir`. Repository config can name programs git would run (core.fsmonitor,
    /// hooks), so those are switched off on the command line: scanning a repo must never execute its code.
    ///
    /// Output goes to temporary files and the wait is a plain polling loop: no pipe readers and no
    /// dispatch queues, so many checks can run at once on a machine with few cores without any of them
    /// waiting for a thread that another one is holding.
    static func run(_ git: String, _ args: [String], in dir: String, timeout: TimeInterval = 20)
        -> (status: Int32, out: String, err: String)? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dcc-git-\(UUID().uuidString)")
        let outURL = tmp.appendingPathExtension("out"), errURL = tmp.appendingPathExtension("err")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil),
              FileManager.default.createFile(atPath: errURL.path, contents: nil),
              let outH = try? FileHandle(forWritingTo: outURL), let errH = try? FileHandle(forWritingTo: errURL)
        else { return nil }
        defer {
            try? outH.close(); try? errH.close()
            try? FileManager.default.removeItem(at: outURL); try? FileManager.default.removeItem(at: errURL)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        for k in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"] {
            env.removeValue(forKey: k)
        }
        env["GIT_OPTIONAL_LOCKS"] = "0"      // do not rewrite the index while only looking
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        p.standardOutput = outH
        p.standardError = errH
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline { p.terminate(); p.waitUntilExit(); return nil }
            usleep(4_000)
        }
        let out = (try? Data(contentsOf: outURL)) ?? Data()
        let err = (try? Data(contentsOf: errURL)) ?? Data()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    /// Inspects the project that owns the cache at `cachePath` (its parent folder).
    static func inspect(cachePath: String) -> GitInfo {
        guard let git = gitPath() else { return GitInfo(state: .unknown) }
        let url = URL(fileURLWithPath: cachePath)
        let project = url.deletingLastPathComponent().path
        let name = url.lastPathComponent

        guard let inside = run(git, ["rev-parse", "--is-inside-work-tree"], in: project) else { return GitInfo(state: .unknown) }
        if inside.status != 0 {
            return GitInfo(state: inside.err.contains("not a git repository") ? .notRepo : .unknown)
        }
        guard inside.out.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return GitInfo(state: .unknown) }

        var info = GitInfo(state: .repo)
        // Tracked files inside the cache folder (literal pathspec: no globbing of odd folder names).
        guard let tracked = run(git, ["ls-files", "-z", "--cached", "--", ":(literal)" + name], in: project),
              tracked.status == 0 else { return GitInfo(state: .unknown) }
        info.trackedInside = !tracked.out.isEmpty

        guard let status = run(git, ["status", "--porcelain=v1", "--", "."], in: project), status.status == 0 else {
            return GitInfo(state: .unknown)
        }
        info.dirty = !status.out.isEmpty

        if let ahead = run(git, ["rev-list", "--count", "@{u}..HEAD"], in: project), ahead.status == 0 {
            info.unpushed = Int(ahead.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        } else if let all = run(git, ["rev-list", "--count", "HEAD"], in: project), all.status == 0 {
            // No upstream: only a problem if there is something that was never pushed.
            info.unpushed = (Int(all.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 ? -1 : 0
        }
        return info
    }
}
