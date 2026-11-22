import Foundation

/// Another recording that a song samples, or that samples it.
struct SampleRef: Codable, Hashable, Sendable {
    /// MusicBrainz recording id, or "genius:" and a Genius song id.
    var id: String
    var title: String
    /// Who it is by, where the source says (Genius does; MusicBrainz needs a further request).
    var artist: String?
    /// The material was replayed rather than lifted from the record.
    var interpolation: Bool?
}

/// What the database says about one song. Kept per video id in `samples.json`.
struct SampleInfo: Codable, Sendable {
    /// Recordings this song takes material from.
    var samples: [SampleRef] = []
    /// Recordings that take material from this song.
    var sampledBy: [SampleRef] = []
    var fetched = Date()
    /// Which databases answered ("musicbrainz", "genius").
    var sources: [String]?
}

/// A documented sampling relationship between the playing song and the next one.
struct SampleRelation: Equatable, Sendable {
    enum Link: Equatable, Sendable {
        /// The next song samples the playing one.
        case nextSamplesCurrent
        /// The playing song samples the next one.
        case currentSamplesNext
        /// Both sample the same third recording.
        case sharedSource(String)
    }

    var link: Link
    /// One of the two songs samples the other (as opposed to both sampling a third).
    var isDirect: Bool {
        if case .sharedSource = link { return false }
        return true
    }
    /// Shown with the transition, e.g. "Stronger samples Harder, Better, Faster, Stronger".
    var text: String
    /// The database that records it.
    var source = "MusicBrainz"
}

