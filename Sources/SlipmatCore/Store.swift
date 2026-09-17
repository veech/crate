import Foundation
import GRDB

public struct Track: Identifiable, Sendable {
    public var id: Int64
    public var status: String
    public var origin: String
    public var scId: String?
    public var bpId: String?
    public var ytmId: String?
    public var title: String
    public var artist: String
    public var mix: String
    public var durationS: Int
    public var gateURL: String
    public var artURL: String
    public var scURL: String
    public var scDownloadable: Bool
    public var chosenSource: String?
    public var filePath: String?
    public var filedAt: String?
    public var upgradePath: String?
    public var rejectedYtmIds: Set<String>

    init(row: Row) {
        id = row["id"]
        status = row["status"]
        origin = row["origin"]
        scId = row["sc_id"]
        bpId = row["bp_id"]
        ytmId = row["ytm_id"]
        title = row["title"] ?? ""
        artist = row["artist"] ?? ""
        mix = row["mix"] ?? ""
        durationS = row["duration_s"] ?? 0
        gateURL = row["gate_url"] ?? ""
        artURL = row["art_url"] ?? ""
        scURL = row["sc_url"] ?? ""
        scDownloadable = (row["sc_downloadable"] ?? 0) != 0
        chosenSource = row["chosen_source"]
        filePath = row["file_path"]
        filedAt = row["filed_at"]
        upgradePath = row["upgrade_path"]
        let rejected: String = row["rejected_ytm_ids"] ?? ""
        rejectedYtmIds = Set(rejected.split(separator: " ").map(String.init))
    }
}

public struct TrackEvent: Sendable {
    public let at: String
    public let event: String
    public let detail: String?
}

public struct AppSettings: Sendable {
    public init() {}

    public var scQueuePlaylist = "Queue"
    public var ytQueuePlaylist = ""
    public var bpKeepersPlaylist = ""
    public var targetFormat = "flac"
    public var pollMinutes = 0
    public var anthropicModel = "claude-opus-5"
    public var anthropicApiKey = ""
    public var collectionDir = NSString(string: "~/Downloads/Queue").expandingTildeInPath
    public var downloadsDir = NSString(string: "~/Downloads").expandingTildeInPath
}

public final class Store: Sendable {
    public let dbQueue: DatabaseQueue

