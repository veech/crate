import Foundation

/// One reconcile cycle: poll both intakes, advance every actionable track.
/// Faithful port of the reference reconcile.py; no external writes anywhere.
public actor Reconciler {
    let cfg: Config
    let store: Store
    public private(set) var running = false

    public init(cfg: Config, store: Store) {
        self.cfg = cfg
        self.store = store
    }

    public func cycle() async throws {
        guard !running else { return }
        running = true
        defer { running = false }

        try recoverInterrupted()
        let settings = try store.loadSettings()
        let sc = try? SoundCloudClient(cookiesFile: cfg.cookies("soundcloud"),
                                       cacheDir: cfg.cacheDir)
        await pollBeatport(settings)
        await pollSoundCloud(settings, sc)
        await pollYouTube(settings)
        await resolveNew(settings)
        await fetchResolved(settings, sc)
        await normalizeFetched(settings)
        if Task.isCancelled { return }
        try purchasesScan(settings)
    }

    /// At most `cap` tracks in flight per stage. The store serializes its own
    /// writes, and the heavy work — network and child processes — releases the
    /// actor, so tracks genuinely overlap. Cancellation stops new launches and
    /// drains the running ones.
    func forEachConcurrent<T: Sendable>(_ items: [T], cap: Int,
                                        _ work: @Sendable @escaping (T) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            var launched = 0
            while launched < cap, let item = iterator.next() {
                group.addTask { await work(item) }
                launched += 1
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let item = iterator.next() else { continue }
                group.addTask { await work(item) }
            }
        }
    }

    /// A crash mid-stage leaves resolving/fetching/normalizing rows; step them back.
    func recoverInterrupted() throws {
        for (stuck, back) in [("resolving", "new"), ("fetching", "resolved"),
                              ("normalizing", "fetched")] {
            for track in try store.inStatus(stuck) {
                try store.setStatus(track.id, back, "Recovered after interrupt")
            }
        }
    }

    // MARK: polls

    func pollBeatport(_ settings: AppSettings) async {
        guard !settings.bpKeepersPlaylist.isEmpty,
              FileManager.default.fileExists(atPath: cfg.cookies("beatport").path) else { return }
        do {
            let client = try await BeatportClient(cookiesFile: cfg.cookies("beatport"))
            let playlistId = try await client.findPlaylist(named: settings.bpKeepersPlaylist)
            for track in try await client.playlistTracks(playlistId) {
                _ = try store.upsertBeatport(track)
            }
        } catch {
            print("beatport poll failed: \(error)")
        }
    }

    func pollSoundCloud(_ settings: AppSettings, _ sc: SoundCloudClient?) async {
        guard let sc else { return }
        do {
            let playlist = try await sc.findPlaylist(named: settings.scQueuePlaylist)
            for track in try await sc.playlistTracks(playlist.id)
            where (try store.track(scId: track.scId)) == nil {
                let gate = Gates.isGate(purchaseURL: track.purchaseURL,
                                        purchaseTitle: track.purchaseTitle)
                _ = try store.upsertSoundCloud(track, gate: gate)
            }
        } catch {
            print("soundcloud poll failed: \(error)")
        }
    }

    func pollYouTube(_ settings: AppSettings) async {
        guard !settings.ytQueuePlaylist.isEmpty else { return }
        do {
            for item in try await YtDlp.playlistItems(settings.ytQueuePlaylist,
                                                      cookies: cfg.cookies("youtube")) {
                _ = try store.upsertYouTube(item)
            }
        } catch {
            print("youtube poll failed: \(error)")
        }
    }

    // MARK: resolve

    func resolveNew(_ settings: AppSettings) async {
        guard let rows = try? store.inStatus("new") else { return }
        await forEachConcurrent(rows, cap: 4) { track in
            if Task.isCancelled { return }
            try? self.store.setStatus(track.id, "resolving", "Resolving source")
            switch track.origin {
            case "beatport": await self.resolveBeatport(settings, track)
            case "youtube": await self.resolveYouTube(settings, track)
            default: await self.resolveSoundCloud(settings, track)
            }
        }
    }

    func fileDuplicate(_ track: Track) throws -> Bool {
        guard let dup = try store.findFiledDuplicate(artist: track.artist, title: track.title),
              dup.id != track.id else { return false }
        try store.update(track.id, ["chosen_source": "existing", "file_path": dup.filePath])
        try store.setStatus(track.id, "filed", "Already in collection", dup.filePath)
        return true
    }

    func resolveBeatport(_ settings: AppSettings, _ track: Track) async {
        if (try? fileDuplicate(track)) == true { return }
        await resolveViaYTM(settings, track)
    }

    /// A YouTube queue item is its own resolution: the video is the source.
    func resolveYouTube(_ settings: AppSettings, _ track: Track) async {
        var track = track
        let uploader = track.artist.replacingOccurrences(of: " - Topic", with: "")
        let (artist, title) = await Anthropic.splitTitle(
            model: settings.anthropicModel, raw: track.title, uploader: uploader,
            key: settings.anthropicApiKey)
        if Task.isCancelled { return }
        if (artist, title) != (track.artist, track.title) {
            try? store.update(track.id, ["artist": artist, "title": title])
            try? store.record(track.id, "Title split", "\(title) — \(artist)")
            track.artist = artist
            track.title = title
        }
        if (try? fileDuplicate(track)) == true { return }
        try? store.update(track.id, ["chosen_source": "ytm"])
        try? store.setStatus(track.id, "resolved", "From YouTube queue")
    }

    func resolveSoundCloud(_ settings: AppSettings, _ track: Track) async {
        var track = track
        let (artist, title) = await Anthropic.splitTitle(
            model: settings.anthropicModel, raw: track.title, uploader: track.artist,
            key: settings.anthropicApiKey)
        // A cancelled split falls back to the heuristic; don't let it stick.
        if Task.isCancelled { return }
        if (artist, title) != (track.artist, track.title) {
            try? store.update(track.id, ["artist": artist, "title": title])
            try? store.record(track.id, "Title split", "\(title) — \(artist)")
            track.artist = artist
            track.title = title
        }
        if (try? fileDuplicate(track)) == true { return }
        if track.scDownloadable {
            try? store.update(track.id, ["chosen_source": "sc_free_dl"])
            try? store.setStatus(track.id, "resolved", "Native free download available")
            return
        }
        if !track.gateURL.isEmpty {
            try? store.setStatus(track.id, "held_gate", "Free download behind gate", track.gateURL)
            return
        }
        let probe = await YtDlp.probeSoundCloud(
            url: track.scURL, cookies: cfg.cookies("soundcloud"), expectedS: track.durationS)
        if probe.ok {
            try? store.update(track.id, ["chosen_source": "sc_rip"])
            try? store.setStatus(track.id, "resolved", "Full stream available; ripping")
        } else {
            try? store.record(track.id, "SoundCloud stream blocked", probe.reason)
            await resolveViaYTM(settings, track)
        }
    }

    func resolveViaYTM(_ settings: AppSettings, _ track: Track) async {
        let query = "\(track.artist) \(Matcher.displayTitle(track.title, mix: track.mix))"
        let candidates: [YTMCandidate]
        do {
            candidates = try await YTMusicClient().searchSongs(query)
        } catch {
            if Task.isCancelled { return }
            try? store.setStatus(track.id, "needs_review", "YTM search failed", "\(error)")
            return
        }
        var result = Matcher.match(candidates: candidates, mix: track.mix,
                                   durationS: track.durationS)
        if result.verdict == "ambiguous" {
            let wanted = "\(track.artist) — \(track.title)"
                + (track.mix.isEmpty ? "" : " (\(track.mix))") + " [\(track.durationS)s]"
            if let verdict = await Anthropic.adjudicate(
                model: settings.anthropicModel, wanted: wanted, candidates: result.candidates,
                key: settings.anthropicApiKey) {
                if let videoId = verdict.videoId {
                    try? store.record(track.id, "LLM adjudicated match", verdict.reason)
                    result = Matcher.Result(verdict: "exact", videoId: videoId,
                                            candidates: result.candidates)
                } else {
                    try? store.setStatus(track.id, "needs_review", "LLM rejected all candidates",
                                         Self.encode(result.candidates))
                    return
                }
            } else {
                if Task.isCancelled { return }
                try? store.setStatus(track.id, "needs_review", "Ambiguous YTM match",
                                     Self.encode(result.candidates))
                return
            }
        }
        if result.verdict == "exact", let videoId = result.videoId {
            try? store.update(track.id, ["ytm_id": videoId, "chosen_source": "ytm"])
            try? store.setStatus(track.id, "resolved", "Matched on YTM", videoId)
        } else if result.verdict == "none" {
            try? store.setStatus(track.id, "buy_list", "No YTM match; buy it")
        }
    }

    static func encode(_ candidates: [YTMCandidate]) -> String {
        guard let data = try? JSONEncoder().encode(candidates) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: fetch

    func fetchResolved(_ settings: AppSettings, _ sc: SoundCloudClient?) async {
        guard let rows = try? store.inStatus("resolved") else { return }
        await forEachConcurrent(rows, cap: 3) { track in
            if Task.isCancelled { return }
            await self.fetchOne(track, sc)
        }
    }

    func fetchOne(_ track: Track, _ sc: SoundCloudClient?) async {
        let source = track.chosenSource ?? ""
        if source == "sc_free_dl" && sc == nil { return }
        if source == "ytm"
            && !FileManager.default.fileExists(atPath: cfg.cookies("youtube").path) {
            return
        }
        try? store.setStatus(track.id, "fetching", "Downloading via \(source)")
        do {
            let file: URL
            var formatId = "?"
            switch source {
            case "ytm":
                (file, formatId) = try await YtDlp.downloadYTM(
                    videoId: track.ytmId ?? "", staging: cfg.stagingDir,
                    cookies: cfg.cookies("youtube"))
                if formatId != YtDlp.premiumFormat {
                    try? store.record(track.id, "Warning: below 256k floor",
                                      "Premium cookies missing or expired?")
                }
            case "sc_rip":
                (file, formatId) = try await YtDlp.downloadSoundCloud(
                    url: track.scURL, staging: cfg.stagingDir,
                    cookies: cfg.cookies("soundcloud"))
            case "sc_free_dl":
                file = try await sc!.downloadOriginal(trackId: track.scId ?? "",
                                                      to: cfg.stagingDir)
                formatId = "original"
            default:
                try? store.setStatus(track.id, "needs_review", "Unknown source", source)
                return
            }
            try? store.update(track.id, ["file_path": file.path])
            try? store.setStatus(track.id, "fetched", "Downloaded (format \(formatId))")
        } catch {
            // A stopped cycle leaves the row in fetching; recovery rewinds it.
            if Task.isCancelled { return }
            try? store.setStatus(track.id, "needs_review", "Download failed", "\(error)")
        }
    }

    // MARK: normalize + file

    func normalizeFetched(_ settings: AppSettings) async {
        guard let rows = try? store.inStatus("fetched") else { return }
        await forEachConcurrent(rows, cap: 2) { track in
            if Task.isCancelled { return }
            await self.normalizeOne(track, settings)
        }
    }

    func normalizeOne(_ track: Track, _ settings: AppSettings) async {
        try? store.setStatus(track.id, "normalizing", "Converting and tagging")
        let title = Matcher.displayTitle(track.title, mix: track.mix)
        do {
            guard let raw = track.filePath else { throw DJError("no file recorded") }
            let converted = try await FFmpeg.convertToTarget(
                URL(fileURLWithPath: raw), target: settings.targetFormat)
            let (suspect, spectrum) = await FFmpeg.spectralSuspect(converted)
            if suspect {
                try? store.record(track.id, "Warning: probable transcode",
                                  "Spectral cliff (\(spectrum)) — consider buying this one")
            }
            let art = await fetchArt(track.artURL)
            try await FFmpeg.stripAndTag(converted, title: title, artist: track.artist,
                                         art: art)
            let dest: URL
            // A back-matched track replaces its old rip where it lives,
            // keeping the genre the user already assigned.
            if let up = track.upgradePath, !up.isEmpty {
                let old = URL(fileURLWithPath: up)
                if let genre = await FFmpeg.probeTags(old)?.genre, !genre.isEmpty {
                    try await FFmpeg.writeTags(converted, ["genre": genre])
                }
                dest = try Self.fileIntoCollection(
                    converted, collectionDir: old.deletingLastPathComponent(),
                    title: title, artist: track.artist)
                if old.path != dest.path, FileManager.default.fileExists(atPath: old.path) {
                    try? FileManager.default.removeItem(at: old)
                    try? store.record(track.id, "Removed superseded file", old.path)
                }
                try? store.deleteLibraryFiles([up, dest.path])
                try? store.deleteFileSource(up)
                try? store.update(track.id, ["upgrade_path": nil])
            } else {
                dest = try Self.fileIntoCollection(
                    converted, collectionDir: URL(fileURLWithPath: settings.collectionDir),
                    title: title, artist: track.artist)
            }
            try? store.update(track.id, ["file_path": dest.path])
            try? store.markFiledNow(track.id)
            try? store.setStatus(track.id, "filed", "Filed", dest.path)
        } catch {
            if Task.isCancelled { return }
            try? store.setStatus(track.id, "needs_review", "Normalize failed", "\(error)")
        }
    }

    func fetchArt(_ url: String) async -> Data? {
        guard !url.isEmpty, let u = URL(string: url),
              let (data, resp) = try? await HTTP.request(u),
              resp.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    public static func safeFilename(title: String, artist: String, ext: String) -> String {
        let raw = "\(title) - \(artist).\(ext)"
        let cleaned = raw.map { ch -> Character in
            "\\/:*?\"<>|".contains(ch) || ch.asciiValue.map { $0 < 0x20 } == true ? "_" : ch
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    static func fileIntoCollection(_ file: URL, collectionDir: URL, title: String,
                                   artist: String) throws -> URL {
        try FileManager.default.createDirectory(at: collectionDir,
                                                withIntermediateDirectories: true)
        let dest = collectionDir.appendingPathComponent(
            safeFilename(title: title, artist: artist, ext: file.pathExtension))
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: file, to: dest)
        return dest
    }

    // MARK: purchases

    func purchasesScan(_ settings: AppSettings) throws {
        let downloads = URL(fileURLWithPath: settings.downloadsDir)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: downloads.path)
        else { return }
        let purchaseRe = #/^(\d+)_.+\.(wav|aiff?|flac|mp3|m4a)$/#.ignoresCase()
        for name in names.sorted() {
            guard let match = name.wholeMatch(of: purchaseRe) else { continue }
            guard let track = try store.track(bpId: String(match.1)),
                  track.chosenSource != "purchase" else { continue }
            let staged = cfg.stagingDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: staged.path) {
                try? FileManager.default.removeItem(at: staged)
            }
            try FileManager.default.copyItem(at: downloads.appendingPathComponent(name),
                                             to: staged)
            let previous = track.filePath
            try store.update(track.id, ["chosen_source": "purchase", "file_path": staged.path])
            try store.setStatus(track.id, "fetched", "Purchase found in downloads", name)
            if let previous,
               previous.hasPrefix(settings.collectionDir),
               FileManager.default.fileExists(atPath: previous) {
                try? FileManager.default.removeItem(atPath: previous)
                try store.record(track.id, "Removed superseded file", previous)
            }
        }
    }
}
