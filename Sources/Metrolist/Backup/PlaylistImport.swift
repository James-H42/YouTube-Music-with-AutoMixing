import Foundation

/// One track of a playlist from another service, before it is matched to YouTube Music.
struct ImportedTrack: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var artist: String
    var album: String?
    /// Seconds.
    var duration: Int?
    /// The exact YouTube video, when the file names one (a "YouTube Video ID" or link column).
    var videoId: String?
}

struct ImportedPlaylist {
    var name: String
    var tracks: [ImportedTrack]
}

enum PlaylistImportError: LocalizedError {
    case unsupported(String), unreadable, empty, tooLarge, privatePlaylist

    var errorDescription: String? {
        switch self {
        case .unsupported(let service): "\(service) playlists can't be read without signing in to \(service). Export the playlist to a CSV file (a tool such as Exportify or TuneMyMusic can) and choose that file instead."
        case .unreadable: "That address couldn't be read as a public playlist."
        case .empty: "No tracks were found."
        case .privatePlaylist: "Spotify only shows this playlist to its members, so it can't be read from its address. Private and collaborative playlists have to be exported instead: use Sign In to Spotify below, which opens Exportify here, and press Export next to the playlist."
        case .tooLarge: "That playlist is too large to import in one go."
        }
    }
}

/// Reads playlists from other services. Public Spotify, Apple Music and Deezer playlist
/// addresses are fetched over HTTPS (only from those services' own hosts); anything else
/// comes from a CSV or text file. Responses are size-limited and read as data only.
enum PlaylistImporter {
    static let maxTracks = 1_000
    static let maxBytes = 8 * 1024 * 1024
    private static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    nonisolated(unsafe) static var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private static func fetch(_ url: URL, allowedHosts: [String]) async throws -> Data {
        guard url.scheme == "https", let host = url.host?.lowercased(), allowedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { throw PlaylistImportError.unreadable }
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= maxBytes else { throw PlaylistImportError.unreadable }
        return data
    }

    /// Reads a playlist from an address.
    static func load(address: String) async throws -> ImportedPlaylist {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased() else { throw PlaylistImportError.unreadable }
        let result: ImportedPlaylist
        if host.hasSuffix("spotify.com") || host == "spotify.link" {
            result = try await spotify(url)
        } else if host.hasSuffix("music.apple.com") {
            result = try await appleMusic(url)
        } else if host.hasSuffix("deezer.com") || host == "deezer.page.link" {
            result = try await deezer(url)
        } else if host.hasSuffix("tidal.com") {
            throw PlaylistImportError.unsupported("Tidal")
        } else if host.contains("amazon.") {
            throw PlaylistImportError.unsupported("Amazon Music")
        } else {
            throw PlaylistImportError.unreadable
        }
        guard !result.tracks.isEmpty else { throw PlaylistImportError.empty }
        return ImportedPlaylist(name: result.name, tracks: Array(result.tracks.prefix(maxTracks)))
    }

    // MARK: Spotify

