import Foundation
import UserNotifications

struct CacheItem: Identifiable, Decodable, Hashable {
    let path: String
    let label: String
    let size: UInt64
    let idle_days: Int
    var id: String { path }
}

@MainActor
final class Model: ObservableObject {
    @Published var items: [CacheItem] = []
    @Published var selection: Set<String> = []
    @Published var scanning = false
    @Published var lastScan: Date?
    @Published var message: String?

    @Published var root: String {
        didSet { UserDefaults.standard.set(root, forKey: "root") }
    }
    @Published var staleDays: Int {
        didSet { UserDefaults.standard.set(staleDays, forKey: "staleDays") }
    }

    private let notifyThreshold: UInt64 = 1 << 30

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
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        message = nil
        let root = self.root
        let found: [CacheItem]? = await withCheckedContinuation { cont in
            let t = Thread {
                guard let raw = root.withCString({ dcc_scan($0) }) else { cont.resume(returning: nil); return }
                defer { dcc_free(raw) }
                cont.resume(returning: try? JSONDecoder().decode([CacheItem].self, from: Data(bytes: raw, count: strlen(raw))))
            }
            t.stackSize = 16 << 20
            t.qualityOfService = .utility
            t.start()
        }
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

    func selectStale() { selection = Set(staleItems.map(\.path)) }

    /// Moves the selected caches to the Trash so the cleanup stays reversible.
    func trashSelected() async {
        let chosen = items.filter { selection.contains($0.path) }
        var failed = 0
        var freed: UInt64 = 0
        for item in chosen {
            let ok = await Task.detached { () -> Bool in
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                    return true
                } catch { return false }
            }.value
            if ok { freed += item.size } else { failed += 1 }
        }
        let gone = Set(chosen.map(\.path))
        items.removeAll { gone.contains($0.path) && !FileManager.default.fileExists(atPath: $0.path) }
        selection.subtract(gone)
        message = "Moved \(Model.format(freed)) to the Trash" + (failed > 0 ? " (\(failed) failed)" : "")
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
