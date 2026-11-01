import Foundation

struct DockerRow: Identifiable, Equatable {
    let id: String
    let title: String
    let total: Int
    let active: Int
    let size: String
    let reclaimableText: String
    let reclaimableBytes: UInt64
    let pruneArgs: [String]
    let warning: String
}

enum DockerState: Equatable {
    case idle
    case loading
    case unavailable(String)
    case ready([DockerRow])
}

private struct RawRow: Decodable {
    let `Type`: String
    let TotalCount: String
    let Active: String
    let Size: String
    let Reclaimable: String
}

@MainActor
final class DockerModel: ObservableObject {
    @Published var state: DockerState = .idle
    @Published var message: String?
    @Published var busy = false

    var reclaimableBytes: UInt64 {
        if case .ready(let rows) = state { return rows.reduce(0) { $0 + $1.reclaimableBytes } }
        return 0
    }

    // MARK: parsing (pure, so it can be tested without a daemon)

    /// Parses "1.2GB (45%)" / "512kB" / "0B" into bytes. Docker uses decimal units.
    nonisolated static func parseBytes(_ text: String) -> UInt64 {
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        let digits = token.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return 0 }
        let unit = token.dropFirst(digits.count).lowercased()
        let mult: Double
        switch unit {
        case "b", "": mult = 1
        case "kb": mult = 1e3
        case "mb": mult = 1e6
        case "gb": mult = 1e9
        case "tb": mult = 1e12
        default: mult = 1
        }
        return UInt64(value * mult)
    }

    /// Accepts both one JSON object per line and a JSON array.
    nonisolated static func parse(_ text: String) -> [DockerRow] {
        let data = Data(text.utf8)
        var raws: [RawRow] = []
        if let arr = try? JSONDecoder().decode([RawRow].self, from: data) {
            raws = arr
        } else {
            for line in text.split(whereSeparator: \.isNewline) {
                if let r = try? JSONDecoder().decode(RawRow.self, from: Data(line.utf8)) { raws.append(r) }
            }
        }
        return raws.compactMap { r in
            let spec: (String, [String], String)
            switch r.Type {
            case "Images":
                spec = ("Unused images", ["image", "prune", "-a", "-f"],
                        "Removes every image not used by a container. They are downloaded again when needed.")
            case "Containers":
                spec = ("Stopped containers", ["container", "prune", "-f"],
                        "Removes all stopped containers.")
            case "Local Volumes":
                spec = ("Unused volumes", ["volume", "prune", "-f"],
                        "Removes volumes no container uses, including volumes of stopped containers. Their data is permanently lost.")
            case "Build Cache":
                spec = ("Build cache", ["builder", "prune", "-a", "-f"],
                        "Removes the build cache. The next builds will be slower.")
            default:
                return nil
            }
            return DockerRow(
                id: r.Type, title: spec.0,
                total: Int(r.TotalCount) ?? 0, active: Int(r.Active) ?? 0,
                size: r.Size, reclaimableText: r.Reclaimable,
                reclaimableBytes: parseBytes(r.Reclaimable),
                pruneArgs: spec.1, warning: spec.2)
        }
    }

    // MARK: running docker

    nonisolated static func findDocker() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            home + "/.orbstack/bin/docker",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin"
        // Prunes must only ever hit the local default daemon, never a remote one inherited from the shell.
        env.removeValue(forKey: "DOCKER_HOST")
        env.removeValue(forKey: "DOCKER_CONTEXT")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", "\(error)") }
        // Drain stderr on a side queue so a chatty child cannot block on a full pipe.
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        g.wait()
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    func refresh() async {
        guard !busy else { return }
        guard let exe = Self.findDocker() else {
            state = .unavailable("Docker CLI not found. Install Docker Desktop or OrbStack.")
            return
        }
        state = .loading
        let result = await Task.detached(priority: .utility) {
            Self.run(exe, ["system", "df", "--format", "json"])
        }.value
        if result.status != 0 {
            state = .unavailable("Docker is not running. Start Docker Desktop or OrbStack, then retry.")
        } else {
            state = .ready(Self.parse(result.out))
        }
    }

    /// Runs the prune command for one category. Docker prunes cannot be undone.
    func prune(_ row: DockerRow) async {
        guard let exe = Self.findDocker() else { return }
        busy = true
        let result = await Task.detached(priority: .utility) { Self.run(exe, row.pruneArgs) }.value
        busy = false
        if result.status == 0 {
            let line = result.out.split(whereSeparator: \.isNewline)
                .last { $0.lowercased().contains("reclaimed") }
            message = line.map(String.init) ?? "\(row.title): done"
        } else {
            message = "\(row.title) failed: " + (result.err.split(whereSeparator: \.isNewline).first.map(String.init) ?? "unknown error")
        }
        await refresh()
    }
}
