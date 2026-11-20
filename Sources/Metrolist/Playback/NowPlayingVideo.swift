import AVFoundation
import Foundation
import Observation

/// The picture of the playing music video or live performance. The sound stays in the audio
/// engine (AutoMix, the equaliser, gapless playback and downloads are unchanged); this plays
/// the same video muted with AVPlayer and keeps it on the engine's clock.
///
/// Nothing is fetched unless a video surface is on screen, the playing item is a video and
/// Settings → "Show the video" is on.
@MainActor
@Observable
final class NowPlayingVideo {
    static let shared = NowPlayingVideo()

    @ObservationIgnored let player = AVPlayer()
    /// The video whose picture is loaded (or loading).
    private(set) var videoId: String?
    /// The first frame is on screen: until then the cover art shows.
    private(set) var isShowing = false
    private(set) var failure: String?
    /// The qualities the loaded video has, best first (for the quality menu).
    private(set) var qualities: [Int] = []
    /// The quality on screen now: the fixed one chosen, or what Auto settled on.
    private(set) var showingQuality: Int?

    @ObservationIgnored weak var controller: PlayerController?
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    /// The quality setting (`VideoQuality`): 0 is Auto.
    @ObservationIgnored var preferredQuality: () -> Int = { VideoQuality.auto }
    /// The quality setting the loaded item was opened for.
    @ObservationIgnored private var loadedQuality = VideoQuality.auto
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var retried = false
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var unload: Task<Void, Never>?
    /// Recent (wall clock, sound position) pairs, for the speed the sound is playing at:
    /// 1, except while AutoMix stretches a song's tempo.
    @ObservationIgnored private var clock: [(Date, Double)] = []
    @ObservationIgnored private var lastAnchor = Date.distantPast

    /// Larger than this, the video seeks (loading what it needs); smaller, it is re-timed.
    static let seekThreshold = 1.0
    /// Gaps up to this go unnoticed; larger ones are corrected.
    static let tolerance = 0.04

    init() {
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = true
        // Required for timing the video to the system clock (`setRate(_:time:atHostTime:)`).
        player.automaticallyWaitsToMinimizeStalling = false
    }

    /// The song whose picture should show now, if any.
    var wantedSong: Song? {
        guard viewers > 0, isEnabled(), let song = controller?.currentSong, song.isMusicVideo else { return nil }
        return song
    }

    /// A video surface appeared.
    func attach() {
        viewers += 1
        unload?.cancel()
        unload = nil
        if loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        tick()
    }