    public init(at url: URL) throws {
        dbQueue = try DatabaseQueue(path: url.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS tracks (
                  id INTEGER PRIMARY KEY,
                  status TEXT NOT NULL,
                  origin TEXT NOT NULL,
                  sc_id TEXT UNIQUE,
                  bp_id TEXT UNIQUE,
                  ytm_id TEXT,
                  title TEXT,
                  artist TEXT,
                  mix TEXT,
                  duration_s INTEGER,
                  gate_url TEXT,
                  art_url TEXT,
                  sc_url TEXT,
                  sc_downloadable INTEGER,
                  chosen_source TEXT,
                  file_path TEXT,
                  filed_at TEXT,
                  upgrade_path TEXT,
                  rejected_ytm_ids TEXT
                );
                CREATE TABLE IF NOT EXISTS track_events (
                  track_id INTEGER NOT NULL REFERENCES tracks(id),
                  at TEXT NOT NULL DEFAULT (datetime('now')),
                  event TEXT NOT NULL,
                  detail TEXT
                );
                CREATE TABLE IF NOT EXISTS settings (
                  key TEXT PRIMARY KEY,
                  value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS repos (
                  path TEXT PRIMARY KEY,
                  added_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE TABLE IF NOT EXISTS library_files (
                  path TEXT PRIMARY KEY,
                  mtime REAL NOT NULL,
                  size INTEGER NOT NULL,
                  title TEXT,
                  artist TEXT,
                  genre TEXT,
                  duration_s REAL,
                  art_path TEXT
                );
                CREATE TABLE IF NOT EXISTS file_sources (
                  path TEXT PRIMARY KEY,
                  sc_id TEXT,
                  page_url TEXT,
                  gate_url TEXT,
                  downloadable INTEGER,
                  art_url TEXT
                );
                CREATE TABLE IF NOT EXISTS file_analysis (
                  path TEXT PRIMARY KEY,
                  ce REAL NOT NULL,
                  cu REAL NOT NULL,
                  pc REAL NOT NULL,
                  pq REAL NOT NULL,
                  analyzed_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                """)
            // Databases created before the column existed pick it up here.
            _ = try? db.execute(sql: "ALTER TABLE tracks ADD COLUMN upgrade_path TEXT")
            _ = try? db.execute(sql: "ALTER TABLE tracks ADD COLUMN rejected_ytm_ids TEXT")
        }
    }

    // MARK: events + status

    public func record(_ trackId: Int64, _ event: String, _ detail: String? = nil) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO track_events (track_id, event, detail) VALUES (?, ?, ?)",
                arguments: [trackId, event, detail])
        }
    }

    public func setStatus(_ trackId: Int64, _ status: String, _ event: String,
                          _ detail: String? = nil) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET status = ? WHERE id = ?",
                           arguments: [status, trackId])
            try db.execute(
                sql: "INSERT INTO track_events (track_id, event, detail) VALUES (?, ?, ?)",
                arguments: [trackId, event, detail])
        }
    }

    public func update(_ trackId: Int64, _ assignments: [String: (any DatabaseValueConvertible)?]) throws {
        guard !assignments.isEmpty else { return }
        let keys = assignments.keys.sorted()
        let sql = "UPDATE tracks SET " + keys.map { "\($0) = ?" }.joined(separator: ", ")
            + " WHERE id = ?"
        var args: [(any DatabaseValueConvertible)?] = keys.map { assignments[$0] ?? nil }
        args.append(trackId)
        try dbQueue.write { db in
            try db.execute(sql: sql, arguments: StatementArguments(args))
        }
    }

    public func markFiledNow(_ trackId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET filed_at = datetime('now') WHERE id = ?",
                           arguments: [trackId])
        }
    }

    // MARK: queries

    public func inStatus(_ status: String) throws -> [Track] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM tracks WHERE status = ? ORDER BY id",
                             arguments: [status]).map(Track.init)
        }
    }

    public func allTracks() throws -> [Track] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM tracks ORDER BY id DESC").map(Track.init)
        }
    }

    public func track(id: Int64) throws -> Track? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = ?", arguments: [id])
                .map(Track.init)
        }
    }

    public func track(scId: String) throws -> Track? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM tracks WHERE sc_id = ?", arguments: [scId])
                .map(Track.init)
        }
    }

    public func track(bpId: String) throws -> Track? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM tracks WHERE bp_id = ?", arguments: [bpId])
                .map(Track.init)
        }
    }

    public func events(trackId: Int64) throws -> [TrackEvent] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db, sql: "SELECT at, event, detail FROM track_events WHERE track_id = ? ORDER BY rowid",
                arguments: [trackId]
            ).map { TrackEvent(at: $0["at"], event: $0["event"], detail: $0["detail"]) }
        }
    }

    public func lastEvent(trackId: Int64) throws -> TrackEvent? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db, sql: "SELECT at, event, detail FROM track_events WHERE track_id = ?"
                    + " ORDER BY rowid DESC LIMIT 1",
                arguments: [trackId]
            ).map { TrackEvent(at: $0["at"], event: $0["event"], detail: $0["detail"]) }
        }
    }

    public func statusCounts() throws -> [String: Int] {
        try dbQueue.read { db in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT status, COUNT(*) AS n FROM tracks GROUP BY status") {
                counts[row["status"]] = row["n"]
            }
            return counts
        }
    }

    // MARK: intake

    /// Insert a Beatport playlist track if unseen; returns the new row id or nil.
    public func upsertBeatport(_ t: BPTrack) throws -> Int64? {
        try dbQueue.write { db in
            if try Row.fetchOne(db, sql: "SELECT id FROM tracks WHERE bp_id = ?",
                                arguments: [t.bpId]) != nil { return nil }
            try db.execute(
                sql: """
                    INSERT INTO tracks (status, origin, bp_id, title, artist, mix, duration_s, art_url)
                    VALUES ('new', 'beatport', ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [t.bpId, t.title, t.artist, t.mix, t.durationS, t.artURL])
            let id = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO track_events (track_id, event) VALUES (?, 'Seen in Beatport playlist')",
                arguments: [id])
            return id
        }
    }

    /// Insert a YouTube queue item if its video is unseen anywhere — a track
    /// already fetched via YTM for another origin is the same recording.
    public func upsertYouTube(_ t: YtDlp.YTPlaylistItem) throws -> Int64? {
        try dbQueue.write { db in
            if try Row.fetchOne(db, sql: "SELECT id FROM tracks WHERE ytm_id = ?",
                                arguments: [t.videoId]) != nil { return nil }
            try db.execute(
                sql: """
                    INSERT INTO tracks (status, origin, ytm_id, title, artist, mix,
                                        duration_s, art_url)
                    VALUES ('new', 'youtube', ?, ?, ?, '', ?, ?)
                    """,
                arguments: [t.videoId, t.rawTitle, t.uploader, t.durationS, t.artURL])
            let id = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO track_events (track_id, event) VALUES (?, 'Seen in YouTube queue')",
                arguments: [id])
            return id
        }
    }

    /// Insert a SoundCloud queue track if unseen; title/artist stay raw until resolve splits them.
    public func upsertSoundCloud(_ t: SCTrack, gate: Bool) throws -> Int64? {
        try dbQueue.write { db in
            if try Row.fetchOne(db, sql: "SELECT id FROM tracks WHERE sc_id = ?",
                                arguments: [t.scId]) != nil { return nil }
            try db.execute(
                sql: """
                    INSERT INTO tracks (status, origin, sc_id, sc_url, title, artist, mix,
                                        duration_s, art_url, gate_url, sc_downloadable)
                    VALUES ('new', 'soundcloud', ?, ?, ?, ?, '', ?, ?, ?, ?)
                    """,
                arguments: [t.scId, t.scURL, t.rawTitle, t.uploader, t.durationS,
                            t.artURL, gate ? t.purchaseURL : "", t.downloadable ? 1 : 0])
            let id = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO track_events (track_id, event) VALUES (?, 'Seen in SoundCloud queue')",
                arguments: [id])
            return id
        }
    }

