import Foundation
import GRDB

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
        Self.migrateLegacyData(into: self.dataDir)
        for dir in [authDir, stagingDir, cacheDir, trashDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public var authDir: URL { dataDir.appendingPathComponent("auth", isDirectory: true) }
    public var stagingDir: URL { dataDir.appendingPathComponent("staging", isDirectory: true) }
    public var cacheDir: URL { dataDir.appendingPathComponent("cache", isDirectory: true) }
    public var trashDir: URL { dataDir.appendingPathComponent("trash", isDirectory: true) }
    public var dbURL: URL { dataDir.appendingPathComponent("slipmat.sqlite3") }

    /// One-time move from the app's old name; stored absolute paths follow.
    static func migrateLegacyData(into dataDir: URL) {
        let fm = FileManager.default
        let legacy = dataDir.deletingLastPathComponent()
            .appendingPathComponent("djhero", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: dataDir.path) else { return }
        try? fm.moveItem(at: legacy, to: dataDir)
        for suffix in ["", "-wal", "-shm"] {
            let old = dataDir.appendingPathComponent("djhero.sqlite3" + suffix)
            let new = dataDir.appendingPathComponent("slipmat.sqlite3" + suffix)
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: new) }
        }
        guard let db = try? DatabaseQueue(path: dataDir.appendingPathComponent("slipmat.sqlite3").path)
        else { return }
        try? db.write { db in
            for (table, column) in [("tracks", "file_path"), ("tracks", "upgrade_path"),
                                    ("library_files", "path"), ("library_files", "art_path"),
                                    ("file_sources", "path")] {
                try db.execute(sql: """
                    UPDATE \(table) SET \(column) = REPLACE(\(column), '/djhero/', '/slipmat/')
                    WHERE \(column) LIKE '%/djhero/%'
                    """)
            }
        }
    }

    public func cookies(_ service: String) -> URL {
        authDir.appendingPathComponent("\(service).txt")
    }

    public func saveCookies(_ service: String, text: String) throws {
        try text.write(to: cookies(service), atomically: true, encoding: .utf8)
    }
}
