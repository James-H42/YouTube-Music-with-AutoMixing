import AppKit
import Foundation

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
        print("album:", page.album.title, "playlist:", page.album.playlistId ?? "-")
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
        print("Metrolist backup, format \(info.manifest.formatVersion), made \(info.manifest.createdAt): \(info.files.count) files")
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
