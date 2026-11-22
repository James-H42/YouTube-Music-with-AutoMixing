import SwiftUI
import AppKit
import AVFoundation
import Foundation

// Test runs (a throwaway METROLIST_HOME, or METROLIST_TEST_KEYCHAIN=1) use a throwaway Keychain
// service, so a debug build never reads the installed app's items and macOS never stops an
// unattended test to ask for the Keychain password.
if Keychain.isTestRun {
    Keychain.service = "Metrolist.test.\(UUID().uuidString)"
}

if CommandLine.arguments.contains("--probe") {
    await Probe.run()
    exit(0)
}

// `--geniusparse song.json`: what the sample lookup reads from a saved Genius song reply.
if let flag = CommandLine.arguments.firstIndex(of: "--geniusparse"), CommandLine.arguments.count > flag + 1 {
    if let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[flag + 1])),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let entry = (json["response"] as? [String: Any])?["song"] as? [String: Any] {
        let info = SampleDatabase.geniusInfo(entry)
        for ref in info.samples { print("uses:", ref.title, "—", ref.artist ?? "?", ref.interpolation == true ? "(replayed)" : "(sampled)") }
        print("used by \(info.sampledBy.count) songs, e.g.", info.sampledBy.prefix(3).map { "\($0.title) — \($0.artist ?? "?")" })
    } else { print("could not read a Genius song from that file") }
    exit(0)
}

// `--rawpost <endpoint> <WEB|WEB_REMIX|MWEB> file '<json body>'`: a raw InnerTube reply, for research.
if let flag = CommandLine.arguments.firstIndex(of: "--rawpost"), CommandLine.arguments.count > flag + 4 {
    let args = Array(CommandLine.arguments[(flag + 1)...])
    let client: YouTubeClient = switch args[1] { case "WEB": .web; case "MWEB": .mweb; default: .webRemix }
    let body = (try? JSONSerialization.jsonObject(with: Data(args[3].utf8))) as? [String: Any] ?? [:]
    do {
        let json = try await InnerTube.shared.post(args[0], client: client, body: body)
        if let raw = json.raw, let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
            try data.write(to: URL(fileURLWithPath: args[2]))
            print("wrote \(data.count) bytes")
        }
    } catch { print("FAILED", error) }
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--rawsearch"), CommandLine.arguments.count > flag + 2 {
    do {
        let json = try await InnerTube.shared.post("search", body: ["query": CommandLine.arguments[flag + 1]])
        if let raw = json.raw, let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 2]))
        }
        for section in try await YTMusic.search(CommandLine.arguments[flag + 1]).sections {
            print("[\(section.title)] \(section.items.count) items")
            for item in section.items { print("    ", item.title, "—", item.subtitle) }
        }
    } catch { print("FAILED", error) }
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--playlist"), CommandLine.arguments.count > flag + 1 {
    let id = CommandLine.arguments[flag + 1]
    do {
        let first = try await YTMusic.playlist(id)
        let all = try await YTMusic.allPlaylistSongs(id)
        print("first page: \(first.songs.count), continuation: \(first.continuation != nil), all: \(all.count), unique: \(Set(all.map(\.id)).count)")
        let multi = all.first { $0.artists.count > 1 }
        print("multi-artist sample:", multi?.title ?? "-", multi?.artists.map { "\($0.name)=\($0.id ?? "nil")" } ?? [])
    } catch { print("FAILED", error) }
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--romanize") {
    var lyrics = Lyrics(provider: "test", isSynced: false, lines: CommandLine.arguments.dropFirst(flag + 1).enumerated().map { LyricLine(id: $0.offset, start: 0, text: $0.element) })
    Romanizer.annotate(&lyrics)
    for line in lyrics.lines { print(line.text, "→", line.romanized ?? "(unchanged)") }
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > flag + 1 {
    do { print("playback ping status:", try await YTMusic.reportPlayback(videoId: CommandLine.arguments[flag + 1])) } catch { print("FAILED", error) }
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--album"), CommandLine.arguments.count > flag + 1 {
    do {
        let results = try await YTMusic.search(CommandLine.arguments[flag + 1], filter: .albums)
        guard case .album(let found)? = results.sections.flatMap(\.items).first else { print("no album"); exit(1) }
        let json = try await InnerTube.shared.post("browse", body: ["browseId": found.id])
        let raw = json.first("musicShelfRenderer")["contents"].array.compactMap { Parser.item($0)?.song }
        let page = try await YTMusic.album(found.id)
        print("album:", page.album.title, "playlist:", page.album.playlistId ?? "-", "artists:", page.album.artists.map { "\($0.name)=\($0.id ?? "nil")" })
        for (index, song) in page.songs.enumerated() {
            let pageSong = index < raw.count ? raw[index] : nil
            print(String(format: "%2d", index + 1), song.id, song.isVideo ? "VIDEO" : "audio", song.duration ?? -1, song.title,
                  "| album-page id:", pageSong?.id ?? "-", pageSong?.isVideo == true ? "VIDEO" : "audio", pageSong?.duration ?? -1,
                  pageSong?.id == song.id ? "" : "  <-- differs")
        }
    } catch { print("FAILED", error) }
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--counterpart"), CommandLine.arguments.count > flag + 4 {
    let args = Array(CommandLine.arguments.dropFirst(flag + 1))
    var song = Song(id: args[0], title: args[1], artists: [ArtistRef(name: args[2])], duration: Int(args[3]), isVideo: true)
    if args.count > 4 { song.album = AlbumRef(name: "", id: args[4]) }
    if let found = await YTMusic.audioCounterpart(for: song) {
        print("→", found.id, found.title, "—", found.artistText, "| album:", found.album?.name ?? "-", "| explicit:", found.explicit, "| video:", found.isVideo, "|", found.duration ?? -1, "s")
    } else { print("→ no audio counterpart found") }
    exit(0)
}

