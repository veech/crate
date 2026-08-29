import AppKit
import SwiftUI
import SlipmatCore

@main
struct SlipmatApp: App {
    @State private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        // A bare SwiftPM executable has no bundle Info.plist; the Dock icon
        // is set at runtime until packaging bakes the icns in.
        if let path = Bundle.module.path(forResource: "AppIcon", ofType: "icns") {
            NSApplication.shared.applicationIconImage = NSImage(contentsOfFile: path)
        }
    }

    var body: some Scene {
        WindowGroup("Slipmat") {
            ContentView()
                .environment(model)
                .frame(minWidth: 920, minHeight: 520)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        Settings {
            SettingsView().environment(model)
        }
    }
}

@Observable
@MainActor
final class AppModel {
    let cfg: Config
    let store: Store
    let reconciler: Reconciler
    let scanner: LibraryScanner
    let player = PlayerModel()

    var tracks: [Track] = []
    var repos: [String] = []
    var collectionDir = AppSettings().collectionDir
    var inboxCount = 0
    var loaded = false
    var cycling = false
    var matching = false
    var matchProgress: (done: Int, total: Int, hits: Int) = (0, 0, 0)
    var matchSummary: String?
    var fileSources: [String: FileSource] = [:]
    var lastError: String?

    init() {
        let cfg = Config()
        self.cfg = cfg
        do {
            let store = try Store(at: cfg.dbURL)
            self.store = store
            self.reconciler = Reconciler(cfg: cfg, store: store)
            self.scanner = LibraryScanner(cfg: cfg, store: store)
        } catch {
            fatalError("cannot open database: \(error)")
        }
        refresh()
        Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self.refresh()
            }
        }
    }

    func refresh() {
        tracks = (try? store.allTracks()) ?? []
        repos = (try? store.repos()) ?? []
        fileSources = (try? store.allFileSources()) ?? [:]
        collectionDir = ((try? store.loadSettings())?.collectionDir) ?? collectionDir
        inboxCount = ((try? FileManager.default.contentsOfDirectory(atPath: collectionDir)) ?? [])
            .filter {
                !$0.hasPrefix(".") && LibraryScanner.audioExts
                    .contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
            }
            .count
        loaded = true
    }

    /// Provenance for Library rows, joined on the filed path. The label is the
    /// service the audio came from; the route detail stays in Pipeline.
    var sourceByPath: [String: String] {
        var out: [String: String] = [:]
        for track in tracks {
            let label = Self.serviceLabel(track)
            guard !label.isEmpty else { continue }
            if let path = track.filePath { out[path] = label }
            if let up = track.upgradePath, !up.isEmpty { out[up] = label }
        }
        return out
    }

    static func serviceLabel(_ track: Track) -> String {
        if track.chosenSource == "ytm" { return "YT" }
        if track.chosenSource == "purchase" { return "BP" }
        if !track.scURL.isEmpty { return "SC" }
        if track.bpId != nil { return "BP" }
        return ""
    }

    func addRepo(_ url: URL) {
        try? store.addRepo(url.path)
        refresh()
    }

    func removeRepo(_ path: String) {
        try? store.removeRepo(path)
        refresh()
    }

    /// Search SoundCloud for these files' uploads and record what was found;
    /// nothing enters the pipeline until the row's explicit Upgrade action.
    func findSources(_ files: [LibraryFile]) {
        guard !matching, !files.isEmpty else { return }
        matching = true
        matchProgress = (0, files.count, 0)
        matchSummary = nil
        Task {
            defer { matching = false }
            let client: SoundCloudClient
            do {
                client = try SoundCloudClient(cookiesFile: cfg.cookies("soundcloud"),
                                              cacheDir: cfg.cacheDir)
            } catch {
                lastError = "\(error)"
                return
            }
            let settings = (try? store.loadSettings()) ?? AppSettings()
            var noDL = 0, misses = 0
            for (i, file) in files.enumerated() {
                let outcome = await BackMatch.find(
                    title: file.title, artist: file.artist,
                    durationS: Int(file.durationS.rounded()),
                    client: client, settings: settings)
                switch outcome {
                case .match(let sc):
                    let gate = Gates.isGate(purchaseURL: sc.purchaseURL,
                                            purchaseTitle: sc.purchaseTitle)
                    try? store.saveFileSource(file.path, FileSource(
                        scId: sc.scId, pageURL: sc.scURL,
                        gateURL: gate ? sc.purchaseURL : "",
                        downloadable: sc.downloadable, artURL: sc.artURL))
                    matchProgress.hits += 1
                    refresh()
                case .noDownload(let sc):
                    try? store.saveFileSource(file.path, FileSource(
                        scId: sc.scId, pageURL: sc.scURL, gateURL: "",
                        downloadable: false, artURL: sc.artURL))
                    noDL += 1
                    refresh()
                case .none:
                    misses += 1
                }
                matchProgress.done = i + 1
                try? await Task.sleep(for: .seconds(1))
            }
            refresh()
            matchSummary = "Checked \(files.count): \(matchProgress.hits) upgradeable,"
                + " \(noDL) found without DL, \(misses) no match"
        }
    }

    /// Queue the found download: gates hold for the click-through, native
    /// downloads fetch on the cycle this starts.
    func upgrade(_ files: [LibraryFile]) {
        var started = 0
        for file in files {
            if let track = tracks.first(where: {
                   $0.filePath == file.path && $0.status == "filed"
               }), track.origin == "soundcloud",
               !track.gateURL.isEmpty || track.scDownloadable {
                try? store.requeueUpgrade(track.id, path: file.path,
                                          native: track.scDownloadable)
                started += 1
            } else if let src = fileSources[file.path], src.offersDL,
                      let id = try? store.insertBackMatch(
                          src, title: file.title, artist: file.artist,
                          durationS: Int(file.durationS.rounded()),
                          upgradePath: file.path),
                      id != nil {
                started += 1
            }
        }
        if started > 0 {
            refresh()
            runCycle()
        }
    }

    /// Where each library file's audio came from, for the row's source link.
    var sourceURLByPath: [String: String] {
        var out: [String: String] = [:]
        for track in tracks {
            guard let url = Self.sourceURL(track) else { continue }
            if let path = track.filePath { out[path] = url }
            if let up = track.upgradePath, !up.isEmpty { out[up] = url }
        }
        return out
    }

    static func sourceURL(_ track: Track) -> String? {
        if track.chosenSource == "ytm", let id = track.ytmId, !id.isEmpty {
            return "https://music.youtube.com/watch?v=\(id)"
        }
        if !track.scURL.isEmpty { return track.scURL }
        if let bp = track.bpId { return "https://www.beatport.com/track/-/\(bp)" }
        return nil
    }

    /// Pipeline state for files still awaiting their in-place upgrade.
    var pendingUpgradeByPath: [String: String] {
        var out: [String: String] = [:]
        for track in tracks where track.status != "filed" {
            guard let up = track.upgradePath, !up.isEmpty else { continue }
            switch track.status {
            case "held_gate": out[up] = "Gate held"
            case "needs_review": out[up] = "Review"
            default: out[up] = "Upgrading…"
            }
        }
        return out
    }

    /// Permanent: removes every file in the trash and unlinks its records.
    func emptyTrash() {
        let dir = cfg.trashDir
        if let playing = player.current?.path, playing.hasPrefix(dir.path) {
            player.stop()
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let path = dir.appendingPathComponent(name).path
            try? store.clearSource(forPath: path)
            try? store.deleteLibraryFiles([path])
            try? FileManager.default.removeItem(atPath: path)
        }
        refresh()
    }

    func clearSource(_ files: [LibraryFile]) {
        for file in files {
            try? store.clearSource(forPath: file.path)
        }
        refresh()
    }

    func retag(_ file: LibraryFile, title: String, artist: String,
               genre: String) async -> LibraryFile? {
        do {
            return try await scanner.retag(file, title: title, artist: artist, genre: genre)
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    /// A gate's payoff: the user did the click-through, the browser downloaded the
    /// file, and this joins it to the track so it inherits title, artist, and art.
    func attachGateFile(track: Track, file: URL) {
        do {
            let staged = cfg.stagingDir.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            try FileManager.default.copyItem(at: file, to: staged)
            try store.update(track.id, ["file_path": staged.path, "chosen_source": "gate"])
            try store.setStatus(track.id, "fetched", "Gate file attached",
                                staged.lastPathComponent)
            refresh()
            runCycle()
        } catch {
            lastError = "\(error)"
        }
    }

    func justRip(_ track: Track) {
        guard !track.scURL.isEmpty else { return }
        try? store.update(track.id, ["chosen_source": "sc_rip"])
        try? store.setStatus(track.id, "resolved", "Gate skipped; ripping instead")
        refresh()
        runCycle()
    }

    func retry(_ track: Track) {
        try? store.setStatus(track.id, "new", "Retrying")
        refresh()
        runCycle()
    }

    func sendToBuyList(_ track: Track) {
        try? store.setStatus(track.id, "buy_list", "Sent to buy list")
        refresh()
    }

    private var cycleTask: Task<Void, Never>?

    func runCycle() {
        guard !cycling else { return }
        cycling = true
        cycleTask = Task {
            defer { cycling = false }
            do {
                try await reconciler.cycle()
                lastError = nil
            } catch is CancellationError {
            } catch {
                lastError = "\(error)"
            }
            refresh()
        }
    }

    /// Interrupted stages rewind at the start of the next cycle.
    func stopCycle() {
        cycleTask?.cancel()
    }
}
