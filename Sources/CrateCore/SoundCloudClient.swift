import Foundation

public struct SCTrack: Sendable {
    public let scId: String
    public let scURL: String
    public let rawTitle: String
    public let uploader: String
    public let durationS: Int
    public let downloadable: Bool
    public let purchaseURL: String
    public let purchaseTitle: String
    public let artURL: String
}

public enum Gates {
    static let domains = ["hypeddit.com", "toneden.io", "theartistunion.com", "gate.fm"]
    static let storeWords = ["buy", "stream", "purchase", "store", "shop"]

    /// Gate hosts also serve store fanlinks, so the uploader's own label
    /// decides: "free" marks a gate, store words mark a fanlink, and only an
    /// unlabeled link falls back to the gate-host list.
    public static func isGate(purchaseURL: String, purchaseTitle: String) -> Bool {
        guard !purchaseURL.isEmpty else { return false }
        let title = purchaseTitle.lowercased()
        if title.contains("free") { return true }
        if storeWords.contains(where: { title.contains($0) }) { return false }
        let host = URL(string: purchaseURL)?.host?.lowercased() ?? ""
        return domains.contains(where: { host.contains($0) })
    }
}

/// SoundCloud api-v2 client authenticated by exported cookies. Read-only.
public final class SoundCloudClient: @unchecked Sendable {
    static let apiV2 = "https://api-v2.soundcloud.com"

    let jar: CookieJar
    let token: String
    let cacheFile: URL
    var clientId: String

