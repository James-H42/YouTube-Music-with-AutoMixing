import Foundation

/// `--playnexttest`: a song chosen with Play Next is the next one played, and AutoMix mixes into it.
///  - Ordering: Play Next on a song Autoplay had lined up (AutoMix's ordering used to move it);
///    shuffle on and off; a shared-queue guest adding a song; your phone's Play Next.
///  - Mixing (muted, real playback of cached songs): Play Next during the tempo approach of
///    another transition, too late for any transition, and while a transition is audible.
@MainActor
enum PlayNextTest {
    static func run() async {
        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            print(passed ? "PASS" : "FAIL", name, detail.isEmpty ? "" : "— \(detail)")
            if !passed { failures += 1 }
        }
        func wait(_ seconds: Double, until done: () -> Bool = { false }) async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, !done() { try? await Task.sleep(for: .milliseconds(100)) }
        }
        Keychain.service = "Metrolist.playnexttest.\(UUID().uuidString)"
        let model = AppModel.shared, player = model.player, settings = model.settings
        let saved = (settings.autoMix, settings.autoplay, settings.mixOrdersQueue, settings.mixStyle)
        defer { (settings.autoMix, settings.autoplay, settings.mixOrdersQueue, settings.mixStyle) = saved }
        settings.autoMix = true
        settings.autoplay = false
        settings.mixOrdersQueue = true
        settings.mixStyle = .smart
        player.volume = 0
        func song(_ id: String) -> Song { model.library.song(id) ?? Song(id: id, title: id) }
        let pyt = song("y32ejtuxSjM"), goodLife = song("GTmbyuTKT_c"), hbfs = song("JhulBGMA7G4"), stronger = song("2ulp_AMut14")
        let birdbrain = song("dBLzh47wdrU"), keepMeGoing = song("V4HdD2Fu_64"), starships = song("_cUM4SlY2_o")
        func next() -> String { player.nextSong?.id ?? "-" }
        func names(_ ids: [String]) -> String { ids.map { id in player.queue.first { $0.id == id }?.title ?? id }.joined(separator: ", ") }

        let only = ProcessInfo.processInfo.environment["PLAYNEXT_ONLY"]
        if only == nil {
        // MARK: Ordering
        player.play([pyt])
        await wait(10) { player.position > 1 }
        player.appendAutoQueued([goodLife, stronger, keepMeGoing, starships])
        player.playNext([keepMeGoing]) // also lined up by Autoplay, further down
        check("Play Next puts the song next", next() == keepMeGoing.id, next())
        check("and takes away Autoplay's mark, so AutoMix's ordering leaves it alone", !player.isAutoQueued(keepMeGoing.id) && player.isPlayNext(keepMeGoing.id))
        await wait(12) // AutoMix looks at the Autoplay songs and re-orders them
        check("after AutoMix has ordered Autoplay's songs, it is still next", next() == keepMeGoing.id, "next: \(player.nextSong?.title ?? "-")")
        player.playNext([birdbrain])
        check("a second Play Next goes in front of the first, as before", Array(player.upcoming.prefix(2)).map(\.id) == [birdbrain.id, keepMeGoing.id])
        let all = Set(player.queue.map(\.id))
        player.toggleShuffle()
        check("shuffle on keeps the Play Next songs in front", Array(player.upcoming.prefix(2)).map(\.id) == [birdbrain.id, keepMeGoing.id], names(player.upcoming.map(\.id)))
        player.toggleShuffle()
        check("shuffle off keeps them in front and loses nothing", Array(player.upcoming.prefix(2)).map(\.id) == [birdbrain.id, keepMeGoing.id] && Set(player.queue.map(\.id)) == all,
              names(player.upcoming.map(\.id)))

        // A shared-queue guest and your own phone.
        let policy = SharedQueuePolicy(persisting: false)
        policy.open = true
        let target = DCTarget(player: player)
        target.guestPolicy = policy
        var session = "", revision = 0
        target.send = { _, message in
            if let id = message["sessionId"] as? String { session = id }
            if let r = ((message["snapshot"] as? [String: Any])?["queueRevision"] as? NSNumber)?.intValue { revision = r }
            return true
        }
        func send(_ object: [String: Any], from peer: String) { target.receive((try? JSONSerialization.data(withJSONObject: object)) ?? Data(), from: peer) }
        send(["type": "ATTACH"], from: "guest:play-next-guest")
        send(["type": "COMMAND", "sessionId": session, "queueRevision": revision, "command": ["action": "ADD", "songs": [target.item(for: hbfs)]]], from: "guest:play-next-guest")
        let guestAt = player.queue.firstIndex { $0.id == hbfs.id } ?? -1, pinnedAt = player.queue.firstIndex { $0.id == keepMeGoing.id } ?? 99
        check("a guest's song goes behind your Play Next songs", guestAt > pinnedAt && next() == birdbrain.id, names(player.upcoming.map(\.id)))
        send(["type": "ATTACH"], from: "own-phone")
        send(["type": "COMMAND", "sessionId": session, "queueRevision": revision, "command": ["action": "PLAY_NEXT", "songs": [target.item(for: stronger)]]], from: "own-phone")
        check("your phone's Play Next is next and held there too", next() == stronger.id && player.isPlayNext(stronger.id) && !player.isAutoQueued(stronger.id), names(player.upcoming.map(\.id)))
        target.stop()
        player.removeFromQueue(at: (player.currentIndex ?? 0) + 1)
        check("removing a Play Next song lets go of it", !player.isPlayNext(stronger.id) || player.queue.contains { $0.id == stronger.id })
        player.pause()

        }
        // MARK: Mixing
        if only == nil {
        // 1. During the 40 s tempo approach of P.Y.T. → Good Life (out at 204.1 s).
        player.play([pyt, goodLife])
        await wait(60) { player.nextMixPlan != nil && player.status == .ready && player.position > 1 }
        let first = player.nextMixPlan
        check("P.Y.T. → Good Life plans its approved transition", first?.summary.hasPrefix("Sample match") == true, first?.summary ?? "none")
        player.seek(to: 175) // inside the approach, which starts about 40 s before 204 s
        await wait(4)
        player.playNext([hbfs])
        check("Play Next during another transition's approach makes the song next", next() == hbfs.id)
        await wait(60) { player.nextMixPlan != nil && player.nextSong?.id == hbfs.id }
        let late = player.nextMixPlan
        check("AutoMix plans a transition into it that can still happen", late.map { $0.outStart - ($0.approach ?? 0) > 175 } ?? false,
              late.map { String(format: "%@, out at %.1f s, approach %.0f s", $0.summary, $0.outStart, $0.approach ?? 0) } ?? "none")
        var mixed = false, handed = false
        await wait(80) {
            if player.mixActivity != nil { mixed = true }
            if player.currentSong?.id == hbfs.id { handed = true }
            return handed && player.mixActivity == nil
        }
        check("the transition runs into the Play Next song", mixed && handed, "mixed \(mixed), now playing \(player.currentSong?.title ?? "-")")

        }
        // 2. Too late for any transition: it still plays next.
        player.play([pyt, goodLife])
        await wait(30) { player.nextMixPlan != nil && player.status == .ready && player.position > 1 }
        player.seek(to: max(0, player.duration - 7))
        await wait(1)
        player.playNext([birdbrain])
        check("Play Next in the last seconds is still next", next() == birdbrain.id)
        for _ in 0 ..< 20 where player.currentSong?.id != birdbrain.id {
            if only != nil { print(String(format: "   %.1f / %.1f s, %@, playing %@, status %@, next %@", player.position, player.duration, player.currentSong?.title ?? "-", player.isPlaying ? "yes" : "no", "\(player.status)", player.nextSong?.title ?? "-")) }
            await wait(1)
        }
        check("and plays next, after the song ends", player.currentSong?.id == birdbrain.id, player.currentSong?.title ?? "-")
        if only != nil { player.pause(); print(failures == 0 ? "ok" : "failed"); return }

        // 3. While a transition is already audible: after the song fading in.
        player.play([hbfs, stronger])
        await wait(60) { player.nextMixPlan != nil && player.status == .ready && player.position > 1 }
        if let plan = player.nextMixPlan {
            player.seek(to: max(0, plan.outStart - 4))
            await wait(15) { player.mixActivity != nil && (player.mixActivity?.progress ?? 1) < 0.4 }
            let during = player.mixActivity != nil && player.currentSong?.id == hbfs.id
            player.playNext([keepMeGoing])
            check("Play Next while a transition is audible goes after the song fading in", during && Array(player.upcoming.prefix(2)).map(\.id) == [stronger.id, keepMeGoing.id],
                  "during: \(during), up next: \(names(player.upcoming.map(\.id)))")
            await wait(30) { player.currentSong?.id == stronger.id && player.mixActivity == nil }
            check("the hand-over still completes, and the Play Next song is next", player.currentSong?.id == stronger.id && next() == keepMeGoing.id,
                  "now \(player.currentSong?.title ?? "-"), next \(player.nextSong?.title ?? "-")")
        } else {
            check("HBFS → Stronger planned", false)
        }
        // 4. The best transition can no longer be reached: the approved P.Y.T. → Good Life
        //    eases P.Y.T. from about 164 s; Play Next Good Life at 185 s must use another one.
        player.play([pyt, stronger])
        await wait(60) { player.status == .ready && player.position > 1 }
        player.seek(to: 185)
        await wait(3)
        player.playNext([goodLife])
        await wait(30) { player.nextMixPlan != nil && player.nextSong?.id == goodLife.id }
        let chosen = player.nextMixPlan
        let best = player.nextMixCandidates.first
        check("when the best transition can't be reached any more, a reachable one is used for this play",
              chosen != nil && best?.summary.hasPrefix("Sample match") == true && chosen.map { $0.outStart - ($0.approach ?? 0) > 185 } == true,
              "best: \(best?.summary ?? "-"); used: \(chosen.map { String(format: "%@ out at %.1f s", $0.summary, $0.outStart) } ?? "-")")
        var ran = false
        await wait(60) {
            if player.mixActivity != nil { ran = true }
            return player.currentSong?.id == goodLife.id && player.mixActivity == nil
        }
        check("and it runs", ran && player.currentSong?.id == goodLife.id)
        player.play([pyt, goodLife])
        await wait(30) { player.nextMixPlan != nil }
        check("the next time the pair plays from the start, the approved transition is back", player.nextMixPlan?.summary.hasPrefix("Sample match") == true, player.nextMixPlan?.summary ?? "-")
        player.pause()
        print(failures == 0 ? "all Play Next checks passed" : "\(failures) Play Next checks FAILED")
    }
}
