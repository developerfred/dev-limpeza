import Foundation
import UserNotifications

struct CacheItem: Identifiable, Codable, Hashable {
    let path: String
    let label: String
    var size: UInt64
    /// Newest activity of the owning project, seconds since the epoch.
    let last_used: Int64
    var id: String { path }
    /// Computed, so a cached result keeps aging correctly.
    var idle_days: Int { max(0, Int((Date().timeIntervalSince1970 - Double(last_used)) / 86400)) }
}

/// A known global location (AI agent data, package manager cache, Xcode...). See src/catalog.zig.
struct GlobalItem: Identifiable, Codable, Hashable {
    let id: String
    let tool: String
    let name: String
    let path: String
    let description: String
    let loses: String
    let category: String
    let risk: String
    var size: UInt64
    var isCareful: Bool { risk == "careful" }
}

enum RemoveMode {
    case trash      // reversible
    case permanent  // immediate, cannot be undone
}

@MainActor
final class Model: ObservableObject {
    @Published var items: [CacheItem] = []
    @Published var selection: Set<String> = []
    @Published var globalItems: [GlobalItem] = []
    /// Git state of each project cache's project, filled in after a scan.
    @Published var gitInfo: [String: GitInfo] = [:]
    @Published var globalSelection: Set<String> = []
    @Published var scanning = false
    @Published var scanningGlobal = false
    @Published var removing = false
    @Published var lastScan: Date?
    @Published var message: String?
    /// How the last scans were done, e.g. "Updated from 3 changed folders in 0.4 s".
    @Published var scanNote: String?
    @Published var globalNote: String?
    private let store = CacheStore()

    @Published var root: String {
        didSet { UserDefaults.standard.set(root, forKey: "root") }
    }
    @Published var staleDays: Int {
        didSet { UserDefaults.standard.set(staleDays, forKey: "staleDays") }
    }

    private let notifyThreshold: UInt64 = 1 << 30
    /// Directory names the project scanner can return; anything else is refused.
    private static let cacheNames: Set<String> =
        ["node_modules", ".next", "target", ".zig-cache", ".venv", "__pycache__", "Pods"]

