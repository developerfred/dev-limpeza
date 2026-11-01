import AppKit
import SwiftUI

/// `DevCacheClean --screenshots <dir>` renders the real window with example data to PNG files
/// (used for the README and website) and quits. It never scans the disk or touches any files.
@MainActor
enum Screenshots {
    static var directory: String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--screenshots"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    static var isActive: Bool { directory != nil }

    private static let dockerSample = """
    {"Active":"3","Reclaimable":"3.2GB (50%)","Size":"6.4GB","TotalCount":"9","Type":"Images"}
    {"Active":"1","Reclaimable":"0B (0%)","Size":"12.3kB","TotalCount":"4","Type":"Containers"}
    {"Active":"2","Reclaimable":"512.5MB (80%)","Size":"640MB","TotalCount":"6","Type":"Local Volumes"}
    {"Active":"0","Reclaimable":"2.1GB","Size":"2.1GB","TotalCount":"52","Type":"Build Cache"}
    """

    static func makeModels() -> (Model, DockerModel) {
        let m = Model()
        m.root = "~/projects"
        m.staleDays = 30
        func c(_ p: String, _ l: String, _ mb: Double, _ d: Int) -> CacheItem {
            CacheItem(path: "~/projects/" + p, label: l, size: UInt64(mb * 1e6), idle_days: d)
        }
        m.items = [
            c("rust-api/target", "rust", 2100, 97), c("acme-web/node_modules", "node", 1800, 212),
            c("ml-notebooks/.venv", "python", 1200, 188), c("mobile-app/node_modules", "node", 980, 41),
            c("dashboard/node_modules", "node", 760, 12), c("acme-web/.next", "next", 640, 212),
            c("mobile-app/ios/Pods", "cocoapods", 420, 41), c("zig-tools/.zig-cache", "zig", 310, 5),
        ]
        m.selection = Set(m.items.prefix(3).map(\.path))
        func g(_ id: String, _ tool: String, _ name: String, _ path: String, _ d: String, _ loses: String,
               _ cat: String, _ risk: String, _ mb: Double) -> GlobalItem {
            GlobalItem(id: id, tool: tool, name: name, path: path, description: d, loses: loses,
                       category: cat, risk: risk, size: UInt64(mb * 1e6))
        }
        m.globalItems = [
            g("bun", "Bun", "Install cache", "~/.bun/install/cache", "Downloaded packages.", "Re-download on the next install.", "cache", "safe", 12400),
            g("pnpm", "pnpm", "Content store", "~/Library/pnpm/store", "Shared package store linked into node_modules.", "Re-download; projects keep working until reinstalled.", "cache", "safe", 8100),
            g("opencode", "opencode", "Sessions and messages", "~/.local/share/opencode/storage", "Stored opencode sessions and messages.", "Past opencode conversations.", "history", "careful", 1100),
            g("go", "Go", "Module cache", "~/go/pkg/mod/cache", "Downloaded module archives.", "Re-download on the next build.", "cache", "safe", 1200),
            g("brew", "Homebrew", "Downloads", "~/Library/Caches/Homebrew", "Downloaded bottles and sources.", "Re-download when reinstalling.", "cache", "safe", 612),
            g("claude", "Claude Code", "Conversations", "~/.claude/projects", "Transcripts of every Claude Code session, grouped by project.", "Past conversations; they can no longer be resumed.", "history", "careful", 159),
            g("tele", "Claude Code", "Telemetry queue", "~/.claude/telemetry", "Usage events queued for upload.", "Usage events that were not sent yet.", "tracking", "safe", 1.9),
        ]
        m.selectSafeGlobal()
        let d = DockerModel()
        d.state = .ready(DockerModel.parse(dockerSample))
        return (m, d)
    }

    static func run(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let shots = [(0, "dev-caches"), (1, "system"), (2, "docker")]
        for (tab, name) in shots {
            let (m, d) = makeModels()
            let view = ContentView(model: m, docker: d, initialTab: tab)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .aqua)
            win.contentView = host
            win.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
            }
            win.orderOut(nil)
        }
    }
}
