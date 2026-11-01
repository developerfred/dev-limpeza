import Foundation
import CoreServices

/// What the macOS file system event log says changed since a stored event id.
enum ChangeResult {
    case changed([String])
    /// The log cannot be trusted (events dropped, volume remounted, ...): do a full scan.
    case unreliable
}

private final class ChangeCollector {
    var paths: [String] = []
    var unreliable = false
    let done = DispatchSemaphore(value: 0)
}

enum FSChanges {
    static func currentEventId() -> UInt64 { FSEventsGetCurrentEventId() }

    /// Identifies the volume's event history; if it differs from the stored one the id is meaningless.
    static func volumeUUID(of path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let u = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, u) as String?
    }

    /// Replays the directories that changed under `paths` since `eventId`.
    static func changes(since eventId: UInt64, under paths: [String], timeout: TimeInterval = 30) -> ChangeResult {
        let collector = ChangeCollector()
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
            let c = Unmanaged<ChangeCollector>.fromOpaque(info!).takeUnretainedValue()
            let list = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let bad = FSEventStreamEventFlags(
                kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
            let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
            for i in 0..<count {
                if flags[i] & bad != 0 { c.unreliable = true }
                if flags[i] & historyDone != 0 {
                    c.done.signal()
                } else if i < list.count {
                    c.paths.append(list[i])
                }
            }
        }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray, eventId, 0.05, flags) else {
            return .unreliable
        }
        let queue = DispatchQueue(label: "dev.cacheclean.fsevents")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            return .unreliable
        }
        var finished = collector.done.wait(timeout: .now() + timeout) == .success
        // The log lags behind the file system by up to a few seconds: ask the service to hand over
        // everything it has seen but not delivered yet, otherwise very recent changes would be missed
        // (and never replayed, because the stored id moves forward).
        FSEventStreamFlushSync(stream)
        queue.sync {}
        if finished { finished = !collector.unreliable }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // Drain the queue so the callback can no longer touch the collector.
        queue.sync {}
        return (finished && !collector.unreliable) ? .changed(collector.paths) : .unreliable
    }
}

/// Decides what must be recomputed after some directories changed. Pure, so it can be tested.
enum Planner {
    /// Directories the scanner never enters (mirrors src/targets.zig).
    static let skipNames: Set<String> = [".git", "Library", ".Trash", ".cache", "Applications"]
    static let maxDepth = 8

    struct Plan: Equatable {
        /// Known caches whose contents changed: size them again.
        var resize: Set<String> = []
        /// Folders to rescan with their depth below the scan root.
        var rescan: [(path: String, depth: Int)] = []
        /// Too much changed, or the root itself: scan everything.
        var full = false

        static func == (a: Plan, b: Plan) -> Bool {
            a.resize == b.resize && a.full == b.full
                && a.rescan.map(\.path) == b.rescan.map(\.path) && a.rescan.map(\.depth) == b.rescan.map(\.depth)
        }
    }

    static func normalize(_ p: String) -> String {
        var s = p
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// `known` are the cache paths found by the last scan; `changed` are directories reported by FSEvents.
    static func plan(known: [String], root: String, changed: [String], maxRescans: Int = 64) -> Plan {
        let root = normalize(root)
        var plan = Plan()
        var candidates: [String] = []

        for raw in changed {
            let p = normalize(raw)
            if p == root || root.hasPrefix(p + "/") { plan.full = true; return plan }   // the root or one of its parents
            guard p.hasPrefix(root + "/") else { continue }
            let rel = p.dropFirst(root.count + 1).split(separator: "/").map(String.init)
            if rel.contains(where: { skipNames.contains($0) }) { continue }
            if let hit = known.first(where: { p == $0 || p.hasPrefix($0 + "/") }) {
                plan.resize.insert(hit)
            } else if rel.count <= maxDepth {
                candidates.append(p)
            }
        }

        // Keep only the topmost changed folders: rescanning a folder covers everything below it.
        var kept: [String] = []
        for p in candidates.sorted(by: { $0.count < $1.count }) where !kept.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) {
            kept.append(p)
        }
        if kept.count > maxRescans { plan.full = true; return plan }
        plan.rescan = kept.map { ($0, $0.dropFirst(root.count + 1).split(separator: "/").count) }
        return plan
    }
}

/// What one scan left behind, so the next one only has to look at what changed.
struct ScopeCache: Codable {
    var eventId: UInt64
    var volumeUUID: String
    var savedAt: Date
    var devItems: [CacheItem]?
    var globalItems: [GlobalItem]?
}

struct CacheStore {
    /// Results older than this are never trusted: the event log is not guaranteed to reach back further.
    static let maxAge: TimeInterval = 24 * 3600
    private static let version = 1

    private struct File: Codable {
        var version: Int
        var scopes: [String: ScopeCache]
    }

    let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else if let override = ProcessInfo.processInfo.environment["DCC_CACHE_FILE"] {
            self.url = URL(fileURLWithPath: override)   // lets tests use a private cache file
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = base.appendingPathComponent("DevCacheClean/size-cache.json")
        }
    }

    func load(_ key: String) -> ScopeCache? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == Self.version,
              let scope = file.scopes[key], Date().timeIntervalSince(scope.savedAt) < Self.maxAge else { return nil }
        return scope
    }

    func save(_ scope: ScopeCache, for key: String) {
        var file = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        if file == nil || file?.version != Self.version { file = File(version: Self.version, scopes: [:]) }
        file?.scopes[key] = scope
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