    /// A video surface went away. With none left, the picture stops; the loaded video is
    /// kept a little while in case the player is reopened.
    func detach() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        loop?.cancel()
        loop = nil
        player.pause()
        unload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.load(nil)
        }
    }

    /// The surface reports when its first frame is shown.
    func surfaceReady(_ ready: Bool) {
        if isShowing != ready { isShowing = ready }
    }

    private func tick() {
        let wanted = wantedSong
        if wanted?.id != videoId {
            load(wanted)
        } else if wanted != nil, preferredQuality() != loadedQuality, !VideoDownloads.shared.isDownloaded(videoId ?? "") {
            changeQuality()
        }
        updateShowingQuality()
        if wanted != nil { follow() } else if player.rate != 0 { player.pause() }
    }

    private func load(_ song: Song?) {
        loading?.cancel()
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
        videoId = song?.id
        isShowing = false
        failure = nil
        retried = false
        qualities = []
        showingQuality = nil
        fixedQuality = nil
        loadedQuality = preferredQuality()
        guard let song else { return }
        loading = Task { [weak self] in await self?.open(song.id) }
    }

    private func open(_ id: String) async {
        // A downloaded video plays from its file, in the quality it was saved in.
        if let file = VideoDownloads.shared.fileURL(id), let record = VideoDownloads.shared.records[id] {
            qualities = [record.quality]
            fixedQuality = record.quality
            play(AVPlayerItem(url: file), id: id)
            return
        }
        do {
            let source = try await VideoStreamResolver.shared.resolve(videoId: id)
            guard !Task.isCancelled, videoId == id else { return }
            qualities = source.qualities
            guard let stream = source.stream(for: loadedQuality) else { throw YTError.noStream }
            let asset = AVURLAsset(url: stream.url, options: [AVURLAssetHTTPUserAgentKey: source.userAgent])
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 15
            fixedQuality = stream.quality
            play(item, id: id)
        } catch {
            guard videoId == id else { return }
            failure = (error as? LocalizedError)?.errorDescription ?? "The video couldn't be loaded."
        }
    }

    private func play(_ item: AVPlayerItem, id: String) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            DispatchQueue.main.async {
                guard let self, failed, self.videoId == id else { return }
                self.failed(id, item.error?.localizedDescription ?? "The video couldn't be played.")
            }
        }
        player.replaceCurrentItem(with: item)
        follow()
    }

    /// The media server refused the address (it expired, or was for another identity): ask
    /// once more, then give up and leave the cover art.
    private func failed(_ id: String, _ message: String) {
        guard !retried else { failure = message; return }
        retried = true
        Task {
            await VideoStreamResolver.shared.forget(id)
            guard videoId == id else { return }
            statusObservation = nil
            player.replaceCurrentItem(with: nil)
            isShowing = false
            loading = Task { [weak self] in await self?.open(id) }
        }
    }

    /// Keeps the picture on the sound's clock. The video is timed to the system clock from
    /// the sound's position, so it plays exactly in step without seeking; it is re-timed
    /// only when it drifts, and seeks only after a large jump (a seek in the song).
    private func follow() {
        guard let controller, let item = player.currentItem, item.status == .readyToPlay, !seeking else { return }
        let target = controller.currentTime
        let now = player.currentTime().seconds
        guard now.isFinite, target.isFinite else { return }
        let playing = controller.isPlaying
        let rate = soundRate(target, playing: playing)
        let drift = now - target

        guard playing else {
            if player.rate != 0 { player.pause() }
            if abs(drift) > 0.08 { seek(to: target) }
            return
        }
        if abs(drift) > Self.seekThreshold {
            seek(to: target)
            return
        }
        let mistimed = abs(drift) > Self.tolerance || player.rate == 0 || abs(Double(player.rate) - rate) > 0.004
        guard mistimed, Date().timeIntervalSince(lastAnchor) > 1 else { return }
        lastAnchor = Date()
        // Where the sound will be a moment from now, when the video starts that frame.
        let lead = 0.05
        let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: lead, preferredTimescale: 1_000_000))
        player.setRate(Float(rate), time: CMTime(seconds: target + lead * rate, preferredTimescale: 600), atHostTime: host)
    }

    /// The fixed quality the loaded item plays (nil for Auto, which AVPlayer adapts).
    @ObservationIgnored private var fixedQuality: Int?

    /// The quality setting changed while a video shows: open the new quality and let
    /// `follow` seek it to the sound. The cover shows for the moment it takes.
    private func changeQuality() {
        guard let id = videoId else { return }
        loading?.cancel()
        statusObservation = nil
        loadedQuality = preferredQuality()
        retried = false
        failure = nil
        loading = Task { [weak self] in await self?.open(id) }
    }

    private func updateShowingQuality() {
        let size = player.currentItem?.presentationSize ?? .zero
        let found = fixedQuality ?? (size.height > 0 ? VideoQuality.label(width: Int(size.width), height: Int(size.height)) : nil)
        if found != showingQuality { showingQuality = found }
    }

    private func seek(to target: Double) {
        seeking = true
        player.pause()
        player.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.seeking = false
                self?.lastAnchor = .distantPast
            }
        }
    }

    /// How fast the sound's position has moved against the wall clock over the last two
    /// seconds, rounded so tiny measurement noise doesn't re-time the video.
    private func soundRate(_ position: Double, playing: Bool) -> Double {
        let now = Date()
        guard playing else { clock = []; return 1 }
        if let last = clock.last, position < last.1 || position - last.1 > 2 { clock = [] }
        clock.append((now, position))
        clock.removeAll { now.timeIntervalSince($0.0) > 2 }
        guard let first = clock.first, now.timeIntervalSince(first.0) > 1.5 else { return 1 }
        let measured = (position - first.1) / now.timeIntervalSince(first.0)
        // Only AutoMix's stretches (a few percent) count; anything else is a jump.
        guard abs(measured - 1) > 0.008, abs(measured - 1) < 0.12 else { return 1 }
        return (measured * 200).rounded() / 200
    }
}
