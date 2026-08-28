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

    var tracks: [Track] = []
    var loaded = false
    var cycling = false
    var lastError: String?

    init() {
        let cfg = Config()
        self.cfg = cfg
        do {
            let store = try Store(at: cfg.dbURL)
            self.store = store
            self.reconciler = Reconciler(cfg: cfg, store: store)
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
        loaded = true
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
