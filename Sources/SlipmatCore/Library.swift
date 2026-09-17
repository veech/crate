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

/// A discovered SoundCloud source for a library file, saved by Find Source;
/// the Upgrade action turns it into a pipeline entry.
public struct FileSource: Sendable {
    public var scId: String
    public var pageURL: String
    public var gateURL: String
    public var downloadable: Bool
    public var artURL: String

    public var offersDL: Bool { downloadable || !gateURL.isEmpty }

    public init(scId: String, pageURL: String, gateURL: String,
                downloadable: Bool, artURL: String) {
        self.scId = scId
        self.pageURL = pageURL
        self.gateURL = gateURL
        self.downloadable = downloadable
        self.artURL = artURL
    }

    init(row: Row) {
        scId = row["sc_id"] ?? ""
        pageURL = row["page_url"] ?? ""
        gateURL = row["gate_url"] ?? ""
        downloadable = (row["downloadable"] ?? 0) != 0
        artURL = row["art_url"] ?? ""
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
            // iCloud can evict a file's content: it still lists, but reads
            // nothing. Ask for it back, and never probe the empty shell —
            // eviction preserves mtime and size, so a bad probe would stick.
            let allocated = (try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]))?
                .fileAllocatedSize ?? 1
            let dataless = allocated == 0 && size > 0
            if dataless { try? fm.startDownloadingUbiquitousItem(at: url) }
            // Only complete probes are cached, so a zero-duration row is
            // garbage from an older cache; fall through and re-probe it.
            if let hit = cached[url.path], hit.mtime == mtime, hit.size == size,
               hit.durationS > 0 {
                files.append(hit)
            } else if dataless {
                files.append(placeholder(url, mtime: mtime, size: size))
            } else {
                stale.append((url, mtime, size))
            }
        }

        for start in stride(from: 0, to: stale.count, by: 4) {
            let chunk = Array(stale[start..<min(start + 4, stale.count)])
            let probed = await withTaskGroup(of: (LibraryFile, Bool).self) { group
                -> [(LibraryFile, Bool)] in
                for (url, mtime, size) in chunk {
                    group.addTask { await probe(url, mtime: mtime, size: size) }
                }
                var out: [(LibraryFile, Bool)] = []
                for await f in group { out.append(f) }
                return out
            }
            for (f, cacheable) in probed where cacheable { try? store.upsertLibraryFile(f) }
            files += probed.map(\.0)
        }

        let live = Set(urls.map(\.path))
        try? store.deleteLibraryFiles(cached.keys.filter { !live.contains($0) })
        return files.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func placeholder(_ url: URL, mtime: Double, size: Int64) -> LibraryFile {
        LibraryFile(path: url.path, mtime: mtime, size: size,
                    title: url.deletingPathExtension().lastPathComponent,
                    artist: "", genre: "", durationS: 0, artPath: nil)
    }

    /// An unprobeable file still lists, named by its filename — but only a
    /// complete probe is cached, so failures retry on the next scan.
    func probe(_ url: URL, mtime: Double, size: Int64) async -> (LibraryFile, Bool) {
        guard let tags = await FFmpeg.probeTags(url) else {
            return (placeholder(url, mtime: mtime, size: size), false)
        }
        var artPath: String?
        if tags.hasArt {
            let out = artDir.appendingPathComponent(Self.hash(url.path) + ".jpg")
            if await FFmpeg.extractArtThumb(url, to: out) { artPath = out.path }
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let file = LibraryFile(
            path: url.path, mtime: mtime, size: size,
            title: tags.title.isEmpty ? stem : tags.title,
            artist: tags.artist, genre: tags.genre,
            durationS: tags.durationS, artPath: artPath)
        let complete = tags.durationS > 0 && (!tags.hasArt || artPath != nil)
        return (file, complete)
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
    /// With `uniquing`, a colliding name gets a numeric suffix instead — for
    /// destinations like the trash, where names carry no identity.
    public func move(_ paths: [String], to folder: URL,
                     uniquing: Bool = false) -> (moved: Int, skipped: [String]) {
        let fm = FileManager.default
        var moved = 0
        var skipped: [String] = []
        for path in paths {
            let name = URL(fileURLWithPath: path).lastPathComponent
            var dest = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) {
                guard uniquing else {
                    skipped.append(name)
                    continue
                }
                let stem = dest.deletingPathExtension().lastPathComponent
                let ext = dest.pathExtension.isEmpty ? "" : ".\(dest.pathExtension)"
                var n = 2
                repeat {
                    dest = folder.appendingPathComponent("\(stem) \(n)\(ext)")
                    n += 1
                } while fm.fileExists(atPath: dest.path)
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
