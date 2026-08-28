import Foundation

public enum HTTP {
    public static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/126.0 Safari/537.36"

    /// Ephemeral session with cookie handling off: Cookie headers we set pass untouched.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    @discardableResult
    public static func request(
        _ url: URL, method: String = "GET",
        headers: [String: String] = [:], body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw DJError("no HTTP response for \(url)") }
        return (data, http)
    }

    public static func json(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }
}

/// Loose navigation over JSONSerialization values.
public enum JSON {
    public static func dict(_ any: Any?) -> [String: Any] { any as? [String: Any] ?? [:] }
    public static func array(_ any: Any?) -> [Any] { any as? [Any] ?? [] }
    public static func string(_ any: Any?) -> String? { any as? String }
    public static func int(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? Double { return Int(n) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    /// Depth-first collection of every dictionary stored under `key`.
    public static func collect(_ any: Any, key: String) -> [[String: Any]] {
        var found: [[String: Any]] = []
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                if let hit = d[key] as? [String: Any] { found.append(hit) }
                for v in d.values { walk(v) }
            } else if let a = node as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(any)
        return found
    }

    /// Depth-first search for the first string stored under `key`.
    public static func firstString(_ any: Any, key: String) -> String? {
        if let d = any as? [String: Any] {
            if let s = d[key] as? String { return s }
            for v in d.values { if let s = firstString(v, key: key) { return s } }
        } else if let a = any as? [Any] {
            for v in a { if let s = firstString(v, key: key) { return s } }
        }
        return nil
    }

    /// Every "text" run string anywhere beneath the node, in document order.
    public static func runTexts(_ any: Any) -> [String] {
        var out: [String] = []
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                if let s = d["text"] as? String, d.count <= 2 { out.append(s) }
                for (_, v) in d.sorted(by: { $0.key < $1.key }) { walk(v) }
            } else if let a = node as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(any)
        return out
    }
}