if CommandLine.arguments.contains("--concerttest") {
    await ConcertTest.run()
    exit(0)
}

if CommandLine.arguments.contains("--bitperfecttest") {
    await BitPerfectTest.run()
    exit(0)
}

// `--matchwhy videoId`: each step of finding a music video's audio release, for debugging a
// video that plays as itself in a playlist.
if let flag = CommandLine.arguments.firstIndex(of: "--matchwhy"), CommandLine.arguments.count > flag + 1 {
    let id = CommandLine.arguments[flag + 1]
    let page = try? await YTMusic.queue(videoId: id)
    guard let video = page?.songs.first(where: { $0.id == id }) ?? page?.songs.first else { print("no queue for \(id)"); exit(1) }
    print("video:", video.id, video.videoType ?? "-", "|", video.title, "—", video.artists.map { "\($0.name)=\($0.id ?? "nil")" }, "| album:", video.album.map { "\($0.name)=\($0.id ?? "nil")" } ?? "-", "|", video.duration ?? -1, "s")
    print("queue pairs:", page?.counterparts[id].map { "\($0.id) \($0.title)" } ?? "none")
    for query in YTMusic.audioSearchQueries(for: video) {
        let results = (try? await YTMusic.search(query, filter: .songs).sections.flatMap(\.items).compactMap(\.song)) ?? []
        print("songs search “\(query)”:")
        for song in results.prefix(8) { print("   ", song.id, song.title, "—", song.artistText, "|", song.album?.name ?? "-", "|", song.duration ?? -1, "s") }
    }
    let strict = await YTMusic.audioCounterpart(for: video)
    print("→ strict:", strict.map { "\($0.id) \($0.title) — \($0.artistText) | \($0.album?.name ?? "-") | \($0.duration ?? -1) s" } ?? "none")
    let loose = await YTMusic.audioCounterpart(for: video, strictLength: false)
    print("→ playlist (any length):", loose.map { "\($0.id) \($0.title) — \($0.artistText) | \($0.album?.name ?? "-") | \($0.duration ?? -1) s" } ?? "none")
    let searched = await YTMusic.searchedAudioVersion(for: video, strictLength: false)
    print("→ playlist search only:", searched.map { "\($0.id) \($0.title) — \($0.artistText) | \($0.album?.name ?? "-") | \($0.duration ?? -1) s" } ?? "none")
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--tagtest"), CommandLine.arguments.count > flag + 2 {
    let source = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    let song = Song(id: "4D7u5KF7SP8", title: "Get Lucky (feat. Pharrell Williams and Nile Rodgers)",
                    artists: [ArtistRef(name: "Daft Punk"), ArtistRef(name: "Pharrell Williams")], album: AlbumRef(name: "Random Access Memories"))
    let destination = URL(fileURLWithPath: CommandLine.arguments[flag + 2]).appendingPathComponent(WebMTagger.fileName(for: song, extension: "webm"))
    do {
        let cover = try? Data(contentsOf: URL(string: "https://lh3.googleusercontent.com/placeholder")!)
        try WebMTagger.tag(source: source, destination: destination, song: song, artwork: cover ?? Data(repeating: 0xFF, count: 2048))
        func scan(_ url: URL) -> (packets: Int, last: Double, duration: Double, seek: Double) {
            let demuxer = WebMDemuxer(source: FileByteSource(url: url))
            var packets = 0; var last = 0.0
            while case .packet(let packet) = demuxer.next() { packets += 1; last = Double(packet.timeNs) / 1e9 }
            demuxer.seek(to: 100)
            var seek = -1.0
            if case .packet(let packet) = demuxer.next() { seek = Double(packet.timeNs) / 1e9 }
            return (packets, last, demuxer.durationSeconds ?? 0, seek)
        }
        print("original:", scan(source))
        print("tagged:  ", scan(destination))
        print("wrote", destination.lastPathComponent)
    } catch { print("FAILED", error) }
    exit(0)
}

