import Foundation

public struct DJError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct Config: Sendable {
    public let dataDir: URL

    public init(dataDir: URL? = nil) {
        self.dataDir = dataDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("slipmat", isDirectory: true)
        for dir in [authDir, stagingDir, cacheDir, trashDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public var authDir: URL { dataDir.appendingPathComponent("auth", isDirectory: true) }
    public var stagingDir: URL { dataDir.appendingPathComponent("staging", isDirectory: true) }
    public var cacheDir: URL { dataDir.appendingPathComponent("cache", isDirectory: true) }
    public var trashDir: URL { dataDir.appendingPathComponent("trash", isDirectory: true) }
    public var dbURL: URL { dataDir.appendingPathComponent("slipmat.sqlite3") }

    public func cookies(_ service: String) -> URL {
        authDir.appendingPathComponent("\(service).txt")
    }

    public func saveCookies(_ service: String, text: String) throws {
        try text.write(to: cookies(service), atomically: true, encoding: .utf8)
    }
}
