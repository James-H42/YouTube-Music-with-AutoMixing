import AppKit
import MediaPlayer
import Network

/// Tracks connectivity so the player can skip songs that aren't available offline.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true
    /// Called when the connection comes back after being lost.
    var onReconnect: (() -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let now = path.status == .satisfied
            let was = self?.lock.withLock { () -> Bool in let before = self?.online ?? true; self?.online = now; return before } ?? true
            if now, !was { self?.onReconnect?() }
        }
        monitor.start(queue: DispatchQueue(label: "metrolist.network"))
    }

    var isOnline: Bool { lock.withLock { online } }
}

/// Publishes playback to macOS (Control Center / menu bar Now Playing, media keys, AirPods
/// controls) and routes the system's transport commands back to the player.
@MainActor
final class NowPlayingBridge {
    private weak var player: PlayerController?
    private var artworkURL: String?
    private var artwork: MPMediaItemArtwork?

    init(player: PlayerController) {
        self.player = player
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.player?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.player?.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.player?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.player?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player?.seek(to: event.positionTime)
            return .success
        }
        center.likeCommand.localizedTitle = "Like"
        center.likeCommand.addTarget { [weak self] _ in
            self?.player?.toggleLikeCurrent()
            return .success
        }
    }

    func update(song: Song?, isPlaying: Bool, position: Double, duration: Double, liked: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        guard let song else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artistText,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = song.album?.name { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if artworkURL == song.thumbnail, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        MPRemoteCommandCenter.shared().likeCommand.isActive = liked

        if artworkURL != song.thumbnail {
            artworkURL = song.thumbnail
            artwork = nil
            guard let url = song.thumbnail?.resizedThumbnail(600) else { return }
            Task { [weak self] in
                guard let image = await ImageLoader.shared.image(for: url), let self, self.artworkURL == song.thumbnail else { return }
                let item = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.artwork = item
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = item
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}