if CommandLine.arguments.contains("--homepages") {
    var token: String?
    for page in 0 ..< 5 {
        guard let home = try? await YTMusic.home(continuation: token) else { print("page \(page): FAILED"); break }
        print("page \(page): \(home.sections.count) sections, next: \(home.continuation != nil)")
        token = home.continuation
        if token == nil { break }
    }
    exit(0)
}

if CommandLine.arguments.contains("--ciphertest") {
    await Probe.cipherTest()
    exit(0)
}

if CommandLine.arguments.contains("--webprobe") {
    await Probe.webProbe()
    exit(0)
}

if CommandLine.arguments.contains("--potoken") {
    await Probe.poTokenTest()
    exit(0)
}

// `--lyricsprobe videoId`: what every lyrics source returns for a song of the library.
if let flag = CommandLine.arguments.firstIndex(of: "--lyricsprobe"), CommandLine.arguments.count > flag + 1 {
    let id = CommandLine.arguments[flag + 1]
    let song = await MainActor.run { LibraryStore().song(id) } ?? Song(id: id, title: CommandLine.arguments.count > flag + 2 ? CommandLine.arguments[flag + 2] : id)
    let found = await LyricsService.shared.search(for: song, duration: Double(song.duration ?? 0))
    print("\(song.title) — \(song.artistText): \(found.count) results")
    for candidate in found {
        let words = candidate.lyrics.lines.filter { !$0.words.isEmpty }.count
        print(String(format: "  %-14@ %@ %d lines, %d with word timing — %@", candidate.source.title as NSString, candidate.lyrics.isSynced ? "synced" : "plain ", candidate.lyrics.lines.count, words,
                     candidate.lyrics.lines.first(where: { !$0.text.isEmpty })?.text ?? ""))
    }
    exit(0)
}

// `--backup out.zip [--analysis]`, `--restore in.zip`, `--inspect file` and `--importforeign file`
// work on the data folder (METROLIST_HOME) without opening the app.
if let flag = CommandLine.arguments.firstIndex(of: "--backup"), CommandLine.arguments.count > flag + 1 {
    do {
        let count = try LibraryBackup.create(at: URL(fileURLWithPath: CommandLine.arguments[flag + 1]), includeAnalysis: CommandLine.arguments.contains("--analysis"))
        print("backed up \(count) files")
    } catch { print("FAILED:", error.localizedDescription); exit(1) }
    exit(0)
}
if let flag = CommandLine.arguments.firstIndex(of: "--restore"), CommandLine.arguments.count > flag + 1 {
    do {
        let result = try LibraryBackup.restore(from: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        print("restored \(result.files) files and \(result.settings) settings; previous data kept in \(result.replacedCopy?.lastPathComponent ?? "-")")
    } catch { print("REJECTED:", error.localizedDescription); exit(1) }
    exit(0)
}
if let flag = CommandLine.arguments.firstIndex(of: "--inspect"), CommandLine.arguments.count > flag + 1 {
    do {
        let info = try LibraryBackup.inspect(URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        print("Metrolist+ backup, format \(info.manifest.formatVersion), made \(info.manifest.createdAt): \(info.files.count) files")
    } catch { print("REJECTED:", error.localizedDescription); exit(1) }
    exit(0)
}
if let flag = CommandLine.arguments.firstIndex(of: "--importforeign"), CommandLine.arguments.count > flag + 1 {
    do {
        let foreign = try ForeignBackup.read(URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        print("\(foreign.family): \(foreign.songs.count) songs, \(foreign.playlists.count) playlists, \(foreign.plays.count) plays, \(foreign.artists.count) artists, \(foreign.albums.count) albums")
        let summary = await MainActor.run { () -> ImportSummary in
            let library = LibraryStore()
            let summary = library.importForeign(foreign)
            library.saveNow()
            return summary
        }
        print(summary.text)
    } catch { print("REJECTED:", error.localizedDescription); exit(1) }
    exit(0)
}

// `--discordtest`: the Discord activity against a stand-in Discord app.
if CommandLine.arguments.contains("--discordtest") {
    await DiscordTest.run()
}

// `--featuretest`: offline checks of the 2026-11-19 features (needs METROLIST_HOME).
if CommandLine.arguments.contains("--featuretest") {
    await MainActor.run { FeatureTests.run() }
}

// `--rawnext <playlist id> file`: the raw reply of the watch queue for a playlist.
if let flag = CommandLine.arguments.firstIndex(of: "--rawnext"), CommandLine.arguments.count > flag + 2 {
    let json = try await InnerTube.shared.post("next", body: ["playlistId": CommandLine.arguments[flag + 1], "isAudioOnly": true, "enablePersistentPlaylistPanel": true, "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"])
    if let raw = json.raw, let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 2]))
    }
    exit(0)
}

