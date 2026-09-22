import AppKit
import SwiftUI
import CrateCore

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
    let analysis: FileAnalysis?

    var quality: Double { analysis?.pq ?? -1 }

    var id: String { file.path }
    var title: String { file.title }
    var artist: String { file.artist }
    var genre: String { file.genre }
    var durationS: Double { file.durationS }
    var mtime: Double { file.mtime }
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
    @State private var sortOrder = [KeyPathComparator(\LibRow.mtime, order: .reverse)]
    @State private var scanning = false
    @State private var note: String?
    @State private var keyMonitor: Any?
    @State private var confirmEmpty = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var isTrash: Bool { folder == model.cfg.trashDir.path }

    /// Every whitespace-separated term must hit title, artist, or genre.
    var visibleFiles: [LibraryFile] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return files }
        return files.filter { file in
            terms.allSatisfy { term in
                [file.title, file.artist, file.genre].contains {
                    $0.range(of: term,
                             options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
        }
    }

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
        return visibleFiles.map { file in
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
                          upgrade: upgrade,
                          analysis: model.analyses[file.path])
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
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
        }
        .task(id: folder) {
            selection = []
            note = nil
            query = ""
            await rescan()
        }
        .onChange(of: sortOrder) { model.player.syncQueue(rows.map(\.file)) }
        .onChange(of: query) { model.player.syncQueue(rows.map(\.file)) }
        .onChange(of: model.player.current?.path) {
            // Selection follows playback, but never tramples a multi-select.
            guard selection.count <= 1,
                  let path = model.player.current?.path,
                  files.contains(where: { $0.path == path }) else { return }
            selection = [path]
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
            Text(query.isEmpty ? "\(files.count)" : "\(rows.count) of \(files.count)")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if scanning { ProgressView().controlSize(.small) }
            if model.matching {
                ProgressView().controlSize(.small)
                Text("Matching \(model.matchProgress.done)/\(model.matchProgress.total)"
                    + " · \(model.matchProgress.hits) hits")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let summary = model.matchSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            if model.analyzing {
                ProgressView().controlSize(.small)
                Text("Analyzing \(model.analyzeProgress.done)/\(model.analyzeProgress.total)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let note {
                Text(note).font(.caption).foregroundStyle(.orange).lineLimit(1)
                    .help(note)
            }
            searchField
            if isTrash {
                Button("Empty Trash", role: .destructive) { confirmEmpty = true }
                    .disabled(files.isEmpty)
                    .confirmationDialog(
                        "Permanently delete \(files.count) file(s)?",
                        isPresented: $confirmEmpty
                    ) {
                        Button("Delete \(files.count) File(s)", role: .destructive) {
                            model.emptyTrash()
                            Task { await rescan() }
                        }
                    }
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

    var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onExitCommand {
                    query = ""
                    searchFocused = false
                }
            if !query.isEmpty {
                IconButton(systemName: "xmark.circle.fill", size: 10, hit: 16) { query = "" }
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: 180)
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
            TableColumn("Modified", value: \.mtime) { row in
                Text(Date(timeIntervalSince1970: row.mtime),
                     format: .dateTime.day().month(.abbreviated).year())
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .width(78)
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
                        .foregroundStyle(.cyan)
                        .help("Free DL found — right-click → Upgrade")
                case .pending(let state):
                    Image(systemName: "hourglass")
                        .foregroundStyle(.orange)
                        .help(state)
                case .lossless:
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(.tertiary)
                        .help("Already lossless")
                case .none:
                    EmptyView()
                }
            }
            .width(56)
            TableColumn("Quality", value: \.quality) { row in
                if let a = row.analysis {
                    Text(String(format: "%.1f", a.pq))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(a.pq < 5 ? Color.red
                                         : a.pq < 7 ? Color.orange : Color.secondary)
                        .help(String(format: "Production %.1f · Enjoyment %.1f"
                                     + " · Usefulness %.1f · Complexity %.1f",
                                     a.pq, a.ce, a.cu, a.pc))
                }
            }
            .width(48)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            contextMenu(paths)
        } primaryAction: { paths in
            if let row = rows.first(where: { paths.contains($0.id) }) {
                model.player.play(row.file, in: rows.map(\.file))
            }
        }
        .onDeleteCommand {
            guard !isTrash, !selection.isEmpty else { return }
            move(selection, to: model.cfg.trashDir.path)
        }
        .overlay {
            if rows.isEmpty && !scanning {
                Text(files.isEmpty ? "No audio files here yet" : "No matches")
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
            if let track = model.tracks.first(where: {
                   $0.filePath == row.id && $0.status == "filed" && $0.chosenSource == "ytm"
               }) {
                Button("Wrong Match — Rematch") { model.rejectMatch(track) }
            }
        }
        let upgradeables = rows.filter { paths.contains($0.id) && $0.isUpgradeable }
        if !upgradeables.isEmpty {
            Button(upgradeables.count > 1 ? "Upgrade (\(upgradeables.count))" : "Upgrade") {
                model.upgrade(upgradeables.map(\.file))
            }
        }
        let selected = files.filter { paths.contains($0.path) }
        let unanalyzed = selected.filter { model.analyses[$0.path] == nil }
        // Scores are deterministic, so fresh files are the default target;
        // an all-analyzed selection offers an explicit re-run instead.
        let targets = unanalyzed.isEmpty ? selected : unanalyzed
        if !targets.isEmpty {
            let verb = unanalyzed.isEmpty ? "Re-analyze Quality" : "Analyze Quality"
            Button(targets.count > 1 ? "\(verb) (\(targets.count))" : verb) {
                model.analyze(targets)
            }
            .disabled(model.analyzing)
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
        if !isTrash {
            Divider()
            Button(paths.count > 1 ? "Move to Trash (\(paths.count))" : "Move to Trash",
                   role: .destructive) {
                move(paths, to: model.cfg.trashDir.path)
            }
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
        var all = [(path: model.collectionDir, name: "Inbox")]
        all += model.repos.map { (path: $0, name: URL(fileURLWithPath: $0).lastPathComponent) }
        return all.filter { $0.path != folder }
    }

    func move(_ paths: Set<String>, to dest: String) {
        Task {
            let result = model.scanner.move(
                Array(paths), to: URL(fileURLWithPath: dest, isDirectory: true),
                uniquing: dest == model.cfg.trashDir.path)
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
        model.player.syncQueue(rows.map(\.file))
    }

    func rescan() async {
        scanning = true
        files = await model.scanner.scan(URL(fileURLWithPath: folder, isDirectory: true))
        scanning = false
        model.player.syncQueue(rows.map(\.file))
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
