import AppKit
import AVFoundation
import SwiftUI

/// `--videoplayertest [music video query]`: the music-video player end to end, live.
///  1. Only official music videos and live performances (`OMV`) count as videos; uploads
///     standing in for songs (`UGC`, e.g. leaks) are audio.
///  2. AutoMix never mixes into or out of a music video; an upload mixes like a song.
///  3. After a chosen music video, Autoplay lines up only music videos, which play as videos.
///  4. The picture fills the player and keeps the video's shape (letterboxed or pillarboxed,
///     never cropped or stretched) as the window grows, shrinks and changes shape, and with
///     lyrics open beside it.
///  5. Downloading a music video saves its picture in the best quality, which then plays.
@MainActor
enum VideoPlayerTest {
    static func run(query: String) async {
        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            print(passed ? "PASS" : "FAIL", name, detail.isEmpty ? "" : "— \(detail)")
            if !passed { failures += 1 }
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        func search(_ text: String) async -> [Song] {
            let found = (try? await YTMusic.search(text, filter: .videos).sections.flatMap(\.items)) ?? []
            return found.compactMap { if case .song(let song) = $0 { song } else { nil } }
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = AppModel.shared, player = model.player, video = NowPlayingVideo.shared
        model.settings.showVideos = true
        model.settings.preferAudioVersions = true
        model.settings.autoplay = true
        model.settings.autoMix = true
        model.settings.videoQuality = VideoQuality.auto
        player.volume = 0

        // 1. Types.
        let leaks = await search("Kanye West Mama's Boyfriend")
        check("uploads of an unreleased song are not music videos", !leaks.isEmpty && leaks.prefix(5).allSatisfy { !$0.isMusicVideo },
              leaks.prefix(5).map { $0.videoType ?? "-" }.joined(separator: ", "))
        guard let omv = await search(query).first(where: \.isMusicVideo), let leak = leaks.first else {
            print("FAIL no official music video found for “\(query)”"); exit(1)
        }
        print("music video: \(omv.id) \(omv.title) — \(omv.artistText)")
        let songs = ((try? await YTMusic.search("Michael Jackson P.Y.T.", filter: .songs).sections.flatMap(\.items)) ?? [])
            .compactMap { if case .song(let song) = $0 { song } else { nil } }
        guard let song = songs.first(where: { !$0.isVideo }) else { print("FAIL no song found"); exit(1) }

        // 2a. In a playlist (a row clicked in a playlist, album or library list, which no
        // longer counts as choosing the video), music videos play as their audio releases.
        let other = await search("Kendrick Lamar Not Like Us").first(where: { $0.isMusicVideo && $0.id != omv.id })
        let playlist = [omv, song] + (other.map { [$0] } ?? [])
        player.play(playlist, startAt: 0, chosen: SongList(songs: playlist).playsVideos)
        for _ in 0 ..< 150 where player.currentSong?.id == omv.id { await wait(0.1) }
        let playing = player.currentSong
        check("a music video at the start of a playlist plays as its audio release", playing?.id != omv.id && playing?.isVideo == false,
              playing.map { "\($0.id) \($0.title) (\($0.videoType ?? "audio"))" } ?? "nothing")
        check("and doesn't start a videos-only session", !player.isVideoSession)
        if let other {
            player.jump(to: 1)
            for _ in 0 ..< 150 where player.nextSong?.id == other.id { await wait(0.1) }
            check("a music video later in the playlist is swapped ahead of time", player.nextSong?.id != other.id && player.nextSong?.isVideo == false,
                  player.nextSong.map { "\($0.id) \($0.title)" } ?? "nothing")
        }
        player.pause()

        // 2. Mixing.
        player.setAudioVersionForTesting(omv.id, nil)
        model.settings.autoplay = false
        player.play([song, omv])
        await wait(0.3)
        check("a song followed by a music video is not mixed", player.mixPair == nil, player.mixSkipReason)
        check("and the queue says why", player.mixSkipReason.contains("music videos"), player.mixSkipReason)
        player.setAudioVersionForTesting(leak.id, nil)
        player.play([leak, song])
        await wait(0.3)
        check("an upload standing in for a song mixes like a song", player.mixPair != nil, player.mixSkipReason)
        player.pause()

        // 3. A video session.
        model.settings.autoplay = true
        player.play(song: omv)
        for _ in 0 ..< 200 where player.queue.count < 4 { await wait(0.1) }
        let queued = Array(player.queue.dropFirst())
        check("Autoplay after a music video lines up music videos", queued.count >= 3, "\(queued.count) queued")
        check("and only music videos", !queued.isEmpty && queued.allSatisfy(\.isMusicVideo),
              queued.filter { !$0.isMusicVideo }.map { "\($0.title) (\($0.videoType ?? "audio"))" }.joined(separator: ", "))
        check("which play as videos, not as their audio releases", !queued.isEmpty && queued.allSatisfy { player.chosenVideos.contains($0.id) })
        check("nothing in the session is mixed", player.mixPair == nil, player.mixSkipReason)

        // 4. Resizing.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var showQueue = false
        let host = NSHostingView(rootView: VideoStageView(showQueue: Binding(get: { showQueue }, set: { showQueue = $0 }))
            .environment(model).environment(\.colorScheme, .dark).ignoresSafeArea())
        window.contentView = host
        window.orderBack(nil)
        for _ in 0 ..< 200 where !video.isShowing { await wait(0.1) }
        check("the picture appears", video.isShowing, video.failure ?? "")
        func surface(in view: NSView) -> VideoSurface.SurfaceView? {
            if let found = view as? VideoSurface.SurfaceView { return found }
            for child in view.subviews { if let found = surface(in: child) { return found } }
            return nil
        }
        let picture = video.player.currentItem?.presentationSize ?? .zero
        print(String(format: "  video picture %.0f × %.0f", picture.width, picture.height))
        for (width, height, lyrics) in [(1180.0, 760.0, false), (1700.0, 1050.0, false), (720.0, 480.0, false), (1500.0, 420.0, false),
                                        (620.0, 900.0, false), (1180.0, 760.0, true), (900.0, 1000.0, true)] {
            model.settings.fullScreenLyrics = lyrics
            window.setContentSize(NSSize(width: width, height: height))
            await wait(0.8)
            host.layoutSubtreeIfNeeded()
            guard let view = surface(in: host) else { check("the video surface is on screen", false); break }
            let bounds = view.bounds, layer = view.playerLayer
            let rect = layer.videoRect
            let expectedWidth = lyrics ? width - min(420, width * 0.34) : width
            let aspect = picture.height > 0 ? picture.width / picture.height : 16 / 9
            let fills = abs(bounds.width - expectedWidth) < 1.5 && abs(bounds.height - height) < 1.5
            let shape = rect.height > 0 && abs(rect.width / rect.height - aspect) < 0.02
            let fitted = abs(rect.width - bounds.width) < 1.5 || abs(rect.height - bounds.height) < 1.5
            let inside = rect.minX >= -0.5 && rect.minY >= -0.5 && rect.maxX <= bounds.width + 0.5 && rect.maxY <= bounds.height + 0.5
            let centred = abs(rect.midX - bounds.midX) < 1 && abs(rect.midY - bounds.midY) < 1
            check(String(format: "window %.0f × %.0f%@: the picture fills the space and keeps its shape", width, height, lyrics ? " with lyrics" : ""),
                  fills && layer.frame == bounds && shape && fitted && inside && centred,
                  String(format: "area %.0f × %.0f, picture %.0f × %.0f at %.0f,%.0f", bounds.width, bounds.height, rect.width, rect.height, rect.minX, rect.minY))
        }
        // METROLIST_VIDEOSHOT=dir: a picture of the controls (offscreen captures leave out
        // the video itself and Liquid Glass).
        if let directory = ProcessInfo.processInfo.environment["METROLIST_VIDEOSHOT"] {
            player.pause() // the controls stay while paused
            for lyrics in [false, true] {
                model.settings.fullScreenLyrics = lyrics
                window.setContentSize(NSSize(width: 1280, height: 760))
                await wait(1)
                host.layoutSubtreeIfNeeded()
                let frame = window.contentView?.superview ?? host
                if let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("video-stage\(lyrics ? "-lyrics" : "").png"))
                }
            }
        }
        model.settings.fullScreenLyrics = false
        window.orderOut(nil)
        window.close()