// `--videotest query|videoId…`: resolves the video stream of a music video and plays it
// muted for a few seconds (and after a seek), counting the frames AVFoundation decodes.
if let flag = CommandLine.arguments.firstIndex(of: "--videotest") {
    for argument in CommandLine.arguments.dropFirst(flag + 1) {
        var videoId = argument
        if argument.count != 11 || argument.contains(" ") {
            let found = (try? await YTMusic.search(argument, filter: .videos).sections.flatMap(\.items)) ?? []
            guard let first = found.compactMap({ if case .song(let song) = $0 { song } else { nil } }).first else { print("\(argument): no video found"); continue }
            print("“\(argument)” → \(first.id) \(first.title) (isVideo \(first.isVideo))")
            videoId = first.id
        }
        let started = Date()
        do {
            let source = try await VideoStreamResolver.shared.resolve(videoId: videoId)
            print(String(format: "  via %@ in %.1f s; HLS manifest: %@; AV1 decoding: %@", source.clientId, Date().timeIntervalSince(started),
                         source.manifest == nil ? "no" : "yes", VideoStreamResolver.decodesAV1 ? "yes" : "no"))
            print("  qualities:", source.qualities.map { "\($0)p" }.joined(separator: ", "))
            for rendition in source.renditions.sorted(by: { ($0.quality, $0.bandwidth) > ($1.quality, $1.bandwidth) }) {
                print("    \(rendition.kind.rawValue) \(rendition.width)x\(rendition.height) → \(rendition.quality)p \(rendition.codecs) \(rendition.bandwidth / 1000) kb/s")
            }
            // METROLIST_VIDEOQUALITY=2160 plays that quality (or the nearest below); default Auto.
            let quality = Int(ProcessInfo.processInfo.environment["METROLIST_VIDEOQUALITY"] ?? "") ?? VideoQuality.auto
            guard let stream = source.stream(for: quality) else { print("  nothing to play"); continue }
            print("  playing \(VideoQuality.title(quality)): \(stream.kind.rawValue) \(stream.quality.map { "\($0)p" } ?? "adaptive")")
            let asset = AVURLAsset(url: stream.url, options: [AVURLAssetHTTPUserAgentKey: source.userAgent])
            let item = AVPlayerItem(asset: asset)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            func frames(for seconds: Double) async -> (count: Int, size: String) {
                var count = 0, size = "-"
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    let time = output.itemTime(forHostTime: CACurrentMediaTime())
                    if output.hasNewPixelBuffer(forItemTime: time), let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                        count += 1
                        size = "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))"
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return (count, size)
            }
            let ready = Date()
            player.play()
            let first = await frames(for: 6)
            print(String(format: "  played 6 s: %d frames at %@, position %.1f s, status %d %@", first.count, first.size, player.currentTime().seconds,
                         item.status.rawValue, item.error?.localizedDescription ?? ""))
            await player.seek(to: CMTime(seconds: 60, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            let afterSeek = await frames(for: 3)
            print(String(format: "  after seeking to 1:00: %d frames, position %.1f s (%.1f s in all)", afterSeek.count, player.currentTime().seconds, Date().timeIntervalSince(ready)))
            player.pause()
        } catch {
            print("  failed: \(error)")
        }
    }
    exit(0)
}

// `--videotypes query…`: YouTube Music's video type for the videos a search finds, and for
// every video on the first artist's page (its "Videos" and "Live performances" shelves).
if let flag = CommandLine.arguments.firstIndex(of: "--videotypes") {
    for query in CommandLine.arguments.dropFirst(flag + 1) {
        print("“\(query)”")
        let found = (try? await YTMusic.search(query, filter: .videos).sections.flatMap(\.items)) ?? []
        for case .song(let song) in found.prefix(8) {
            print("  search: \(song.id) \(song.videoType ?? "-") music video: \(song.isMusicVideo) | \(song.title) — \(song.artistText)")
        }
        let artists = (try? await YTMusic.search(query, filter: .artists).sections.flatMap(\.items)) ?? []
        guard let artist = artists.first, let page = try? await YTMusic.artist(artist.id) else { continue }
        for section in page.sections {
            for case .song(let song) in section.items.prefix(6) where song.isVideo {
                print("  [\(section.title)] \(song.id) \(song.videoType ?? "-") | \(song.title)")
            }
        }
    }
    exit(0)
}

// `--albumshot dir "album query"`: the album page at three window widths, as PNGs.
if let flag = CommandLine.arguments.firstIndex(of: "--albumshot"), CommandLine.arguments.count > flag + 2 {
    let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    let albums = (try? await YTMusic.search(CommandLine.arguments[flag + 2], filter: .albums).sections.flatMap(\.items)) ?? []
    let found = albums.compactMap { if case .album(let found) = $0 { found } else { nil } }
    guard let album = found.first(where: { $0.title.caseInsensitiveCompare(CommandLine.arguments[flag + 2]) == .orderedSame }) ?? found.first else { print("no album"); exit(1) }
    print("album:", album.title, album.id)
    for width in [640.0, 980.0, 1500.0] {
        let size = NSSize(width: width, height: 760)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: NavigationStack { AlbumView(browseId: album.id) }.environment(AppModel.shared).frame(width: width, height: 760))
        window.contentView = host
        window.orderBack(nil)
        try? await Task.sleep(for: .seconds(6))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("album-\(Int(width)).png"))
        }
        window.orderOut(nil)
    }
    exit(0)
}

