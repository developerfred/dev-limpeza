// Checks GitCheck against real repositories, including one whose config tries to run a program.
// Run with ./test-git.sh
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "PASS " : "FAIL ") + what)
    if !ok { failures += 1 }
}

let fm = FileManager.default
let base = CommandLine.arguments[1]
try? fm.removeItem(atPath: base)
try! fm.createDirectory(atPath: base, withIntermediateDirectories: true)

@discardableResult
func sh(_ dir: String, _ args: String...) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: GitCheck.gitPath()!)
    p.arguments = ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                   "-c", "protocol.file.allow=always", "-C", dir] + args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
    return p.terminationStatus
}
func put(_ path: String, _ text: String = "x") {
    try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! text.write(toFile: path, atomically: true, encoding: .utf8)
}

guard GitCheck.gitPath() != nil else { print("SKIP no git binary"); exit(0) }

// 1. Not a repository.
let plain = base + "/plain"
put(plain + "/package.json"); put(plain + "/node_modules/a/f")
check(GitCheck.inspect(cachePath: plain + "/node_modules").state == .notRepo, "folder outside git is notRepo")

// 2. Repo with the cache ignored, committed, no upstream: never pushed.
let repo = base + "/repo"
try! fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
sh(repo, "init", "-q", "-b", "main")
put(repo + "/.gitignore", "node_modules\n"); put(repo + "/package.json"); put(repo + "/node_modules/a/f")
sh(repo, "add", "."); sh(repo, "commit", "-q", "-m", "init")
var info = GitCheck.inspect(cachePath: repo + "/node_modules")
check(info.state == .repo && !info.trackedInside && !info.dirty, "ignored cache in clean repo: repo, not tracked, not dirty")
check(info.unpushed == -1, "no upstream with commits reports -1 (never pushed)")

// 3. Push to a bare remote: nothing unpushed.
let remote = base + "/remote.git"
sh(base, "init", "-q", "--bare", remote)
sh(repo, "remote", "add", "origin", remote); sh(repo, "push", "-q", "-u", "origin", "main")
info = GitCheck.inspect(cachePath: repo + "/node_modules")
check(info.unpushed == 0 && !info.needsAttention, "after push: unpushed 0, no attention needed")

// 4. Uncommitted change and an untracked file.
put(repo + "/package.json", "changed")
check(GitCheck.inspect(cachePath: repo + "/node_modules").dirty, "modified tracked file makes it dirty")
sh(repo, "checkout", "-q", "--", "package.json")
put(repo + "/new.txt")
check(GitCheck.inspect(cachePath: repo + "/node_modules").dirty, "untracked file makes it dirty")
try! fm.removeItem(atPath: repo + "/new.txt")

// 5. A local commit that was not pushed.
put(repo + "/more.txt"); sh(repo, "add", "more.txt"); sh(repo, "commit", "-q", "-m", "more")
info = GitCheck.inspect(cachePath: repo + "/node_modules")
check(info.unpushed == 1 && info.needsAttention, "one local commit: unpushed 1 and needs attention")

// 6. Versioned files inside the cache folder.
put(repo + "/target/keep.txt"); sh(repo, "add", "-f", "target/keep.txt"); sh(repo, "commit", "-q", "-m", "oops")
check(GitCheck.inspect(cachePath: repo + "/target").trackedInside, "tracked file inside the folder is detected")
check(!GitCheck.inspect(cachePath: repo + "/node_modules").trackedInside, "sibling ignored cache is not flagged")

// 7. Folder name that looks like a glob must be matched literally.
put(repo + "/pkg/[abc]/f"); put(repo + "/pkg/a/g")
sh(repo, "add", "-f", "pkg/a/g"); sh(repo, "commit", "-q", "-m", "glob")
check(!GitCheck.inspect(cachePath: repo + "/pkg/[abc]").trackedInside, "literal pathspec: '[abc]' does not match folder 'a'")

// 8. A repo whose config tries to run a program on `git status` must not run it.
let evil = base + "/evil"
try! fm.createDirectory(atPath: evil, withIntermediateDirectories: true)
sh(evil, "init", "-q", "-b", "main")
put(evil + "/package.json"); put(evil + "/node_modules/f")
let marker = base + "/PWNED"
sh(evil, "config", "core.fsmonitor", "touch '\(marker)'; echo")
_ = GitCheck.inspect(cachePath: evil + "/node_modules")
check(!fm.fileExists(atPath: marker), "core.fsmonitor from the repo config is not executed")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
