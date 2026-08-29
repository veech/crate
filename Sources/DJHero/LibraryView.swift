import AppKit
import SwiftUI
import DJHeroCore

let losslessExts: Set<String> = ["flac", "wav", "aiff", "aif"]

enum UpgradeState {
    case available
    case pending(String)
    case lossless
    case none
}

/// A library file joined with its pipeline provenance, shaped for the table.
struct LibRow: Identifiable {
    let file: LibraryFile
    let source: String
    let sourceURL: String?
    let upgrade: UpgradeState

    var id: String { file.path }
    var title: String { file.title }
    var artist: String { file.artist }
    var genre: String { file.genre }
    var durationS: Double { file.durationS }
    var ext: String { URL(fileURLWithPath: file.path).pathExtension.uppercased() }

    var isUpgradeable: Bool {
        if case .available = upgrade { return true }
        return false
    }

    var upgradeRank: Int {
        switch upgrade {
        case .available: 3
        case .pending: 2
        case .none: 1
        case .lossless: 0
        }
    }
}

// Table cells and menus render in bridged AppKit hosts where the observable
// environment does not reliably reach; the model is passed by reference instead.
struct LibraryView: View {
    let model: AppModel
    let folder: String
    let name: String

    @State private var files: [LibraryFile] = []
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\LibRow.title)]
    @State private var scanning = false
    @State private var note: String?
    @State private var keyMonitor: Any?

    var rows: [LibRow] {
        let sources = model.sourceByPath
        let pending = model.pendingUpgradeByPath
        let urls = model.sourceURLByPath
        let discovered = model.fileSources
        var filedOffersDL: [String: Bool] = [:]
        for track in model.tracks where track.status == "filed" && track.origin == "soundcloud" {
            if let path = track.filePath {
                filedOffersDL[path] = !track.gateURL.isEmpty || track.scDownloadable
            }
        }
        return files.map { file in
            let src = discovered[file.path]
            let upgrade: UpgradeState
            if let state = pending[file.path] {
                upgrade = .pending(state)
            } else if losslessExts.contains(URL(fileURLWithPath: file.path)
                          .pathExtension.lowercased()) {
                upgrade = .lossless
            } else if filedOffersDL[file.path] == true || src?.offersDL == true {
                upgrade = .available
            } else {
                upgrade = .none
            }
            return LibRow(file: file,
                          source: sources[file.path] ?? (src != nil ? "SC" : ""),
                          sourceURL: urls[file.path] ?? src?.pageURL,
                          upgrade: upgrade)
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.player.current != nil { PlayerBar(player: model.player) }
        }
        .task(id: folder) {
            selection = []
            note = nil
            await rescan()
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { handleSpace(event) }
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// Space plays the selected row or toggles the player; typing stays typing.
    func handleSpace(_ event: NSEvent) -> NSEvent? {
        guard event.charactersIgnoringModifiers == " ",
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              !(event.window?.firstResponder is NSTextView) else { return event }
        let ordered = rows
        if let target = ordered.first(where: { selection.contains($0.id) }),
           target.file.path != model.player.current?.path {
            model.player.play(target.file, in: ordered.map(\.file))
        } else if model.player.current != nil {
            model.player.toggle()
        } else {
            return event
        }
        return nil
    }

    var header: some View {
        HStack {
            Text(name).font(.headline)
            Text("\(files.count)").font(.caption.monospaced()).foregroundStyle(.secondary)
            if scanning { ProgressView().controlSize(.small) }
            if model.matching {
                ProgressView().controlSize(.small)
                Text("Matching \(model.matchProgress.done)/\(model.matchProgress.total)"
                    + " · \(model.matchProgress.hits) hits")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let summary = model.matchSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let note {
                Text(note).font(.caption).foregroundStyle(.orange).lineLimit(1)
                    .help(note)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true))
            }
            Button("Rescan") { Task { await rescan() } }
                .disabled(scanning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { row in
                HStack(spacing: 8) {
                    ArtThumb(path: row.file.artPath, size: 24)
                    tagCell(row, .title)
                }
            }
            TableColumn("Artist", value: \.artist) { row in
                tagCell(row, .artist)
            }
            TableColumn("Genre", value: \.genre) { row in
                tagCell(row, .genre)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Time", value: \.durationS) { row in
                Text(timestamp(row.durationS))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .width(44)
            TableColumn("Ext", value: \.ext) { row in
                Text(row.ext)
                    .font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
            }
            .width(40)
            TableColumn("Source", value: \.source) { row in
                HStack(spacing: 4) {
                    Text(row.source)
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.secondary)
                    if let raw = row.sourceURL, let url = URL(string: raw) {
                        IconButton(systemName: "arrow.up.right", size: 8, weight: .bold,
                                   hit: 20) { NSWorkspace.shared.open(url) }
                            .foregroundStyle(.tertiary)
                            .help(raw)
                    }
                }
            }
            .width(56)
            TableColumn("Upgrade", value: \.upgradeRank) { row in
                switch row.upgrade {
                case .available:
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(.teal)
                        .help("Free DL found — right-click → Upgrade")
                case .pending(let state):
                    Image(systemName: "hourglass")
                        .foregroundStyle(.orange)
                        .help(state)
                case .lossless:
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(.cyan)
                        .help("Already lossless")
                case .none:
                    EmptyView()
                }
            }
            .width(56)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            contextMenu(paths)
        } primaryAction: { paths in
            if let row = rows.first(where: { paths.contains($0.id) }) {
                model.player.play(row.file, in: rows.map(\.file))
            }
        }
        .overlay {
            if files.isEmpty && !scanning {
                Text("No audio files here yet")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    func contextMenu(_ paths: Set<String>) -> some View {
        if paths.count == 1, let row = rows.first(where: { paths.contains($0.id) }) {
            Button("Play") { model.player.play(row.file, in: rows.map(\.file)) }
            if let raw = row.sourceURL, let url = URL(string: raw) {
                Button("Open Source Page") { NSWorkspace.shared.open(url) }
            }
        }
        let upgradeables = rows.filter { paths.contains($0.id) && $0.isUpgradeable }
        if !upgradeables.isEmpty {
            Button(upgradeables.count > 1 ? "Upgrade (\(upgradeables.count))" : "Upgrade") {
                model.upgrade(upgradeables.map(\.file))
            }
        }
        if !destinations.isEmpty {
            Menu("Move to") {
                ForEach(destinations, id: \.path) { dest in
                    Button(dest.name) { move(paths, to: dest.path) }
                }
            }
        }
        let candidates = files.filter { paths.contains($0.path) && !pipelinePaths.contains($0.path) }
        if !candidates.isEmpty {
            Button(candidates.count > 1
                   ? "Find Sources on SoundCloud (\(candidates.count))"
                   : "Find Source on SoundCloud") {
                model.findSources(candidates)
            }
            .disabled(model.matching)
        }
        let sourced = files.filter {
            paths.contains($0.path)
                && (pipelinePaths.contains($0.path) || model.fileSources[$0.path] != nil)
        }
        if !sourced.isEmpty {
            Button(sourced.count > 1 ? "Clear Source Info (\(sourced.count))"
                                     : "Clear Source Info") {
                model.clearSource(sourced)
            }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        }
    }

    /// Files the pipeline already knows: filed by it, or queued for an upgrade.
    var pipelinePaths: Set<String> {
        var out = Set<String>()
        for track in model.tracks {
            if let path = track.filePath { out.insert(path) }
            if let up = track.upgradePath, !up.isEmpty { out.insert(up) }
        }
        return out
    }

    var destinations: [(path: String, name: String)] {
        var all = [(path: model.collectionDir, name: "Holding")]
        all += model.repos.map { (path: $0, name: URL(fileURLWithPath: $0).lastPathComponent) }
        return all.filter { $0.path != folder }
    }

    func move(_ paths: Set<String>, to dest: String) {
        Task {
            let result = model.scanner.move(
                Array(paths), to: URL(fileURLWithPath: dest, isDirectory: true))
            note = result.skipped.isEmpty ? nil
                : "Skipped, name already at destination: " + result.skipped.joined(separator: ", ")
            selection = []
            await rescan()
        }
    }

    /// Finder-style: cells are plain text until their row is the lone selection.
    @ViewBuilder
    func tagCell(_ row: LibRow, _ field: TagField) -> some View {
        if selection == [row.id] {
            TagCell(model: model, file: row.file, field: field) { updated in
                replace(row.file.path, with: updated)
            }
        } else {
            Text(field.value(in: row.file))
                .font(field.font)
                .foregroundStyle(field == .artist ? Color.secondary : Color.primary)
                .lineLimit(1)
        }
    }

    /// A retag can rename, so the row is matched by its pre-edit path.
    func replace(_ oldPath: String, with updated: LibraryFile) {
        if let i = files.firstIndex(where: { $0.path == oldPath }) {
            files[i] = updated
        }
        if selection.remove(oldPath) != nil {
            selection.insert(updated.path)
        }
    }

    func rescan() async {
        scanning = true
        files = await model.scanner.scan(URL(fileURLWithPath: folder, isDirectory: true))
        scanning = false
    }

    func timestamp(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

enum TagField {
    case title, artist, genre

    func value(in file: LibraryFile) -> String {
        switch self {
        case .title: file.title
        case .artist: file.artist
        case .genre: file.genre
        }
    }

    var font: Font {
        self == .title ? .system(size: 12, weight: .medium) : .system(size: 12)
    }
}

/// Edits write straight into the file's tags; Return commits. A title or
/// artist edit also renames the file to the collection convention.
struct TagCell: View {
    let model: AppModel
    let file: LibraryFile
    let field: TagField
    let onSaved: (LibraryFile) -> Void
    @State private var text: String
    @State private var saving = false

    init(model: AppModel, file: LibraryFile, field: TagField,
         onSaved: @escaping (LibraryFile) -> Void) {
        self.model = model
        self.file = file
        self.field = field
        self.onSaved = onSaved
        _text = State(initialValue: field.value(in: file))
    }

    var current: String { field.value(in: file) }

    var body: some View {
        HStack(spacing: 4) {
            TextField("—", text: $text)
                .textFieldStyle(.plain)
                .font(field.font)
                .foregroundStyle(field == .artist ? Color.secondary : Color.primary)
                .onSubmit(save)
            if saving { ProgressView().controlSize(.mini) }
        }
        .onChange(of: current) { text = current }
    }

    func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // The filename needs both halves; only genre may clear.
        if trimmed.isEmpty && field != .genre {
            text = current
            return
        }
        guard trimmed != current, !saving else { return }
        saving = true
        Task {
            var (title, artist, genre) = (file.title, file.artist, file.genre)
            switch field {
            case .title: title = trimmed
            case .artist: artist = trimmed
            case .genre: genre = trimmed
            }
            if let updated = await model.retag(file, title: title, artist: artist, genre: genre) {
                onSaved(updated)
                text = field.value(in: updated)
            } else {
                text = current
            }
            saving = false
        }
    }
}
