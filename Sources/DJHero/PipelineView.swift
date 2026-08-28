import SwiftUI
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
            SettingsLink { Text("Settings") }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    func section(_ stage: StageSpec) -> some View {
        let rows = model.tracks.filter { stage.statuses.contains($0.status) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(stage.color).frame(width: 7, height: 7)
                Text(stage.label).font(.subheadline).bold()
                Text("\(rows.count)").font(.caption.monospaced())
                    .foregroundStyle(rows.isEmpty ? .secondary : Color.primary)
            }
            if rows.isEmpty {
                Text("Empty").font(.caption).foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                ForEach(rows.prefix(stage.id == "filed" ? 30 : 500)) { track in
                    TrackRow(track: track)
                }
            }
        }
    }
}

struct TrackRow: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        HStack(spacing: 10) {
            if activeStatuses.contains(track.status) {
                ProgressView().controlSize(.mini)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(Matcher.displayTitle(track.title, mix: track.mix))
                    .font(.system(size: 12, weight: .medium))
                Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(track.origin == "beatport" ? "BP" : "SC")
                .font(.system(size: 9).monospaced()).foregroundStyle(.secondary)
            if let event = try? model.store.lastEvent(trackId: track.id) {
                Text(event.event).font(.system(size: 10).monospaced())
                    .foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}
