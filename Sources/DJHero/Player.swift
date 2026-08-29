import AVFoundation
import AppKit
import MediaPlayer
import SwiftUI
import DJHeroCore

@Observable
@MainActor
final class PlayerModel {
    private(set) var current: LibraryFile?
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private(set) var position: Double = 0
    private(set) var queue: [LibraryFile] = []
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    init() {
        setupRemoteCommands()
    }

    /// The visible list re-syncs the queue on sort or content changes, so
    /// next/previous always follow what the user is looking at.
    func syncQueue(_ files: [LibraryFile]) {
        guard let current, files.contains(where: { $0.path == current.path }) else { return }
        queue = files
    }

    /// Hardware media keys arrive through the system's Now Playing service.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Bool) {
            command.addTarget { _ in
                MainActor.assumeIsolated { action() ? .success : .noSuchContent }
            }
        }
        bind(center.playCommand) { self.resumeIfLoaded() }
        bind(center.pauseCommand) { self.pauseIfPlaying() }
        bind(center.togglePlayPauseCommand) {
            guard self.current != nil else { return false }
            self.toggle()
            return true
        }
        bind(center.nextTrackCommand) {
            guard self.hasNext else { return false }
            self.next()
            return true
        }
        bind(center.previousTrackCommand) {
            guard self.current != nil else { return false }
            self.previous()
            return true
        }
        center.changePlaybackPositionCommand.addTarget { event in
            MainActor.assumeIsolated {
                guard let event = event as? MPChangePlaybackPositionCommandEvent,
                      self.current != nil else { return .noSuchContent }
                self.seek(event.positionTime)
                return .success
            }
        }
    }

    private func resumeIfLoaded() -> Bool {
        guard current != nil, !isPlaying else { return current != nil }
        toggle()
        return true
    }

    private func pauseIfPlaying() -> Bool {
        guard isPlaying else { return current != nil }
        toggle()
        return true
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artPath = current.artPath, let image = NSImage(contentsOfFile: artPath) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in
                image
            }
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    /// The queue is the folder's rows as sorted when playback started.
    func play(_ file: LibraryFile, in newQueue: [LibraryFile]? = nil) {
        if let newQueue { queue = newQueue }
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
        updateNowPlaying()
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
            if hasNext {
                next()
            } else {
                isPlaying = false
                position = duration
                updateNowPlaying()
            }
        }
    }

    private var currentIndex: Int? {
        guard let current else { return nil }
        return queue.firstIndex { $0.path == current.path }
    }

    var hasNext: Bool {
        guard let i = currentIndex else { return false }
        return i + 1 < queue.count
    }

    func next() {
        guard let i = currentIndex, i + 1 < queue.count else { return }
        play(queue[i + 1])
    }

    /// Deep into a track it restarts; near the start it goes back one.
    func previous() {
        guard current != nil else { return }
        if position > 3 {
            seek(0)
        } else if let i = currentIndex, i > 0 {
            play(queue[i - 1])
        } else {
            seek(0)
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
        updateNowPlaying()
    }

    func seek(_ t: Double) {
        player?.currentTime = min(max(0, t), max(0, duration - 0.05))
        position = t
        updateNowPlaying()
    }

    func stop() {
        ticker?.cancel()
        player?.stop()
        player = nil
        current = nil
        isPlaying = false
        position = 0
        duration = 0
        updateNowPlaying()
    }
}

struct PlayerBar: View {
    let player: PlayerModel
    @State private var scrub: Double?

    var body: some View {
        HStack(spacing: 12) {
            ArtThumb(path: player.current?.artPath, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.current?.title ?? "")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(player.current?.artist ?? "")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 200, alignment: .leading)
            IconButton(systemName: "backward.fill", size: 11) { player.previous() }
            IconButton(systemName: player.isPlaying ? "pause.fill" : "play.fill",
                       size: 15, hit: 30) { player.toggle() }
            IconButton(systemName: "forward.fill", size: 11) { player.next() }
                .disabled(!player.hasNext)
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
            IconButton(systemName: "xmark.circle.fill") { player.stop() }
                .foregroundStyle(.tertiary)
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

/// A bare glyph is only clickable on its own pixels; this pads every icon
/// button out to a real hit target.
struct IconButton: View {
    let systemName: String
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    var hit: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .frame(width: hit, height: hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
