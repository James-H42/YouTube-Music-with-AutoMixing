import Foundation
import Observation

/// An artist whose concerts are looked for: followed in the library, or listened to often.
struct ConcertArtist: Hashable {
    var name: String
    /// The YouTube Music artist page (a YouTube channel id).
    var channelId: String?
    /// Their YouTube Music picture, for concerts that come without one.
    var thumbnail: String?
    var key: String { ArtistName.key(name) }
}

/// Concerts near the chosen location from the listener's artists, and each artist's tour for
/// their page. Results are kept in memory for six hours; nothing is fetched until the listener
/// opens Concerts or an artist page.
@MainActor
@Observable
final class ConcertStore {
    static let shared = ConcertStore()

    static let freshFor: TimeInterval = 6 * 3600
    /// At most this many artists are looked up on Ticketmaster (followed first), and on
    /// MusicBrainz, which allows one request a second.
    static let ticketmasterArtists = 150
    static let musicBrainzArtists = 150

    var location: ConcertLocation? {
        didSet {
            guard location != oldValue else { return }
            UserDefaults.standard.set(location.flatMap { try? JSONEncoder().encode($0) }, forKey: "concertLocation")
        }
    }
    var order: ConcertRanking.Order {
        didSet { UserDefaults.standard.set(order.rawValue, forKey: "concertOrder") }
    }
    var useMusicBrainz: Bool {
        didSet { UserDefaults.standard.set(useMusicBrainz, forKey: "concertsMusicBrainz") }
    }
    /// Whether a Ticketmaster key is saved (checked again after Settings changes it).
    private(set) var hasKey = Ticketmaster.apiKey != nil

    private(set) var concerts: [Concert] = []
    private(set) var loading = false
    private(set) var progress: (done: Int, total: Int)?
    private(set) var problem: String?
    private(set) var loadedAt: Date?
    @ObservationIgnored private var loadedFor: String?
    @ObservationIgnored private var artistTours: [String: (date: Date, concerts: [Concert])] = [:]
    @ObservationIgnored private var ids = ArtistIdCache()
    /// What each source has found so far in this refresh, shown as it arrives.
    @ObservationIgnored private var foundTicketmaster: [Concert] = []
    @ObservationIgnored private var foundMusicBrainz: [Concert] = []
    /// The listener's artists by name key, for their pictures and YouTube Music pages.
    @ObservationIgnored private var known: [String: ConcertArtist] = [:]
    /// Artists whose picture has been looked for, so each is looked for once a session.
    @ObservationIgnored private var pictureAsked: Set<String> = []
    /// Websites and ticket pages of MusicBrainz events, fetched when their page opens.
    private(set) var links: [String: ConcertLinks] = [:]

    init() {
        location = UserDefaults.standard.data(forKey: "concertLocation").flatMap { try? JSONDecoder().decode(ConcertLocation.self, from: $0) }
        order = ConcertRanking.Order(rawValue: UserDefaults.standard.string(forKey: "concertOrder") ?? "") ?? .soonest
        useMusicBrainz = UserDefaults.standard.object(forKey: "concertsMusicBrainz") as? Bool ?? true
    }

    func setKey(_ key: String?) {
        Keychain.set(key?.trimmingCharacters(in: .whitespacesAndNewlines), for: Ticketmaster.keychainAccount)
        hasKey = Ticketmaster.apiKey != nil
        loadedFor = nil
        artistTours = [:]
    }

