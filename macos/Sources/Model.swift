import Foundation
import UserNotifications

struct CacheItem: Identifiable, Decodable, Hashable {
    let path: String
    let label: String
    let size: UInt64
    let idle_days: Int
    var id: String { path }
}

/// A known global location (AI agent data, package manager cache, Xcode...). See src/catalog.zig.
struct GlobalItem: Identifiable, Decodable, Hashable {
    let id: String
    let tool: String
    let name: String
    let path: String
    let description: String
    let loses: String
    let category: String
    let risk: String
    let size: UInt64
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
    @Published var globalSelection: Set<String> = []
    @Published var scanning = false
    @Published var scanningGlobal = false
    @Published var removing = false
    @Published var lastScan: Date?
    @Published var message: String?

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

    /// Runs a blocking C scan on its own thread with a large stack and decodes its JSON result.
    private func callScan<T: Decodable>(_ body: @escaping @Sendable () -> UnsafeMutablePointer<CChar>?) async -> T? {
        await withCheckedContinuation { cont in
            let t = Thread {
                guard let raw = body() else { cont.resume(returning: nil); return }
                defer { dcc_free(raw) }
                cont.resume(returning: try? JSONDecoder().decode(T.self, from: Data(bytes: raw, count: strlen(raw))))
            }
            t.stackSize = 16 << 20
            t.qualityOfService = .utility
            t.start()
        }
    }

    func scan() async {
        guard !scanning, !removing else { return }
        scanning = true
        message = nil
        let root = self.root
        let found: [CacheItem]? = await callScan { root.withCString { dcc_scan($0) } }
        scanning = false
        guard let found else {
            message = "Scan failed for \(root)"
            return
        }
        items = found
        selection = selection.intersection(Set(found.map(\.path)))
        lastScan = Date()
        notifyIfNeeded()
    }

    func scanGlobal() async {
        guard !scanningGlobal else { return }
        scanningGlobal = true
        let found: [GlobalItem]? = await callScan { dcc_scan_global() }
        scanningGlobal = false
        guard let found else { return }
        globalItems = found
        globalSelection = globalSelection.intersection(Set(found.map(\.path)))
    }

    func selectStale() { selection = Set(staleItems.map(\.path)) }

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
                           requireCacheName: Bool, mode: RemoveMode) async -> (freed: UInt64, failed: Int) {
        removing = true
        defer { removing = false }
        var freed: UInt64 = 0
        var failed = 0
        for (i, t) in targets.enumerated() {
            message = (mode == .permanent ? "Deleting " : "Moving ") + "\(i + 1)/\(targets.count)…"
            guard isSafe(t.path, allowed: allowed, requireCacheName: requireCacheName) else { failed += 1; continue }
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
        return (freed, failed)
    }

    private func summary(_ r: (freed: UInt64, failed: Int), mode: RemoveMode) -> String {
        let verb = mode == .permanent ? "Deleted" : "Moved to the Trash:"
        return "\(verb) \(Model.format(r.freed))" + (r.failed > 0 ? " (\(r.failed) failed)" : "")
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
