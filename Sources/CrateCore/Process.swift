import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    public var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
}

public enum Binaries {
    /// Bundled copy first, then the usual install locations.
    public static func find(_ name: String) throws -> URL {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(name))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            candidates.append(URL(fileURLWithPath: "\(dir)/\(name)"))
        }
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        throw DJError("\(name) not found — install it with brew, or bundle it in the app")
    }
}

public enum ProcessRunner {
    /// Cancellation terminates the child and surfaces as CancellationError.
    public static func run(_ tool: URL, _ args: [String],
                           env extra: [String: String] = [:]) async throws -> ProcessResult {
        let process = Process()
        let result = try await withTaskCancellationHandler {
            try await launch(process, tool, args, extra)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        return result
    }

    static func launch(_ process: Process, _ tool: URL, _ args: [String],
                       _ extra: [String: String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            process.executableURL = tool
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            env.merge(extra) { _, new in new }
            process.environment = env

            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice

            let collector = DataCollector()
            let group = DispatchGroup()
            for (pipe, isOut) in [(out, true), (err, false)] {
                group.enter()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        pipe.fileHandleForReading.readabilityHandler = nil
                        group.leave()
                    } else {
                        collector.append(data, out: isOut)
                    }
                }
            }
            process.terminationHandler = { proc in
                group.notify(queue: .global()) {
                    let (o, e) = collector.snapshot()
                    continuation.resume(returning: ProcessResult(
                        status: proc.terminationStatus, stdout: o, stderr: e))
                }
            }
            do {
                try process.run()
            } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func append(_ data: Data, out isOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isOut { out.append(data) } else { err.append(data) }
    }

    func snapshot() -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (out, err)
    }
}
