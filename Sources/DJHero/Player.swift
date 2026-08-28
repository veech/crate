import AVFoundation
import SwiftUI
import DJHeroCore

@Observable
@MainActor
final class PlayerModel {
    private(set) var current: LibraryFile?
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private(set) var position: Double = 0
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    func play(_ file: LibraryFile) {
        ticker?.cancel()
        player?.stop()
        guard let loaded = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: file.path)) else {
            stop()
            return
        }
        player = loaded
        current = file
        duration = loaded.duration
        position = 0
        loaded.play()
        isPlaying = true
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let player else { return }
        position = player.currentTime
        if isPlaying && !player.isPlaying {
            isPlaying = false
            position = duration
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if position >= duration - 0.05 {
                player.currentTime = 0
                position = 0
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(_ t: Double) {
        player?.currentTime = min(max(0, t), max(0, duration - 0.05))
        position = t
    }

    func stop() {
        ticker?.cancel()
        player?.stop()
        player = nil
        current = nil
        isPlaying = false
        position = 0
        duration = 0
    }
}

struct PlayerBar: View {
    @Environment(AppModel.self) private var model
    @State private var scrub: Double?

    var body: some View {
        let player = model.player
        HStack(spacing: 12) {
            ArtThumb(path: player.current?.artPath, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.current?.title ?? "")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(player.current?.artist ?? "")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 200, alignment: .leading)
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
            Text(timestamp(scrub ?? player.position))
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { scrub ?? player.position },
                    set: { scrub = $0 }),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let target = scrub {
                        player.seek(target)
                        scrub = nil
                    }
                }
            )
            .controlSize(.small)
            Text(timestamp(player.duration))
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            Button { player.stop() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    func timestamp(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct ArtThumb: View {
    let path: String?
    let size: CGFloat

    var body: some View {
        if let path {
            AsyncImage(url: URL(fileURLWithPath: path)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: size, height: size)
        }
    }
}