    /// The listener's artists: everyone they follow, then those they play most.
    static func artists(followed: [ArtistItem], history: [Song], playCounts: [String: Int]) -> [ConcertArtist] {
        var seen = Set<String>()
        var result: [ConcertArtist] = []
        func add(_ name: String, _ channelId: String?, _ thumbnail: String? = nil) {
            let artist = ConcertArtist(name: name, channelId: channelId, thumbnail: thumbnail)
            guard !artist.key.isEmpty, seen.insert(artist.key).inserted else { return }
            result.append(artist)
        }
        for artist in followed { add(artist.title, artist.id.hasPrefix("UC") ? artist.id : nil, artist.thumbnail) }
        var plays: [String: (artist: ArtistRef, count: Int)] = [:]
        for song in history {
            for artist in song.artists.prefix(2) where artist.id != nil {
                let key = ArtistName.key(artist.name)
                plays[key, default: (artist, 0)].count += max(playCounts[song.id] ?? 1, 1)
            }
        }
        for entry in plays.values.sorted(by: { $0.count > $1.count }).prefix(60) { add(entry.artist.name, entry.artist.id) }
        return result
    }

    /// Pictures of the listener's artists by name key, for concerts without a picture.
    private(set) var artistImages: [String: String] = [:]

    /// The concert's own picture, else its first performer's, else the artist's own.
    func image(for concert: Concert) -> String? {
        concert.imageURL ?? concert.performers.lazy.compactMap(\.imageURL).first
            ?? (concert.artists + concert.performers.map(\.name)).lazy.compactMap { self.artistImages[ArtistName.key($0)] }.first
    }

    func remember(_ artists: [ConcertArtist]) {
        for artist in artists {
            if known[artist.key] == nil { known[artist.key] = artist }
            // YouTube's list thumbnails are small; a card is up to 360 points wide.
            if let thumbnail = artist.thumbnail, artistImages[artist.key] == nil { artistImages[artist.key] = thumbnail.resizedThumbnail(1200) }
        }
    }

    /// Looks up a picture of the headliner for each concert that has none: Apple Music's wide
    /// artist banner when that setting is on, else their YouTube Music picture (found by their
    /// page when known, else by an exact-name search).
    func findPictures(for concerts: [Concert], apple: Bool) async {
        for concert in concerts where image(for: concert) == nil {
            guard let name = concert.artists.first ?? concert.performers.first?.name else { continue }
            let key = ArtistName.key(name)
            guard !key.isEmpty, pictureAsked.insert(key).inserted else { continue }
            let channelId = known[key]?.channelId ?? concert.performers.first { ArtistName.same($0.name, name) }?.channelId
            if let url = await Self.picture(of: name, channelId: channelId, apple: apple) {
                artistImages[key] = url.resizedThumbnail(1200)
            }
        }
    }

    private static func picture(of name: String, channelId: String?, apple: Bool) async -> String? {
        if apple, let art = await AppleMusicArtwork.shared.artist(named: name, includeVideo: false), let url = art.banner ?? art.image {
            return url.absoluteString
        }
        if let channelId, let page = try? await YTMusic.artist(channelId), let thumbnail = page.artist.thumbnail {
            return thumbnail
        }
        let results = try? await YTMusic.search(name, filter: .artists)
        return results?.sections.flatMap(\.items).lazy.compactMap { item -> String? in
            if case .artist(let found) = item, ArtistName.same(found.title, name) { found.thumbnail } else { nil }
        }.first
    }

    /// Fetches a MusicBrainz event's website and ticket page for its page.
    func completeLinks(_ id: String) async {
        guard id.hasPrefix("mb:"), links[id] == nil, let found = try? await MusicBrainzEvents.links(eventId: id) else { return }
        links[id] = found
    }

    /// Kilometres from the chosen location to a concert's venue.
    func distance(to concert: Concert) -> Double? {
        guard let location, let lat = concert.venue.latitude, let lon = concert.venue.longitude else { return nil }
        return Geo.distanceKm(location.latitude, location.longitude, lat, lon)
    }

    /// Shows these concerts without fetching (snapshots and checks).
    func preview(_ concerts: [Concert]) {
        self.concerts = concerts
        loadedAt = Date()
        loadedFor = location.map { $0.countryCode + "|" }
    }