        // 5. Downloading.
        let source = try? await VideoStreamResolver.shared.resolve(videoId: omv.id)
        let best = source?.bestFile
        print("  best file: \(best.map { "\($0.width)x\($0.height) \($0.codecs) \($0.bandwidth / 1000) kb/s" } ?? "none")")
        let started = Date()
        model.download([omv])
        check("downloading a music video saves its picture too", VideoDownloads.shared.isDownloading(omv.id) || VideoDownloads.shared.isDownloaded(omv.id))
        check("it is listed under Music Videos, not Downloads", model.media.isVideoDownload(omv.id))
        var lastReport = Date()
        while VideoDownloads.shared.isDownloading(omv.id), Date().timeIntervalSince(started) < 600 {
            await wait(0.5)
            if Date().timeIntervalSince(lastReport) > 15 {
                lastReport = Date()
                print(String(format: "  … %.0f%%", (VideoDownloads.shared.progress[omv.id] ?? 0) * 100))
            }
        }
        let record = VideoDownloads.shared.records[omv.id]
        check("the picture is saved", record != nil, VideoDownloads.shared.failed.contains(omv.id) ? "failed (see mixlog)" : "")
        if let record, let file = VideoDownloads.shared.fileURL(omv.id) {
            print(String(format: "  saved %.0f MB (%d × %d %@) in %.0f s", Double(record.bytes) / 1_048_576, record.width, record.height, record.codecs, Date().timeIntervalSince(started)))
            check("in the best quality offered", record.quality == source?.qualities.first, "\(record.quality)p of \(source?.qualities.first ?? 0)p")
            let asset = AVURLAsset(url: file)
            let playable = (try? await asset.load(.isPlayable)) == true
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            check("and the saved file plays", playable && duration > 10, String(format: "%.0f s", duration))
        }
        player.pause()
        print(failures == 0 ? "all video player checks passed" : "\(failures) video player checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
