import Foundation

/// Fetches lyrics from several providers, preferring word-synced over line-synced over plain,
/// and caches results on disk so they are available offline.
actor LyricsService {
    static let shared = LyricsService()

    private let session: URLSession
    private var memory: [String: Lyrics] = [:]
    private var missing: Set<String> = []

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        session = URLSession(configuration: configuration)
    }

    private func cacheURL(_ videoId: String) -> URL {
        AppPaths.lyrics.appendingPathComponent("\(videoId).json")
    }

    func cached(_ videoId: String) -> Lyrics? {
        if let lyrics = memory[videoId] { return lyrics }
        guard let data = try? Data(contentsOf: cacheURL(videoId)),
              var lyrics = try? JSONDecoder().decode(Lyrics.self, from: data)
        else { return nil }
        if !lyrics.lines.contains(where: { $0.romanized != nil }) { Romanizer.annotate(&lyrics) }
        memory[videoId] = lyrics
        return lyrics
    }

    func store(_ lyrics: Lyrics, for videoId: String) {
        memory[videoId] = lyrics
        if let data = try? JSONEncoder().encode(lyrics) {
            try? data.write(to: cacheURL(videoId), options: .atomic)
        }
    }

    func setOffset(_ offset: Double, for videoId: String) {
        guard var lyrics = cached(videoId) else { return }
        lyrics.offset = offset
        store(lyrics, for: videoId)
    }

    func fetch(for song: Song, duration: Double, forceRefresh: Bool = false) async -> Lyrics? {
        if !forceRefresh {
            if let cached = cached(song.id) { return cached }
            if missing.contains(song.id) { return nil }
        }

        let title = song.title
        let artist = song.artists.first?.name ?? ""
        let album = song.album?.name
        let seconds = Int(duration.rounded())

        var best: Lyrics?
        func consider(_ candidate: Lyrics?) -> Bool {
            guard let candidate, !candidate.lines.isEmpty else { return false }
            let rank: (Lyrics) -> Int = { $0.lines.contains { !$0.words.isEmpty } ? 2 : ($0.isSynced ? 1 : 0) }
            if best == nil || rank(candidate) > rank(best!) { best = candidate }
            return rank(candidate) == 2
        }

        // Decorations such as "(feat. X)" or "(Remastered)" often prevent an exact match.
        let simple = Self.simplified(title)
        let titles = simple == title || simple.isEmpty ? [title] : [title, simple]

        search: do {
            for candidate in titles {
                if consider(await betterLyrics(title: candidate, artist: artist, album: album, duration: seconds)) { break search }
            }
            if best?.isSynced == true { break search }
            for candidate in titles {
                if consider(await lrcLib(title: candidate, artist: artist, album: album, duration: seconds)) { break search }
                if best?.isSynced == true { break search }
            }
            if best == nil { _ = consider(await youTube(videoId: song.id)) }
        }

        if var best {
            Romanizer.annotate(&best)
            store(best, for: song.id)
            return best
        } else {
            missing.insert(song.id)
        }
        return best
    }

    private static func simplified(_ title: String) -> String {
        var result = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring)\s.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Providers

    private func get(_ base: String, _ items: [String: String?], headers: [String: String] = [:]) async -> Data? {
        var components = URLComponents(string: base)!
        components.queryItems = items.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    private func betterLyrics(title: String, artist: String, album: String?, duration: Int) async -> Lyrics? {
        guard !artist.isEmpty else { return nil }
        let data = await get(
            "https://lyrics-api.boidu.dev/getLyrics",
            ["s": title, "a": artist, "d": duration > 0 ? String(duration) : nil, "al": album],
            headers: ["User-Agent": "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15", "Accept": "application/json"]
        )
        guard let data, let ttml = JSON(data: data)["ttml"].string, !ttml.isEmpty else { return nil }
        let lines = TTMLParser.parse(ttml)
        guard !lines.isEmpty else { return nil }
        return Lyrics(provider: "BetterLyrics", isSynced: true, lines: lines)
    }

    private func lrcLib(title: String, artist: String, album: String?, duration: Int) async -> Lyrics? {
        let headers = ["User-Agent": "Metrolist for macOS (https://github.com/MetrolistGroup/Metrolist)"]
        var record = JSON(nil)
        if duration > 0, let data = await get(
            "https://lrclib.net/api/get",
            ["track_name": title, "artist_name": artist, "album_name": album, "duration": String(duration)],
            headers: headers
        ) {
            record = JSON(data: data)
        }
        if record["syncedLyrics"].string == nil,
           let data = await get("https://lrclib.net/api/search", ["track_name": title, "artist_name": artist], headers: headers) {
            let candidates = JSON(data: data).array.filter { candidate in
                guard duration > 0, let length = candidate["duration"].double else { return true }
                return abs(length - Double(duration)) <= 3
            }
            record = candidates.first { $0["syncedLyrics"].string != nil } ?? (record.exists ? record : candidates.first ?? JSON(nil))
        }
        if let synced = record["syncedLyrics"].string {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty { return Lyrics(provider: "LRCLIB", isSynced: true, lines: lines) }
        }
        if let plain = record["plainLyrics"].string {
            return Self.plain(plain, provider: "LRCLIB")
        }
        return nil
    }

    private func youTube(videoId: String) async -> Lyrics? {
        guard let text = try? await YTMusic.plainLyrics(videoId: videoId) else { return nil }
        return Self.plain(text, provider: "YouTube Music")
    }

    private static func plain(_ text: String, provider: String) -> Lyrics? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated().map { index, line in
            LyricLine(id: index, start: 0, text: String(line))
        }
        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
        return Lyrics(provider: provider, isSynced: false, lines: lines)
    }
}