    func concert(_ id: String) -> Concert? {
        guard var found = concerts.first(where: { $0.id == id }) ?? artistTours.values.lazy.flatMap(\.concerts).first(where: { $0.id == id }) else { return nil }
        if let extra = links[id] {
            found.websiteURL = found.websiteURL ?? extra.website
            if found.ticketURL == nil, let tickets = extra.tickets {
                found.ticketURL = tickets
                found.ticketSeller = URL(string: tickets)?.host?.replacingOccurrences(of: "www.", with: "")
            }
        }
        return found
    }

    /// The concerts for the chosen location, grouped and ordered.
    var groups: [ConcertRanking.Group] {
        guard let location else { return [] }
        return ConcertRanking.groups(concerts, near: location, order: order)
    }

    // MARK: Loading

    /// Fetches the location's concerts unless they were fetched in the last six hours for the
    /// same country and artists. Ticketmaster and MusicBrainz are asked at the same time, and
    /// concerts show as each source finds them.
    func refresh(artists: [ConcertArtist], force: Bool = false, applePictures: Bool = false) async {
        guard let location, !loading else { return }
        remember(artists)
        let signature = location.countryCode + "|" + artists.map(\.key).sorted().joined(separator: ",")
        if !force, loadedFor == signature, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.freshFor { return }
        loading = true
        problem = nil
        defer { loading = false; progress = nil }
        if loadedFor?.hasPrefix(location.countryCode + "|") != true { concerts = [] }

        let tmArtists = hasKey ? Array(artists.prefix(Self.ticketmasterArtists)) : []
        let mbArtists = useMusicBrainz ? Array(artists.prefix(Self.musicBrainzArtists)) : []
        progress = (0, tmArtists.count + mbArtists.count)
        foundTicketmaster = []
        foundMusicBrainz = []

        async let fromTicketmaster = ticketmasterSearch(tmArtists, countryCode: location.countryCode)
        async let fromMusicBrainz = musicBrainzSearch(mbArtists)
        let problems = [await fromTicketmaster, await fromMusicBrainz].compactMap { $0 }

        showFound()
        problem = problems.first
        loadedAt = Date()
        loadedFor = problems.isEmpty ? signature : nil
        await findPictures(for: ConcertRanking.located(concerts, near: location), apple: applePictures)
    }

    private func step(_ count: Int = 1) {
        if let progress { self.progress = (min(progress.done + count, progress.total), progress.total) }
    }

    private func showFound() {
        concerts = ConcertRanking.merge(foundTicketmaster + foundMusicBrainz)
    }

