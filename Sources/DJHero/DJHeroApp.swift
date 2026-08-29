import AppKit
import SwiftUI
import DJHeroCore

@main
struct DJHeroApp: App {
    @State private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("djhero") {
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
    var loaded = false
    var cycling = false
    var matching = false
    var matchProgress: (done: Int, total: Int, hits: Int) = (0, 0, 0)
    var matchOutcome: [String: String] = [:]
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
        collectionDir = ((try? store.loadSettings())?.collectionDir) ?? collectionDir
        loaded = true
    }

    /// Provenance for Library rows, joined on the filed path.
    var sourceByPath: [String: String] {
        var out: [String: String] = [:]
        for track in tracks {
            guard let path = track.filePath else { continue }
            out[path] = track.chosenSource.flatMap { sourceLabel[$0] } ?? ""
        }
        return out
    }

    func addRepo(_ url: URL) {
        try? store.addRepo(url.path)
        refresh()
    }

    func removeRepo(_ path: String) {
        try? store.removeRepo(path)
        refresh()
    }

    /// Search SoundCloud for uploads of these files that offer a download; hits
    /// enter the pipeline aimed at upgrading the old rip in place. Outcomes show
    /// per row in the Source column as the sweep progresses.
    func findSources(_ files: [LibraryFile]) {
        guard !matching, !files.isEmpty else { return }
        matching = true
        matchProgress = (0, files.count, 0)
        for file in files { matchOutcome.removeValue(forKey: file.path) }
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
            for (i, file) in files.enumerated() {
                if let sc = await BackMatch.find(
                       title: file.title, artist: file.artist,
                       durationS: Int(file.durationS.rounded()),
                       client: client, settings: settings),
                   let id = try? store.insertBackMatch(
                       sc, title: file.title, artist: file.artist, upgradePath: file.path),
                   id != nil {
                    matchProgress.hits += 1
                    refresh()
                } else {
                    matchOutcome[file.path] = "none"
                }
                matchProgress.done = i + 1
                try? await Task.sleep(for: .seconds(1))
            }
            refresh()
            if matchProgress.hits > 0 { runCycle() }
        }
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

    func runCycle() {
        guard !cycling else { return }
        cycling = true
        Task {
            defer { cycling = false }
            do {
                try await reconciler.cycle()
                lastError = nil
            } catch {
                lastError = "\(error)"
            }
            refresh()
        }
    }
}