// `--typerefreshtest`: saved videos without a type (as libraries from before it was kept)
// get the right one: an official music video, an upload, an art track, and a removed video
// that must not stop the others.
if CommandLine.arguments.contains("--typerefreshtest") {
    let model = AppModel.shared
    let cases = ["H58vbez_m4E": "MUSIC_VIDEO_TYPE_OMV", "mhmGwTDpPf0": "MUSIC_VIDEO_TYPE_OMV", "fR1c8Qw3wEA": "MUSIC_VIDEO_TYPE_UGC",
                 "GTmbyuTKT_c": "MUSIC_VIDEO_TYPE_ATV", "zzzzzzzzzz0": ""]
    let old = cases.keys.map { Song(id: $0, title: "old \($0)", isVideo: true) }
    model.library.remember(old)
    for song in old { model.library.setVideoTypesForTesting(song.id) }
    model.player.play(old)
    model.player.pause()
    var failures = 0
    print("untyped before:", model.library.untypedVideoIds.filter { cases[$0] != nil }.count)
    let learned = await VideoTypeRefresh.run(library: model.library, player: model.player, pause: .milliseconds(200))
    for (id, wanted) in cases.sorted(by: { $0.key < $1.key }) {
        let song = model.library.song(id)
        let queued = model.player.queue.first { $0.id == id }
        let ok = song?.videoType == wanted && (wanted.isEmpty || queued?.videoType == wanted)
        if !ok { failures += 1 }
        print(ok ? "PASS" : "FAIL", id, "library:", song?.videoType ?? "nil", "queue:", queued?.videoType ?? "nil",
              "music video:", song?.isMusicVideo == true, "video:", song?.isVideo == true)
    }
    let again = await VideoTypeRefresh.run(library: model.library, player: model.player)
    print(again == 0 && model.library.untypedVideoIds.filter { cases[$0] != nil }.isEmpty ? "PASS" : "FAIL", "nothing is asked about twice")
    // A later sighting on a page updates an old entry too.
    model.library.remember([Song(id: "fR1c8Qw3wEA", title: "x", isVideo: true, videoType: "MUSIC_VIDEO_TYPE_OMV")])
    print(model.library.song("fR1c8Qw3wEA")?.videoType == "MUSIC_VIDEO_TYPE_OMV" ? "PASS" : "FAIL", "a page's type replaces a saved one")
    print("learned \(learned);", failures == 0 ? "all type checks passed" : "\(failures) FAILED")
    model.library.saveNow()
    exit(failures == 0 ? 0 : 1)
}

// `--typeprobe id…`: the video types YouTube Music reports for these ids in one request.
if let flag = CommandLine.arguments.firstIndex(of: "--typeprobe") {
    let ids = Array(CommandLine.arguments.dropFirst(flag + 1))
    do {
        let types = try await YTMusic.videoTypes(ids)
        for id in ids { print(id, types[id] ?? "-") }
    } catch { print("failed:", error) }
    exit(0)
}