    /// Marker file that must still sit next to the cache (mirrors src/targets.zig); nil = no check.
    private static let markers: [String: String] =
        ["node_modules": "package.json", ".next": "package.json", "target": "Cargo.toml",
         ".zig-cache": "build.zig", "Pods": "Podfile"]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dev = home + "/development"
        let defaultRoot = FileManager.default.fileExists(atPath: dev) ? dev : home
        root = UserDefaults.standard.string(forKey: "root") ?? defaultRoot
        let d = UserDefaults.standard.integer(forKey: "staleDays")
        staleDays = d > 0 ? d : 30
    }

    var staleItems: [CacheItem] { items.filter { $0.idle_days >= staleDays } }
    var staleBytes: UInt64 { staleItems.reduce(0) { $0 + $1.size } }
    var selectedBytes: UInt64 { items.filter { selection.contains($0.path) }.reduce(0) { $0 + $1.size } }
    var globalBytes: UInt64 { globalItems.reduce(0) { $0 + $1.size } }
    var globalSelectedItems: [GlobalItem] { globalItems.filter { globalSelection.contains($0.path) } }
    var globalSelectedBytes: UInt64 { globalSelectedItems.reduce(0) { $0 + $1.size } }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        Task {
            while true {
                await scan()
                await scanGlobal()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    // MARK: scanning (incremental when the file system event log allows it)

    /// The real path FSEvents reports (Foundation's resolvingSymlinksInPath drops the /private prefix, realpath does not).
    private func canonical(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    private func detect(since id: UInt64, under paths: [String]) async -> ChangeResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: FSChanges.changes(since: id, under: paths)) }
        }
    }

    /// Runs `body` with `strings` as a C array on a big-stack thread (the C scans are blocking and recursive-free but heavy).
    private func onBigThread<T>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            let t = Thread { cont.resume(returning: body()) }
            t.stackSize = 16 << 20
            t.qualityOfService = .utility
            t.start()
        }
    }

    private func sizes(of paths: [String]) async -> [UInt64]? {
        guard !paths.isEmpty else { return [] }
        return await onBigThread {
            var cstrs: [UnsafePointer<CChar>?] = paths.map { UnsafePointer(strdup($0)) }
            defer { cstrs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
            var out = [UInt64](repeating: 0, count: paths.count)
            let rc = dcc_size_paths(&cstrs, paths.count, &out)
            return rc == 0 ? out : nil
        }
    }

    nonisolated private static func decode<T: Decodable>(_ raw: UnsafeMutablePointer<CChar>?) -> T? {
        guard let raw else { return nil }
        defer { dcc_free(raw) }
        return try? JSONDecoder().decode(T.self, from: Data(bytes: raw, count: strlen(raw)))
    }

    func scan(forceFull: Bool = false) async {
        guard !scanning, !removing else { return }
        scanning = true
        message = nil
        let root = self.root
        let started = Date()
        let idBefore = FSChanges.currentEventId()
        let uuid = FSChanges.volumeUUID(of: root) ?? ""

        var result: [CacheItem]?
        var note = ""
        if !forceFull, !uuid.isEmpty, let cached = store.load("dev:" + root),
           cached.volumeUUID == uuid, let known = cached.devItems {
            let real = canonical(root)
            if case .changed(let paths) = await detect(since: cached.eventId, under: [real]) {
                let mapped = paths.map { $0 == real || $0.hasPrefix(real + "/") ? root + $0.dropFirst(real.count) : $0 }
                let plan = Planner.plan(known: known.map(\.path), root: root, changed: mapped)
                if ProcessInfo.processInfo.environment["DCC_DEBUG"] != nil {
                    print("DEBUG real=\(real)\n  events=\(paths)\n  plan resize=\(plan.resize) rescan=\(plan.rescan.map(\.path)) full=\(plan.full)")
                }
                if !plan.full {
                    result = await apply(plan, to: known)
                    let n = plan.rescan.count + plan.resize.count
                    note = n == 0 ? "Nothing changed" : "Updated \(n) changed \(n == 1 ? "folder" : "folders")"
                }
            }
        }
        if result == nil {
            result = await onBigThread { [root] in Model.decode(root.withCString { dcc_scan($0) }) }
            note = "Full scan"
        }
        scanning = false
        guard let found = result else {
            message = "Scan failed for \(root)"
            return
        }
        scanNote = note + String(format: " in %.1f s", Date().timeIntervalSince(started))
        items = found.sorted { $0.size > $1.size }
        selection = selection.intersection(Set(found.map(\.path)))
        lastScan = Date()
        let paths = items.map(\.path)
        gitInfo = gitInfo.filter { paths.contains($0.key) }
        Task { await checkGit(paths, force: true) }
        if !uuid.isEmpty {
            store.save(ScopeCache(eventId: idBefore, volumeUUID: uuid, savedAt: Date(), devItems: items, globalItems: nil), for: "dev:" + root)
        }
        notifyIfNeeded()
    }

    /// Applies an incremental plan to the previously known caches.
    private func apply(_ plan: Planner.Plan, to known: [CacheItem]) async -> [CacheItem] {
        var items = known
        var refreshed = Set<String>()
        for (path, depth) in plan.rescan {
            let sub: [CacheItem] = await onBigThread { [path] in
                Model.decode(path.withCString { dcc_scan_sub($0, UInt32(depth)) }) ?? []   // nil: folder is gone
            }
            items.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
            items += sub
            refreshed.formUnion(sub.map(\.path))
        }
        let fm = FileManager.default
        let gone = plan.resize.filter { !fm.fileExists(atPath: $0) }
        items.removeAll { gone.contains($0.path) }
        let toSize = plan.resize.filter { r in !refreshed.contains(r) && !gone.contains(r) && items.contains { $0.path == r } }.sorted()
        if let new = await sizes(of: toSize) {
            let map = Dictionary(uniqueKeysWithValues: zip(toSize, new))
            for i in items.indices { if let s = map[items[i].path] { items[i].size = s } }
        }
        return items
    }

    func scanGlobal(forceFull: Bool = false) async {
        guard !scanningGlobal else { return }
        scanningGlobal = true
        let started = Date()
        let idBefore = FSChanges.currentEventId()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let uuid = FSChanges.volumeUUID(of: home) ?? ""

        var result: [GlobalItem]?
        var note = ""
        if !forceFull, !uuid.isEmpty, let cached = store.load("global"), cached.volumeUUID == uuid,
           let known = cached.globalItems, !known.isEmpty {
            let real = known.map { canonical($0.path) }
            if case .changed(let paths) = await detect(since: cached.eventId, under: real) {
                let changed = paths.map { Planner.normalize($0) }
                let dirty = Set(known.indices.filter { i in
                    changed.contains { $0 == real[i] || $0.hasPrefix(real[i] + "/") || real[i].hasPrefix($0 + "/") }
                })
                let clean = known.indices.filter { !dirty.contains($0) }.map { known[$0] }
                let skip = clean.map(\.path)
                let fresh: [GlobalItem]? = await onBigThread {
                    var cstrs: [UnsafePointer<CChar>?] = skip.map { UnsafePointer(strdup($0)) }
                    defer { cstrs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
                    let raw = cstrs.withUnsafeBufferPointer { dcc_scan_global_partial($0.baseAddress, skip.count) }
                    return Model.decode(raw)
                }
                if let fresh {
                    result = clean + fresh
                    note = dirty.isEmpty ? "Nothing changed" : "Updated \(dirty.count) changed \(dirty.count == 1 ? "location" : "locations")"
                }
            }
        }
        if result == nil {
            result = await onBigThread { Model.decode(dcc_scan_global()) }
            note = "Full scan"
        }
        scanningGlobal = false
        guard let found = result else { return }
        globalNote = note + String(format: " in %.1f s", Date().timeIntervalSince(started))
        globalItems = found.sorted { $0.size > $1.size }
        globalSelection = globalSelection.intersection(Set(found.map(\.path)))
        if !uuid.isEmpty {
            store.save(ScopeCache(eventId: idBefore, volumeUUID: uuid, savedAt: Date(), devItems: nil, globalItems: globalItems), for: "global")
        }
    }

    /// Runs git on the projects of the given caches on a few dedicated threads (not the Swift task pool:
    /// each check blocks while git runs).
    func checkGit(_ paths: [String], force: Bool = false) async {
        let todo = paths.filter { force || gitInfo[$0] == nil }
        guard !todo.isEmpty else { return }
        let results: [String: GitInfo] = await withCheckedContinuation { cont in
            let lock = NSLock()
            var next = 0
            var out: [String: GitInfo] = [:]
            let workers = min(4, todo.count)
            let group = DispatchGroup()
            for _ in 0..<workers {
                group.enter()
                let t = Thread {
                    while true {
                        lock.lock(); let i = next; next += 1; lock.unlock()
                        if i >= todo.count { break }
                        let info = GitCheck.inspect(cachePath: todo[i])
                        lock.lock(); out[todo[i]] = info; lock.unlock()
                    }
                    group.leave()
                }
                t.stackSize = 4 << 20
                t.start()
            }
            // A plain thread waits for the workers, so no pool thread is ever parked here.
            Thread { group.wait(); cont.resume(returning: out) }.start()
        }
        for (p, info) in results { gitInfo[p] = info }
    }

    /// Selects the idle caches whose projects show no sign of live work: nothing uncommitted, nothing unpushed,
    /// and no versioned files inside the cache. Those are left for the user to choose on purpose.
    func selectStale() async {
        let stale = staleItems
        await checkGit(stale.map(\.path))
        selection = Set(stale.filter { !(gitInfo[$0.path]?.needsAttention ?? false) }.map(\.path))
        let skipped = stale.count - selection.count
        if skipped > 0 {
            message = "Left out \(skipped) idle \(skipped == 1 ? "cache" : "caches") whose project has uncommitted or unpushed work"
        }
    }

    var selectedGit: (dirty: Int, unpushed: Int, notRepo: Int, tracked: Int) {
        var r = (dirty: 0, unpushed: 0, notRepo: 0, tracked: 0)
        for i in items where selection.contains(i.path) {
            guard let g = gitInfo[i.path] else { continue }
            if g.dirty { r.dirty += 1 }
            if g.unpushed != 0 { r.unpushed += 1 }
            if g.state == .notRepo { r.notRepo += 1 }
            if g.trackedInside { r.tracked += 1 }
        }
        return r
    }

    /// Selects what is safe to remove: regenerated data, logs and tracking. Never history or "careful" items.
    func selectSafeGlobal() {
        globalSelection = Set(globalItems.filter { !$0.isCareful && $0.category != "history" }.map(\.path))
    }

    // MARK: removal

    /// Refuses anything that was not returned by the last scan, is not an absolute path, or is a symlink.
    private func isSafe(_ path: String, allowed: Set<String>, requireCacheName: Bool) -> Bool {
        guard path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/.."), allowed.contains(path) else { return false }
        let url = URL(fileURLWithPath: path)
        if requireCacheName {
            let name = url.lastPathComponent
            guard Self.cacheNames.contains(name) else { return false }
            // The scan may be hours old: make sure the project the cache belongs to is still there.
            if let marker = Self.markers[name],
               !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(marker).path) {
                return false
            }
        }
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? true
        return !isLink
    }

    private func removeAll(_ targets: [(path: String, size: UInt64)], allowed: Set<String>,
                           requireCacheName: Bool, mode: RemoveMode) async -> (freed: UInt64, failed: Int, skipped: Int) {
        removing = true
        defer { removing = false }
        var freed: UInt64 = 0
        var failed = 0
        var skipped = 0
        for (i, t) in targets.enumerated() {
            message = (mode == .permanent ? "Deleting " : "Moving ") + "\(i + 1)/\(targets.count)…"
            guard isSafe(t.path, allowed: allowed, requireCacheName: requireCacheName) else { failed += 1; continue }
            // Project caches: look at git again right now (it may have changed since the scan). A folder
            // that holds versioned files is never deleted permanently; the Trash can still restore it.
            if requireCacheName && mode == .permanent {
                let info = await Task.detached { GitCheck.inspect(cachePath: t.path) }.value
                if info.trackedInside { skipped += 1; continue }
            }
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    switch mode {
                    case .trash: try FileManager.default.trashItem(at: URL(fileURLWithPath: t.path), resultingItemURL: nil)
                    case .permanent: try FileManager.default.removeItem(atPath: t.path)
                    }
                    return true
                } catch { return false }
            }.value
            if ok { freed += t.size } else { failed += 1 }
        }
        return (freed, failed, skipped)
    }

    private func summary(_ r: (freed: UInt64, failed: Int, skipped: Int), mode: RemoveMode) -> String {
        let verb = mode == .permanent ? "Deleted" : "Moved to the Trash:"
        return "\(verb) \(Model.format(r.freed))" + (r.failed > 0 ? " (\(r.failed) failed)" : "")
            + (r.skipped > 0 ? ", kept \(r.skipped) that hold files tracked by git (use the Trash for those)" : "")
    }

    func removeSelected(_ mode: RemoveMode) async {
        let chosen = items.filter { selection.contains($0.path) }
        let r = await removeAll(chosen.map { ($0.path, $0.size) }, allowed: Set(items.map(\.path)),
                                requireCacheName: true, mode: mode)
        let gone = Set(chosen.map(\.path))
        items.removeAll { gone.contains($0.path) && !FileManager.default.fileExists(atPath: $0.path) }
        selection.subtract(gone)
        message = summary(r, mode: mode)
    }

    func removeGlobalSelected(_ mode: RemoveMode) async {
        let chosen = globalSelectedItems
        let r = await removeAll(chosen.map { ($0.path, $0.size) }, allowed: Set(globalItems.map(\.path)),
                                requireCacheName: false, mode: mode)
        let gone = Set(chosen.map(\.path))
        globalItems.removeAll { gone.contains($0.path) && !FileManager.default.fileExists(atPath: $0.path) }
        globalSelection.subtract(gone)
        message = summary(r, mode: mode)
    }

    private func notifyIfNeeded() {
        let key = "lastNotified"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Bundle.main.bundleIdentifier != nil,
              staleBytes >= notifyThreshold, Date().timeIntervalSince(last) > 24 * 3600 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Dev Cache Clean"
        content.body = "\(Model.format(staleBytes)) in \(staleItems.count) caches unused for \(staleDays)+ days."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "stale", content: content, trigger: nil))
        UserDefaults.standard.set(Date(), forKey: key)
    }
}