/// Looks up who sampled whom, so AutoMix knows when two songs really do share material
/// instead of inferring it from the audio alone.
///
/// WhoSampled, the obvious source, has no API and turns automated requests away, so two
/// others are used. MusicBrainz's "samples material" relationships are open data with a
/// public API and need no account, but are patchy (Stronger → Harder, Better, Faster,
/// Stronger is there; Good Life → P.Y.T. is not). Genius records samples and interpolations
/// far more completely, through its official API, which needs a free access token: it is
/// asked as well when the user has entered one in Settings.
///
/// Both record *that* one song samples another, not where or how; the audio analysis still
/// finds the passage, speed and pitch, but can trust weaker evidence once the link is known.
///
/// Lookups run in the background, at most one request a second as MusicBrainz asks, and each
/// song is asked about once: nothing here delays planning a transition.
actor SampleDatabase {
    static let shared = SampleDatabase()

    static let file = AppPaths.root.appendingPathComponent("samples.json")
    private static let refreshAfter: TimeInterval = 60 * 24 * 3600

    private var cache: [String: SampleInfo]
    private var artists: [String: [String]] = [:]
    private var inFlight: [String: Task<SampleInfo?, Never>] = [:]
    private var lastRequest = Date.distantPast
    nonisolated(unsafe) static var debug = false

    /// The user's Genius API access token, kept in a file only they can read.
    static let tokenFile = AppPaths.root.appendingPathComponent("genius-token")
    static var geniusToken: String? {
        get {
            let text = (try? String(contentsOf: tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        set {
            let text = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                try? FileManager.default.removeItem(at: tokenFile)
            } else {
                try? text.write(to: tokenFile, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
            }
        }
    }

    init() {
        cache = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([String: SampleInfo].self, from: $0) } ?? [:]
    }

    // MARK: - Names

    /// A title as it is compared: no "(feat. …)", "- Remastered", punctuation, case or accents.
    static func normalized(_ text: String) -> String {
        var text = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        // "P.Y.T. (Pretty Young Thing)" keeps its subtitle; version notes go.
        let notes = "feat|ft|with|remaster|radio|edit|version|mix|live|mono|stereo|explicit|clean|album|single|bonus|deluxe|from|official|audio|video|lyric"
        for pattern in ["[\\(\\[][^\\)\\]]*\\b(\(notes))[^\\)\\]]*[\\)\\]]", "\\s[-–—]\\s.*\\b(\(notes)).*$", "\\s(feat|ft)\\.?\\s.*$"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "&", with: " and ")
        text = text.replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
        return text.split(separator: " ").joined(separator: " ")
    }

    private static func sameTitle(_ a: String, _ b: String) -> Bool {
        let (a, b) = (normalized(a), normalized(b))
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        // "pyt" against "pyt pretty young thing".
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        return short.count >= 3 && long.hasPrefix(short + " ")
    }

    private static func sameArtist(_ names: [String], _ song: Song) -> Bool {
        let wanted = song.artists.map { normalized($0.name) }.filter { !$0.isEmpty }
        let found = names.map(normalized).filter { !$0.isEmpty }
        return wanted.contains { name in found.contains { $0 == name || $0.contains(name) || name.contains($0) } }
    }

    // MARK: - Requests

    private func get(_ path: String, genius token: String? = nil) async -> [String: Any]? {
        guard let url = URL(string: (token == nil ? "https://musicbrainz.org/ws/2/" : "https://api.genius.com/") + path) else { return nil }
        for attempt in 0 ..< 2 {
            // MusicBrainz asks for no more than one request a second.
            let wait = (token == nil ? 1.1 : 0.3) - Date().timeIntervalSince(lastRequest)
            if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
            lastRequest = Date()
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue(token == nil ? AppIdentity.musicBrainzUserAgent : AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { continue }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return json }
            if Self.debug { print("   \(token == nil ? "musicbrainz" : "genius") \(status) for \(path.prefix(70))") }
            // Asked to slow down: wait once, then give up until another time.
            guard status == 503 || status == 429, attempt == 0 else { return nil }
            try? await Task.sleep(for: .seconds(3))
        }
        return nil
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: " ").replacingOccurrences(of: "\"", with: " ") + "\""
    }

    /// What MusicBrainz records about a song, from the cache when it has been asked before.
    /// Nil when it could not be reached (which is not remembered).
    func info(for song: Song) async -> SampleInfo? {
        let token = Self.geniusToken
        if let known = cache[song.id], Date().timeIntervalSince(known.fetched) < Self.refreshAfter,
           token == nil || known.sources?.contains("genius") == true { return known }
        if let running = inFlight[song.id] { return await running.value }
        let task = Task { () -> SampleInfo? in
            let open = await fetch(song)
            let genius = token == nil ? nil : await fetchGenius(song, token: token!)
            guard open != nil || genius != nil else { return nil }
            var merged = open ?? SampleInfo()
            merged.sources = (open != nil ? ["musicbrainz"] : []) + (genius != nil ? ["genius"] : [])
            // Genius names the artist, so its entry is the one kept when both list a song.
            for ref in genius?.samples ?? [] {
                merged.samples.removeAll { Self.sameTitle($0.title, ref.title) }
                merged.samples.append(ref)
            }
            for ref in genius?.sampledBy ?? [] {
                merged.sampledBy.removeAll { Self.sameTitle($0.title, ref.title) }
                merged.sampledBy.append(ref)
            }
            return merged
        }
        inFlight[song.id] = task
        let result = await task.value
        inFlight[song.id] = nil
        if let result {
            cache[song.id] = result
            save()
        }
        return result ?? cache[song.id]
    }

    private func fetch(_ song: Song) async -> SampleInfo? {
        guard let artist = song.artists.first?.name, !song.title.isEmpty else { return SampleInfo() }
        // Search on the bare title: version notes in brackets are rarely part of the entry's name.
        let bare = song.title.replacingOccurrences(of: "\\s*[\\(\\[].*$", with: "", options: .regularExpression)
        let title = bare.count >= 2 ? bare : song.title
        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "query", value: "recording:\(Self.quoted(title)) AND artist:\(Self.quoted(artist))"),
            URLQueryItem(name: "fmt", value: "json"), URLQueryItem(name: "limit", value: "15"),
        ]
        guard let search = await get("recording?" + (query.percentEncodedQuery ?? "")),
              let recordings = search["recordings"] as? [[String: Any]]
        else { return nil }
        // The relationships sit on whichever entry an editor chose, usually the studio one.
        let matching = recordings.filter { Self.sameTitle($0["title"] as? String ?? "", song.title) }
        let studio = matching.filter { !(($0["disambiguation"] as? String ?? "").lowercased().contains("live")) }
        var info = SampleInfo()
        var reached = false
        for recording in (studio + matching.filter { entry in !studio.contains { $0["id"] as? String == entry["id"] as? String } }).prefix(10) {
            guard let id = recording["id"] as? String, let detail = await get("recording/\(id)?inc=recording-rels&fmt=json") else { continue }
            reached = true
            for relation in detail["relations"] as? [[String: Any]] ?? [] where relation["type"] as? String == "samples material" {
                guard let other = relation["recording"] as? [String: Any], let otherId = other["id"] as? String, let otherTitle = other["title"] as? String else { continue }
                let ref = SampleRef(id: otherId, title: otherTitle)
                if relation["direction"] as? String == "backward" {
                    if !info.sampledBy.contains(ref) { info.sampledBy.append(ref) }
                } else if !info.samples.contains(ref) {
                    info.samples.append(ref)
                }
            }
            // Editors put a song's samples on one entry; the rest would only repeat the search.
            if !info.samples.isEmpty || !info.sampledBy.isEmpty { break }
        }
        if Self.debug { print("   musicbrainz: \(song.title): \(matching.count) entries, samples \(info.samples.map(\.title)), sampled by \(info.sampledBy.count)") }
        return reached || matching.isEmpty ? info : nil
    }

    /// The same question put to Genius, which also knows about replayed melodies.
    private func fetchGenius(_ song: Song, token: String) async -> SampleInfo? {
        guard let artist = song.artists.first?.name, !song.title.isEmpty else { return SampleInfo() }
        let bare = song.title.replacingOccurrences(of: "\\s*[\\(\\[].*$", with: "", options: .regularExpression)
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "q", value: "\(bare.count >= 2 ? bare : song.title) \(artist)")]
        guard let search = await get("search?" + (query.percentEncodedQuery ?? ""), genius: token),
              let hits = (search["response"] as? [String: Any])?["hits"] as? [[String: Any]]
        else { return nil }
        let results = hits.compactMap { $0["result"] as? [String: Any] }
        guard let match = results.first(where: { Self.sameTitle($0["title"] as? String ?? "", song.title) && Self.sameArtist(Self.geniusArtists($0), song) }),
              let id = match["id"] as? Int
        else {
            if Self.debug { print("   genius: \(song.title): not found among \(results.count) results") }
            return SampleInfo()
        }
        guard let detail = await get("songs/\(id)", genius: token),
              let entry = (detail["response"] as? [String: Any])?["song"] as? [String: Any]
        else { return nil }
        let info = Self.geniusInfo(entry)
        if Self.debug { print("   genius: \(song.title): samples \(info.samples.map(\.title)), sampled by \(info.sampledBy.count)") }
        return info
    }

    /// Reads the sampling relationships out of a Genius song entry.
    static func geniusInfo(_ entry: [String: Any]) -> SampleInfo {
        var info = SampleInfo()
        for relationship in entry["song_relationships"] as? [[String: Any]] ?? [] {
            let kind = relationship["relationship_type"] as? String ?? ""
            guard ["samples", "sampled_in", "interpolates", "interpolated_by"].contains(kind) else { continue }
            for other in relationship["songs"] as? [[String: Any]] ?? [] {
                guard let otherId = other["id"] as? Int, let title = other["title"] as? String else { continue }
                let ref = SampleRef(id: "genius:\(otherId)", title: title, artist: Self.geniusArtists(other).first,
                                    interpolation: kind.hasPrefix("interpolat") ? true : nil)
                if kind == "samples" || kind == "interpolates" { info.samples.append(ref) } else { info.sampledBy.append(ref) }
            }
        }
        return info
    }

    private static func geniusArtists(_ entry: [String: Any]) -> [String] {
        [(entry["primary_artist"] as? [String: Any])?["name"] as? String, entry["artist_names"] as? String].compactMap { $0 }
    }

    /// The artists credited on a recording, to tell "Bam Bam" by Sister Nancy from any other.
    private func credited(_ id: String) async -> [String]? {
        if let known = artists[id] { return known }
        guard let detail = await get("recording/\(id)?inc=artist-credits&fmt=json") else { return nil }
        let names = (detail["artist-credit"] as? [[String: Any]] ?? []).flatMap { credit -> [String] in
            [credit["name"] as? String, (credit["artist"] as? [String: Any])?["name"] as? String].compactMap { $0 }
        }
        artists[id] = names
        return names
    }

    /// Whether `ref` is `song`: the same title and, when it can be checked, the same artist.
    private func refers(_ ref: SampleRef, to song: Song) async -> Bool {
        guard Self.sameTitle(ref.title, song.title) else { return false }
        if let artist = ref.artist { return Self.sameArtist([artist], song) }
        if let names = await credited(ref.id) { return Self.sameArtist(names, song) }
        // Unreachable: a long, distinctive title is taken on trust.
        return Self.normalized(song.title).count >= 12
    }

    /// The documented link between two songs, if there is one. Uses only what is cached when
    /// `cachedOnly` is set, so it can be asked on the way to planning without waiting.
    func relation(current: Song, next: Song, cachedOnly: Bool = false) async -> SampleRelation? {
        let a: SampleInfo?
        let b: SampleInfo?
        if cachedOnly {
            (a, b) = (cache[current.id], cache[next.id])
        } else {
            a = await info(for: current)
            b = await info(for: next)
        }
        func verb(_ ref: SampleRef) -> String { ref.interpolation == true ? "replays part of" : "samples" }
        func source(_ ref: SampleRef) -> String { ref.id.hasPrefix("genius:") ? "Genius" : "MusicBrainz" }
        for ref in b?.samples ?? [] {
            if await refers(ref, to: current) { return SampleRelation(link: .nextSamplesCurrent, text: "\(next.title) \(verb(ref)) \(current.title)", source: source(ref)) }
        }
        for ref in a?.sampledBy ?? [] {
            if await refers(ref, to: next) { return SampleRelation(link: .nextSamplesCurrent, text: "\(next.title) \(verb(ref)) \(current.title)", source: source(ref)) }
        }
        for ref in a?.samples ?? [] {
            if await refers(ref, to: next) { return SampleRelation(link: .currentSamplesNext, text: "\(current.title) \(verb(ref)) \(next.title)", source: source(ref)) }
        }
        for ref in b?.sampledBy ?? [] {
            if await refers(ref, to: current) { return SampleRelation(link: .currentSamplesNext, text: "\(current.title) \(verb(ref)) \(next.title)", source: source(ref)) }
        }
        // Two songs built on the same record.
        for source in a?.samples ?? [] {
            let same = (b?.samples ?? []).contains { other in
                if other.id == source.id { return true }
                guard Self.normalized(other.title) == Self.normalized(source.title) else { return false }
                if let one = other.artist, let two = source.artist { return Self.normalized(one) == Self.normalized(two) }
                return Self.normalized(source.title).count >= 6
            }
            if same {
                let title = source.artist.map { "\(source.title) by \($0)" } ?? source.title
                return SampleRelation(link: .sharedSource(source.title), text: "Both use \(title)", source: source.id.hasPrefix("genius:") ? "Genius" : "MusicBrainz")
            }
        }
        return nil
    }

    private func save() {
        let snapshot = cache
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.file, options: .atomic) }
        }
    }
}
