import Foundation

/// Matches a sourceless library file back to a SoundCloud upload that offers a
/// download, so an old rip can be upgraded to the uploader's original file.
public enum BackMatch {
    static func tokens(_ s: String) -> Set<String> {
        Set(Store.normalizeName("", s).split(separator: " ").map(String.init))
    }

    public enum Outcome: Sendable {
        case match(SCTrack)
        /// The track is on SoundCloud but no upload offers a download.
        case noDownload(SCTrack)
        case none
    }

    /// Search → keep results that fit the duration gate and overlap on name →
    /// among those offering a download, a lone strict survivor matches and
    /// anything murkier goes to the LLM, which may reject them all.
    public static func find(title: String, artist: String, durationS: Int,
                            client: SoundCloudClient,
                            settings: AppSettings) async -> Outcome {
        guard let results = try? await client.searchTracks("\(artist) \(title)") else {
            return .none
        }
        let wanted = tokens(title)
        func strict(_ c: SCTrack) -> Bool {
            tokens(c.rawTitle + " " + c.uploader).isSuperset(of: wanted)
        }
        let plausible = results.filter { c in
            let have = tokens(c.rawTitle + " " + c.uploader)
            return abs(c.durationS - durationS) <= Matcher.durationToleranceS
                && (wanted.isEmpty || wanted.intersection(have).count * 2 >= wanted.count)
        }
        let offering = plausible.filter {
            $0.downloadable
                || Gates.isGate(purchaseURL: $0.purchaseURL, purchaseTitle: $0.purchaseTitle)
        }
        if offering.isEmpty {
            if let found = plausible.first(where: strict) ?? plausible.first {
                return .noDownload(found)
            }
            return .none
        }
        if offering.count == 1, strict(offering[0]) {
            return .match(offering[0])
        }
        let wrapped = offering.map {
            YTMCandidate(videoId: $0.scId, title: $0.rawTitle,
                         artists: $0.uploader, durationS: $0.durationS)
        }
        guard let verdict = await Anthropic.adjudicate(
                  model: settings.anthropicModel,
                  wanted: "\(title) — \(artist) (\(durationS)s)",
                  candidates: wrapped, key: settings.anthropicApiKey,
                  service: "SoundCloud"),
              let id = verdict.videoId,
              let picked = offering.first(where: { $0.scId == id }) else { return .none }
        return .match(picked)
    }
}
