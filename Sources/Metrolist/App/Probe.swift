import Foundation

/// Command-line smoke test of the network layer: `Metrolist --probe [query]`.
enum Probe {
    static func run() async {
        let query = CommandLine.arguments.drop { $0 != "--probe" }.dropFirst().first ?? "Daft Punk Get Lucky"

        func describe(_ sections: [ItemSection]) {
            for section in sections.prefix(8) {
                print("  [\(section.title)] \(section.items.count) items\(section.isList ? " (list)" : "")")
                for item in section.items.prefix(3) {
                    var extra = ""
                    if case .song(let song) = item {
                        extra = " | \(song.album?.name ?? "-") | \(song.duration.map { formatDuration(Double($0)) } ?? "-")\(song.isVideo ? " | VIDEO" : "")"
                    }
                    print("     \(item.id) — \(item.title) — \(item.subtitle)\(extra)")
                }
            }
        }

        await step("home") {
            let home = try await YTMusic.home()
            print("  continuation: \(home.continuation != nil)")
            describe(home.sections)
        }

        await step("suggestions") {
            print("  ", try await YTMusic.searchSuggestions(String(query.prefix(6))))
        }

        var firstSong: Song?
        var firstAlbum: AlbumItem?
        var firstArtist: ArtistItem?
        var firstPlaylist: PlaylistItem?
        await step("search all") {
            let results = try await YTMusic.search(query)
            describe(results.sections)
        }
        for filter in [SearchFilter.songs, .videos, .albums, .artists, .playlists] {
            await step("search \(filter.rawValue)") {
                let results = try await YTMusic.search(query, filter: filter)
                describe(results.sections)
                print("  continuation: \(results.continuation != nil)")
                for item in results.sections.flatMap(\.items) {
                    switch item {
                    case .song(let song) where filter == .songs: firstSong = firstSong ?? song
                    case .song(let song) where filter == .videos:
                        if let audio = await YTMusic.audioCounterpart(for: song) {
                            print("  counterpart of video \(song.id) '\(song.title)' → \(audio.id) '\(audio.title)' video=\(audio.isVideo)")
                        } else {
                            print("  no counterpart for video \(song.id) '\(song.title)'")
                        }
                        return
                    case .album(let album): firstAlbum = firstAlbum ?? album
                    case .artist(let artist): firstArtist = firstArtist ?? artist
                    case .playlist(let playlist): firstPlaylist = firstPlaylist ?? playlist
                    default: break
                    }
                }
            }
        }

        if let album = firstAlbum {
            await step("album \(album.id)") {
                let page = try await YTMusic.album(album.id)
                print("  \(page.album.title) by \(page.album.artists.map(\.name)) year=\(page.album.year ?? "-") playlist=\(page.album.playlistId ?? "-") — \(page.subtitle ?? "")")
                for song in page.songs.prefix(3) { print("     \(song.id) \(song.title) — \(song.artistText) \(song.duration ?? -1)s") }
                print("  \(page.songs.count) songs, \(page.sections.count) extra sections")
            }
        }
        if let artist = firstArtist {
            await step("artist \(artist.id)") {
                let page = try await YTMusic.artist(artist.id)
                print("  \(page.artist.title) — \(page.artist.subtitle ?? "-") radio=\(page.radioPlaylistId ?? "-")")
                describe(page.sections)
            }
        }
        if let playlist = firstPlaylist {
            await step("playlist \(playlist.id)") {
                let page = try await YTMusic.playlist(playlist.id)
                print("  \(page.playlist.title) by \(page.playlist.author ?? "-") — \(page.songs.count) songs, continuation=\(page.continuation != nil)")
                for song in page.songs.prefix(3) { print("     \(song.id) \(song.title) — \(song.artistText) | \(song.album?.name ?? "-")") }
            }
        }
        if let song = firstSong {
            await step("radio \(song.id)") {
                let page = try await YTMusic.radio(for: song.id)
                print("  \(page.songs.count) songs, continuation=\(page.continuation != nil), lyrics=\(page.lyricsBrowseId ?? "-"), counterparts=\(page.counterparts.count)")
                for song in page.songs.prefix(3) { print("     \(song.id) \(song.title) — \(song.artistText) | \(song.album?.name ?? "-") \(song.duration ?? -1)s video=\(song.isVideo)") }
            }
            await step("stream \(song.id)") {
                let stream = try await StreamResolver.shared.resolve(videoId: song.id, quality: .high)
                print("  itag \(stream.itag) \(stream.mimeType) \(stream.bitrate) bps via \(stream.clientId), length \(stream.contentLength ?? -1), loudness \(stream.loudnessDb ?? 0) dB, expires \(stream.expiresAt)")
            }
            await step("lyrics \(song.title)") {
                let result = await LyricsService.shared.fetch(for: song, duration: Double(song.duration ?? 0))
                if let result {
                    let wordSynced = result.lines.contains { !$0.words.isEmpty }
                    print("  \(result.provider): \(result.lines.count) lines, synced=\(result.isSynced), wordSynced=\(wordSynced)")
                    for line in result.lines.prefix(3) { print("     [\(line.start)] \(line.text) (\(line.words.count) words)") }
                } else {
                    print("  none")
                }
            }
        }
    }

