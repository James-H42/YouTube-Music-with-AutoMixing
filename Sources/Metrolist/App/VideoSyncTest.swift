import AVFoundation
import Foundation

/// `--videosynctest [query]`: a music video chosen by the listener plays as a video. Its
/// sound plays (at zero volume) through the audio engine and its picture through
/// `NowPlayingVideo`; the gap between them is measured while playing, after a seek, and
/// while paused.
@MainActor
enum VideoSyncTest {
    static func run(query: String) async {
        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            print(passed ? "PASS" : "FAIL", name, detail.isEmpty ? "" : "— \(detail)")
            if !passed { failures += 1 }
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        let model = AppModel.shared, player = model.player, video = NowPlayingVideo.shared
        model.settings.autoplay = false
        model.settings.preferAudioVersions = true
        model.settings.showVideos = true
        player.volume = 0

        let found = (try? await YTMusic.search(query, filter: .videos).sections.flatMap(\.items)) ?? []
        guard let song = found.compactMap({ if case .song(let song) = $0 { song } else { nil } }).first(where: \.isVideo) else {
            print("FAIL no video found for “\(query)”"); exit(1)
        }
        print("video: \(song.id) \(song.title)")
        var opened = false
        player.onChosenVideo = { opened = true }
        player.play(song: song)
        check("choosing a video asks for the full-screen player", opened)
        // A surface on screen (attach is what the view does).
        video.attach()
        for _ in 0 ..< 200 where !(player.isPlaying && player.currentTime > 1) { await wait(0.1) }
        check("the chosen video itself plays, not its audio release", player.currentSong?.id == song.id, player.currentSong.map { "\($0.id) \($0.title)" } ?? "nothing")

        func gaps(for seconds: Double) async -> [Double] {
            var result: [Double] = []
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                await wait(0.5)
                let picture = video.player.currentTime().seconds
                if picture.isFinite, video.player.currentItem?.status == .readyToPlay { result.append(picture - player.currentTime) }
                if ProcessInfo.processInfo.environment["VIDEOSYNC_DEBUG"] == "1" {
                    print(String(format: "  gap %+.3f rate %.3f status %d", picture - player.currentTime, video.player.rate, video.player.timeControlStatus.rawValue))
                }
            }
            return result
        }
        func summary(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "no samples" }
            return String(format: "%d samples, median %+.3f s, worst %+.3f s", values.count, values.sorted()[values.count / 2], values.max { abs($0) < abs($1) }!)
        }
        for _ in 0 ..< 100 where video.player.currentItem?.status != .readyToPlay { await wait(0.1) }
        check("the picture loads", video.player.currentItem?.status == .readyToPlay, video.failure ?? "")
        _ = await gaps(for: 3) // settling
        if ProcessInfo.processInfo.environment["VIDEOSYNC_DEBUG"] == "1" {
            let wall = Date(), sound = player.currentTime, picture = video.player.currentTime().seconds
            await wait(4)
            let elapsed = Date().timeIntervalSince(wall)
            print(String(format: "  over %.2f s of wall time: sound advanced %.3f s, picture %.3f s; effective video rate %.3f",
                         elapsed, player.currentTime - sound, video.player.currentTime().seconds - picture,
                         video.player.currentItem.map { CMTimebaseGetRate($0.timebase!) } ?? -1))
        }
        let playing = await gaps(for: 8)
        let steady = playing.suffix(8)
        check("while playing, the picture stays within 0.1 s of the sound", !steady.isEmpty && steady.allSatisfy { abs($0) < 0.1 }, summary(Array(steady)))

        player.seek(to: 60)
        for _ in 0 ..< 100 where !(player.isPlaying && player.currentTime > 60.5) { await wait(0.1) }
        _ = await gaps(for: 2)
        let afterSeek = await gaps(for: 4)
        check("after a seek to 1:00, the picture follows", !afterSeek.isEmpty && afterSeek.suffix(4).allSatisfy { abs($0) < 0.1 }, summary(afterSeek))

        player.pause()
        await wait(1.5)
        let pausedAt = video.player.currentTime().seconds
        await wait(1.5)
        check("pausing pauses the picture on the same moment", video.player.rate == 0 && abs(video.player.currentTime().seconds - pausedAt) < 0.05
              && abs(pausedAt - player.currentTime) < 0.15, String(format: "picture %.2f, sound %.2f", pausedAt, player.currentTime))

        // A video arriving in a queue on its own is still swapped for its audio release.
        video.detach()
        print(failures == 0 ? "all video sync checks passed" : "\(failures) video sync checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
