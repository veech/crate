import Foundation

/// Netscape cookies.txt, the format browser exporters and yt-dlp share.
public struct CookieJar: Sendable {
    public struct Entry: Sendable {
        public let domain: String
        public let name: String
        public let value: String
    }

    public let entries: [Entry]

    public static func load(_ url: URL) throws -> CookieJar {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DJError("no cookie file at \(url.path)")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var entries: [Entry] = []
        for rawLine in text.split(separator: "\n") {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#HttpOnly_") {
                line.removeFirst("#HttpOnly_".count)
            } else if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 7 else { continue }
            entries.append(Entry(domain: parts[0], name: parts[5], value: parts[6]))
        }
        return CookieJar(entries: entries)
    }

    public func value(name: String, domainContains fragment: String) -> String? {
        entries.first { $0.name == name && $0.domain.contains(fragment) }?.value
    }

    public func headerValue(forHost host: String) -> String {
        entries
            .filter { entry in
                let d = entry.domain.hasPrefix(".") ? String(entry.domain.dropFirst()) : entry.domain
                return host == d || host.hasSuffix("." + d)
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}