    /// A discovered source enters the pipeline pre-resolved (title and artist
    /// are already the curated 1:1 names), aimed at upgrading the existing file
    /// in place. Returns nil when the SC track is already known.
    public func insertBackMatch(_ s: FileSource, title: String, artist: String,
                                durationS: Int, upgradePath: String) throws -> Int64? {
        try dbQueue.write { db in
            if try Row.fetchOne(db, sql: "SELECT id FROM tracks WHERE sc_id = ?",
                                arguments: [s.scId]) != nil { return nil }
            let status = s.downloadable ? "resolved" : "held_gate"
            try db.execute(
                sql: """
                    INSERT INTO tracks (status, origin, sc_id, sc_url, title, artist, mix,
                                        duration_s, art_url, gate_url, sc_downloadable,
                                        chosen_source, upgrade_path)
                    VALUES (?, 'soundcloud', ?, ?, ?, ?, '', ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [status, s.scId, s.pageURL, title, artist, durationS, s.artURL,
                            s.gateURL, s.downloadable ? 1 : 0,
                            s.downloadable ? "sc_free_dl" : nil, upgradePath])
            let id = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO track_events (track_id, event, detail) VALUES (?, ?, ?)",
                arguments: [id, "Upgrade requested",
                            URL(fileURLWithPath: upgradePath).lastPathComponent])
            return id
        }
    }

    /// Remove a track and its dossier outright. The source identity frees up:
    /// if it is still in a queue playlist, the next poll re-enters it fresh.
    public func deleteTrack(_ trackId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM track_events WHERE track_id = ?",
                           arguments: [trackId])
            try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [trackId])
        }
    }

    /// The filed audio is the wrong recording: remember the rejected video id
    /// so resolve never picks it again, and send the track back through.
    public func rejectYtmMatch(_ trackId: Int64) throws {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                      db, sql: "SELECT ytm_id, rejected_ytm_ids FROM tracks WHERE id = ?",
                      arguments: [trackId]),
                  let ytmId: String = row["ytm_id"] else { return }
            let prior: String = row["rejected_ytm_ids"] ?? ""
            let rejected = (prior.split(separator: " ").map(String.init) + [ytmId])
                .joined(separator: " ")
            try db.execute(
                sql: """
                    UPDATE tracks SET rejected_ytm_ids = ?, ytm_id = NULL,
                      chosen_source = NULL, file_path = NULL, filed_at = NULL,
                      status = 'new' WHERE id = ?
                    """,
                arguments: [rejected, trackId])
            try db.execute(
                sql: "INSERT INTO track_events (track_id, event, detail) VALUES (?, ?, ?)",
                arguments: [trackId, "Wrong match rejected", ytmId])
        }
    }

    /// Send a filed track back through the pipeline to upgrade its own file.
    public func requeueUpgrade(_ trackId: Int64, path: String, native: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE tracks SET upgrade_path = ?, chosen_source = ?, status = ?"
                    + " WHERE id = ?",
                arguments: [path, native ? "sc_free_dl" : nil,
                            native ? "resolved" : "held_gate", trackId])
            try db.execute(
                sql: "INSERT INTO track_events (track_id, event) VALUES (?, 'Upgrade requested')",
                arguments: [trackId])
        }
    }

    // MARK: discovered sources

    public func allFileSources() throws -> [String: FileSource] {
        try dbQueue.read { db in
            var out: [String: FileSource] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM file_sources") {
                out[row["path"]] = FileSource(row: row)
            }
            return out
        }
    }

    public func saveFileSource(_ path: String, _ s: FileSource) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO file_sources (path, sc_id, page_url, gate_url, downloadable, art_url)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET sc_id = excluded.sc_id,
                      page_url = excluded.page_url, gate_url = excluded.gate_url,
                      downloadable = excluded.downloadable, art_url = excluded.art_url
                    """,
                arguments: [path, s.scId, s.pageURL, s.gateURL, s.downloadable ? 1 : 0, s.artURL])
        }
    }

