import Foundation

public enum YtDlp {
    public static let premiumFormat = "141"  // 256 kbps AAC, Premium accounts only
    static let formatChain = "141/bestaudio[ext=m4a]/bestaudio"

    static func commonArgs(cookies: URL?) -> [String] {
        var args = ["--no-progress", "--js-runtimes", "bun"]
        if let cookies, FileManager.default.fileExists(atPath: cookies.path) {
            args += ["--cookies", cookies.path]
        }
        return args
    }

    static func info(url: String, cookies: URL?) async throws -> [String: Any] {
        let tool = try Binaries.find("yt-dlp")
        let result = try await ProcessRunner.run(tool, commonArgs(cookies: cookies) + ["-J", url])
        guard result.status == 0, !result.stdout.isEmpty else {
            throw DJError(Self.tail(result.stderrText))
        }
        return JSON.dict(try HTTP.json(result.stdout))
    }

    /// Premium cookies expose format 141 on YTM tracks; free ones do not.
    public static func probePremium(cookies: URL) async throws -> Bool {
        let info = try await info(url: "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
                                  cookies: cookies)
        return JSON.array(info["formats"]).map(JSON.dict)
            .contains { JSON.string($0["format_id"]) == premiumFormat }
    }

    /// A full-length stream must exist; DRM'd Go+ tracks expose only a snippet.
    public static func probeSoundCloud(url: String, cookies: URL?,
                                       expectedS: Int) async -> (ok: Bool, reason: String) {
        do {
            let info = try await info(url: url, cookies: cookies)
            let duration = JSON.int(info["duration"]) ?? 0
            if expectedS > 0 && duration < expectedS - 45 {
                return (false, "only a \(duration)s preview stream is available")
            }
            return (true, "")
        } catch {
            return (false, "\(error)")
        }
    }

    static func download(url: String, staging: URL, cookies: URL?,
                         format: String) async throws -> (file: URL, formatId: String) {
        let tool = try Binaries.find("yt-dlp")
        let args = commonArgs(cookies: cookies) + [
            "-f", format,
            "-o", staging.appendingPathComponent("%(id)s.%(ext)s").path,
            "--no-simulate", "--quiet",
            "--print", "format_id",
            "--print", "after_move:filepath",
            url,
        ]
        let result = try await ProcessRunner.run(tool, args)
        guard result.status == 0 else { throw DJError(Self.tail(result.stderrText)) }
        let lines = result.stdoutText.split(separator: "\n").map(String.init)
        guard let path = lines.last(where: { $0.hasPrefix("/") }) else {
            throw DJError("yt-dlp reported no output file")
        }
        let formatId = lines.first { !$0.hasPrefix("/") && !$0.isEmpty } ?? "?"
        return (URL(fileURLWithPath: path), formatId)
    }

    public static func downloadYTM(videoId: String, staging: URL,
                                   cookies: URL?) async throws -> (URL, String) {
        try await download(url: "https://music.youtube.com/watch?v=\(videoId)",
                           staging: staging, cookies: cookies, format: formatChain)
    }

    public static func downloadSoundCloud(url: String, staging: URL,
                                          cookies: URL?) async throws -> (URL, String) {
        try await download(url: url, staging: staging, cookies: cookies, format: "bestaudio")
    }

    static func tail(_ text: String) -> String {
        let lines = text.split(separator: "\n").filter { !$0.isEmpty }
        return lines.suffix(3).joined(separator: " | ")
    }
}
