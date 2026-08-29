import CryptoKit
import Foundation
import GRDB

public struct LibraryFile: Identifiable, Sendable, Hashable {
    public var path: String
    public var mtime: Double
    public var size: Int64
    public var title: String
    public var artist: String
    public var genre: String
    public var durationS: Double
    public var artPath: String?

    public var id: String { path }

    public init(path: String, mtime: Double, size: Int64, title: String, artist: String,
                genre: String, durationS: Double, artPath: String?) {
        self.path = path
        self.mtime = mtime
        self.size = size
        self.title = title
        self.artist = artist
        self.genre = genre
        self.durationS = durationS
        self.artPath = artPath
    }

    init(row: Row) {
        path = row["path"]
        mtime = row["mtime"]
        size = row["size"]
        title = row["title"] ?? ""
        artist = row["artist"] ?? ""
        genre = row["genre"] ?? ""
        durationS = row["duration_s"] ?? 0
        artPath = row["art_path"]
    }
}

/// Reads library folders straight from disk; the DB only caches probe results
/// keyed by (path, mtime, size) so a rescan is cheap.
public struct LibraryScanner: Sendable {
    let cfg: Config
    let store: Store

    public init(cfg: Config, store: Store) {
        self.cfg = cfg
        self.store = store
        try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
    }

    var artDir: URL { cfg.cacheDir.appendingPathComponent("art", isDirectory: true) }

    public static let audioExts: Set<String> = ["flac", "m4a", "mp3", "wav", "aiff", "aif"]

    /// Direct children only; genre folders are flat by convention.
    public func scan(_ folder: URL) async -> [LibraryFile] {
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { folder.appendingPathComponent($0) }
            .filter { Self.audioExts.contains($0.pathExtension.lowercased()) }
        let cached = (try? store.cachedLibraryFiles(inFolder: folder.path)) ?? [:]

        var files: [LibraryFile] = []
        var stale: [(URL, Double, Int64)] = []
        for url in urls {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { continue }
            if let hit = cached[url.path], hit.mtime == mtime, hit.size == size {
                files.append(hit)
            } else {
                stale.append((url, mtime, size))
            }
        }

        for start in stride(from: 0, to: stale.count, by: 4) {
            let chunk = Array(stale[start..<min(start + 4, stale.count)])
            let probed = await withTaskGroup(of: LibraryFile.self) { group -> [LibraryFile] in
                for (url, mtime, size) in chunk {
                    group.addTask { await probe(url, mtime: mtime, size: size) }
                }
                var out: [LibraryFile] = []
                for await f in group { out.append(f) }
                return out
            }
            for f in probed { try? store.upsertLibraryFile(f) }
            files += probed
        }

        let live = Set(urls.map(\.path))
        try? store.deleteLibraryFiles(cached.keys.filter { !live.contains($0) })
        return files.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// An unprobeable file still lists, named by its filename.
    func probe(_ url: URL, mtime: Double, size: Int64) async -> LibraryFile {
        let tags = await FFmpeg.probeTags(url) ?? FFmpeg.ProbedTags()
        var artPath: String?
        if tags.hasArt {
            let out = artDir.appendingPathComponent(Self.hash(url.path) + ".jpg")
            if await FFmpeg.extractArtThumb(url, to: out) { artPath = out.path }
        }
        let stem = url.deletingPathExtension().lastPathComponent
        return LibraryFile(
            path: url.path, mtime: mtime, size: size,
            title: tags.title.isEmpty ? stem : tags.title,
            artist: tags.artist, genre: tags.genre,
            durationS: tags.durationS, artPath: artPath)
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Rewrites the three curated tags; a title or artist change also renames
    /// the file to the collection convention and updates the pipeline record.
    public func retag(_ file: LibraryFile, title: String, artist: String,
                      genre: String) async throws -> LibraryFile {
        let url = URL(fileURLWithPath: file.path)
        try await FFmpeg.writeTags(url, ["title": title, "artist": artist, "genre": genre])

        var updated = file
        updated.title = title
        updated.artist = artist
        updated.genre = genre

        var finalURL = url
        if title != file.title || artist != file.artist {
            let name = Reconciler.safeFilename(title: title, artist: artist,
                                               ext: url.pathExtension)
            let dest = url.deletingLastPathComponent().appendingPathComponent(name)
            if dest.path != url.path {
                // A case-only rename collides with itself on APFS; let it through.
                if FileManager.default.fileExists(atPath: dest.path),
                   dest.path.lowercased() != url.path.lowercased() {
                    throw DJError("a file named \(name) already exists here")
                }
                try FileManager.default.moveItem(at: url, to: dest)
                try store.relocateFile(from: url.path, to: dest.path)
                finalURL = dest
                updated.path = dest.path
            }
            try store.setFiledMetadata(path: finalURL.path, title: title, artist: artist)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path) {
            updated.mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? file.mtime
            updated.size = (attrs[.size] as? NSNumber)?.int64Value ?? file.size
        }
        try store.upsertLibraryFile(updated)
        return updated
    }

    /// Existing names at the destination are left alone and reported back.
    public func move(_ paths: [String], to folder: URL) -> (moved: Int, skipped: [String]) {
        let fm = FileManager.default
        var moved = 0
        var skipped: [String] = []
        for path in paths {
            let name = URL(fileURLWithPath: path).lastPathComponent
            let dest = folder.appendingPathComponent(name)
            guard !fm.fileExists(atPath: dest.path) else {
                skipped.append(name)
                continue
            }
            do {
                try fm.moveItem(atPath: path, toPath: dest.path)
                try store.relocateFile(from: path, to: dest.path)
                moved += 1
            } catch {
                skipped.append(name)
            }
        }
        return (moved, skipped)
    }
}
