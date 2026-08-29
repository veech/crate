import AppKit
import SwiftUI
import SlipmatCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var auth: [String: AuthRow] = [:]
    @State private var settings = AppSettings()
    @State private var apiKeyDraft = ""
    @State private var notes: [String: String] = [:]
    @State private var checking = false

    var body: some View {
        TabView {
            soundcloudTab.tabItem { Label("SoundCloud", systemImage: "cloud") }
            youtubeTab.tabItem { Label("YouTube", systemImage: "play.rectangle") }
            beatportTab.tabItem { Label("Beatport", systemImage: "cart") }
            anthropicTab.tabItem { Label("Anthropic", systemImage: "sparkles") }
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560)
        .task { await load() }
    }

    // MARK: data

    func load() async {
        settings = (try? model.store.loadSettings()) ?? AppSettings()
        await refreshAuth()
    }

    func refreshAuth() async {
        checking = true
        auth = [:]
        for row in await AuthStatus.check(cfg: model.cfg, store: model.store) {
            auth[row.service] = row
        }
        checking = false
    }

    func save(_ values: [String: String], note tab: String) {
        do {
            try model.store.saveSettings(values)
            notes[tab] = "Saved"
        } catch {
            notes[tab] = "\(error)"
        }
    }

    func pasteCookies(_ service: String) {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notes[service] = "Clipboard is empty — copy the cookies.txt export first"
            return
        }
        do {
            try model.cfg.saveCookies(service, text: text)
            notes[service] = nil
            Task { await refreshAuth() }
        } catch {
            notes[service] = "\(error)"
        }
    }

    // MARK: pieces

    func statusRow(_ service: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor(service)).frame(width: 8, height: 8)
            if let row = auth[service] {
                Text(row.detail).font(.caption).textSelection(.enabled)
            } else {
                ProgressView().controlSize(.small)
                Text("Running live credential check…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    func statusColor(_ service: String) -> Color {
        switch auth[service]?.state {
        case "ok": .green
        case "invalid": .red
        case "missing": .secondary.opacity(0.4)
        default: .secondary.opacity(0.2)
        }
    }

    func cookieControls(_ service: String, steps: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Paste cookies from clipboard") { pasteCookies(service) }
                    .disabled(checking)
                Button("Re-check") { Task { await refreshAuth() } }
                    .disabled(checking)
            }
            if let note = notes[service] {
                Text(note).font(.caption).foregroundStyle(.red)
            }
            Text(steps).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: tabs

    var soundcloudTab: some View {
        Form {
            statusRow("soundcloud")
            TextField("Queue playlist", text: $settings.scQueuePlaylist)
            Button("Save") {
                save(["sc_queue_playlist": settings.scQueuePlaylist], note: "soundcloud")
            }
            Divider()
            cookieControls("soundcloud", steps:
                "In your dedicated djcopilot Chrome profile: sign in to soundcloud.com "
                + "with the Go+ account, export with Get cookies.txt LOCALLY, copy, then "
                + "paste here and close the profile.")
        }
        .formStyle(.grouped)
    }

    var youtubeTab: some View {
        Form {
            statusRow("youtube")
            cookieControls("youtube", steps:
                "In your dedicated djcopilot Chrome profile: sign in to music.youtube.com "
                + "with the Premium account, export with Get cookies.txt LOCALLY, copy, "
                + "paste here — then close the profile and do not reopen it; reopening "
                + "rotates Google cookies and kills the export.")
        }
        .formStyle(.grouped)
    }

    var beatportTab: some View {
        Form {
            statusRow("beatport")
            TextField("Keepers playlist", text: $settings.bpKeepersPlaylist)
            Button("Save") {
                save(["bp_keepers_playlist": settings.bpKeepersPlaylist], note: "beatport")
            }
            Divider()
            cookieControls("beatport", steps:
                "In your dedicated djcopilot Chrome profile: sign in to www.beatport.com, "
                + "export with Get cookies.txt LOCALLY, copy, then paste here.")
        }
        .formStyle(.grouped)
    }

    var anthropicTab: some View {
        Form {
            statusRow("anthropic")
            SecureField(settings.anthropicApiKey.isEmpty
                        ? "sk-ant-…" : "Key saved — paste to replace",
                        text: $apiKeyDraft)
            TextField("Model", text: $settings.anthropicModel)
            HStack {
                Button("Save + test") {
                    var values = ["anthropic_model": settings.anthropicModel]
                    if !apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                        values["anthropic_api_key"] =
                            apiKeyDraft.trimmingCharacters(in: .whitespaces)
                        settings.anthropicApiKey = values["anthropic_api_key"]!
                        apiKeyDraft = ""
                    }
                    save(values, note: "anthropic")
                    Task { await refreshAuth() }
                }
                if let note = notes["anthropic"] {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Used for messy title splitting and match adjudication. Stored in the "
                + "app database; the ANTHROPIC_API_KEY environment variable works as a "
                + "fallback for the CLI.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }

    var generalTab: some View {
        Form {
            Picker("Target format", selection: $settings.targetFormat) {
                Text("FLAC").tag("flac")
                Text("AIFF").tag("aiff")
            }
            .pickerStyle(.segmented)
            directoryField("Collection folder", path: $settings.collectionDir)
            directoryField("Downloads folder", path: $settings.downloadsDir)
            HStack {
                Button("Save") {
                    save([
                        "target_format": settings.targetFormat,
                        "collection_dir": settings.collectionDir,
                        "downloads_dir": settings.downloadsDir,
                    ], note: "general")
                }
                if let note = notes["general"] {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    func directoryField(_ label: String, path: Binding<String>) -> some View {
        LabeledContent(label) {
            HStack {
                TextField("", text: path).labelsHidden()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = URL(fileURLWithPath: path.wrappedValue)
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                    }
                }
            }
        }
    }
}