// `--facetest image…`: where the artist header crops each picture (face detection).
if let flag = CommandLine.arguments.firstIndex(of: "--facetest") {
    for path in CommandLine.arguments.dropFirst(flag + 1) {
        guard let image = NSImage(contentsOfFile: path) else { print("\(path): not an image"); continue }
        let faces = await FillImage.faceCentre(in: image)
        let focus = faces ?? CGPoint(x: 0.5, y: 0.45)
        let frame = FillImage.placement(of: image.size, in: CGSize(width: 1490, height: 400), focus: focus, alignment: .top)
        // The part of the picture the header shows, as fractions of its height.
        let top = -frame.minY / frame.height, bottom = top + 400 / frame.height
        print(String(format: "%@: %dx%d faces at %@ → shows %.2f–%.2f of the height", (path as NSString).lastPathComponent,
                     Int(image.size.width), Int(image.size.height), faces.map { String(format: "(%.2f, %.2f)", $0.x, $0.y) } ?? "none", top, bottom))
    }
    exit(0)
}

// `--amtest artist [album]…`: Apple Music artist picture, animated artist video and
// animated album covers, and whether AVFoundation can play the videos.
if let flag = CommandLine.arguments.firstIndex(of: "--amtest"), CommandLine.arguments.count > flag + 1 {
    let names = Array(CommandLine.arguments.dropFirst(flag + 1))
    let artist = names[0]
    func playable(_ url: URL?) async -> String {
        guard let url else { return "-" }
        let asset = AVURLAsset(url: url)
        let ok = (try? await asset.load(.isPlayable)) ?? false
        let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)).map { "\(Int($0.width))x\(Int($0.height))" } ?? "stream"
        return "\(ok ? "playable" : "NOT PLAYABLE") (\(size)) \(url.absoluteString.prefix(90))…"
    }
    let started = Date()
    let art = await AppleMusicArtwork.shared.artist(named: artist, includeVideo: true)
    print(String(format: "artist “%@” (%.1f s)", artist, Date().timeIntervalSince(started)))
    print("  picture:", art?.image?.absoluteString ?? "none")
    print("  video:  ", await playable(art?.video))
    for album in names.dropFirst() {
        let start = Date()
        let cover = await AppleMusicArtwork.shared.album(title: album, artist: artist)
        print(String(format: "album “%@” (%.1f s) apple id %@", album, Date().timeIntervalSince(start), cover?.appleId ?? "-"))
        print("  square:", await playable(cover?.video))
        print("  tall:  ", await playable(cover?.tallVideo))
    }
    exit(0)
}

// `--qualitytest <video id>…`: every audio format each playback identity is offered, and the one chosen.
if let flag = CommandLine.arguments.firstIndex(of: "--qualitytest"), CommandLine.arguments.count > flag + 1 {
    for id in CommandLine.arguments.dropFirst(flag + 1) where !id.hasPrefix("--") {
        print("video \(id)")
        for entry in await StreamResolver.shared.formatsReport(videoId: id) {
            if let error = entry.error { print("  \(entry.client): \(error)"); continue }
            let list = entry.formats.map { "\($0["itag"].int ?? 0) \(($0["mimeType"].string ?? "").components(separatedBy: ";").first ?? "") \(($0["bitrate"].int ?? 0) / 1000)k\(StreamResolver.audioContent($0).map { " " + $0 } ?? "")\($0["isDrc"].bool == true ? " drc" : "")" }
            let chosen = StreamResolver.select(entry.formats.filter { $0["url"].string != nil || $0["signatureCipher"].string != nil }, quality: .high)
            print("  \(entry.client): \(list.joined(separator: ", "))")
            print("     chosen: \(chosen.map { "\($0["itag"].int ?? 0) at \(($0["bitrate"].int ?? 0) / 1000) kbps" } ?? "none")")
        }
        if let stream = try? await StreamResolver.shared.resolve(videoId: id, quality: .high) {
            print("  played: itag \(stream.itag), \(stream.mimeType.components(separatedBy: ";").first ?? ""), \(stream.bitrate / 1000) kbps via \(stream.clientId)")
        } else { print("  played: could not resolve") }
    }
    exit(0)
}

