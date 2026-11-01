// Checks that an incremental rescan gives exactly the same result as a full scan after real changes.
// Run with ./test-incremental.sh (builds this against the real Model and the Zig core).
import Foundation

let fm = FileManager.default
var failures = 0

func check(_ ok: Bool, _ what: String) {
    print((ok ? "PASS " : "FAIL ") + what)
    if !ok { failures += 1 }
}

func write(_ path: String, bytes: Int = 1) {
    try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! Data(repeating: 0x61, count: bytes).write(to: URL(fileURLWithPath: path))
}

func append(_ path: String, bytes: Int) {
    let h = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
    h.seekToEndOfFile(); h.write(Data(repeating: 0x62, count: bytes)); try! h.close()
}

func snapshot(_ items: [CacheItem]) -> [String: UInt64] {
    Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0.size) })
}

/// `check --bench <root>`: times a full scan, then an incremental rescan, on real data (read-only).
@MainActor func bench(_ root: String) async {
    let model = Model()
    model.root = root
    await model.scan(forceFull: true)
    print("dev     full:        \(model.scanNote ?? "-")  [\(model.items.count) caches]")
    await model.scan()
    print("dev     incremental: \(model.scanNote ?? "-")  [\(model.items.count) caches]")
    await model.scanGlobal(forceFull: true)
    print("global  full:        \(model.globalNote ?? "-")  [\(model.globalItems.count) locations]")
    await model.scanGlobal()
    print("global  incremental: \(model.globalNote ?? "-")  [\(model.globalItems.count) locations]")
    exit(0)
}

@MainActor func run() async {
    if CommandLine.arguments[1] == "--bench" { await bench(CommandLine.arguments[2]) }
    let tmp = CommandLine.arguments[1]
    let root = tmp + "/tree"
    try? fm.removeItem(atPath: tmp)
    try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)

    // p1, p2, p3 sit directly under the root; p4 is nested. All have their proof file.
    write(root + "/p1/package.json"); write(root + "/p1/node_modules/a/f.bin", bytes: 100_000)
    write(root + "/p2/Cargo.toml"); write(root + "/p2/target/debug/x", bytes: 50_000)
    write(root + "/p3/package.json"); try! fm.createDirectory(atPath: root + "/p3/node_modules", withIntermediateDirectories: true)
    write(root + "/deep/a/b/p4/package.json"); write(root + "/deep/a/b/p4/node_modules/z/f.bin", bytes: 30_000)

    let model = Model()
    model.root = root
    await model.scan(forceFull: true)
    check(model.items.count == 4, "initial full scan finds 4 caches (found \(model.items.count))")
    print("  note: \(model.scanNote ?? "-")")

    // 0) nothing changed -> incremental must report that and return the same thing.
    let before = snapshot(model.items)
    await model.scan()
    check(snapshot(model.items) == before, "no changes: same result")
    // Events from the setup above can still be arriving on the first rescan; once consumed, nothing is left.
    Thread.sleep(forTimeInterval: 1.5)
    await model.scan()
    check(snapshot(model.items) == before, "no changes: same result again")
    check((model.scanNote ?? "").hasPrefix("Nothing changed"), "no changes: note says so (\(model.scanNote ?? "-"))")

    // Real changes, in the places a developer's disk changes.
    append(root + "/p1/node_modules/a/f.bin", bytes: 200_000)                      // a cache grows
    write(root + "/deep/a/b/p6/package.json"); write(root + "/deep/a/b/p6/node_modules/q/f.bin", bytes: 12_345) // new nested cache
    try! fm.removeItem(atPath: root + "/p2/target")                                // a cache disappears
    try! fm.removeItem(atPath: root + "/deep/a/b/p4/node_modules/z/f.bin")        // a cache shrinks
    write(root + "/deep/a/b/p4/node_modules/z/g.bin", bytes: 777)

    Thread.sleep(forTimeInterval: 1.5)   // fseventsd needs a moment to register what just happened
    await model.scan()                                                              // incremental
    let incremental = snapshot(model.items)
    print("  note: \(model.scanNote ?? "-")")
    check(!(model.scanNote ?? "").hasPrefix("Full scan"), "changes: used the incremental path")

    await model.scan(forceFull: true)
    let full = snapshot(model.items)
    check(incremental == full, "incremental == full scan (\(incremental.count) vs \(full.count) caches)")
    if incremental != full {
        for k in Set(incremental.keys).union(full.keys).sorted() where incremental[k] != full[k] {
            print("  differs: \(k)  incremental=\(incremental[k].map(String.init) ?? "missing")  full=\(full[k].map(String.init) ?? "missing")")
        }
    }

    // Changes made right before a scan may not be registered yet; the next scan must still catch them.
    write(root + "/p1/node_modules/late.bin", bytes: 5_000)
    await model.scan()          // may or may not see it yet
    Thread.sleep(forTimeInterval: 1.5)
    await model.scan()
    let settled = snapshot(model.items)
    await model.scan(forceFull: true)
    check(settled == snapshot(model.items), "late change is picked up by the following scan (eventually consistent)")

    // A change directly in the root is always a full scan (cannot be narrowed down).
    write(root + "/p7/package.json"); write(root + "/p7/node_modules/x", bytes: 10)
    Thread.sleep(forTimeInterval: 1.5)
    await model.scan()
    check(model.items.contains { $0.path == root + "/p7/node_modules" }, "new project directly under the root is found")

    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

await run()
