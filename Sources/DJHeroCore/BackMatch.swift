import Foundation

/// Matches a sourceless library file back to a SoundCloud upload that offers a
/// download, so an old rip can be upgraded to the uploader's original file.
public enum BackMatch {
    static func tokens(_ s: String) -> Set<String> {
        Set(Store.normalizeName("", s).split(separator: " ").map(String.init))
    }

    /// Search → keep results that offer a download and fit the duration gate →
    /// require name overlap → a lone strict survivor matches, anything murkier
    /// goes to the LLM, which may reject them all.
    public static func find(title: String, artist: String, durationS: Int,
                            client: SoundCloudClient,
                            settings: AppSettings) async -> SCTrack? {
        guard let results = try? await client.searchTracks("\(artist) \(title)") else {
            return nil
        }
        let wanted = tokens(title)
        let candidates = results.filter { c in
            (c.downloadable
                || Gates.isGate(purchaseURL: c.purchaseURL, purchaseTitle: c.purchaseTitle))
                && abs(c.durationS - durationS) <= Matcher.durationToleranceS
        }.filter { c in
            let have = tokens(c.rawTitle + " " + c.uploader)
            return wanted.isEmpty
                || wanted.intersection(have).count * 2 >= wanted.count
        }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1,
           tokens(candidates[0].rawTitle + " " + candidates[0].uploader).isSuperset(of: wanted) {
            return candidates[0]
        }
        let wrapped = candidates.map {
            YTMCandidate(videoId: $0.scId, title: $0.rawTitle,
                         artists: $0.uploader, durationS: $0.durationS)
        }
        guard let verdict = await Anthropic.adjudicate(
                  model: settings.anthropicModel,
                  wanted: "\(title) — \(artist) (\(durationS)s)",
                  candidates: wrapped, key: settings.anthropicApiKey,
                  service: "SoundCloud"),
              let id = verdict.videoId else { return nil }
        return candidates.first { $0.scId == id }
    }
}
