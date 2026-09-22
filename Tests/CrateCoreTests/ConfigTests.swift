import Foundation
import XCTest
@testable import CrateCore

final class ConfigTests: XCTestCase {
    func testMovesLegacyStateAndRenamesDatabaseFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateConfigTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = root.appendingPathComponent("slipmat", isDirectory: true)
        let current = root.appendingPathComponent("crate", isDirectory: true)
        let auth = legacy.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        try Data("cookie".utf8).write(to: auth.appendingPathComponent("soundcloud.txt"))

        for suffix in ["", "-wal", "-shm", "-journal"] {
            try Data("file\(suffix)".utf8)
                .write(to: legacy.appendingPathComponent("slipmat.sqlite3\(suffix)"))
        }

        try Config.migrateLegacyState(from: legacy, to: current)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("auth/soundcloud.txt"),
                                  encoding: .utf8), "cookie")
        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("crate.sqlite3\(suffix)"),
                                      encoding: .utf8), "file\(suffix)")
        }
    }

    func testExistingCrateStateIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateConfigTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = root.appendingPathComponent("slipmat", isDirectory: true)
        let current = root.appendingPathComponent("crate", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: legacy.appendingPathComponent("slipmat.sqlite3"))
        try Data("new".utf8).write(to: current.appendingPathComponent("crate.sqlite3"))

        try Config.migrateLegacyState(from: legacy, to: current)

        XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("slipmat.sqlite3"),
                                  encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("crate.sqlite3"),
                                  encoding: .utf8), "new")
    }
}