    /// Silent end-to-end check of resolve → progressive download → decode → output:
    /// `Metrolist --playtest [videoId]`.
    @MainActor
    static func playTest() async {
        let videoId = CommandLine.arguments.drop { $0 != "--playtest" }.dropFirst().first ?? "4D7u5KF7SP8"
        let media = MediaStore()
        let engine = AudioEngine()
        engine.volume = 0
        var statuses: [String] = []
        var ended = false
        engine.onStatus = { statuses.append("\($0)") }
        engine.onEnded = { ended = true }

        func report(_ label: String) {
            print(String(format: "  %@: t=%.2f dur=%.2f", label, engine.currentTime, engine.duration), "statuses:", statuses)
            statuses = []
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

        print("== streaming playback of \(videoId) (muted)")
        let started = Date()
        let opened = media.open(videoId: videoId)
        print("  source: \(opened.download == nil ? "local file" : "progressive download")")
        engine.load(opened, startAt: 0, autoplay: true, normalize: true)
        while engine.currentTime <= 0, Date().timeIntervalSince(started) < 15 { await wait(0.05) }
        print(String(format: "  time to first audio: %.2fs", Date().timeIntervalSince(started)))
        await wait(2); report("after 2s")
        engine.seek(to: 120); await wait(1.5); report("seek 120 +1.5s")
        engine.pause(); await wait(0.3); let held = engine.currentTime; await wait(1); report("paused 1s (held \(String(format: "%.2f", held)))")
        engine.play(); await wait(1); report("resumed +1s")
        let length = engine.duration
        engine.seek(to: max(0, length - 2.5)); await wait(4); report("seek to end-2.5 +4s")
        print("  ended callback: \(ended)")

        await wait(1)
        print("== cached replay")
        print("  cached on disk: \(media.isAvailableOffline(videoId)), bytes: \(media.records[videoId]?.bytes ?? 0), itag: \(media.records[videoId]?.itag ?? 0)")
        let again = media.open(videoId: videoId)
        print("  source: \(again.download == nil ? "local file" : "progressive download")")
        let restarted = Date()
        ended = false
        engine.load(again, startAt: 30, autoplay: true, normalize: true)
        while engine.currentTime <= 30, Date().timeIntervalSince(restarted) < 10 { await wait(0.02) }
        print(String(format: "  time to first audio from disk: %.2fs", Date().timeIntervalSince(restarted)))
        await wait(1); report("local +1s from 30")
        engine.stop()

        print("== gapless hand-over")
        let second = CommandLine.arguments.drop { $0 != "--playtest" }.dropFirst(2).first ?? "qPRNIHxLhmc"
        var advanced: [String] = []
        ended = false
        engine.onAdvanced = { advanced.append($0) }
        engine.load(media.open(videoId: videoId), startAt: 0, autoplay: true, normalize: true)
        await wait(2)
        engine.enqueueNext(media.open(videoId: second))
        await wait(1.5)
        engine.seek(to: max(0, length - 3))
        await wait(2)
        report("1s before the join")
        await wait(2.5)
        report("after the join (expect t≈1.5, new duration)")
        print("  advanced to: \(advanced), ended callback: \(ended)")
        engine.seek(to: 60); await wait(1.2); report("seek 60 in second track")
        engine.stop()

        print("== word-synced lyrics")
        let song = Song(id: "probe-shape-of-you", title: "Shape of You", artists: [ArtistRef(name: "Ed Sheeran")])
        if let lyrics = await LyricsService.shared.fetch(for: song, duration: 234, forceRefresh: true) {
            let worded = lyrics.lines.filter { !$0.words.isEmpty }
            print("  \(lyrics.provider): \(lyrics.lines.count) lines, \(worded.count) with word timing, background: \(lyrics.lines.filter(\.isBackground).count)")
            for line in lyrics.lines.prefix(2) {
                print("     [\(line.start)–\(line.end ?? -1)] \(line.text)")
                print("        " + line.words.prefix(6).map { "\($0.text)|\($0.start)-\($0.end)" }.joined(separator: " "))
            }
        } else {
            print("  none")
        }
        try? FileManager.default.removeItem(at: AppPaths.lyrics.appendingPathComponent("probe-shape-of-you.json"))
    }

    /// Downloads a song into the cache and returns its file, for analysis and mix tests.
    @MainActor
    static func fetch(_ query: String, media: MediaStore) async -> (song: Song, file: URL)? {
        var song: Song?
        if query.count == 11, !query.contains(" ") {
            song = Song(id: query, title: query)
        } else {
            song = try? await YTMusic.search(query, filter: .songs).sections.first?.items.compactMap(\.song).first
        }
        guard let song else { return nil }
        let opened = media.open(videoId: song.id)
        if let download = opened.download {
            for _ in 0 ..< 600 {
                if case .downloading = download.state { try? await Task.sleep(for: .milliseconds(100)) } else { break }
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard let record = media.records[song.id] else { return nil }
        return (song, AppPaths.media.appendingPathComponent(record.fileName))
    }

    /// `Metrolist --analyze "query" ...` prints the tempo, key and structure AutoMix detects.
    @MainActor
    static func analyzeTest() async {
        let media = MediaStore()
        let queries = Array(CommandLine.arguments.drop { $0 != "--analyze" }.dropFirst())
        for query in queries {
            guard let (song, file) = await fetch(query, media: media) else { print("\(query): could not fetch"); continue }
            let started = Date()
            guard let analysis = await TrackAnalyzer.shared.analysis(videoId: song.id, file: file) else { print("\(song.title): analysis failed"); continue }
            print(String(format: "%@ — %@ [\(song.id)]\n   %.1f BPM (confidence %.2f) | %@ %@ (confidence %.2f) | %d beats, bar phase %d | audible %.1f–%.1f s, intro ends %.1f, outro starts %.1f of %.1f | %.2fs",
                         song.title, song.artistText, analysis.bpm, analysis.beatConfidence, analysis.camelot, analysis.keyName, analysis.keyConfidence,
                         analysis.beats.count, analysis.downbeatPhase, analysis.audibleStart, analysis.audibleEnd, analysis.introEnd, analysis.outroStart,
                         analysis.duration, Date().timeIntervalSince(started)))
        }
    }

    /// `Metrolist --potoken [identifier…]` mints attestation tokens, to check BotGuard runs here.
    @MainActor
    static func poTokenTest() async {
        let started = Date()
        let visitor = await InnerTube.shared.streamVisitorData() ?? ""
        let extra = CommandLine.arguments.drop { $0 != "--potoken" }.dropFirst().filter { !$0.hasPrefix("--") }
        print("visitor", visitor)
        for identifier in [visitor] + extra {
            do {
                let token = try await PoTokenGenerator.shared.token(for: identifier)
                print("token", identifier == visitor ? "visitor" : identifier, token)
            } catch { print("FAILED", error) }
        }
        print(String(format: "took %.1f s", Date().timeIntervalSince(started)))
    }

    /// `Metrolist --ciphertest response.json [token] [output]` unscrambles the audio addresses of a
    /// saved player response and writes them to a file, one per line as "itag address".
    static func cipherTest() async {
        let arguments = Array(CommandLine.arguments.drop { $0 != "--ciphertest" }.dropFirst())
        guard let path = arguments.first, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { print("need a response file"); return }
        let formats = JSON(data: data)["streamingData"]["adaptiveFormats"].array.filter { ($0["mimeType"].string ?? "").hasPrefix("audio/") }
        let started = Date()
        do {
            let player = try await PlayerCipher.shared.current()
            print("player \(player.id), signature timestamp \(player.signatureTimestamp)")
            let token = arguments.count > 1 && arguments[1] != "-" ? arguments[1] : nil
            let solved = try await PlayerCipher.shared.unscramble(formats, token: token)
            print(String(format: "unscrambled %d of %d formats in %.1f s", solved.count, formats.count, Date().timeIntervalSince(started)))
            let again = Date()
            _ = try await PlayerCipher.shared.unscramble(formats, token: token)
            print(String(format: "second time: %.2f s", Date().timeIntervalSince(again)))
            let lines = solved.map { "\($0.format["itag"].int ?? 0) \($0.url.absoluteString)" }.joined(separator: "\n")
            if arguments.count > 2 { try lines.write(toFile: arguments[2], atomically: true, encoding: .utf8) }
            for item in solved {
                let query = URLComponents(url: item.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                print("  itag \(item.format["itag"].int ?? 0): n = \(query.first { $0.name == "n" }?.value ?? "-"), sig \(query.contains { $0.name == "sig" || $0.name == "signature" } ? "yes" : "no")")
            }
        } catch { print("FAILED", error.localizedDescription) }
    }

    /// `Metrolist --webprobe videoId` asks each browser-family identity for a stream, with
    /// each kind of attestation token, and prints what YouTube answers.
    @MainActor
    static func webProbe() async {
        let videoId = CommandLine.arguments.drop { $0 != "--webprobe" }.dropFirst().first ?? "_cUM4SlY2_o"
        let visitor = await InnerTube.shared.streamVisitorData() ?? ""
        let visitorToken = try? await PoTokenGenerator.shared.token(for: visitor)
        let videoToken = try? await PoTokenGenerator.shared.token(for: videoId)
        var timestamp: Int?
        if let (data, _) = try? await InnerTube.shared.session.data(from: URL(string: "https://www.youtube.com/iframe_api")!),
           let text = String(data: data, encoding: .utf8), let match = text.firstMatch(of: #/player\\?\/([0-9a-zA-Z_-]{8})\\?\//#) {
            let address = "https://www.youtube.com/s/player/\(match.1)/player_ias.vflset/en_US/base.js"
            if let (script, _) = try? await InnerTube.shared.session.data(from: URL(string: address)!), let js = String(data: script, encoding: .utf8) {
                timestamp = js.firstMatch(of: #/(?:signatureTimestamp|sts)\s*:\s*(\d{5})/#).flatMap { Int($0.1) }
                print("player \(match.1), \(js.count / 1024) KB, signature timestamp \(timestamp ?? -1)")
            }
        }
        print("tokens: visitor \(visitorToken == nil ? "FAILED" : "ok"), video \(videoToken == nil ? "FAILED" : "ok")")
        let clients: [YouTubeClient] = [.webRemixPlayback, .web, .mweb, .webEmbedded, .tv, .tvSimply, .tvEmbedded]
        for client in clients {
            for (label, token) in [("no token", nil), ("visitor token", visitorToken), ("video token", videoToken)] {
                var body: [String: Any] = ["videoId": videoId, "contentCheckOk": true, "racyCheckOk": true]
                if let timestamp { body["playbackContext"] = ["contentPlaybackContext": ["signatureTimestamp": timestamp, "html5Preference": "HTML5_PREF_WANTS"]] }
                if let token { body["serviceIntegrityDimensions"] = ["poToken": token] }
                do {
                    let json = try await InnerTube.shared.post("player", client: client, body: body, anonymous: true)
                    let audio = json["streamingData"]["adaptiveFormats"].array.filter { ($0["mimeType"].string ?? "").hasPrefix("audio/") }
                    let itags = audio.compactMap { $0["itag"].int }.map(String.init).joined(separator: ",")
                    print(String(format: "%-30@ %-13@ %@ | %@ | audio %d (url %d, cipher %d) itags %@ | sabr %@ | hls %@", client.id as NSString, label as NSString,
                                 json["playabilityStatus"]["status"].string ?? "-", String((json["playabilityStatus"]["reason"].string ?? "").prefix(42)),
                                 audio.count, audio.filter { $0["url"].string != nil }.count, audio.filter { $0["signatureCipher"].string != nil }.count, itags,
                                 json["streamingData"]["serverAbrStreamingUrl"].string == nil ? "no" : "yes", json["streamingData"]["hlsManifestUrl"].string == nil ? "no" : "yes"))
                } catch { print(client.id, label, "FAILED", error) }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Analyses two songs and returns what the planner needs, using cached lyrics when present.
    @MainActor
    private static func preparePair(_ queries: [String], media: MediaStore) async -> (songs: [Song], a: TrackAnalysis, b: TrackAnalysis, lyricsA: Lyrics?, lyricsB: Lyrics?)? {
        guard queries.count >= 2,
              let (songA, fileA) = await fetch(queries[0], media: media),
              let (songB, fileB) = await fetch(queries[1], media: media),
              let a = await TrackAnalyzer.shared.analysis(videoId: songA.id, file: fileA),
              let b = await TrackAnalyzer.shared.analysis(videoId: songB.id, file: fileB)
        else { return nil }
        func lyrics(_ song: Song, _ analysis: TrackAnalysis) async -> Lyrics? {
            if let cached = await LyricsService.shared.cached(song.id) { return cached }
            guard song.title != song.id, !CommandLine.arguments.contains("--no-lyrics") else { return nil }
            return await LyricsService.shared.fetch(for: song, duration: analysis.duration)
        }
        return ([songA, songB], a, b, await lyrics(songA, a), await lyrics(songB, b))
    }

    private static func describe(_ plan: MixPlan, _ a: TrackAnalysis) -> String {
        String(format: "%@ (%@) [%@, score %.2f] leave A at %.1f s of %.0f, enter B at %.1f s, %@, %.1f s, pitch %+.0f%@ — %@",
               plan.summary, plan.detail, plan.reason.rawValue, plan.score, plan.outStart, a.duration, plan.inPoint,
               plan.sync ? "synced \(plan.beats) beats (B rate \(String(format: "%.3f", plan.periodB / plan.periodA)))" : "free-running",
               plan.duration(glide: true), plan.pitchShift, plan.loop == nil ? "" : ", looped", plan.note)
    }

    /// `Metrolist --mixplan "A" "B"` prints the transitions AutoMix proposes for a pair.
    @MainActor
    static func mixPlanTest() async {
        let media = MediaStore()
        let queries = Array(CommandLine.arguments.drop { $0 != "--mixplan" }.dropFirst()).filter { !$0.hasPrefix("--") }
        guard let pair = await preparePair(queries, media: media) else { print("could not prepare both tracks"); return }
        let (a, b) = (pair.a, pair.b)
        for (song, x, lyrics) in [(pair.songs[0], a, pair.lyricsA), (pair.songs[1], b, pair.lyricsB)] {
            print(String(format: "%@ — %.1f BPM (%.2f), %@, %d beats, %d sections at %@, lyrics: %@", song.title, x.bpm, x.beatConfidence, x.camelot, x.beats.count,
                         x.boundaries.count, x.boundaries.map { String(format: "%.0f", x.beats[$0]) }.joined(separator: " "),
                         lyrics.map { "\($0.provider) \($0.isSynced ? "synced" : "plain") \($0.lines.count) lines" } ?? "none"))
        }
        MixPlanner.debug = CommandLine.arguments.contains("--debug")
        // `--samples` asks the sample database about the pair first; `--assume-sample` plans as
        // if it had confirmed that the second song samples the first.
        var relation: SampleRelation?
        // Songs given by id carry no names; the library knows them.
        let library = LibraryStore()
        let songs = pair.songs.map { $0.artists.isEmpty ? (library.song($0.id) ?? $0) : $0 }
        if CommandLine.arguments.contains("--samples") {
            SampleDatabase.debug = true
            let asked = Date()
            relation = await SampleDatabase.shared.relation(current: songs[0], next: songs[1])
            print(String(format: "sample database: %@ (%.1f s)", relation?.text ?? "no link recorded", Date().timeIntervalSince(asked)))
            let again = Date()
            _ = await SampleDatabase.shared.relation(current: songs[0], next: songs[1])
            print(String(format: "asked again from the cache: %.3f s", Date().timeIntervalSince(again)))
        }
        if CommandLine.arguments.contains("--assume-sample") {
            relation = SampleRelation(link: .nextSamplesCurrent, text: "\(songs[1].title) samples \(songs[0].title)")
        }
        let started = Date()
        for length in CommandLine.arguments.contains("--all-lengths") ? MixLength.allCases : [.medium] {
            var options = MixOptions(length: length)
            options.relation = relation
            let plans = MixPlanner.candidates(from: a, to: b, lyricsA: pair.lyricsA, lyricsB: pair.lyricsB, options: options)
            print("\(length.title):")
            for plan in plans { print("   " + describe(plan, a)) }
        }
        print(String(format: "planned in %.2f s", Date().timeIntervalSince(started)))
    }

    /// `Metrolist --mixtest "song A" "song B" [--preset name] [--pick n] [--interrupt]` runs a muted
    /// transition and reports its timing, deck levels and how closely the beats line up.
    @MainActor
    static func mixTest() async {
        let media = MediaStore()
        let arguments = Array(CommandLine.arguments.drop { $0 != "--mixtest" }.dropFirst())
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        var queries: [String] = []
        var skip = false
        for argument in arguments {
            if skip { skip = false; continue }
            if argument == "--preset" || argument == "--pick" || argument == "--lead" { skip = true; continue }
            if !argument.hasPrefix("--") { queries.append(argument) }
        }
        guard let pair = await preparePair(queries, media: media) else { print("could not prepare both tracks"); return }
        let (songA, songB, a, b) = (pair.songs[0], pair.songs[1], pair.a, pair.b)
        var mixOptions = MixOptions()
        mixOptions.stems = arguments.contains("--stems")
        let plans = MixPlanner.candidates(from: a, to: b, lyricsA: pair.lyricsA, lyricsB: pair.lyricsB, options: mixOptions)
        guard var plan = plans.indices.contains(Int(option("--pick") ?? "0") ?? 0) ? plans[Int(option("--pick") ?? "0") ?? 0] : nil else {
            print("no plan (would play gaplessly)"); return
        }
        if let name = option("--preset"), let preset = MixPreset(rawValue: name) {
            plan = MixPlanner.shaped(plans.first { $0.sync } ?? plan, as: preset, a, b, options: MixOptions())
        }
        print("A:", songA.title, String(format: "%.1f BPM %@", a.bpm, a.camelot), "| B:", songB.title, String(format: "%.1f BPM %@", b.bpm, b.camelot))
        print("plan:", describe(plan, a))

        let engine = MixEngine()
        engine.volume = 0
        engine.enableMeters()
        var advanced: [String] = []
        var ended = false
        var activity: MixEngine.Activity?
        engine.onAdvanced = { advanced.append($0) }
        engine.onEnded = { ended = true }
        engine.onActivity = { activity = $0 }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

        // `--lead s`: how long before the mix point the first song starts (5 s by default; the
        // player queues the next song about 30 s ahead, which stem separation needs).
        let lead = Double(option("--lead") ?? "") ?? 5
        // `--ahead`: separate the stems first, as the player now does as soon as the plan is
        // known, so a short lead (a preview) has them in place.
        if arguments.contains("--ahead"), let fileA = media.open(videoId: songA.id).fileURL, let fileB = media.open(videoId: songB.id).fileURL {
            let started = Date()
            engine.separateStemsAhead(plan, current: fileA, next: fileB)
            let stretches = MixEngine.stemStretches(plan)
            while Date().timeIntervalSince(started) < 60,
                  !(StemSeparator.isCached(file: fileA, from: stretches.outgoing.start, to: stretches.outgoing.end)
                    && StemSeparator.isCached(file: fileB, from: stretches.incoming.start, to: stretches.incoming.end)) {
                await wait(0.1)
            }
            print(String(format: "stems separated ahead in %.1f s", Date().timeIntervalSince(started)))
        }
        engine.load(media.open(videoId: songA.id), startAt: max(0, plan.outStart - lead - (plan.approach ?? 0)), autoplay: true, normalize: true, mixReady: !arguments.contains("--no-glide"))
        await wait(1.5)
        engine.enqueueNext(media.open(videoId: songB.id), plan: plan)

        if arguments.contains("--interrupt") {
            // Pause and seek in the middle of a transition.
            while (activity?.progress ?? 0) < 0.25 { await wait(0.02) }
            engine.pause()
            await wait(0.4)
            let held = engine.deckTimes
            let heldProgress = activity?.progress ?? -1
            await wait(1.0)
            let after = engine.deckTimes
            print(String(format: "paused at %.0f%%: decks moved %.3f s and %.3f s in 1 s (expect 0); progress now %.0f%%",
                         heldProgress * 100, after.0 - held.0, after.1 - held.1, (activity?.progress ?? -1) * 100))
            engine.play()
            while (activity?.progress ?? 0) < 0.7, activity != nil { await wait(0.02) }
            print("resumed; shown track after midpoint:", advanced.isEmpty ? "A" : "B")
            engine.seek(to: 60)
            await wait(1.5)
            print(String(format: "seek to 60 during the blend: now at %.2f s of %.1f, transition active: %@", engine.currentTime, engine.duration, activity == nil ? "no" : "yes"))
            await wait(1.0)
            print(String(format: "one second later: %.2f s (expect about +1)", engine.currentTime))
            engine.stop()
            await wait(0.3)
            return
        }

        /// Position within the beat (0…1) at a time, from the analysed beat grid.
        func phase(_ time: Double, _ x: TrackAnalysis) -> Double? {
            guard let next = x.beats.firstIndex(where: { $0 > time }), next > 0 else { return nil }
            return (time - x.beats[next - 1]) / (x.beats[next] - x.beats[next - 1])
        }
        var errors: [Double] = []
        let deadline = Date().addingTimeInterval(plan.duration(glide: true) + 16 + plan.approachDuration)
        var lastPrint = Date.distantPast
        var from: Int?
        while Date() < deadline {
            await wait(0.05)
            guard let current = activity else {
                if from != nil, Date().timeIntervalSince(lastPrint) > 2 {
                    lastPrint = Date()
                    let rates = engine.deckRates
                    print(String(format: "  after the mix | B at %.2f s, rate %.4f", engine.currentTime, engine.activeDeckIndex == 0 ? rates.0 : rates.1))
                } else if from == nil, plan.approach != nil, Date().timeIntervalSince(lastPrint) > 4 {
                    lastPrint = Date()
                    print(String(format: "  approach | A at %.2f s, rate %.4f", engine.currentTime, engine.deckRates.0))
                }
                continue
            }
            if from == nil { from = engine.activeDeckIndex }
            let (t0, t1) = engine.deckTimes
            let (l0, l1) = engine.deckLevels
            let (r0, r1) = engine.deckRates
            let zero = from == 0
            let (timeA, timeB) = zero ? (t0, t1) : (t1, t0)
            if plan.sync, plan.loop == nil, current.progress > 0.1, current.progress < 0.95, let phaseA = phase(timeA, a), let phaseB = phase(timeB, b) {
                // With a half/double-time match, two beats of one track span one of the other.
                var error = phaseA - phaseB
                error -= error.rounded()
                errors.append(error * plan.periodA)
            }
            if Date().timeIntervalSince(lastPrint) > 1 {
                lastPrint = Date()
                print(String(format: "  %3.0f%% | A %.2f s level %.3f rate %.4f | B %.2f s level %.3f rate %.4f | shown: %@", current.progress * 100,
                             timeA, zero ? l0 : l1, zero ? r0 : r1, timeB, zero ? l1 : l0, zero ? r1 : r0, advanced.isEmpty ? "A" : "B"))
            }
        }
        if !errors.isEmpty {
            let sorted = errors.map { $0 * 1000 }.sorted()
            print(String(format: "beat alignment over %d samples: median %+.0f ms, 10–90 %% %+.0f … %+.0f ms (beat = %.0f ms)",
                         sorted.count, sorted[sorted.count / 2], sorted[sorted.count / 10], sorted[sorted.count * 9 / 10], plan.periodA * 1000))
        }
        print(String(format: "handed over to: %@ | ended callback: %@ | now playing position %.2f s of %.1f | transition active: %@",
                     advanced.joined(separator: ","), ended ? "yes" : "no", engine.currentTime, engine.duration, activity == nil ? "no" : "yes"))
        engine.stop()
        await wait(0.3)
    }

    /// `Metrolist --mixplay "A" "B" ["C"]` drives the real player (muted) with AutoMix on and
    /// logs what the interface would show: analysis, the planned transition, and the hand-over.
    @MainActor
    static func mixPlayTest() async {
        let model = AppModel.shared
        let player = model.player
        let wasOn = model.settings.autoMix
        let volume = player.volume
        model.settings.autoMix = !CommandLine.arguments.contains("--off")
        player.volume = 0
        defer {
            model.settings.autoMix = wasOn
            player.volume = volume
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

        var songs: [Song] = []
        for query in CommandLine.arguments.drop(while: { $0 != "--mixplay" }).dropFirst() where !query.hasPrefix("--") {
            if query.count == 11, !query.contains(" ") {
                songs.append(model.library.song(query) ?? Song(id: query, title: query))
            } else if let song = try? await YTMusic.search(query, filter: .songs).sections.first?.items.compactMap(\.song).first { songs.append(song) }
        }
        guard songs.count >= 2 else { print("need two songs"); return }
        model.settings.autoplay = false
        if CommandLine.arguments.contains("--autoqueue") {
            // Treat everything after the first song as Autoplay's choice, to watch it re-ordered.
            player.play([songs[0]])
            player.appendAutoQueued(Array(songs.dropFirst()))
            var shown = ""
            for _ in 0 ..< 600 {
                await wait(0.5)
                let known = player.queue.filter { player.analyses[$0.id] != nil }.count
                let line = "analysed \(known) of \(player.queue.count) | queue: " + player.queue.map(\.title).joined(separator: " → ")
                if line != shown { print(String(format: "  [%5.1f s] ", player.position) + line); shown = line }
                if known == player.queue.count { break }
            }
            await wait(2)
            for (one, two) in zip(player.queue, player.queue.dropFirst()) {
                guard let a = player.analyses[one.id], let b = player.analyses[two.id] else { continue }
                let fit = MixSequencer.fit(a, b, sameArtist: !MixSequencer.names(of: one).isDisjoint(with: MixSequencer.names(of: two)))
                print(String(format: "   %@ → %@: %@ | tempo %.2f, key %.2f, fit %.2f", one.title, two.title, fit.note, fit.tempo, fit.key, fit.total))
            }
            print("final order: " + player.queue.map { song in
                player.analyses[song.id].map { "\(song.title) [\(String(format: "%.0f", $0.bpm)) BPM \($0.camelot)]" } ?? song.title
            }.joined(separator: " → "))
            player.pause()
            return
        }
        player.play(songs)
        print("queue:", songs.map(\.title).joined(separator: " → "), "| AutoMix:", model.settings.autoMix ? "on" : "off")

        var lastLine = ""
        func log(_ line: String) {
            if line != lastLine { print(String(format: "  [%6.1f s] ", player.position) + line); lastLine = line }
        }
        // Wait for the first track to be playing and (with AutoMix) for the pair to be analysed.
        for _ in 0 ..< 400 {
            await wait(0.1)
            if model.settings.autoMix ? (player.nextMixPlan != nil || (!player.isPreparingMix && player.position > 8)) : player.position > 2 { break }
            log(player.isPreparingMix ? "analysing…" : "waiting")
        }
        if CommandLine.arguments.contains("--samples") {
            // Give the sample lookup time to answer and the pair to be planned again.
            for _ in 0 ..< 400 where player.nextMixPlan?.known == nil { await wait(0.1) }
        }
        if let plan = player.nextMixPlan {
            print("planned: \(plan.summary) — \(plan.detail); \(plan.note); leaves at \(String(format: "%.1f", plan.outStart)) s, overlap \(String(format: "%.1f", plan.duration(glide: true))) s")
            player.seek(to: max(0, plan.outStart - 6))
        } else {
            print("no mix plan → gapless")
            player.seek(to: max(0, player.duration - 6))
        }
        let deadline = Date().addingTimeInterval(40)
        var handedOverAt: Date?
        while Date() < deadline {
            await wait(0.1)
            let title = player.currentSong?.title ?? "-"
            if let activity = player.mixActivity {
                log("MIXING \(Int(activity.progress * 10) * 10)% | showing: \(title)")
            } else {
                log("playing: \(title) | index \(player.currentIndex ?? -1) | status \(player.status)")
            }
            if player.currentIndex == 1, handedOverAt == nil { handedOverAt = Date() }
            if let handedOverAt, Date().timeIntervalSince(handedOverAt) > 12, player.mixActivity == nil { break }
        }
        print(String(format: "result: index %d, '%@' at %.1f s of %.1f, playing %@, lyrics %@, analyses cached %d",
                     player.currentIndex ?? -1, player.currentSong?.title ?? "-", player.position, player.duration,
                     player.isPlaying ? "yes" : "no", player.lyrics == nil ? "none yet" : "loaded", player.analyses.count))
        player.pause()
        await wait(0.3)
    }

    private static func step(_ name: String, _ body: () async throws -> Void) async {
        print("== \(name)")
        do { try await body() } catch { print("  FAILED: \(error.localizedDescription) (\(error))") }
    }
}
