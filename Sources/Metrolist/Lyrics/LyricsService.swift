import Foundation

/// Where lyrics can come from.
enum LyricsSource: String, CaseIterable, Identifiable, Codable {
    case betterLyrics, lrcLib, simpMusic, lrcRed, youTube

    var id: String { rawValue }
    var title: String {
        switch self {
        case .betterLyrics: "Better Lyrics"
        case .lrcLib: "LRCLIB"
        case .simpMusic: "SimpMusic"
        case .lrcRed: "lrc.red"
        case .youTube: "YouTube Music"
        }
    }

    /// The order tried by default, following Metrolist 14's priority (word-timed sources
    /// first: BetterLyrics, lrc.red, then LRCLIB; YouTube Music's own lyrics last). SimpMusic,
    /// which Metrolist doesn't rank, comes before YouTube. A saved order is kept as it is.
    /// Lyrics already cached for a song are not fetched again.
    static let defaultOrder: [LyricsSource] = [.betterLyrics, .lrcRed, .lrcLib, .simpMusic, .youTube]
}

/// The listener's choice of lyric sources: which are used, in which order.
enum LyricsPreferences {
    private static let orderKey = "lyricsProviderOrder"
    private static let disabledKey = "lyricsProvidersDisabled"
    static let wordSyncedKey = "lyricsPreferWordSynced"

    static var order: [LyricsSource] {
        get {
            let saved = (UserDefaults.standard.string(forKey: orderKey) ?? "").split(separator: ",").compactMap { LyricsSource(rawValue: String($0)) }
            // Sources added since the order was saved go at the end.
            return saved + LyricsSource.defaultOrder.filter { !saved.contains($0) }
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).joined(separator: ","), forKey: orderKey) }
    }

    static var disabled: Set<LyricsSource> {
        get { Set((UserDefaults.standard.string(forKey: disabledKey) ?? "").split(separator: ",").compactMap { LyricsSource(rawValue: String($0)) }) }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).sorted().joined(separator: ","), forKey: disabledKey) }
    }

    /// Keep asking sources until one has word timing, instead of stopping at line timing.
    static var preferWordSynced: Bool {
        get { UserDefaults.standard.bool(forKey: wordSyncedKey) }
        set { UserDefaults.standard.set(newValue, forKey: wordSyncedKey) }
    }

    static var active: [LyricsSource] { order.filter { !disabled.contains($0) } }
}

/// One result of a search across the sources, for the listener to choose from.
struct LyricsCandidate: Identifiable {
    var id = UUID()
    var source: LyricsSource
    var lyrics: Lyrics

    var isWordSynced: Bool { lyrics.lines.contains { !$0.words.isEmpty } }
}

