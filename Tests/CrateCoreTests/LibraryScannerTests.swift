import Foundation
import XCTest
@testable import CrateCore

final class LibraryScannerTests: XCTestCase {
    func testScanRepairsMovedCachedArtworkPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateLibraryScannerTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("music", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("track.mp3")
        try Data("audio".utf8).write(to: audio)

        let cfg = try Config(dataDir: root.appendingPathComponent("crate", isDirectory: true))
        let store = try Store(at: cfg.dbURL)
        let scanner = LibraryScanner(cfg: cfg, store: store)
        let artName = LibraryScanner.hash(audio.path) + ".jpg"
        let oldArt = root.appendingPathComponent("slipmat/cache/art/\(artName)")
        let currentArt = scanner.artDir.appendingPathComponent(artName)
        try Data("art".utf8).write(to: currentArt)

        let attrs = try FileManager.default.attributesOfItem(atPath: audio.path)
        let mtime = try XCTUnwrap(attrs[.modificationDate] as? Date).timeIntervalSince1970
        let size = try XCTUnwrap(attrs[.size] as? NSNumber).int64Value
        try store.upsertLibraryFile(LibraryFile(
            path: audio.path, mtime: mtime, size: size,
            title: "Track", artist: "Artist", genre: "House",
            durationS: 180, artPath: oldArt.path))

        let files = await scanner.scan(folder)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.artPath, currentArt.path)
        XCTAssertEqual(try store.cachedLibraryFiles(inFolder: folder.path)[audio.path]?.artPath,
                       currentArt.path)
    }
}