    public func deleteFileSource(_ path: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM file_sources WHERE path = ?", arguments: [path])
        }
    }

    // MARK: quality analysis

    public func allFileAnalyses() throws -> [String: FileAnalysis] {
        try dbQueue.read { db in
            var out: [String: FileAnalysis] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM file_analysis") {
                out[row["path"]] = FileAnalysis(ce: row["ce"], cu: row["cu"],
                                                pc: row["pc"], pq: row["pq"])
            }
            return out
        }
    }

    public func saveFileAnalysis(_ path: String, _ a: FileAnalysis) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO file_analysis (path, ce, cu, pc, pq)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET ce = excluded.ce, cu = excluded.cu,
                      pc = excluded.pc, pq = excluded.pq, analyzed_at = datetime('now')
                    """,
                arguments: [path, a.ce, a.cu, a.pc, a.pq])
        }
    }

    public func deleteFileAnalysis(_ path: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM file_analysis WHERE path = ?", arguments: [path])
        }
    }

    // MARK: dedupe

    public static func normalizeName(_ artist: String, _ title: String) -> String {
        let lowered = "\(artist) \(title)".lowercased()
        let cleaned = lowered.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    public func findFiledDuplicate(artist: String, title: String) throws -> Track? {
        let want = Self.normalizeName(artist, title)
        return try inStatus("filed").first {
            Self.normalizeName($0.artist, $0.title) == want
        }
    }

    // MARK: library

    public func repos() throws -> [String] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT path FROM repos ORDER BY path").map { $0["path"] }
        }
    }

    public func addRepo(_ path: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO repos (path) VALUES (?)", arguments: [path])
        }
    }

    public func removeRepo(_ path: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM repos WHERE path = ?", arguments: [path])
        }
    }

    /// Cached probe results for a folder's direct children.
    public func cachedLibraryFiles(inFolder folder: String) throws -> [String: LibraryFile] {
        let escaped = folder
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try dbQueue.read { db in
            var out: [String: LibraryFile] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT * FROM library_files WHERE path LIKE ? ESCAPE '\\'",
                arguments: [escaped + "/%"]) {
                let f = LibraryFile(row: row)
                if URL(fileURLWithPath: f.path).deletingLastPathComponent().path == folder {
                    out[f.path] = f
                }
            }
            return out
        }
    }

    public func upsertLibraryFile(_ f: LibraryFile) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO library_files (path, mtime, size, title, artist, genre, duration_s, art_path)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET mtime = excluded.mtime, size = excluded.size,
                      title = excluded.title, artist = excluded.artist, genre = excluded.genre,
                      duration_s = excluded.duration_s, art_path = excluded.art_path
                    """,
                arguments: [f.path, f.mtime, f.size, f.title, f.artist, f.genre,
                            f.durationS, f.artPath])
        }
    }

    public func deleteLibraryFiles(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try dbQueue.write { db in
            for path in paths {
                try db.execute(sql: "DELETE FROM library_files WHERE path = ?", arguments: [path])
            }
        }
    }

    /// An edited name feeds back into the pipeline record so dedupe matches it.
    public func setFiledMetadata(path: String, title: String, artist: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE tracks SET title = ?, artist = ?, mix = '' WHERE file_path = ?",
                arguments: [title, artist, path])
        }
    }

    /// Detach a library file from the pipeline: filed records forget the path
    /// (their history stays), and a pending upgrade aimed at it is withdrawn.
    public func clearSource(forPath path: String) throws {
        try dbQueue.write { db in
            for row in try Row.fetchAll(
                db, sql: "SELECT id FROM tracks WHERE file_path = ?", arguments: [path]) {
                let id: Int64 = row["id"]
                try db.execute(sql: "UPDATE tracks SET file_path = NULL WHERE id = ?",
                               arguments: [id])
                try db.execute(
                    sql: "INSERT INTO track_events (track_id, event, detail) VALUES (?, ?, ?)",
                    arguments: [id, "Source link cleared", path])
            }
            for row in try Row.fetchAll(
                db, sql: "SELECT id FROM tracks WHERE upgrade_path = ? AND status != 'filed'",
                arguments: [path]) {
                let id: Int64 = row["id"]
                try db.execute(sql: "DELETE FROM track_events WHERE track_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [id])
            }
            try db.execute(sql: "DELETE FROM file_sources WHERE path = ?", arguments: [path])
        }
    }

    /// A moved file keeps its probe cache, and its pipeline record follows it.
    public func relocateFile(from old: String, to new: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE library_files SET path = ? WHERE path = ?",
                           arguments: [new, old])
            try db.execute(sql: "UPDATE tracks SET file_path = ? WHERE file_path = ?",
                           arguments: [new, old])
            try db.execute(sql: "UPDATE tracks SET upgrade_path = ? WHERE upgrade_path = ?",
                           arguments: [new, old])
            try db.execute(sql: "UPDATE file_sources SET path = ? WHERE path = ?",
                           arguments: [new, old])
            try db.execute(sql: "UPDATE file_analysis SET path = ? WHERE path = ?",
                           arguments: [new, old])
        }
    }

    // MARK: settings

    public func loadSettings() throws -> AppSettings {
        let stored: [String: String] = try dbQueue.read { db in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, value FROM settings") {
                out[row["key"]] = row["value"]
            }
            return out
        }
        var s = AppSettings()
        if let v = stored["sc_queue_playlist"] { s.scQueuePlaylist = v }
        if let v = stored["yt_queue_playlist"] { s.ytQueuePlaylist = v }
        if let v = stored["bp_keepers_playlist"] { s.bpKeepersPlaylist = v }
        if let v = stored["target_format"] { s.targetFormat = v }
        if let v = stored["poll_minutes"], let n = Int(v) { s.pollMinutes = n }
        if let v = stored["anthropic_model"] { s.anthropicModel = v }
        if let v = stored["anthropic_api_key"] { s.anthropicApiKey = v }
        if let v = stored["collection_dir"] { s.collectionDir = v }
        if let v = stored["downloads_dir"] { s.downloadsDir = v }
        return s
    }

    public func saveSettings(_ values: [String: String]) throws {
        let allowed: Set<String> = ["sc_queue_playlist", "yt_queue_playlist",
                                    "bp_keepers_playlist", "target_format",
                                    "poll_minutes", "anthropic_model", "anthropic_api_key",
                                    "collection_dir", "downloads_dir"]
        try dbQueue.write { db in
            for (key, value) in values {
                guard allowed.contains(key) else { throw DJError("unknown setting \(key)") }
                try db.execute(
                    sql: "INSERT INTO settings (key, value) VALUES (?, ?)"
                        + " ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value])
            }
        }
    }
}
