import Foundation

/// Runs a child process and collects its output without pipe readers or dispatch queues: output goes to
/// temporary files and the wait is a polling loop, so several runs at once can never starve each other of
/// threads (this once hung the tests on a runner with few cores).
enum ProcessRunner {
    struct Result {
        var status: Int32
        var out: String
        var err: String
    }

    /// Returns nil if the process could not start or did not finish within `timeout` seconds.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    timeout: TimeInterval) -> Result? {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dcc-proc-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out"), errURL = base.appendingPathExtension("err")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil),
              FileManager.default.createFile(atPath: errURL.path, contents: nil),
              let outH = try? FileHandle(forWritingTo: outURL), let errH = try? FileHandle(forWritingTo: errURL)
        else { return nil }
        defer {
            try? outH.close(); try? errH.close()
            try? FileManager.default.removeItem(at: outURL); try? FileManager.default.removeItem(at: errURL)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = environment
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
        return Result(status: p.terminationStatus, out: String(decoding: out, as: UTF8.self),
                      err: String(decoding: err, as: UTF8.self))
    }
}
