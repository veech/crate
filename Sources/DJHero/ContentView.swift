import SwiftUI
import DJHeroCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String? = "pipeline"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Workspace") {
                    HStack {
                        Label("Pipeline", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if model.tracks.contains(where: { activeStatuses.contains($0.status) }) {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .tag("pipeline")
                }
                Section("Library") {
                    Label("Holding", systemImage: "tray")
                        .foregroundStyle(.tertiary)
                        .selectionDisabled()
                    Label("Repositories", systemImage: "folder")
                        .foregroundStyle(.tertiary)
                        .selectionDisabled()
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            PipelineView()
        }
    }
}