// `--audioswap <playlist id>`: how many music videos in a playlist get their audio release, and how long that takes.
if let flag = CommandLine.arguments.firstIndex(of: "--audioswap"), CommandLine.arguments.count > flag + 1 {
    let id = CommandLine.arguments[flag + 1]
    let started = Date()
    let page = try await YTMusic.playlist(id)
    let loaded = Date()
    let videos = page.songs.filter(\.isVideo)
    let firstRows = Set(videos.prefix(15).map(\.id))
    var swaps: [String: Song] = [:]
    var answered = Set<String>()
    var firstRowsDone: Date?
    await YTMusic.audioVersions(forPlaylist: id, videos: videos) { found in
        swaps.merge(found.compactMapValues { $0 }) { $1 }
        answered.formUnion(found.keys)
        if firstRowsDone == nil, firstRows.isSubset(of: answered) { firstRowsDone = Date() }
    }
    let done = Date()
    await AudioVersionCache.shared.save()
    print("“\(page.playlist.title)”: \(page.songs.count) songs on the first page, \(videos.count) videos, \(swaps.count) swapped")
    print(String(format: "playlist page %.2f s, first 15 rows answered %.2f s, all audio versions %.2f s", loaded.timeIntervalSince(started), (firstRowsDone ?? done).timeIntervalSince(loaded), done.timeIntervalSince(loaded)))
    if CommandLine.arguments.contains("--why") {
        for video in videos.filter({ swaps[$0.id] == nil }).prefix(6) {
            let results = try? await YTMusic.search("\(video.title) \(video.artists.first?.name ?? "")", filter: .songs)
            print("MISS \(video.title) — \(video.artistText) \(video.duration ?? -1)s album=\(video.album?.name ?? "-")")
            for candidate in (results?.sections.flatMap(\.items).compactMap(\.song) ?? []).prefix(4) {
                print("     \(candidate.title) — \(candidate.artistText) \(candidate.duration ?? -1)s \(candidate.isVideo ? "VIDEO" : "")")
            }
        }
    }
    for video in videos.prefix(12) {
        print("  \(video.title) — \(video.artistText) [\(video.id)] → \(swaps[video.id].map { "\($0.title) — \($0.artistText) [\($0.id)]" } ?? "no audio version")")
    }
    exit(0)
}

// `--importplaylist <address or file> [--limit n]`: reads a playlist and matches its tracks on YouTube Music.
if let flag = CommandLine.arguments.firstIndex(of: "--importplaylist"), CommandLine.arguments.count > flag + 1 {
    let source = CommandLine.arguments[flag + 1]
    let limit = CommandLine.arguments.firstIndex(of: "--limit").flatMap { Int(CommandLine.arguments[$0 + 1]) } ?? 8
    do {
        let playlist = source.hasPrefix("https://") ? try await PlaylistImporter.load(address: source) : try PlaylistImporter.load(file: URL(fileURLWithPath: source))
        print("“\(playlist.name)”: \(playlist.tracks.count) tracks read")
        let sample = Array(playlist.tracks.prefix(limit))
        let matches = await TrackMatcher.matchAll(sample) { _ in }
        for match in matches {
            print(String(format: "  %-9@ %@ — %@ (%@ s) → %@", "\(match.kind)" as NSString, match.track.title, match.track.artist, match.track.duration.map(String.init) ?? "?",
                         match.chosen.map { "\($0.title) — \($0.artistText) [\($0.id)] \($0.duration.map(String.init) ?? "?") s\($0.isVideo ? " VIDEO" : "")" } ?? "none"))
        }
    } catch { print("FAILED:", error.localizedDescription); exit(1) }
    exit(0)
}

// `--outputs`: the outputs Core Audio lists. `--outputtest`: plays silence through each in turn
// and checks that the engine really moves to it.
if CommandLine.arguments.contains("--outputs") {
    let devices = OutputDevices.listOutputs()
    let current = OutputDevices.defaultOutput()
    for device in devices { print("\(device.id == current ? "*" : " ") \(device.name) [\(device.uid)] transport \(String(format: "%08x", device.transport))\(device.isAirPlay ? " AirPlay" : "")") }
    print("\(devices.count) outputs; * is the system default")
    exit(0)
}
if CommandLine.arguments.contains("--chaintest") {
    await OutputTest.chain()
    exit(0)
}
if CommandLine.arguments.contains("--outputtest") {
    await OutputTest.run()
    exit(0)
}

// `--dcserve seconds`: listens as Device Connect would, without touching the saved setting.
if let flag = CommandLine.arguments.firstIndex(of: "--dcserve") {
    let seconds = CommandLine.arguments.count > flag + 1 ? Double(CommandLine.arguments[flag + 1]) ?? 30 : 30
    await MainActor.run {
        NSApplication.shared.setActivationPolicy(.accessory)
        DeviceConnect.shared.serveForTesting()
    }
    try? await Task.sleep(for: .seconds(2))
    let state = await MainActor.run { (DeviceConnect.shared.listening, DeviceConnect.shared.port, DeviceConnect.shared.deviceId) }
    print("listening: \(state.0) port: \(state.1.map(String.init) ?? "-") id: \(state.2)")
    fflush(stdout)
    try? await Task.sleep(for: .seconds(seconds))
    await MainActor.run { DeviceConnect.shared.shutdown() }
    print("stopped")
    exit(0)
}

