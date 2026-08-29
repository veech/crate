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
                    HStack {
                        Label("Inbox", systemImage: "tray")
                        Spacer()
                        if model.inboxCount > 0 {
                            Text("\(model.inboxCount)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.cyan.opacity(0.15), in: Capsule())
                        }
                    }
                    .tag("inbox")
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
                                    if selection == "repo:" + path { selection = "inbox" }
                                }
                            }
                    }
                    Button { addRepo() } label: {
                        Label("Add Folder…", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Label("Trash", systemImage: "trash")
                        .tag("trash")
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
            case "inbox":
                LibraryView(model: model, folder: model.collectionDir, name: "Inbox")
            case "trash":
                LibraryView(model: model, folder: model.cfg.trashDir.path, name: "Trash")
            case let tag? where tag.hasPrefix("repo:"):
                let path = String(tag.dropFirst("repo:".count))
                LibraryView(model: model, folder: path,
                            name: URL(fileURLWithPath: path).lastPathComponent)
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
            selection = "inbox"
        } else {
            model.addRepo(url)
            selection = "repo:" + url.path
        }
    }
}
