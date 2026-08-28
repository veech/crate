import Foundation

public struct YTMCandidate: Sendable, Codable {
    public let videoId: String
    public let title: String
    public let artists: String
    public let durationS: Int
}

/// Minimal YouTube Music InnerTube search. Constants copied from the reference
/// ytmusicapi package: WEB_REMIX client, songs filter param.
public struct YTMusicClient: Sendable {
    static let endpoint = "https://music.youtube.com/youtubei/v1/search?prettyPrint=false"
    static let songsParams = "EgWKAQIIAWoMEA4QChADEAQQCRAF"

    public init() {}

    public func searchSongs(_ query: String) async throws -> [YTMCandidate] {
        let body: [String: Any] = [
            "context": ["client": [
                "clientName": "WEB_REMIX",
                "clientVersion": "1.20250101.01.00",
                "hl": "en",
            ]],
            "query": query,
            "params": Self.songsParams,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let (respData, resp) = try await HTTP.request(
            URL(string: Self.endpoint)!, method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Origin": "https://music.youtube.com",
                "Referer": "https://music.youtube.com/",
            ],
            body: data)
        guard resp.statusCode == 200 else {
            throw DJError("ytm search returned \(resp.statusCode)")
        }
        let json = try HTTP.json(respData)
        return JSON.collect(json, key: "musicResponsiveListItemRenderer")
            .compactMap(Self.candidate)
    }

    static func candidate(_ renderer: [String: Any]) -> YTMCandidate? {
        guard let videoId = JSON.firstString(renderer, key: "videoId") else { return nil }
        let columns = JSON.array(renderer["flexColumns"])
        guard !columns.isEmpty else { return nil }
        let title = JSON.runTexts(columns[0]).joined()
        guard !title.isEmpty else { return nil }

        var artists: [String] = []
        var durationS = 0
        let durationRe = #/^(\d+):(\d{2})(?::(\d{2}))?$/#
        var texts: [String] = []
        for column in columns.dropFirst() { texts.append(contentsOf: JSON.runTexts(column)) }
        texts.append(contentsOf: JSON.runTexts(JSON.array(renderer["fixedColumns"])))
        var pastArtists = false
        for text in texts {
            if let m = text.wholeMatch(of: durationRe) {
                let a = Int(m.1) ?? 0, b = Int(m.2) ?? 0
                if let cRaw = m.3, let c = Int(cRaw) {
                    durationS = a * 3600 + b * 60 + c
                } else {
                    durationS = a * 60 + b
                }
            } else if text.trimmingCharacters(in: .whitespaces) == "•" {
                pastArtists = true
            } else if !pastArtists {
                artists.append(text)
            }
        }
        guard durationS > 0 else { return nil }
        return YTMCandidate(
            videoId: videoId, title: title,
            artists: artists.prefix(4).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces),
            durationS: durationS)
    }
}

public enum Matcher {
    public static let durationToleranceS = 2
    static let genericMixes: Set<String> = ["", "original mix", "original"]

    public static func displayTitle(_ title: String, mix: String) -> String {
        genericMixes.contains(mix.lowercased()) ? title : "\(title) (\(mix))"
    }

    public struct Result: Sendable {
        public let verdict: String  // exact | ambiguous | none
        public let videoId: String?
        public let candidates: [YTMCandidate]
    }

    public static func match(candidates raw: [YTMCandidate], mix: String,
                             durationS: Int) -> Result {
        let candidates = raw.filter { abs($0.durationS - durationS) <= durationToleranceS }
        if candidates.isEmpty { return Result(verdict: "none", videoId: nil, candidates: []) }
        if candidates.count == 1 {
            return Result(verdict: "exact", videoId: candidates[0].videoId, candidates: candidates)
        }
        if !genericMixes.contains(mix.lowercased()) {
            let named = candidates.filter { $0.title.lowercased().contains(mix.lowercased()) }
            if named.count == 1 {
                return Result(verdict: "exact", videoId: named[0].videoId, candidates: candidates)
            }
        }
        return Result(verdict: "ambiguous", videoId: nil, candidates: candidates)
    }
}
