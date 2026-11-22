import Foundation

/// Artist pictures, animated artist pictures and animated album covers from Apple Music, as
/// Metrolist fetches them (`AnimatedArtworkService.kt`):
///
/// 1. The public token Apple's own web player uses is read from music.apple.com's script
///    bundle (a JWT issued by "AMPWebPlay"). No Apple account is involved.
/// 2. The iTunes Search API finds the artist's or album's Apple Music id.
/// 3. Apple's catalogue API (amp-api.music.apple.com) returns the artwork and, where Apple
///    has one, the `editorialVideo`: an HLS stream that AVPlayer plays directly.
///
/// Only HTTPS addresses on Apple's hosts are accepted from any reply, and answers (including
/// "nothing found") are cached on disk, so each artist or album is looked up once a week.
actor AppleMusicArtwork {
    static let shared = AppleMusicArtwork()

    struct ArtistArt: Codable, Equatable {
        /// The square artist picture.
        var image: URL?
        /// A wide editorial banner (Apple Music's own artist-page header), when there is one.
        var banner: URL?
        /// Wide (16:9) motion artwork when Apple has it, else the square one.
        var video: URL?
    }

    struct AlbumArt: Codable, Equatable {
        /// Square motion cover.
        var video: URL?
        /// Portrait (3:4) motion cover, when there is one.
        var tallVideo: URL?
        var appleId: String?
    }

    private struct CacheFile: Codable {
        var artists: [String: Stamped<ArtistArt>] = [:]
        var albums: [String: Stamped<AlbumArt>] = [:]
        var token: String?
        var tokenExpiry: Date?
    }

    private struct Stamped<Value: Codable>: Codable {
        var value: Value?
        var date: Date
    }

    /// What one lookup came to. Only `found` and `nothing` are cached: a lookup that failed
    /// (no network, a rate limit, an expired token) is tried again next time.
    private enum Outcome<Value> {
        case found(Value)
        case nothing
        case failed

        var value: Value? { if case .found(let value) = self { value } else { nil } }
    }

    nonisolated(unsafe) static var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    private static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
    private static let foundLifetime: TimeInterval = 7 * 86_400
    private static let missLifetime: TimeInterval = 86_400

    private var cache: CacheFile?
    private var inFlight: [String: Task<Any?, Never>] = [:]
    private let file: URL

    init(file: URL = AppPaths.appleArtwork) { self.file = file }

    /// The Apple Music storefront for this Mac's region ("gb", "us"…).
    static var storefront: String {
        if let forced = ProcessInfo.processInfo.environment["METROLIST_STOREFRONT"], forced.count == 2 { return forced.lowercased() }
        let region = (Locale.current.region?.identifier ?? "US").lowercased()
        return region.count == 2 && region.allSatisfy(\.isLetter) ? region : "us"
    }

    // MARK: Public lookups

    func artist(named name: String, includeVideo: Bool) async -> ArtistArt? {
        // "v2": entries from before banners were looked up are fetched again.
        let key = "v2|\(Self.storefront)|\(Self.normalized(name))"
        guard !Self.normalized(name).isEmpty else { return nil }
        func shown(_ art: ArtistArt?) -> ArtistArt? {
            art.map { includeVideo ? $0 : ArtistArt(image: $0.image, banner: $0.banner, video: nil) }
        }
        if let hit = loadCache().artists[key], Date().timeIntervalSince(hit.date) < (hit.value == nil ? Self.missLifetime : Self.foundLifetime) {
            return shown(hit.value)
        }
        let outcome = await deduplicated("artist|" + key) { await self.fetchArtist(name) } as? Outcome<ArtistArt> ?? .failed
        switch outcome {
        case .found(let art): update { $0.artists[key] = Stamped(value: art, date: Date()) }
        case .nothing: update { $0.artists[key] = Stamped(value: nil, date: Date()) }
        case .failed: break
        }
        return shown(outcome.value)
    }

    func album(title: String, artist: String) async -> AlbumArt? {
        // "v2": compilations credited to Various Artists are found now; misses cached
        // before that are not trusted.
        let key = "v2|\(Self.storefront)|\(Self.normalized(artist))|\(Self.normalized(Self.albumBase(title)))"
        if let hit = loadCache().albums[key], Date().timeIntervalSince(hit.date) < (hit.value == nil ? Self.missLifetime : Self.foundLifetime) {
            return hit.value
        }
        let outcome = await deduplicated("album|" + key) { await self.fetchAlbum(title: title, artist: artist) } as? Outcome<AlbumArt> ?? .failed
        switch outcome {
        case .found(let art): update { $0.albums[key] = Stamped(value: art, date: Date()) }
        case .nothing: update { $0.albums[key] = Stamped(value: nil, date: Date()) }
        case .failed: break
        }
        return outcome.value
    }

    /// Several views can ask for the same artist at once; one lookup serves them all.
    private func deduplicated(_ key: String, _ work: @escaping @Sendable () async -> Any?) async -> Any? {
        if let running = inFlight[key] { return await running.value }
        let task = Task { await work() }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }

    // MARK: Artists

    private func fetchArtist(_ name: String) async -> Outcome<ArtistArt> {
        let id: String
        switch await artistId(name) {
        case .found(let found): id = found
        case .nothing: return .nothing
        case .failed: return .failed
        }
        let reply = await catalog("artists/\(id)", query: ["extend": "editorialArtwork,editorialVideo", "art[url]": "c,f"])
        guard case .found(let json) = reply else { return reply.isNothing ? .nothing : .failed }
        let attributes = json["data"][0]["attributes"]
        var art = ArtistArt()
        art.image = Self.image(attributes["artwork"], maxSide: 2400)
        art.banner = Self.banner(attributes["editorialArtwork"])
        let video = attributes["editorialVideo"]
        art.video = ["motionArtistWide16x9", "motionArtistFullscreen16x9", "motionArtistSquare1x1"].lazy.compactMap { Self.trusted(video[$0]["video"].string) }.first
        return art.image == nil && art.banner == nil && art.video == nil ? .nothing : .found(art)
    }

    /// An artwork object's address at (up to) `maxSide` pixels on its longer side.
    static func image(_ artwork: JSON, maxSide: Int) -> URL? {
        guard let template = artwork["url"].string else { return nil }
        let width = Double(artwork["width"].int ?? maxSide), height = Double(artwork["height"].int ?? maxSide)
        let scale = min(1, Double(maxSide) / max(width, height, 1))
        return trusted(template.replacingOccurrences(of: "{w}", with: "\(Int(width * scale))").replacingOccurrences(of: "{h}", with: "\(Int(height * scale))")
            .replacingOccurrences(of: "{c}", with: "bb").replacingOccurrences(of: "{f}", with: "jpg"))
    }

    /// The wide picture Apple Music shows across the top of an artist page. Apple names it
    /// `bannerUber` (others are kept as fallbacks); any other wide editorial picture without
    /// text or a logo on it will do.
    static func banner(_ editorial: JSON) -> URL? {
        for key in ["bannerUber", "centeredFullscreenBackground", "fullscreenBackground"] {
            let art = editorial[key]
            if let width = art["width"].int, let height = art["height"].int, height > 0, Double(width) / Double(height) >= 1.6,
               let url = image(art, maxSide: 3840) { return url }
        }
        let entries = (editorial.dictionary ?? [:]).mapValues(JSON.init)
        let wide = entries.filter { key, art in
            let lower = key.lowercased()
            guard !lower.contains("logo"), !lower.contains("text"), let width = art["width"].int, let height = art["height"].int, height > 0 else { return false }
            return Double(width) / Double(height) >= 2 && width >= 1600
        }
        return wide.sorted { $0.key < $1.key }.lazy.compactMap { image($0.value, maxSide: 3840) }.first
    }

    /// The Apple Music id of the artist whose name is exactly this one (ignoring case and
    /// accents). Several artists with the same name make it ambiguous, and then none is used.
    private func artistId(_ name: String) async -> Outcome<String> {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return .nothing }
        components.queryItems = [
            URLQueryItem(name: "term", value: name), URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "attribute", value: "artistTerm"), URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "country", value: Self.storefront),
        ]
        guard let url = components.url else { return .nothing }
        guard let data = await get(url) else { return .failed }
        let wanted = Self.normalized(name)
        let ids = Set(JSON(data: data)["results"].array.filter { Self.normalized($0["artistName"].string ?? "") == wanted }.compactMap { $0["artistId"].int })
        return ids.count == 1 ? .found(String(ids.first!)) : .nothing
    }

    // MARK: Albums

    private func fetchAlbum(title: String, artist: String) async -> Outcome<AlbumArt> {
        guard let candidates = await albumIds(title: title, artist: artist) else { return .failed }
        guard !candidates.isEmpty else { return .nothing }
        var failed = false
        for id in candidates.prefix(5) {
            // The extensions Metrolist (and Apple's web player) ask for on an album page.
            let reply = await catalog("albums/\(id)", query: ["extend": "editorialArtwork,editorialVideo,extendedAssetUrls,offers"])
            guard case .found(let json) = reply else { failed = failed || !reply.isNothing; continue }
            let video = json["data"][0]["attributes"]["editorialVideo"]
            let square = ["motionSquareVideo1x1", "motionDetailSquare"].lazy.compactMap { Self.trusted(video[$0]["video"].string) }.first
            let tall = ["motionTallVideo3x4", "motionDetailTall"].lazy.compactMap { Self.trusted(video[$0]["video"].string) }.first
            if square != nil || tall != nil { return .found(AlbumArt(video: square ?? tall, tallVideo: tall, appleId: id)) }
        }
        return failed ? .failed : .nothing
    }

    /// Apple Music ids of albums by this artist with this title, exact title first. Both the
    /// album search and a song search are used, as in Metrolist: motion artwork is often on
    /// one edition only (explicit or clean, original or re-release), and songs reach editions
    /// the album search leaves out.
    /// Nil when the search itself failed.
    private func albumIds(title: String, artist: String) async -> [String]? {
        let wantedArtist = Self.normalized(artist)
        let wantedTitle = Self.normalized(Self.albumBase(title))
        let exactTitle = Self.normalized(title)
        var found: [(id: String, exact: Bool, explicit: Bool)] = []
        var searched = false
        for entity in ["album", "song"] {
            guard var components = URLComponents(string: "https://itunes.apple.com/search") else { continue }
            components.queryItems = [
                URLQueryItem(name: "term", value: "\(artist) \(Self.albumBase(title))"), URLQueryItem(name: "entity", value: entity),
                URLQueryItem(name: "limit", value: entity == "song" ? "50" : "25"), URLQueryItem(name: "country", value: Self.storefront),
            ]
            guard let url = components.url, let data = await get(url) else { continue }
            searched = true
            for result in JSON(data: data)["results"].array {
                let name = Self.normalized(result["artistName"].string ?? "")
                let albumArtist = Self.normalized(result["collectionArtistName"].string ?? "")
                let collection = result["collectionName"].string ?? ""
                // "Kanye West" also matches a credit such as "Kanye West & Jay-Z".
                func matches(_ name: String) -> Bool {
                    !name.isEmpty && (name == wantedArtist || name.hasPrefix(wantedArtist) || wantedArtist.hasPrefix(name))
                }
                // A soundtrack or compilation is credited to Various Artists on Apple Music
                // ("Grand Theft Auto VI: The Album"), and to the game, film or label on YouTube
                // Music: then the whole title must match, and be more than a generic one.
                let compilation = (name == "variousartists" || albumArtist == "variousartists")
                    && Self.normalized(collection) == exactTitle && exactTitle.count >= 10
                guard matches(name) || matches(albumArtist) || compilation,
                      Self.normalized(Self.albumBase(collection)) == wantedTitle,
                      let id = result["collectionId"].int.map(String.init), !found.contains(where: { $0.id == id })
                else { continue }
                found.append((id, Self.normalized(collection) == exactTitle, result["collectionExplicitness"].string == "explicit"))
            }
        }
        guard searched else { return nil }
        // The exact title first, and the explicit (original) edition before a clean one.
        return found.enumerated().sorted { a, b in
            if a.element.exact != b.element.exact { return a.element.exact }
            if a.element.explicit != b.element.explicit { return a.element.explicit }
            return a.offset < b.offset
        }.map(\.element.id)
    }

    // MARK: Token and requests

    /// Apple's public web-player token, kept until five minutes before it expires.
    private func token() async -> String? {
        let saved = loadCache()
        if let token = saved.token, let expiry = saved.tokenExpiry, expiry.timeIntervalSinceNow > 300 { return token }
        return await deduplicated("token") { await self.fetchToken() } as? String
    }

    private func fetchToken() async -> String? {
        guard let page = URL(string: "https://music.apple.com/\(Self.storefront)/browse"),
              let html = await get(page, limit: 4 * 1024 * 1024).map({ String(decoding: $0, as: UTF8.self) }),
              let path = html.range(of: #"/assets/index[^"'\s]*\.js"#, options: .regularExpression).map({ String(html[$0]) }),
              let script = URL(string: "https://music.apple.com" + path),
              let js = await get(script, limit: 16 * 1024 * 1024).map({ String(decoding: $0, as: UTF8.self) })
        else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#) else { return nil }
        var best: (token: String, expiry: Date)?
        for match in regex.matches(in: js, range: NSRange(js.startIndex..., in: js)) {
            guard let range = Range(match.range, in: js) else { continue }
            let token = String(js[range])
            let parts = token.split(separator: ".")
            guard parts.count == 3, let payload = Self.base64URL(String(parts[1])) else { continue }
            let claims = JSON(data: payload)
            guard claims["iss"].string == "AMPWebPlay", let exp = claims["exp"].double else { continue }
            let expiry = Date(timeIntervalSince1970: exp)
            if expiry.timeIntervalSinceNow > 300, expiry > (best?.expiry ?? .distantPast) { best = (token, expiry) }
        }
        guard let best else { return nil }
        update { $0.token = best.token; $0.tokenExpiry = best.expiry }
        return best.token
    }

    private enum Reply {
        case found(JSON)
        /// Apple answered that there is no such item.
        case missing
        case failed

        var isNothing: Bool { if case .missing = self { true } else { false } }
    }

    /// A catalogue request. A refused token (it expired early, or Apple replaced it) is
    /// fetched again and the request repeated once.
    private func catalog(_ path: String, query: [String: String]) async -> Reply {
        for attempt in 0 ..< 2 {
            guard let token = await token() else { return .failed }
            guard var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(Self.storefront)/\(path)") else { return .failed }
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "platform", value: "web")]
            guard let url = components.url else { return .failed }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
            request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await Self.session.data(for: request), data.count <= 2 * 1024 * 1024 else { return .failed }
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return .found(JSON(data: data))
            case 404: return .missing
            case 401, 403:
                update { $0.token = nil; $0.tokenExpiry = nil }
                if attempt == 0 { continue }
                return .failed
            default: return .failed
            }
        }
        return .failed
    }

    private func get(_ url: URL, limit: Int = 2 * 1024 * 1024) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await Self.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= limit else { return nil }
        return data
    }

    // MARK: Helpers

    /// An address from a reply is only used if it is HTTPS on one of Apple's media hosts.
    static func trusted(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", url.user == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return nil }
        let allowed = ["mzstatic.com", "apple.com", "itunes.apple.com", "akamaized.net"]
        return allowed.contains { host == $0 || host.hasSuffix("." + $0) } ? url : nil
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "&", with: "and")
            .filter { $0.isLetter || $0.isNumber }
    }

    /// An album title without edition labels: "Currents (Deluxe)" and "Graduation - Single"
    /// are looked up as "Currents" and "Graduation".
    static func albumBase(_ title: String) -> String {
        var result = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(deluxe|edition|remaster|expanded|anniversary|version|bonus)[^\)\]]*[\)\]]"#,
                                                with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"\s+-\s+(single|ep)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func base64URL(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base)
    }

    private func loadCache() -> CacheFile {
        if let cache { return cache }
        let loaded = (try? JSONDecoder().decode(CacheFile.self, from: Data(contentsOf: file))) ?? CacheFile()
        cache = loaded
        return loaded
    }

    private func update(_ change: (inout CacheFile) -> Void) {
        var current = loadCache()
        change(&current)
        cache = current
        if let data = try? JSONEncoder().encode(current) { try? data.write(to: file, options: .atomic) }
    }
}
