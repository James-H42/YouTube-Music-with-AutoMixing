import Foundation

/// `--videomixtest`: AutoMix with videos in the queue ("Prefer audio versions" on).
///  1. A song, then a video whose audio release is known: the release must be put in the
///     queue ahead of time and the pair planned as the approved P.Y.T. → Good Life transition.
///  2. A song, then a cached video with no audio release: the video's own audio is analysed
///     and planned; the queue row must not claim "same album".
@MainActor
enum VideoMixTest {
    static func run() async {
        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            print(passed ? "PASS" : "FAIL", name, detail.isEmpty ? "" : "— \(detail)")
            if !passed { failures += 1 }
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        let model = AppModel.shared, player = model.player
        let wasOn = model.settings.autoMix, preferWas = model.settings.preferAudioVersions
        model.settings.autoMix = true
        model.settings.autoplay = false
        model.settings.preferAudioVersions = true
        player.volume = 0
        defer { model.settings.autoMix = wasOn; model.settings.preferAudioVersions = preferWas }

        let pyt = model.library.song("y32ejtuxSjM") ?? Song(id: "y32ejtuxSjM", title: "P.Y.T.")
        let goodLife = model.library.song("GTmbyuTKT_c") ?? Song(id: "GTmbyuTKT_c", title: "Good Life")
        let video = Song(id: "vidtest0001", title: "Good Life (Official Video)", artists: goodLife.artists, duration: goodLife.duration, isVideo: true)
        player.setAudioVersionForTesting(video.id, goodLife)
        player.play([pyt, video])
        for _ in 0 ..< 300 where player.nextMixPlan == nil { await wait(0.1) }
        check("the video next in the queue is replaced by its audio release ahead of time", player.nextSong?.id == goodLife.id, player.nextSong?.id ?? "none")
        let plan = player.nextMixPlan
        check("and the pair is planned against that release (the approved sample match)", plan?.summary.hasPrefix("Sample match") == true && abs((plan?.outStart ?? 0) - 204.1) < 0.2,
              plan.map { "\($0.summary), leaves at \(String(format: "%.1f", $0.outStart)) s" } ?? "no plan")

        let freestyle = model.library.song("wQjZrBDy5s8") ?? Song(id: "wQjZrBDy5s8", title: "video", isVideo: true)
        check("the second test item is a cached video", freestyle.isVideo && model.media.isAvailableOffline(freestyle.id))
        player.play([goodLife, freestyle])
        for _ in 0 ..< 300 where player.nextMixPlan == nil { await wait(0.1) }
        check("a cached video with no audio release is analysed and mixed into", player.nextMixPlan != nil && player.nextSong?.id == freestyle.id,
              player.nextMixPlan?.summary ?? "no plan; row says: \(player.mixSkipReason)")
        check("the queue row no longer says 'same album' for it", player.mixSkipReason != "Plays straight through (same album)")

        let uncached = Song(id: "vidtest0002", title: "Unknown video", isVideo: true)
        player.play([goodLife, uncached])
        await wait(0.5)
        check("while the lookup hasn't answered, the row says so instead of 'same album'", player.mixSkipReason.hasPrefix("Looking for the audio version"), player.mixSkipReason)
        player.pause()
        print(failures == 0 ? "all video mixing checks passed" : "\(failures) video mixing checks FAILED")
    }
}
