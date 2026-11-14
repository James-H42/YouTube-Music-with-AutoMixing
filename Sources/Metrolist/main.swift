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
