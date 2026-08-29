import Foundation

public struct BPTrack: Sendable {
    public let bpId: String
    public let title: String
    public let mix: String
    public let artist: String
    public let durationS: Int
    public let artURL: String
}

/// Read-only Beatport v4 client authenticated by exported web-session cookies.
public struct BeatportClient: Sendable {
    static let api = "https://api.beatport.com/v4"
    static let sessionURL = "https://www.beatport.com/api/auth/session"

    let bearer: String

    public init(cookiesFile: URL) async throws {
        let jar = try CookieJar.load(cookiesFile)
        let url = URL(string: Self.sessionURL)!
        let (data, resp) = try await HTTP.request(
            url, headers: ["Cookie": jar.headerValue(forHost: "www.beatport.com")])
        guard resp.statusCode == 200 else {
            throw DJError("beatport session endpoint returned \(resp.statusCode); re-export cookies")
        }
        let session = JSON.dict(try? HTTP.json(data))
        let token = JSON.string(JSON.dict(session["token"])["accessToken"])
            ?? JSON.string(session["accessToken"])
        guard let token, !token.isEmpty else {
            throw DJError("no access token in beatport session response; re-export cookies")
        }
        bearer = token
    }

    func get(_ pathOrURL: String, query: [String: String] = [:]) async throws -> Any {
        let base = pathOrURL.hasPrefix("http") ? pathOrURL : Self.api + pathOrURL
        var comps = URLComponents(string: base)!
        if !query.isEmpty {
            var items = comps.queryItems ?? []
            items.append(contentsOf: query.map { URLQueryItem(name: $0.key, value: $0.value) })
            comps.queryItems = items
        }
        let (data, resp) = try await HTTP.request(
            comps.url!, headers: ["Authorization": "Bearer \(bearer)"])
        guard (200..<300).contains(resp.statusCode) else {
            throw DJError("beatport \(resp.statusCode) for \(comps.path)")
        }
        return try HTTP.json(data)
    }

    func paged(_ path: String) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        var next: String? = path
        var query = ["per_page": "100"]
        while let url = next {
            let page = JSON.dict(try await get(url, query: query))
            query = [:]
            results.append(contentsOf: JSON.array(page["results"]).map(JSON.dict))
            next = JSON.string(page["next"])
        }
        return results
    }

    public func myAccount() async throws -> [String: Any] {
        JSON.dict(try await get("/my/account/"))
    }

    public func findPlaylist(named name: String) async throws -> String {
        for pl in try await paged("/my/playlists/") {
            let title = (JSON.string(pl["name"]) ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            if title == name.trimmingCharacters(in: .whitespaces).lowercased(),
               let id = JSON.int(pl["id"]) {
                return String(id)
            }
        }
        throw DJError("no Beatport playlist named \(name)")
    }

    public func playlistTracks(_ playlistId: String) async throws -> [BPTrack] {
        try await paged("/my/playlists/\(playlistId)/tracks/").map { item in
            let t = JSON.dict(item["track"] ?? item)
            let artists = JSON.array(t["artists"]).map(JSON.dict)
                .compactMap { JSON.string($0["name"]) }
                .joined(separator: ", ")
            let image = JSON.dict(JSON.dict(t["release"])["image"])
            return BPTrack(
                bpId: String(JSON.int(t["id"]) ?? 0),
                title: JSON.string(t["name"]) ?? "",
                mix: JSON.string(t["mix_name"]) ?? "",
                artist: artists,
                durationS: Int((Double(JSON.int(t["length_ms"]) ?? 0) / 1000).rounded()),
                artURL: JSON.string(image["uri"]) ?? "")
        }
    }
}