    public init(cookiesFile: URL, cacheDir: URL) throws {
        jar = try CookieJar.load(cookiesFile)
        guard let t = jar.value(name: "oauth_token", domainContains: "soundcloud"), !t.isEmpty else {
            throw DJError("no oauth_token cookie; re-export from a logged-in soundcloud.com tab")
        }
        token = t
        cacheFile = cacheDir.appendingPathComponent("sc_client_id.txt")
        clientId = (try? String(contentsOf: cacheFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }

    func headers(forHost host: String) -> [String: String] {
        [
            "Authorization": "OAuth \(token)",
            "Origin": "https://soundcloud.com",
            "Referer": "https://soundcloud.com/",
            "Cookie": jar.headerValue(forHost: host),
        ]
    }

    func discoverClientId() async throws {
        let home = URL(string: "https://soundcloud.com/")!
        let (data, _) = try await HTTP.request(home, headers: headers(forHost: "soundcloud.com"))
        let html = String(data: data, encoding: .utf8) ?? ""
        let scriptRe = #/src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)"/#
        for match in html.matches(of: scriptRe) {
            guard let src = URL(string: String(match.1)) else { continue }
            let (js, _) = try await HTTP.request(src)
            let text = String(data: js, encoding: .utf8) ?? ""
            if let hit = text.firstMatch(of: #/client_id\s*[:=]\s*"([A-Za-z0-9]{20,})"/#) {
                clientId = String(hit.1)
                try? clientId.write(to: cacheFile, atomically: true, encoding: .utf8)
                return
            }
        }
        throw DJError("could not discover a SoundCloud client_id")
    }

    func get(_ pathOrURL: String, query: [String: String] = [:]) async throws -> Any {
        if clientId.isEmpty { try await discoverClientId() }
        for attempt in 1...2 {
            let base = pathOrURL.hasPrefix("http") ? pathOrURL : Self.apiV2 + pathOrURL
            var comps = URLComponents(string: base)!
            var items = comps.queryItems ?? []
            items.append(contentsOf: query.map { URLQueryItem(name: $0.key, value: $0.value) })
            items.removeAll { $0.name == "client_id" }
            items.append(URLQueryItem(name: "client_id", value: clientId))
            comps.queryItems = items
            let url = comps.url!
            let (data, resp) = try await HTTP.request(url, headers: headers(forHost: url.host ?? ""))
            if (resp.statusCode == 401 || resp.statusCode == 403) && attempt == 1 {
                try await discoverClientId()
                continue
            }
            guard (200..<300).contains(resp.statusCode) else {
                throw DJError("soundcloud \(resp.statusCode) for \(url.path)")
            }
            return try HTTP.json(data)
        }
        throw DJError("unreachable")
    }

    public func me() async throws -> [String: Any] {
        JSON.dict(try await get("/me"))
    }

    public func findPlaylist(named name: String) async throws -> (id: String, raw: [String: Any]) {
        let meId = JSON.int(JSON.dict(try await me())["id"]) ?? 0
        var next: String? = "/users/\(meId)/playlists"
        var query = ["limit": "50"]
        while let url = next {
            let page = JSON.dict(try await get(url, query: query))
            query = [:]
            for item in JSON.array(page["collection"]) {
                let pl = JSON.dict(item)
                let title = (JSON.string(pl["title"]) ?? "")
                    .trimmingCharacters(in: .whitespaces).lowercased()
                if title == name.trimmingCharacters(in: .whitespaces).lowercased(),
                   let id = JSON.int(pl["id"]) {
                    return (String(id), pl)
                }
            }
            next = JSON.string(page["next_href"])
        }
        throw DJError("no SoundCloud playlist named \(name)")
    }

    public func searchTracks(_ query: String, limit: Int = 20) async throws -> [SCTrack] {
        let page = JSON.dict(try await get("/search/tracks",
                                           query: ["q": query, "limit": String(limit)]))
        return JSON.array(page["collection"]).map(JSON.dict)
            .filter { JSON.int($0["id"]) != nil }
            .map(Self.normalize)
    }

    public func playlistTracks(_ playlistId: String) async throws -> [SCTrack] {
        let pl = JSON.dict(try await get("/playlists/\(playlistId)", query: ["representation": "full"]))
        let items = JSON.array(pl["tracks"]).map(JSON.dict)
        let ids = items.compactMap { JSON.int($0["id"]) }
        var hydrated: [Int: [String: Any]] = [:]
        for item in items where item["title"] != nil {
            if let id = JSON.int(item["id"]) { hydrated[id] = item }
        }
        let missing = ids.filter { hydrated[$0] == nil }
        for chunkStart in stride(from: 0, to: missing.count, by: 50) {
            let chunk = missing[chunkStart..<min(chunkStart + 50, missing.count)]
            let fetched = JSON.array(try await get("/tracks",
                query: ["ids": chunk.map(String.init).joined(separator: ",")]))
            for item in fetched.map(JSON.dict) {
                if let id = JSON.int(item["id"]) { hydrated[id] = item }
            }
        }
        return ids.compactMap { hydrated[$0] }.map(Self.normalize)
    }

    static func normalize(_ t: [String: Any]) -> SCTrack {
        let user = JSON.dict(t["user"])
        var art = JSON.string(t["artwork_url"]) ?? JSON.string(user["avatar_url"]) ?? ""
        art = art.replacingOccurrences(of: "-large.", with: "-t500x500.")
        let hasDownloadsLeft = (t["has_downloads_left"] as? Bool) ?? true
        return SCTrack(
            scId: String(JSON.int(t["id"]) ?? 0),
            scURL: JSON.string(t["permalink_url"]) ?? "",
            rawTitle: JSON.string(t["title"]) ?? "",
            uploader: JSON.string(user["username"]) ?? "",
            durationS: Int((Double(JSON.int(t["duration"]) ?? 0) / 1000).rounded()),
            downloadable: ((t["downloadable"] as? Bool) ?? false) && hasDownloadsLeft,
            purchaseURL: JSON.string(t["purchase_url"]) ?? "",
            purchaseTitle: JSON.string(t["purchase_title"]) ?? "",
            artURL: art)
    }

    /// Native free downloads hand out the uploader's original file.
    public func downloadOriginal(trackId: String, to dir: URL) async throws -> URL {
        let info = JSON.dict(try await get("/tracks/\(trackId)/download"))
        guard let redirect = JSON.string(info["redirectUri"]), let url = URL(string: redirect) else {
            throw DJError("download endpoint returned no redirectUri")
        }
        let (data, resp) = try await HTTP.request(url)
        guard (200..<300).contains(resp.statusCode) else {
            throw DJError("original download failed with \(resp.statusCode)")
        }
        let name = Self.filename(from: resp, fallbackStem: "sc_\(trackId)")
        let dest = dir.appendingPathComponent(name)
        try data.write(to: dest)
        return dest
    }

    static let mimeExt: [String: String] = [
        "audio/wav": ".wav", "audio/x-wav": ".wav", "audio/flac": ".flac",
        "audio/x-flac": ".flac", "audio/aiff": ".aiff", "audio/x-aiff": ".aiff",
        "audio/mpeg": ".mp3", "audio/mp4": ".m4a",
    ]

    public static func filename(from resp: HTTPURLResponse, fallbackStem: String) -> String {
        if let disp = resp.value(forHTTPHeaderField: "Content-Disposition"),
           let match = disp.firstMatch(of: #/filename="?([^";]+)"?/#) {
            return URL(fileURLWithPath: String(match.1)).lastPathComponent
        }
        if let tail = resp.url?.lastPathComponent, tail.contains(".") {
            return tail
        }
        let mime = (resp.value(forHTTPHeaderField: "Content-Type") ?? "")
            .components(separatedBy: ";")[0]
        return fallbackStem + (mimeExt[mime] ?? ".bin")
    }
}
