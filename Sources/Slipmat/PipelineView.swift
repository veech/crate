import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SlipmatCore

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
]

let activeStatuses: Set<String> = ["resolving", "fetching", "normalizing"]

let activeStageLabel: [String: String] = [
    "resolving": "Resolving", "fetching": "Downloading", "normalizing": "Tagging",
]

let originLabel: [String: String] = [
    "beatport": "BP", "youtube": "YT", "soundcloud": "SC",
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
    static let actions: CGFloat = 250
    /// Fixed columns + spacing + padding, plus room for the title to breathe.
    static let minContent: CGFloat = 940
}

struct PipelineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Fixed-width columns scroll sideways below their natural width
            // instead of crushing the title and clipping the action buttons.
            GeometryReader { geo in
                ScrollView(.horizontal) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(stages) { stage in
                                section(stage)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: max(geo.size.width, Col.minContent),
                           height: geo.size.height)
                }
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
            if model.cycling {
                Button("Stop") { model.stopCycle() }
            } else {
                Button("Run cycle") { model.runCycle() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    func section(_ stage: StageSpec) -> some View {
        let rows = model.tracks.filter { stage.statuses.contains($0.status) }
        let shown = Array(rows.prefix(500))
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
            }
        }
    }

    var columnHeaders: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: Col.art, height: 1)
            headerText("Title").frame(maxWidth: .infinity, alignment: .leading)
            headerText("Artist").frame(width: Col.artist, alignment: .leading)
            headerText("Time").frame(width: Col.time, alignment: .trailing)
            headerText("Org").frame(width: Col.origin, alignment: .leading)
            headerText("Source").frame(width: Col.source, alignment: .leading)
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
            Text(duration)
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: Col.time, alignment: .trailing)
            Text(originLabel[track.origin] ?? "SC")
                .font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                .frame(width: Col.origin, alignment: .leading)
            Text(track.chosenSource.flatMap { sourceLabel[$0] } ?? track.chosenSource ?? "")
                .font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Col.source, alignment: .leading)
            eventCell
                .frame(width: Col.event, alignment: .leading)
            actionsCell
                .frame(width: Col.actions, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    var actionsCell: some View {
        HStack(spacing: 6) {
            if track.status == "held_gate" {
                Button("Open gate") {
                    if let url = URL(string: track.gateURL) { NSWorkspace.shared.open(url) }
                }
                Button("Choose file…") { selectGateFile() }
                Button("Just rip") { model.justRip(track) }
            } else if track.status == "needs_review" {
                Button("Retry") { model.retry(track) }
                Button("Buy instead") { model.sendToBuyList(track) }
            }
            IconButton(systemName: "xmark.circle.fill", size: 10, hit: 16) {
                model.deleteFromPipeline(track)
            }
            .help("Remove from pipeline")
        }
        .controlSize(.small)
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
