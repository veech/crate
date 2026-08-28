import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DJHeroCore

struct StageSpec: Identifiable {
    let id: String
    let label: String
    let color: Color
    let statuses: Set<String>
}

let stages: [StageSpec] = [
    StageSpec(id: "in_flight", label: "In Flight", color: .cyan,
              statuses: ["new", "resolving", "resolved", "fetching", "fetched", "normalizing"]),
    StageSpec(id: "held_gate", label: "Gates", color: .orange, statuses: ["held_gate"]),
    StageSpec(id: "needs_review", label: "Needs Review", color: .red,
              statuses: ["needs_review"]),
    StageSpec(id: "buy_list", label: "Buy List", color: .purple, statuses: ["buy_list"]),
    StageSpec(id: "filed", label: "Filed", color: .green, statuses: ["filed"]),
]

let activeStatuses: Set<String> = ["resolving", "fetching", "normalizing"]

let activeStageLabel: [String: String] = [
    "resolving": "Resolving", "fetching": "Downloading", "normalizing": "Tagging",
]

let sourceLabel: [String: String] = [
    "sc_free_dl": "Free DL", "sc_rip": "SC rip", "ytm": "YTM",
    "gate": "Gate", "purchase": "Purchase", "existing": "Duplicate",
]

enum Col {
    static let art: CGFloat = 28
    static let artist: CGFloat = 150
    static let origin: CGFloat = 30
    static let source: CGFloat = 64
    static let time: CGFloat = 42
    static let event: CGFloat = 240
    static let actions: CGFloat = 185
}

struct PipelineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(stages) { stage in
                        section(stage)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var header: some View {
        HStack {
            Text("Pipeline").font(.headline)
            Spacer()
            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            if model.tracks.contains(where: { activeStatuses.contains($0.status) }) {
                ProgressView().controlSize(.small)
            }
            Button(model.cycling ? "Cycling…" : "Run cycle") { model.runCycle() }
                .disabled(model.cycling)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    func section(_ stage: StageSpec) -> some View {
        let rows = model.tracks.filter { stage.statuses.contains($0.status) }
        let shown = Array(rows.prefix(stage.id == "filed" ? 30 : 500))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(stage.color).frame(width: 7, height: 7)
                Text(stage.label).font(.subheadline).bold()
                Text("\(rows.count)").font(.caption.monospaced())
                    .foregroundStyle(rows.isEmpty ? .secondary : Color.primary)
            }
            if rows.isEmpty {
                Text("Empty").font(.caption).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
                    columnHeaders
                    Divider()
                    ForEach(shown) { track in
                        TrackRow(track: track)
                        if track.id != shown.last?.id {
                            Divider().opacity(0.5)
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                if stage.id == "filed" && rows.count > 30 {
                    Text("Showing the latest 30 of \(rows.count)")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    var columnHeaders: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: Col.art, height: 1)
            headerText("Title").frame(maxWidth: .infinity, alignment: .leading)
            headerText("Artist").frame(width: Col.artist, alignment: .leading)
            headerText("Org").frame(width: Col.origin, alignment: .leading)
            headerText("Source").frame(width: Col.source, alignment: .leading)
            headerText("Time").frame(width: Col.time, alignment: .trailing)
            headerText("Last event").frame(width: Col.event, alignment: .leading)
            Color.clear.frame(width: Col.actions, height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    func headerText(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .medium))
            .foregroundStyle(.tertiary).kerning(0.8)
    }
}

struct TrackRow: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        HStack(spacing: 10) {
            artwork
            Text(Matcher.displayTitle(track.title, mix: track.mix))
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(track.artist)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: Col.artist, alignment: .leading)
            Text(track.origin == "beatport" ? "BP" : "SC")
                .font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                .frame(width: Col.origin, alignment: .leading)
            Text(track.chosenSource.flatMap { sourceLabel[$0] } ?? track.chosenSource ?? "")
                .font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Col.source, alignment: .leading)
            Text(duration)
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: Col.time, alignment: .trailing)
            eventCell
                .frame(width: Col.event, alignment: .leading)
            actionsCell
                .frame(width: Col.actions, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    var actionsCell: some View {
        if track.status == "held_gate" {
            HStack(spacing: 6) {
                Button("Open gate") {
                    if let url = URL(string: track.gateURL) { NSWorkspace.shared.open(url) }
                }
                Button("Choose file…") { selectGateFile() }
            }
            .controlSize(.small)
        } else if track.status == "needs_review" {
            HStack(spacing: 6) {
                Button("Retry") { model.retry(track) }
                Button("Buy instead") { model.sendToBuyList(track) }
            }
            .controlSize(.small)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    func selectGateFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.directoryURL = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            model.attachGateFile(track: track, file: url)
        }
    }

    var duration: String {
        String(format: "%d:%02d", track.durationS / 60, track.durationS % 60)
    }

    var eventCell: some View {
        HStack(spacing: 6) {
            if let stage = activeStageLabel[track.status] {
                ProgressView().controlSize(.mini)
                Text(stage).font(.system(size: 10).monospaced()).foregroundStyle(.cyan)
            }
            if let event = try? model.store.lastEvent(trackId: track.id) {
                Text(event.event)
                    .font(.system(size: 10).monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(event.detail.map { "\(event.event) · \($0)" } ?? event.event)
            }
        }
    }

    @ViewBuilder
    var artwork: some View {
        if !track.artURL.isEmpty, let url = URL(string: track.artURL) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            }
            .frame(width: Col.art, height: Col.art)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: Col.art, height: Col.art)
        }
    }
}
