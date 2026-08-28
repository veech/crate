import Foundation

/// Anthropic Messages API with structured outputs. Used for two things only:
/// messy SoundCloud title splitting and ambiguous-match adjudication.
public enum Anthropic {
    public static func resolveKey(_ stored: String?) -> String? {
        if let stored, !stored.isEmpty { return stored }
        return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    }

    static func structured(model: String, prompt: String, schema: [String: Any],
                           key stored: String?) async throws -> [String: Any]? {
        guard let key = resolveKey(stored) else { return nil }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "messages": [["role": "user", "content": prompt]],
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
        ]
        let (data, resp) = try await HTTP.request(
            URL(string: "https://api.anthropic.com/v1/messages")!, method: "POST",
            headers: [
                "x-api-key": key,
                "anthropic-version": "2023-06-01",
                "Content-Type": "application/json",
            ],
            body: JSONSerialization.data(withJSONObject: body))
        guard resp.statusCode == 200 else {
            throw DJError("anthropic \(resp.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        let message = JSON.dict(try HTTP.json(data))
        guard let text = JSON.string(JSON.dict(JSON.array(message["content"]).first)["text"]),
              let parsed = try? HTTP.json(Data(text.utf8)) else { return nil }
        return JSON.dict(parsed)
    }

    public static func countTokens(model: String, key stored: String?) async throws {
        guard let key = resolveKey(stored) else { throw DJError("no API key configured") }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "ping"]],
        ]
        let (data, resp) = try await HTTP.request(
            URL(string: "https://api.anthropic.com/v1/messages/count_tokens")!, method: "POST",
            headers: [
                "x-api-key": key,
                "anthropic-version": "2023-06-01",
                "Content-Type": "application/json",
            ],
            body: JSONSerialization.data(withJSONObject: body))
        guard resp.statusCode == 200 else {
            throw DJError("anthropic \(resp.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        _ = data
    }

    static func heuristicSplit(raw: String, uploader: String) -> (artist: String, title: String) {
        if let range = raw.range(of: " - ") {
            let artist = String(raw[..<range.lowerBound])
            let title = String(raw[range.upperBound...])
            return (artist.trimmingCharacters(in: .whitespaces),
                    title.trimmingCharacters(in: .whitespaces))
        }
        return (uploader.trimmingCharacters(in: .whitespaces),
                raw.trimmingCharacters(in: .whitespaces))
    }

    public static func splitTitle(model: String, raw: String, uploader: String,
                                  key: String?) async -> (artist: String, title: String) {
        let prompt = """
            SoundCloud track metadata is messy. Determine the artist and the clean track \
            title for tagging a DJ library file.

            Raw title: \(raw)
            Uploader account: \(uploader)

            Keep mix/edit/remix qualifiers in the title, in parentheses. Remove noise like \
            "FREE DOWNLOAD", "OUT NOW", emoji, and label prefixes. The uploader is the \
            artist only when the title itself does not name one.
            """
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["artist": ["type": "string"], "title": ["type": "string"]],
            "required": ["artist", "title"],
            "additionalProperties": false,
        ]
        if let out = try? await structured(model: model, prompt: prompt, schema: schema, key: key),
           let artist = JSON.string(out["artist"])?.trimmingCharacters(in: .whitespaces),
           let title = JSON.string(out["title"])?.trimmingCharacters(in: .whitespaces),
           !artist.isEmpty, !title.isEmpty {
            return (artist, title)
        }
        return heuristicSplit(raw: raw, uploader: uploader)
    }

    public struct Verdict: Sendable {
        public let videoId: String?
        public let reason: String
    }

    /// nil means no verdict (no key or API failure); the track goes to human review.
    public static func adjudicate(model: String, wanted: String,
                                  candidates: [YTMCandidate], key: String?) async -> Verdict? {
        guard resolveKey(key) != nil else { return nil }
        let list = candidates
            .map { "- videoId \($0.videoId): \($0.title) — \($0.artists) (\($0.durationS)s)" }
            .joined(separator: "\n")
        let prompt = """
            A DJ library tool must decide which YouTube Music result IS this exact track \
            (same recording, same mix/edit), or reject all of them.

            Wanted track: \(wanted)

            Candidates:
            \(list)

            Pick the candidate that is the same recording and the same mix. Radio edits, \
            remixes, sped-up versions, covers, and live versions are different tracks. If \
            no candidate is certainly the same, return null for videoId.
            """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "videoId": ["type": ["string", "null"]],
                "reason": ["type": "string"],
            ],
            "required": ["videoId", "reason"],
            "additionalProperties": false,
        ]
        guard let out = try? await structured(model: model, prompt: prompt, schema: schema, key: key),
              let reason = JSON.string(out["reason"]) else { return nil }
        return Verdict(videoId: JSON.string(out["videoId"]), reason: reason)
    }
}