/// Fetches lyrics from several providers, preferring word-synced over line-synced over plain,
/// and caches results on disk so they are available offline.
actor LyricsService {
    static let shared = LyricsService()

    private let session: URLSession
    private var memory: [String: Lyrics] = [:]
    /// Songs no source had lyrics for, and when that was found out. Asked again after a week.
    private var missing: [String: Date]
    private static let missingLifetime: TimeInterval = 7 * 24 * 3600

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        session = URLSession(configuration: configuration)
        if let data = try? Data(contentsOf: Self.missesURL), let saved = try? JSONDecoder().decode([String: Date].self, from: data) {
            missing = saved.filter { Date().timeIntervalSince($0.value) < Self.missingLifetime }
        } else {
            missing = [:]
        }
    }

    private static var missesURL: URL { AppPaths.lyrics.appendingPathComponent("misses.json") }

    private func saveMisses() {
        if let data = try? JSONEncoder().encode(missing) { try? data.write(to: Self.missesURL, options: .atomic) }
    }

    private func cacheURL(_ videoId: String) -> URL {
        AppPaths.lyrics.appendingPathComponent("\(videoId).json")
    }

    /// The listener's own version of a song's lyrics, which no provider search replaces.
    private func userURL(_ videoId: String) -> URL {
        AppPaths.lyrics.appendingPathComponent("\(videoId).user.json")
    }

    func hasUserCopy(_ videoId: String) -> Bool {
        FileManager.default.fileExists(atPath: userURL(videoId).path)
    }

    /// Saves hand-edited lyrics as the song's "User" lyrics.
    func saveUser(_ lyrics: Lyrics, for videoId: String) {
        var copy = lyrics
        copy.provider = "User"
        copy.userEdited = true
        memory[videoId] = copy
        missing[videoId] = nil
        if let data = try? JSONEncoder().encode(copy) { try? data.write(to: userURL(videoId), options: .atomic) }
    }

    /// Drops the listener's edits, so the provider's lyrics are used again.
    func removeUserCopy(for videoId: String) {
        try? FileManager.default.removeItem(at: userURL(videoId))
        memory[videoId] = nil
    }

    func cached(_ videoId: String) -> Lyrics? {
        if let lyrics = memory[videoId] { return lyrics }
        let file = hasUserCopy(videoId) ? userURL(videoId) : cacheURL(videoId)
        guard let data = try? Data(contentsOf: file),
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
        if hasUserCopy(videoId) { saveUser(lyrics, for: videoId) } else { store(lyrics, for: videoId) }
    }

    func fetch(for song: Song, duration: Double, forceRefresh: Bool = false) async -> Lyrics? {
        // Lyrics the listener edited are never replaced by a search.
        if hasUserCopy(song.id), let own = cached(song.id) { return own }
        if !forceRefresh {
            if let cached = cached(song.id) { return cached }
            if let when = missing[song.id], Date().timeIntervalSince(when) < Self.missingLifetime { return nil }
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

        // Plain lyrics are a last resort: keep asking the other sources for timed ones, but never
        // stop early for plain text. With "prefer word-synced" off, line timing is good enough.
        let wantsWords = LyricsPreferences.preferWordSynced
        search: for source in LyricsPreferences.active {
            if source == .youTube, best != nil { continue }
            for candidate in titles {
                if consider(await lyrics(from: source, song: song, title: candidate, artist: artist, album: album, duration: seconds)) { break search }
                if best?.isSynced == true && !wantsWords { break search }
                // The YouTube Music lyrics have no title to vary.
                if source == .youTube { break }
            }
        }

        if var best {
            Romanizer.annotate(&best)
            store(best, for: song.id)
            return best
        } else {
            missing[song.id] = Date()
            saveMisses()
        }
        return best
    }

    private static func simplified(_ title: String) -> String {
        var result = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring)\s.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Sources

    private func lyrics(from source: LyricsSource, song: Song, title: String, artist: String, album: String?, duration: Int) async -> Lyrics? {
        switch source {
        case .betterLyrics: return await betterLyrics(title: title, artist: artist, album: album, duration: duration)
        case .lrcLib: return await lrcLib(title: title, artist: artist, album: album, duration: duration)
        case .simpMusic: return await simpMusic(videoId: song.id, duration: duration)
        case .lrcRed: return await lrcRed(title: title, artist: artist, album: album, duration: duration)
        case .youTube: return await youTube(videoId: song.id)
        }
    }

    /// Asks every enabled source for lyrics of a song and returns what each has, for the
    /// listener to choose from. Nothing is stored until one is chosen.
    func search(for song: Song, duration: Double) async -> [LyricsCandidate] {
        let title = song.title
        let artist = song.artists.first?.name ?? ""
        let album = song.album?.name
        let seconds = Int(duration.rounded())
        let simple = Self.simplified(title)
        var found: [(Int, LyricsCandidate)] = []
        await withTaskGroup(of: [(Int, LyricsCandidate)].self) { group in
            for (rank, source) in LyricsSource.allCases.enumerated() {
                group.addTask { [self] in
                    var results: [Lyrics] = []
                    if source == .lrcLib {
                        results = await lrcLibResults(title: title, artist: artist, duration: seconds)
                    } else if let one = await lyrics(from: source, song: song, title: title, artist: artist, album: album, duration: seconds) {
                        results = [one]
                    } else if source != .youTube, source != .simpMusic, !simple.isEmpty, simple != title,
                              let two = await lyrics(from: source, song: song, title: simple, artist: artist, album: album, duration: seconds) {
                        results = [two]
                    }
                    return results.filter { !$0.lines.isEmpty }.map { (rank, LyricsCandidate(source: source, lyrics: $0)) }
                }
            }
            for await part in group { found += part }
        }
        // Several LRCLIB records are often the same text; show it once.
        var seen = Set<String>()
        found = found.filter { entry in
            let lines = entry.1.lyrics.lines
            return seen.insert("\(entry.1.source.rawValue)|\(lines.count)|\(lines.first?.text ?? "")|\(lines.last?.text ?? "")|\(lines.first?.start ?? 0)").inserted
        }
        // Word timing first, then line timing, then plain.
        func quality(_ candidate: LyricsCandidate) -> Int { candidate.isWordSynced ? 2 : (candidate.lyrics.isSynced ? 1 : 0) }
        return found.sorted { (quality($0.1), -$0.0) > (quality($1.1), -$1.0) }.map { var candidate = $0.1; Romanizer.annotate(&candidate.lyrics); return candidate }
    }

    private func simpMusic(videoId: String, duration: Int) async -> Lyrics? {
        guard let data = await get("https://api-lyrics.simpmusic.org/v1/\(videoId)", [:], headers: ["User-Agent": "SimpMusicLyrics/1.0", "Accept": "application/json"]) else { return nil }
        let root = JSON(data: data)
        guard root["type"].string == "success" else { return nil }
        let tracks = root["data"].array
        guard !tracks.isEmpty else { return nil }
        let close = tracks.filter { duration <= 0 || abs((($0["durationSeconds"].double) ?? 0) - Double(duration)) <= 10 }
        let pool = close.isEmpty ? tracks : close
        let best = duration > 0
            ? pool.min { abs(($0["durationSeconds"].double ?? 0) - Double(duration)) < abs(($1["durationSeconds"].double ?? 0) - Double(duration)) }
            : pool.first
        guard let best, let raw = [best["richSyncLyrics"].string, best["syncedLyrics"].string].compactMap({ $0 }).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return nil }
        // Some uploads carry a credit line for whoever timed them.
        let cleaned = raw.split(whereSeparator: \.isNewline).filter { !$0.lowercased().hasSuffix("synced by noob.exe") }.joined(separator: "\n")
        let lines = LRCParser.parse(cleaned)
        return lines.isEmpty ? nil : Lyrics(provider: "SimpMusic", isSynced: true, lines: lines)
    }

    private func lrcRed(title: String, artist: String, album: String?, duration: Int) async -> Lyrics? {
        let query = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let data = await get("https://lrc.red/api/v1", ["q": query], headers: ["Accept": "application/json"]) else { return nil }
        let results = JSON(data: data)["results"].array
        let match = results.filter { candidate in
            // The same rules Metrolist uses: the length within 2 s, and an artist that overlaps.
            if duration > 0, let length = candidate["duration"].double, length > 0, abs(length - Double(duration)) > 2 { return false }
            let wanted = Self.words(artist), found = Self.words(candidate["artist_name"].string ?? "")
            return wanted.isEmpty || found.isEmpty || !wanted.isDisjoint(with: found)
        }.max { score($0, title: title) < score($1, title: title) }
        guard let match, var path = match["lyricsUrl"].string, !path.isEmpty else { return nil }
        if path.hasPrefix("/") { path = "https://lrc.red" + path }
        // Only lrc.red's own address is followed, and only over HTTPS.
        guard let url = URL(string: path), url.scheme == "https", url.host == "lrc.red",
              let ttml = await get(url.absoluteString, [:]), ttml.count < 1_048_576,
              let text = String(data: ttml, encoding: .utf8)
        else { return nil }
        let lines = TTMLParser.parse(text)
        return lines.isEmpty ? nil : Lyrics(provider: "lrc.red", isSynced: true, lines: lines)
    }

    private func score(_ candidate: JSON, title: String) -> Int {
        let wanted = Self.words(Self.simplified(title)), found = Self.words(Self.simplified(candidate["track_name"].string ?? ""))
        if wanted == found { return 3 }
        if wanted.isSubset(of: found) || found.isSubset(of: wanted) { return 1 }
        return 0
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private func lrcLibResults(title: String, artist: String, duration: Int) async -> [Lyrics] {
        let headers = ["User-Agent": AppIdentity.userAgent]
        guard let data = await get("https://lrclib.net/api/search", ["track_name": title, "artist_name": artist], headers: headers) else { return [] }
        return JSON(data: data).array.prefix(6).compactMap { record -> Lyrics? in
            if duration > 0, let length = record["duration"].double, abs(length - Double(duration)) > 5 { return nil }
            if let synced = record["syncedLyrics"].string {
                let lines = LRCParser.parse(synced)
                if !lines.isEmpty { return Lyrics(provider: "LRCLIB", isSynced: true, lines: lines) }
            }
            return record["plainLyrics"].string.flatMap { Self.plain($0, provider: "LRCLIB") }
        }
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
        return Lyrics(provider: "Better Lyrics", isSynced: true, lines: lines)
    }

    private func lrcLib(title: String, artist: String, album: String?, duration: Int) async -> Lyrics? {
        let headers = ["User-Agent": AppIdentity.userAgent]
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
