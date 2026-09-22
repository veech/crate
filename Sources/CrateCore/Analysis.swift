import Foundation

public struct FileAnalysis: Sendable {
    public var ce: Double
    public var cu: Double
    public var pc: Double
    public var pq: Double

    public init(ce: Double, cu: Double, pc: Double, pq: Double) {
        self.ce = ce
        self.cu = cu
        self.pc = pc
        self.pq = pq
    }
}

/// Perceptual quality scores from Meta's audiobox-aesthetics model, run as a
/// uv-installed CLI (`uv tool install audiobox-aesthetics --with requests
/// --with torchcodec`). PQ — production quality — is the axis that exposes
/// bad rips and live recordings. Scores stay in the DB, never in tags.
public enum Analyzer {
    /// torch's MPS backend has hung the GPU driver under sustained load — a
    /// hard system freeze, not a crash — and offers no switch to refuse the
    /// GPU (verified against torch 2.13). So the tool runs through its own
    /// python with the patch in the open: MPS is disabled on the way in and
    /// inference stays on CPU. Slower, but it cannot take the machine down.
    static let bootstrap = """
        import sys
        import torch
        torch.backends.mps.is_available = lambda: False
        from audiobox_aesthetics.cli import app
        sys.exit(app())
        """

    static func toolPython() throws -> URL {
        let python = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/uv/tools/audiobox-aesthetics/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw DJError("audio-aes not installed — run: uv tool install"
                + " audiobox-aesthetics --with requests --with torchcodec")
        }
        return python
    }

    /// Results come back in input order, one per path.
    public static func run(_ paths: [String], cacheDir: URL) async throws -> [FileAnalysis] {
        let tool = try toolPython()
        var lines: [String] = []
        for path in paths {
            let data = try JSONSerialization.data(withJSONObject: ["path": path])
            lines.append(String(data: data, encoding: .utf8) ?? "")
        }
        let input = cacheDir.appendingPathComponent("aes-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: input, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: input) }

        // torchcodec links versioned libav dylibs (ffmpeg 4-7 today). The
        // keg-only ffmpeg@7 keeps those stable while the main ffmpeg floats.
        let result = try await ProcessRunner.run(
            tool, ["-c", Self.bootstrap, input.path, "--batch-size", "1"],
            env: ["DYLD_FALLBACK_LIBRARY_PATH":
                    "/opt/homebrew/opt/ffmpeg@7/lib:/opt/homebrew/lib"])
        guard result.status == 0 else {
            throw DJError("audio-aes failed: " + YtDlp.tail(result.stderrText))
        }
        let scores = result.stdoutText.split(separator: "\n").compactMap { line -> FileAnalysis? in
            guard let root = try? HTTP.json(Data(line.utf8)) else { return nil }
            let obj = JSON.dict(root)
            func score(_ key: String) -> Double? { (obj[key] as? NSNumber)?.doubleValue }
            guard let ce = score("CE"), let cu = score("CU"),
                  let pc = score("PC"), let pq = score("PQ") else { return nil }
            return FileAnalysis(ce: ce, cu: cu, pc: pc, pq: pq)
        }
        guard scores.count == paths.count else {
            throw DJError("audio-aes returned \(scores.count) results for \(paths.count) files")
        }
        return scores
    }
}
