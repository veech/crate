import Foundation

public struct DJError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct Config: Sendable {
    public let dataDir: URL

    public init(dataDir: URL? = nil) throws {
        if let dataDir {
            self.dataDir = dataDir
        } else {
            let supportDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let current = supportDir.appendingPathComponent("crate", isDirectory: true)
            let legacy = supportDir.appendingPathComponent("slipmat", isDirectory: true)
            try Self.migrateLegacyState(from: legacy, to: current)
            self.dataDir = current
        }
        for dir in [authDir, stagingDir, cacheDir, trashDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func migrateLegacyState(from legacy: URL, to current: URL) throws {
        let files = FileManager.default
        if !files.fileExists(atPath: current.path), files.fileExists(atPath: legacy.path) {
            try files.moveItem(at: legacy, to: current)
        }

        let oldBase = current.appendingPathComponent("slipmat.sqlite3").path
        let newBase = current.appendingPathComponent("crate.sqlite3").path
        guard files.fileExists(atPath: oldBase), !files.fileExists(atPath: newBase) else { return }

        for suffix in ["-wal", "-shm", "-journal", ""] {
            let source = oldBase + suffix
            guard files.fileExists(atPath: source) else { continue }
            let target = newBase + suffix
            guard !files.fileExists(atPath: target) else {
                throw DJError("cannot rename existing database sidecar: \(target)")
            }
            try files.moveItem(atPath: source, toPath: target)
        }
    }

    public var authDir: URL { dataDir.appendingPathComponent("auth", isDirectory: true) }
    public var stagingDir: URL { dataDir.appendingPathComponent("staging", isDirectory: true) }
    public var cacheDir: URL { dataDir.appendingPathComponent("cache", isDirectory: true) }
    public var trashDir: URL { dataDir.appendingPathComponent("trash", isDirectory: true) }
    public var dbURL: URL { dataDir.appendingPathComponent("crate.sqlite3") }

    public func cookies(_ service: String) -> URL {
        authDir.appendingPathComponent("\(service).txt")
    }

    public func saveCookies(_ service: String, text: String) throws {
        try text.write(to: cookies(service), atomically: true, encoding: .utf8)
    }
}