    /// Answers a problem to show, or nil.
    private func ticketmasterSearch(_ artists: [ConcertArtist], countryCode: String) async -> String? {
        guard !artists.isEmpty else { return nil }
        do {
            foundTicketmaster = try await ticketmasterConcerts(artists, countryCode: countryCode)
            showFound()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Answers a problem to show, or nil. A busy batch doesn't stop the others.
    private func musicBrainzSearch(_ artists: [ConcertArtist]) async -> String? {
        guard !artists.isEmpty else { return nil }
        let (found, failures) = await ids.musicBrainz(artists) { [weak self] count in self?.step(count) }
        var missed = failures
        let size = MusicBrainzEvents.artistsPerRequest
        for start in stride(from: 0, to: found.count, by: size) {
            if Task.isCancelled { break }
            let batch = found[start ..< min(start + size, found.count)]
            do {
                foundMusicBrainz += try await MusicBrainzEvents.events(artists: Dictionary(batch.map { ($0.id, $0.name) }) { first, _ in first })
                showFound()
            } catch {
                missed += batch.count
            }
        }
        return missed > 0 ? "MusicBrainz was busy, so \(missed) of \(artists.count) artists weren't checked. Refresh to try again." : nil
    }

    private func ticketmasterConcerts(_ artists: [ConcertArtist], countryCode: String?) async throws -> [Concert] {
        var attractions: [String: String] = [:]
        for artist in artists {
            if Task.isCancelled { break }
            if let id = try await ids.ticketmaster(artist) { attractions[id] = artist.name }
            step()
        }
        guard !attractions.isEmpty else { return [] }
        return try await Ticketmaster.events(attractionIds: Array(attractions.keys).sorted(), countryCode: countryCode, artists: attractions)
    }

    /// An artist's upcoming concerts everywhere, for their page.
    func tour(of artist: ConcertArtist) async -> [Concert] {
        if let cached = artistTours[artist.key], Date().timeIntervalSince(cached.date) < Self.freshFor { return cached.concerts }
        var found: [Concert] = []
        if hasKey, let tm = try? await ticketmasterConcerts([artist], countryCode: nil) { found += tm }
        if useMusicBrainz {
            let (known, _) = await self.ids.musicBrainz([artist]) { _ in }
            if let id = known.first?.id, let mb = try? await MusicBrainzEvents.events(artistId: id, artist: artist.name) { found += mb }
        }
        let tour = ConcertRanking.merge(found).filter { $0.status != .cancelled && $0.start >= Calendar.current.startOfDay(for: Date()) }.sorted { $0.start < $1.start }
        artistTours[artist.key] = (Date(), tour)
        return tour
    }
}

/// Which Ticketmaster and MusicBrainz ids belong to the listener's artists, saved for two weeks
/// (ids only, no event details), so the next visit needs a single search per country.
private final class ArtistIdCache {
    private struct Entry: Codable {
        var ticketmaster: String?
        var ticketmasterChecked: Date?
        var musicBrainz: String?
        var musicBrainzChecked: Date?
    }

    private static let keep: TimeInterval = 14 * 86_400
    private static var file: URL { AppPaths.root.appendingPathComponent("concert-artists.json") }
    private var entries: [String: Entry]

    init() {
        entries = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: Self.file, options: .atomic) }
    }

    private func fresh(_ date: Date?) -> Bool { date.map { Date().timeIntervalSince($0) < Self.keep } ?? false }

    func ticketmaster(_ artist: ConcertArtist) async throws -> String? {
        let key = artist.key + "|" + (artist.channelId ?? "")
        if let entry = entries[key], fresh(entry.ticketmasterChecked) { return entry.ticketmaster }
        let id = try await Ticketmaster.attractionId(for: artist.name, channelId: artist.channelId)
        entries[key, default: Entry()].ticketmaster = id
        entries[key, default: Entry()].ticketmasterChecked = Date()
        save()
        return id
    }

    /// MusicBrainz ids of these artists: saved ones first, the rest looked up a batch at a
    /// time. Answers the artists that have an id (with the listener's name for them) and how
    /// many couldn't be checked because MusicBrainz was busy. `progress` hears how many
    /// artists each step settled.
    func musicBrainz(_ artists: [ConcertArtist], progress: (Int) -> Void) async -> (found: [(id: String, name: String)], failures: Int) {
        var found: [(id: String, name: String)] = []
        var unknown: [ConcertArtist] = []
        var settled = 0
        for artist in artists {
            let key = artist.key + "|" + (artist.channelId ?? "")
            if let entry = entries[key], fresh(entry.musicBrainzChecked) {
                if let id = entry.musicBrainz { found.append((id, artist.name)) }
                settled += 1
            } else {
                unknown.append(artist)
            }
        }
        progress(settled)
        var failures = 0
        let size = MusicBrainzEvents.namesPerRequest
        for start in stride(from: 0, to: unknown.count, by: size) {
            if Task.isCancelled { break }
            let batch = Array(unknown[start ..< min(start + size, unknown.count)])
            guard let ids = try? await MusicBrainzEvents.artistIds(for: batch.map(\.name)) else {
                failures += batch.count
                progress(batch.count)
                continue
            }
            for artist in batch {
                let id = ids[artist.key] ?? nil
                let key = artist.key + "|" + (artist.channelId ?? "")
                entries[key, default: Entry()].musicBrainz = id
                entries[key, default: Entry()].musicBrainzChecked = Date()
                if let id { found.append((id, artist.name)) }
            }
            save()
            progress(batch.count)
        }
        return (found, failures)
    }
}