    private static func spotify(_ url: URL) async throws -> ImportedPlaylist {
        // Public playlists are readable through the embeddable player, which needs no sign-in.
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "playlist"), index + 1 < parts.count,
              parts[index + 1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { throw PlaylistImportError.unreadable }
        let embed = URL(string: "https://open.spotify.com/embed/playlist/\(parts[index + 1])")!
        let html = String(decoding: try await fetch(embed, allowedHosts: ["open.spotify.com"]), as: UTF8.self)
        guard let json = scriptJSON(in: html, marker: #"<script id="__NEXT_DATA__" type="application/json""#) else { throw PlaylistImportError.unreadable }
        let page = JSON(json)["props"]["pageProps"]
        // Private and collaborative playlists answer "page not found" to anyone not signed in.
        if page["status"].int == 404 || page["state"]["data"]["entity"]["trackList"].array.isEmpty && page["title"].string == "Page not found" {
            throw PlaylistImportError.privatePlaylist
        }
        let entity = page["state"]["data"]["entity"]
        let tracks = entity["trackList"].array.compactMap { item -> ImportedTrack? in
            guard let title = item["title"].string, !title.isEmpty else { return nil }
            let artist = (item["subtitle"].string ?? "").replacingOccurrences(of: "\u{00A0}", with: " ")
            return ImportedTrack(title: title, artist: artist.components(separatedBy: ", ").first ?? artist, album: nil, duration: item["duration"].double.map { Int($0 / 1000) })
        }
        return ImportedPlaylist(name: entity["name"].string ?? entity["title"].string ?? "Spotify playlist", tracks: tracks)
    }

    // MARK: Apple Music

    private static func appleMusic(_ url: URL) async throws -> ImportedPlaylist {
        guard url.pathComponents.contains("playlist") else { throw PlaylistImportError.unreadable }
        let html = String(decoding: try await fetch(url, allowedHosts: ["music.apple.com"]), as: UTF8.self)
        guard let json = scriptJSON(in: html, marker: #"id="serialized-server-data""#) else { throw PlaylistImportError.unreadable }
        var tracks: [ImportedTrack] = []
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                if let title = object["title"] as? String, let artist = object["artistName"] as? String, let duration = object["duration"] as? Double {
                    tracks.append(ImportedTrack(title: title, artist: artist, album: object["tertiaryLinks"] as? String, duration: Int(duration / 1000)))
                } else {
                    for child in object.values { walk(child) }
                }
            } else if let list = value as? [Any] {
                for child in list { walk(child) }
            }
        }
        walk(json)
        var name = "Apple Music playlist"
        if let range = html.range(of: #"<meta property="og:title" content=""#), let end = html[range.upperBound...].firstIndex(of: "\"") {
            name = String(html[range.upperBound ..< end]).replacingOccurrences(of: " on Apple Music", with: "")
        }
        // The page lists each song once; guard against the same list appearing twice.
        var seen = Set<String>()
        tracks = tracks.filter { seen.insert($0.title + "|" + $0.artist).inserted }
        return ImportedPlaylist(name: name, tracks: tracks)
    }

    // MARK: Deezer

    private static func deezer(_ url: URL) async throws -> ImportedPlaylist {
        var id = url.pathComponents.last(where: { $0.allSatisfy(\.isNumber) && !$0.isEmpty })
        if id == nil, url.host?.lowercased() != "api.deezer.com" { id = nil }
        guard let id else { throw PlaylistImportError.unreadable }
        let info = JSON(data: try await fetch(URL(string: "https://api.deezer.com/playlist/\(id)")!, allowedHosts: ["api.deezer.com"]))
        var tracks: [ImportedTrack] = []
        var next: URL? = URL(string: "https://api.deezer.com/playlist/\(id)/tracks?limit=100")
        while let page = next, tracks.count < maxTracks {
            let json = JSON(data: try await fetch(page, allowedHosts: ["api.deezer.com"]))
            for item in json["data"].array {
                guard let title = item["title"].string else { continue }
                tracks.append(ImportedTrack(title: title, artist: item["artist"]["name"].string ?? "", album: item["album"]["title"].string, duration: item["duration"].int))
            }
            next = json["next"].string.flatMap(URL.init(string:))
        }
        return ImportedPlaylist(name: info["title"].string ?? "Deezer playlist", tracks: tracks)
    }

