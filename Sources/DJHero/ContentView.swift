import AppKit
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
                        .tag("holding")
                    ForEach(model.repos, id: \.self) { path in
                        Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                            .tag("repo:" + path)
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.open(
                                        URL(fileURLWithPath: path, isDirectory: true))
                                }
                                Button("Remove from Library") {
                                    model.removeRepo(path)
                                    if selection == "repo:" + path { selection = "holding" }
                                }
                            }
                    }
                    Button { addRepo() } label: {
                        Label("Add Folder…", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
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
            switch selection {
            case "holding":
                LibraryView(folder: model.collectionDir, name: "Holding")
            case let tag? where tag.hasPrefix("repo:"):
                let path = String(tag.dropFirst("repo:".count))
                LibraryView(folder: path, name: URL(fileURLWithPath: path).lastPathComponent)
            default:
                PipelineView()
            }
        }
    }

    func addRepo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.path == model.collectionDir {
            selection = "holding"
        } else {
            model.addRepo(url)
            selection = "repo:" + url.path
        }
    }
}
