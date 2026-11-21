import AppKit
import Foundation

/// `--radiotest` (live, needs METROLIST_HOME; use a release build for the last part, which
/// analyses songs): the queue fixes of 2026-11-21.
///  1. Start Radio fills the queue at once, with Autoplay on or off, and its songs are Autoplay's
///     (AutoMix may order them).
///  2. Play Next goes straight after the playing song; Add to Queue goes after the listener's own
///     songs but before what the radio lined up.
///  3. A radio started while another radio's page is still being fetched gets only its own songs.
///  4. Autoplay follows its setting for a single song.
///  5. With AutoMix ordering on, Autoplay's songs after a Play Next song are ordered to mix out of
///     that song, and the Play Next song keeps its place.
///  6. Test runs keep their settings apart from the app's own.
@MainActor
enum RadioTest {
    static func run() async {
        guard let home = ProcessInfo.processInfo.environment["METROLIST_HOME"], !home.isEmpty else {
            print("FAIL set METROLIST_HOME to a test folder")
            exit(1)
        }
        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            print(passed ? "PASS" : "FAIL", name, detail.isEmpty ? "" : "— \(detail)")
            if !passed { failures += 1 }
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        func song(_ query: String) async -> Song? {
            let found = (try? await YTMusic.search(query, filter: .songs).sections.flatMap(\.items)) ?? []
            return found.compactMap { if case .song(let song) = $0, !song.isVideo { song } else { nil } }.first
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = AppModel.shared, player = model.player, settings = model.settings
        let appSettings = UserDefaults(suiteName: "app.metrolist.mac.automix")
        let appAutoplayBefore = appSettings?.object(forKey: "autoplay") as? Bool
        player.volume = 0
        settings.autoMix = false
        settings.preferAudioVersions = true
        settings.autoplay = false

        guard let seed = await song("Jamiroquai Virtual Insanity"), let other = await song("Kenshi Yonezu Lemon"),
              let extra = await song("Daft Punk One More Time")
        else {
            print("FAIL could not find the test songs (offline?)")
            exit(1)
        }
        print("songs: \(seed.title) [\(seed.id)], \(other.title) [\(other.id)], \(extra.title) [\(extra.id)]")

        // 1. Start Radio with Autoplay off.
        player.playRadio(for: seed)
        for _ in 0 ..< 200 where player.queue.count < 6 { await wait(0.1) }
        check("Start Radio fills the queue with Autoplay off", player.queue.count >= 6, "\(player.queue.count) songs")
        check("the radio's songs are Autoplay's, so AutoMix may order them",
              player.queue.count > 1 && player.queue.dropFirst().allSatisfy { player.isAutoQueued($0.id) })
        check("the song it was started for plays first and isn't queued again",
              player.queue.first?.id == seed.id && player.queue.filter { $0.id == seed.id || $0.title == seed.title && $0.artistText == seed.artistText }.count == 1,
              player.queue.prefix(4).map(\.title).joined(separator: ", "))

        // 2. Priority.
        let radioOrder = Array(player.queue.dropFirst()).map(\.id)
        player.playNext([other])
        check("Play Next goes straight after the playing song", player.queue.count > 1 && player.queue[1].id == other.id)
        player.enqueue([extra])
        let extraIndex = player.queue.firstIndex { $0.id == extra.id }
        check("Add to Queue goes after the listener's songs, before the radio's", extraIndex == 2, "at \(extraIndex.map(String.init) ?? "-")")
        check("and the radio's songs follow in their order", Array(player.queue.dropFirst(3)).map(\.id) == radioOrder)

        // 3. A radio replaced while its first page is still on the way.
        let firstPage = Set(((try? await YTMusic.radio(for: seed.id))?.songs ?? []).map(\.id)).subtracting([seed.id])
        player.playRadio(for: seed)
        player.playRadio(for: other)
        for _ in 0 ..< 200 where player.queue.count < 6 { await wait(0.1) }
        await wait(4) // time for the first request to land, if it were going to
        let strays = player.queue.dropFirst().filter { firstPage.contains($0.id) }
        check("a radio started while another was loading gets only its own songs",
              player.queue.first?.id == other.id && player.queue.count >= 6 && strays.isEmpty,
              "\(player.queue.count) songs, \(strays.count) from the earlier radio: \(strays.prefix(3).map(\.title).joined(separator: ", "))")

        // 4. Autoplay's setting.
        player.play(song: extra)
        await wait(4)
        check("with Autoplay off, a single song stays alone", player.queue.count == 1, "\(player.queue.count) songs")
        settings.autoplay = true
        player.play(song: extra)
        for _ in 0 ..< 200 where player.queue.count < 4 { await wait(0.1) }
        check("with Autoplay on, a single song is followed by its radio", player.queue.count >= 4, "\(player.queue.count) songs")

        // 6. Settings.
        check("test runs keep their settings apart from the app's", AppPaths.settings !== UserDefaults.standard)
        check("the app's own Autoplay setting is untouched", (appSettings?.object(forKey: "autoplay") as? Bool) == appAutoplayBefore,
              "\(appAutoplayBefore.map(String.init) ?? "unset") before")

        // 5. Ordering for mixing after a Play Next song.
        if CommandLine.arguments.contains("--no-order") {
            print("SKIP ordering (--no-order)")
        } else {
            settings.autoMix = true
            settings.mixStyle = .smart
            settings.mixOrdersQueue = true
            settings.mixStems = false
            player.playRadio(for: seed)
            for _ in 0 ..< 200 where player.queue.count < 7 { await wait(0.1) }
            player.playNext([other])
            let started = Date()
            var verdict: (passed: Bool, detail: String) = (false, "nothing analysed in time")
            while Date().timeIntervalSince(started) < 420 {
                await wait(2)
                guard let anchor = player.analyses[other.id] else { continue }
                let start = player.firstFlexibleIndex
                let pool = player.queue[start ..< min(player.queue.count, start + MixSequencer.pool)].filter { player.isAutoQueued($0.id) }
                let analysed = pool.compactMap { song in player.analyses[song.id].map { (song, MixSequencer.fit(anchor, $0, sameArtist: !MixSequencer.names(of: other).isDisjoint(with: MixSequencer.names(of: song)))) } }
                guard analysed.count >= 3, let first = pool.first, let best = analysed.max(by: { $0.1.total < $1.1.total }) else { continue }
                guard let placed = analysed.first(where: { $0.0.id == first.id }) else { continue }
                // Autoplay's own order is kept in close calls, by 0.03 a place (`MixSequencer.order`).
                let passed = player.queue[1].id == other.id && placed.1.total >= best.1.total - 0.03 * Double(MixSequencer.pool)
                verdict = (passed, String(format: "after %@: %@ (%.2f) placed first; best analysed %@ (%.2f); %d of %d analysed",
                                          other.title, first.title, placed.1.total, best.0.title, best.1.total, analysed.count, pool.count))
                if passed, analysed.count == pool.count { break }
                if Date().timeIntervalSince(started) > 300, passed { break }
            }
            check("Autoplay's songs after a Play Next song are ordered to mix out of it, and it keeps its place", verdict.passed, verdict.detail)
            let log = (try? String(contentsOf: AppPaths.root.appendingPathComponent("mix.log"), encoding: .utf8)) ?? ""
            for line in log.split(separator: "\n").filter({ $0.contains("autoplay order") }).suffix(3) { print("  log: \(line)") }
        }
        player.pause()
        print(failures == 0 ? "all radio checks passed" : "\(failures) radio checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
