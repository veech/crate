import Foundation

public enum FFmpeg {
    static let losslessExts: Set<String> = ["wav", "aif", "aiff", "flac"]

    /// Lossless sources convert to the target container; lossy files keep theirs.
    public static func convertToTarget(_ path: URL, target: String) async throws -> URL {
        var ext = path.pathExtension.lowercased()
        if ext == "aif" { ext = "aiff" }
        guard losslessExts.contains(ext), ext != target else { return path }
        let out = path.deletingPathExtension().appendingPathExtension(target)
        let tool = try Binaries.find("ffmpeg")
        let result = try await ProcessRunner.run(tool, ["-y", "-i", path.path, out.path])
        guard result.status == 0 else {
            throw DJError("ffmpeg convert failed: " + YtDlp.tail(result.stderrText))
        }
        try? FileManager.default.removeItem(at: path)
        return out
    }

    /// Remove every tag, then write exactly title, artist, and embedded art.
    public static func stripAndTag(_ path: URL, title: String, artist: String,
                                   art: Data?) async throws {
        let ext = path.pathExtension.lowercased()
        let temp = path.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + "." + ext)
        var args = ["-y", "-i", path.path]

        var artFile: URL?
        // AIFF has no reliable embedded-art path through ffmpeg; tags only.
        if let art, ext == "flac" || ext == "m4a" {
            let file = path.deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString + ".jpg")
            try art.write(to: file)
            artFile = file
            args += ["-i", file.path, "-map", "0:a", "-map", "1",
                     "-c:a", "copy", "-c:v", "mjpeg", "-disposition:v", "attached_pic"]
        } else {
            args += ["-map", "0:a", "-c:a", "copy"]
        }
        args += ["-map_metadata", "-1",
                 "-metadata", "title=\(title)",
                 "-metadata", "artist=\(artist)"]
        if ext == "aiff" || ext == "aif" { args += ["-write_id3v2", "1"] }
        args.append(temp.path)

        defer { if let artFile { try? FileManager.default.removeItem(at: artFile) } }
        let tool = try Binaries.find("ffmpeg")
        let result = try await ProcessRunner.run(tool, args)
        guard result.status == 0 else {
            throw DJError("ffmpeg tag failed: " + YtDlp.tail(result.stderrText))
        }
        _ = try FileManager.default.replaceItemAt(path, withItemAt: temp)
    }

    static let spectralEdges = [10000, 13000, 15000, 17000]

    /// A lossy transcode shows a cliff in the upper spectrum; natural rolloff is
    /// gradual. Bands stop below the clean-256k-AAC encoder cutoff.
    public static func spectralSuspect(_ path: URL) async -> (Bool, String) {
        let n = spectralEdges.count
        var parts = ["asplit=\(n)" + (0..<n).map { "[s\($0)]" }.joined()]
        for (i, lo) in spectralEdges.enumerated() {
            let hi = lo + 1500
            parts.append("[s\(i)]highpass=f=\(lo):p=2,highpass=f=\(lo):p=2,"
                + "lowpass=f=\(hi):p=2,lowpass=f=\(hi):p=2,volumedetect[d\(i)]")
        }
        parts.append((0..<n).map { "[d\($0)]" }.joined() + "amix=inputs=\(n)[out]")
        guard let tool = try? Binaries.find("ffmpeg"),
              let result = try? await ProcessRunner.run(tool, [
                  "-i", path.path, "-filter_complex", parts.joined(separator: ";"),
                  "-map", "[out]", "-f", "null", "-",
              ]) else { return (false, "spectral check unavailable") }

        var found: [(Int, Double)] = []
        for match in result.stderrText.matches(
            of: #/Parsed_volumedetect_(\d+) @ [^\]]*\] mean_volume:\s*(-?[\d.]+)/#) {
            if let idx = Int(match.1), let level = Double(match.2) {
                found.append((idx, level))
            }
        }
        let levels = found.sorted { $0.0 < $1.0 }.map(\.1)
        guard levels.count == n else { return (false, "spectral check unavailable") }
        let steps = (0..<n - 1).map { levels[$0] - levels[$0 + 1] }
        let detail = zip(spectralEdges, levels)
            .map { "\($0 / 1000)k:\(Int($1))dB" }.joined(separator: " ")
        let suspect = (steps.max() ?? 0) >= 8.0 || (levels[0] - levels[n - 1]) >= 15.0
        return (suspect, detail)
    }
}
