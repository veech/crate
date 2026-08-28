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
            PipelineView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
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