if CommandLine.arguments.contains("--playnexttest") {
    await PlayNextTest.run()
    exit(0)
}
if CommandLine.arguments.contains("--exportifytest") {
    await ExportifyTest.run()
    exit(0)
}
// `--radiotest`: Start Radio, Autoplay, queue priority and mixing order, live (needs METROLIST_HOME).
if CommandLine.arguments.contains("--radiotest") {
    await RadioTest.run()
    exit(0)
}
if let flag = CommandLine.arguments.firstIndex(of: "--videosynctest") {
    let query = CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : "Daft Punk Get Lucky official video"
    await VideoSyncTest.run(query: query)
}
if let flag = CommandLine.arguments.firstIndex(of: "--videoplayertest") {
    let query = CommandLine.arguments.count > flag + 1 ? CommandLine.arguments[flag + 1] : "Billie Eilish CHIHIRO official music video"
    await VideoPlayerTest.run(query: query)
}
if CommandLine.arguments.contains("--videomixtest") {
    await VideoMixTest.run()
    exit(0)
}
if CommandLine.arguments.contains("--sqtest") {
    await SQTest.run()
    exit(0)
}
if CommandLine.arguments.contains("--sqnettest") {
    await SQTest.network()
    exit(0)
}
// `--sqjoin address port`: joins a shared queue from this process and reports what happens.
if let flag = CommandLine.arguments.firstIndex(of: "--sqjoin"), CommandLine.arguments.count > flag + 2 {
    let address = CommandLine.arguments[flag + 1], port = UInt16(CommandLine.arguments[flag + 2]) ?? 0
    await MainActor.run {
        Keychain.service = "Metrolist.sqjoin.\(UUID().uuidString)"
        SharedQueueClient.shared.log = { print("  session:", $0) }
        SharedQueueClient.shared.join(address: address, port: port)
    }
    for _ in 0 ..< 16 {
        try? await Task.sleep(for: .milliseconds(500))
        print(await MainActor.run { "\(SharedQueueClient.shared.phase)" })
    }
    exit(0)
}
if CommandLine.arguments.contains("--sqmixtest") {
    await SQTest.mixTest()
    exit(0)
}

if CommandLine.arguments.contains("--dctest") {
    await DCTest.run()
    exit(0)
}

if CommandLine.arguments.contains("--blocktest") {
    await BlockTest.run()
    exit(0)
}

if CommandLine.arguments.contains("--scrobbletest") {
    await ScrobbleTest.run()
    exit(0)
}

if CommandLine.arguments.contains("--soundtest") {
    SoundTest.run()
    exit(0)
}

if CommandLine.arguments.contains("--mixplan") {
    await Probe.mixPlanTest()
    exit(0)
}

if CommandLine.arguments.contains("--mixtest") {
    await Probe.mixTest()
    exit(0)
}

if CommandLine.arguments.contains("--mixplay") {
    await Probe.mixPlayTest()
    exit(0)
}

if CommandLine.arguments.contains("--dumppcm") {
    await AnalysisAudit.dumpPCM()
    exit(0)
}

if CommandLine.arguments.contains("--beatmodeltest") {
    await AnalysisAudit.beatModelTest()
    exit(0)
}

if CommandLine.arguments.contains("--analysisaudit") {
    await AnalysisAudit.run()
    exit(0)
}

if CommandLine.arguments.contains("--mixaudit") {
    await MixAudit.run()
    exit(0)
}

if CommandLine.arguments.contains("--stemtest") {
    StemTest.run()
    exit(0)
}
if CommandLine.arguments.contains("--vocalresidue") {
    StemTest.vocalResidue()
    exit(0)
}

if CommandLine.arguments.contains("--analyze") {
    await Probe.analyzeTest()
    exit(0)
}

if CommandLine.arguments.contains("--playtest") {
    await Probe.playTest()
    exit(0)
}

if CommandLine.arguments.contains("--snapshot") {
    await Snapshot.run()
    exit(0)
}

// A mistyped diagnostic flag should fail loudly rather than open the app's window.
if let unknown = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("--") }) {
    FileHandle.standardError.write(Data("Unknown option \(unknown)\n".utf8))
    exit(2)
}

MetrolistApp.main()
