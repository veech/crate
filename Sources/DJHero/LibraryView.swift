import AppKit
import SwiftUI
import DJHeroCore

/// A library file joined with its pipeline provenance, shaped for the table.
struct LibRow: Identifiable {
    let file: LibraryFile
    let source: String

    var id: String { file.path }
    var title: String { file.title }
    var artist: String { file.artist }
    var genre: String { file.genre }
    var durationS: Double { file.durationS }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let folder: String
    let name: String

    @State private var files: [LibraryFile] = []
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\LibRow.title)]
    @State private var scanning = false
    @State private var note: String?

    var rows: [LibRow] {
        let sources = model.sourceByPath
        return files.map { LibRow(file: $0, source: sources[$0.path] ?? "") }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.player.current != nil { PlayerBar() }
        }
        .task(id: folder) {
            selection = []
            note = nil
            await rescan()
        }
    }

    var header: some View {
        HStack {
            Text(name).font(.headline)
            Text("\(files.count)").font(.caption.monospaced()).foregroundStyle(.secondary)
            if scanning { ProgressView().controlSize(.small) }
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
                    Text(row.title)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
            }
            TableColumn("Artist", value: \.artist) { row in
                Text(row.artist)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            TableColumn("Genre", value: \.genre) { row in
                GenreCell(file: row.file) { updated in
                    if let i = files.firstIndex(where: { $0.path == updated.path }) {
                        files[i] = updated
                    }
                }
            }
            .width(min: 90, ideal: 140)
            TableColumn("Time", value: \.durationS) { row in
                Text(timestamp(row.durationS))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .width(44)
            TableColumn("Source", value: \.source) { row in
                Text(row.source)
                    .font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
            }
            .width(64)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            contextMenu(paths)
        } primaryAction: { paths in
            if let row = rows.first(where: { paths.contains($0.id) }) {
                model.player.play(row.file)
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
        if paths.count == 1, let file = files.first(where: { paths.contains($0.path) }) {
            Button("Play") { model.player.play(file) }
        }
        if !destinations.isEmpty {
            Menu("Move to") {
                ForEach(destinations, id: \.path) { dest in
                    Button(dest.name) { move(paths, to: dest.path) }
                }
            }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        }
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

/// Genre edits write straight into the file's tag; Return commits.
struct GenreCell: View {
    @Environment(AppModel.self) private var model
    let file: LibraryFile
    let onSaved: (LibraryFile) -> Void
    @State private var text: String
    @State private var saving = false

    init(file: LibraryFile, onSaved: @escaping (LibraryFile) -> Void) {
        self.file = file
        self.onSaved = onSaved
        _text = State(initialValue: file.genre)
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField("—", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(save)
            if saving { ProgressView().controlSize(.mini) }
        }
        .onChange(of: file.genre) { text = file.genre }
    }

    func save() {
        guard text != file.genre, !saving else { return }
        saving = true
        Task {
            if let updated = await model.setGenre(file, genre: text) {
                onSaved(updated)
            } else {
                text = file.genre
            }
            saving = false
        }
    }
}