    /// The JSON inside the `<script>` tag that follows `marker`.
    private static func scriptJSON(in html: String, marker: String) -> Any? {
        guard let start = html.range(of: marker), let open = html[start.upperBound...].firstIndex(of: ">"),
              let end = html[open...].range(of: "</script>")
        else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(html[html.index(after: open) ..< end.lowerBound].utf8))
    }

    // MARK: Files

    static func load(file url: URL) throws -> ImportedPlaylist {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw PlaylistImportError.tooLarge }
        let text = try String(contentsOf: url, encoding: .utf8)
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let delimited = ["csv", "tsv"].contains(url.pathExtension.lowercased()) || firstLine.contains(",") || firstLine.contains(";") || firstLine.contains("\t")
        let tracks = delimited ? parseCSV(text) : parseLines(text)
        guard !tracks.isEmpty else { throw PlaylistImportError.empty }
        return ImportedPlaylist(name: url.deletingPathExtension().lastPathComponent, tracks: Array(tracks.prefix(maxTracks)))
    }

    /// CSV with a header row naming the columns, as Exportify, TuneMyMusic and Apple's export write them.
    /// Commas, semicolons or tabs may separate the fields (a leading `sep=;` line says which).
    static func parseCSV(_ text: String) -> [ImportedTrack] {
        var body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var delimiter: Character?
        // Excel's "sep=;" directive, on a line of its own before the header.
        if let firstLine = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
           firstLine.lowercased().hasPrefix("sep="), firstLine.trimmingCharacters(in: .whitespacesAndNewlines).count == 5 {
            delimiter = firstLine.dropFirst(4).first
            body = String(body.dropFirst(firstLine.count + 1))
        }
        let rows = csvRows(body, delimiter: delimiter ?? detectDelimiter(body))
        guard let header = rows.first else { return [] }
        let names = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: " ") }
        // An exact name wins over one that merely starts the same way ("track name" over "track uri").
        func column(_ options: [String]) -> Int? {
            for option in options { if let exact = names.firstIndex(of: option) { return exact } }
            for option in options { if let prefix = names.firstIndex(where: { $0.hasPrefix(option + " ") || $0.hasPrefix(option + "(") }) { return prefix } }
            return nil
        }
        let link = column(["youtube video id", "video id", "videoid", "youtube id", "youtube url", "youtube link", "url", "link"])
        guard let title = column(["track name", "track", "title", "song", "name", "song name", "track title", "song title"]) ?? link else { return parseLines(text) }
        let artist = column(["artist name(s)", "artist name", "artist", "artists", "album artist name(s)", "creator"])
        let album = column(["album name", "album", "album title"])
        // Exportify lists one link per artist, so a name such as "Tyler, The Creator" is only split when there are several.
        let artistLinks = column(["artist uri(s)", "artist uris"])
        let duration = column(["duration (ms)", "track duration (ms)", "duration ms", "duration", "length", "time"])
        return rows.dropFirst().compactMap { row in
            func cell(_ index: Int?) -> String? {
                guard let index, index < row.count else { return nil }
                let value = row[index].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            let videoId = cell(link).flatMap(youTubeVideoId)
            let titleText = title == link ? "" : (cell(title) ?? "")
            guard !titleText.isEmpty || videoId != nil else { return nil }
            var seconds: Int?
            if let duration, let raw = cell(duration) {
                if raw.contains(":") { seconds = ForeignBackup.parseDuration(raw) }
                else if let value = Double(raw) { seconds = names[duration].contains("ms") || value > 10_000 ? Int(value / 1000) : Int(value) }
            }
            let artistText = cell(artist) ?? ""
            let single = artistLinks.map { $0 < row.count && !row[$0].contains(",") && !row[$0].isEmpty } ?? false
            let firstArtist = single ? artistText : artistText.components(separatedBy: [";", ","]).first?.trimmingCharacters(in: .whitespaces) ?? artistText
            return ImportedTrack(title: titleText, artist: firstArtist, album: cell(album), duration: seconds, videoId: videoId)
        }
    }

    /// An 11-character video id, given bare or as a youtube.com, music.youtube.com or youtu.be link.
    static func youTubeVideoId(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces)
        func valid(_ id: String) -> Bool { id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
        if valid(value) { return value }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else { return nil }
        if host == "youtu.be" { let id = url.pathComponents.dropFirst().first ?? ""; return valid(id) ? id : nil }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com"), url.path == "/watch" else { return nil }
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value ?? ""
        return valid(id) ? id : nil
    }

    /// The separator used most consistently across the first lines, outside quotes.
    static func detectDelimiter(_ text: String) -> Character {
        let candidates: [Character] = [",", ";", "\t"]
        var counts: [[Int]] = []
        var row = [0, 0, 0], quoted = false
        for c in text {
            if counts.count >= 20 { break }
            if c == "\"" { quoted.toggle() }
            else if !quoted, c == "\n" || c == "\r" { if row.contains(where: { $0 > 0 }) { counts.append(row) }; row = [0, 0, 0] }
            else if !quoted, let index = candidates.firstIndex(of: c) { row[index] += 1 }
        }
        if row.contains(where: { $0 > 0 }) { counts.append(row) }
        // The best separator splits most lines into the same number of fields.
        func consistency(_ index: Int) -> (Int, Int) {
            let per = counts.map { $0[index] }.filter { $0 > 0 }
            let modal = Dictionary(grouping: per, by: { $0 }).values.map(\.count).max() ?? 0
            return (modal, counts.first?[index] ?? 0)
        }
        let best = candidates.indices.max { consistency($0) < consistency($1) } ?? 0
        return candidates[best]
    }

    /// One track per line: "Artist - Title".
    static func parseLines(_ text: String) -> [ImportedTrack] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            for separator in [" - ", " – ", " — ", " by "] {
                if let range = line.range(of: separator) {
                    let (left, right) = (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
                    return separator == " by " ? ImportedTrack(title: left, artist: right) : ImportedTrack(title: right, artist: left)
                }
            }
            return ImportedTrack(title: line, artist: "")
        }
    }

    private static func csvRows(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if quoted {
                if c == "\"" { if index + 1 < characters.count, characters[index + 1] == "\"" { field.append("\""); index += 1 } else { quoted = false } }
                else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == delimiter { row.append(field); field = "" }
            else if c == "\n" { row.append(field); field = ""; if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }; row = [] }
            else { field.append(c) }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

// MARK: - Matching

struct TrackMatch: Identifiable {
    enum Kind { case matched, uncertain, missing }
    var id: UUID { track.id }
    var track: ImportedTrack
    var kind: Kind
    var candidates: [Song]
    var chosen: Song?
    var include: Bool
}

/// Finds each imported track on YouTube Music: the title and artist have to agree, the length
/// within 3 seconds, and the audio release is preferred over music videos.
enum TrackMatcher {
    private static func words(_ text: String) -> Set<String> {
        var cleaned = text.lowercased()
        cleaned = cleaned.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring|with)\s.*$"#, with: "", options: .regularExpression)
        return Set(cleaned.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    static func score(_ track: ImportedTrack, _ song: Song) -> (value: Double, strong: Bool) {
        let wanted = words(track.title), found = words(song.title)
        var title = 0.0
        if wanted == found { title = 1 }
        else if !wanted.isEmpty, !found.isEmpty, wanted.isSubset(of: found) || found.isSubset(of: wanted) { title = 0.7 }
        else if !wanted.isEmpty { title = Double(wanted.intersection(found).count) / Double(wanted.union(found).count) }
        let artistWords = words(track.artist)
        let songArtists = Set(song.artists.flatMap { words($0.name) })
        let artistMatch = artistWords.isEmpty || !artistWords.isDisjoint(with: songArtists) || !artistWords.isDisjoint(with: found)
        var value = 0.5 * title + (artistMatch ? 0.4 : 0)
        var durationOK = true
        if let wantedLength = track.duration, let length = song.duration, wantedLength > 0 {
            let difference = abs(wantedLength - length)
            if difference <= 3 { value += 0.2 } else if difference > 8 { value -= 0.3 }
            durationOK = difference <= 3
        }
        if song.isVideo { value -= 0.15 }
        return (value, title >= 0.7 && artistMatch && durationOK)
    }

    static func match(_ track: ImportedTrack) async -> TrackMatch {
        // A file that names the exact YouTube video needs no searching.
        if let videoId = track.videoId, let song = await song(videoId: videoId) {
            return TrackMatch(track: track, kind: .matched, candidates: [song], chosen: song, include: true)
        }
        let query = "\(track.title) \(track.artist)".trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return TrackMatch(track: track, kind: .missing, candidates: [], chosen: nil, include: false) }
        let songs = ((try? await YTMusic.search(query, filter: .songs, hidingBlocked: false))?.sections.flatMap(\.items).compactMap(\.song)) ?? []
        let ranked = songs.map { ($0, score(track, $0)) }.sorted { $0.1.value > $1.1.value }
        guard let best = ranked.first else { return TrackMatch(track: track, kind: .missing, candidates: [], chosen: nil, include: false) }
        if best.1.strong { return TrackMatch(track: track, kind: .matched, candidates: ranked.prefix(4).map(\.0), chosen: best.0, include: true) }
        if best.1.value >= 0.55 { return TrackMatch(track: track, kind: .uncertain, candidates: ranked.prefix(4).map(\.0), chosen: best.0, include: false) }
        return TrackMatch(track: track, kind: .missing, candidates: ranked.prefix(4).map(\.0), chosen: nil, include: false)
    }

    /// The song behind a video id: the first entry of YouTube Music's queue for it.
    static func song(videoId: String) async -> Song? {
        guard let page = try? await YTMusic.queue(videoId: videoId) else { return nil }
        return page.songs.first { $0.id == videoId }
    }

    /// Matches every track, a few at a time, reporting progress.
    static func matchAll(_ tracks: [ImportedTrack], progress: @escaping @Sendable (Int) -> Void) async -> [TrackMatch] {
        var results = [TrackMatch?](repeating: nil, count: tracks.count)
        var done = 0
        await withTaskGroup(of: (Int, TrackMatch).self) { group in
            var next = 0
            func launch() {
                guard next < tracks.count else { return }
                let index = next
                next += 1
                group.addTask { (index, await match(tracks[index])) }
            }
            for _ in 0 ..< min(4, tracks.count) { launch() }
            for await (index, result) in group {
                results[index] = result
                done += 1
                progress(done)
                launch()
            }
        }
        return results.compactMap { $0 }
    }
}
