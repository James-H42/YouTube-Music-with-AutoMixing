import CoreLocation
import Foundation
import MapKit

/// Concerts from MusicBrainz, the open music encyclopaedia: no key, worldwide (Japan included),
/// entered by its volunteers, so many shows are missing. It fills gaps Ticketmaster leaves.
///
/// MusicBrainz asks for at most one request a second and a descriptive User-Agent, and sheds
/// load with 503 answers when it is busy. So questions are asked in batches (several artists,
/// events or venues per request), venues are remembered on disk, and an event's links are only
/// fetched when its page is opened.
enum MusicBrainzEvents {
    private static let pacer = Pacer(interval: 1.1)
    private static let userAgent = AppIdentity.musicBrainzUserAgent
    /// Names per artist search, artists per event search, venues per place search.
    static let namesPerRequest = 8
    static let artistsPerRequest = 25
    static let placesPerRequest = 20

    static func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/" + path)!
        components.queryItems = query.merging(["fmt": "json"]) { a, _ in a }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // A 503 means "busy" (MusicBrainz sheds load for everyone at times, not only for
        // clients asking too often): wait as long as it says, a little longer each time.
        for attempt in 0 ..< 8 {
            await pacer.wait()
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 503 || status == 429 {
                let asked = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
                try await Task.sleep(for: .seconds(min(asked, 10) + Double(attempt) * 0.75))
                continue
            }
            guard status == 200 else { throw Ticketmaster.Failure.http(status) }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        throw Ticketmaster.Failure.http(503)
    }

    /// A name inside a quoted search term.
    private static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\\", with: " ").replacingOccurrences(of: "\"", with: " ") + "\""
    }

    // MARK: Artists

    /// The MusicBrainz id of an artist with exactly this name, if there is one.
    static func artistId(for name: String) async throws -> String? {
        try await artistIds(for: [name])[ArtistName.key(name)] ?? nil
    }

    /// MusicBrainz ids for up to `namesPerRequest` names in one search, by name key. A name with
    /// no artist of exactly that name (or alias) maps to nil. Among namesakes the best-known
    /// (highest scored) is taken, as a single search would.
    static func artistIds(for names: [String]) async throws -> [String: String?] {
        let wanted = Array(Set(names.map(ArtistName.key).filter { !$0.isEmpty }))
        guard !wanted.isEmpty else { return [:] }
        let query = names.map { "artist:" + quoted($0) }.joined(separator: " OR ")
        let reply = try await get("artist", ["query": query, "limit": "100"])
        var best: [String: (id: String, score: Int)] = [:]
        for artist in reply["artists"] as? [[String: Any]] ?? [] {
            guard let id = artist["id"] as? String else { continue }
            let score = artist["score"] as? Int ?? 0
            let spellings = [artist["name"] as? String] + ((artist["aliases"] as? [[String: Any]]) ?? []).map { $0["name"] as? String }
            for key in Set(spellings.compactMap { $0.map(ArtistName.key) }) where wanted.contains(key) {
                if score > best[key]?.score ?? -1 { best[key] = (id, score) }
            }
        }
        var result: [String: String?] = [:]
        for key in wanted { result[key] = best[key]?.id }
        return result
    }

    // MARK: Events

    /// One artist's concerts from today on.
    static func events(artistId: String, artist: String, today: Date = Date()) async throws -> [Concert] {
        try await events(artists: [artistId: artist], today: today)
    }

    /// The concerts from today on of up to `artistsPerRequest` artists (MusicBrainz id → the
    /// listener's name for them), with their venues placed on the map.
    static func events(artists: [String: String], today: Date = Date()) async throws -> [Concert] {
        guard !artists.isEmpty else { return [] }
        let day = Self.day(today)
        let query = "arid:(" + artists.keys.sorted().joined(separator: " OR ") + ") AND begin:[\(day) TO 2099-12-31]"
        var raw: [[String: Any]] = []
        var offset = 0
        // Up to 300 events: enough for two dozen touring artists.
        while offset < 300 {
            let reply = try await get("event", ["query": query, "limit": "100", "offset": String(offset)])
            let page = reply["events"] as? [[String: Any]] ?? []
            raw += page
            offset += page.count
            if page.count < 100 || offset >= (reply["count"] as? Int ?? 0) { break }
        }

        struct Pending { var event: [String: Any]; var placeId: String }
        var pending: [Pending] = []
        for event in raw {
            guard let begin = (event["life-span"] as? [String: Any])?["begin"] as? String, begin.count == 10, begin >= day else { continue }
            // Concerts and festivals; not award shows, launches or masterclasses.
            if let type = event["type"] as? String, !["Concert", "Festival"].contains(type) { continue }
            let relations = event["relations"] as? [[String: Any]] ?? []
            guard let placeId = relations.compactMap({ ($0["place"] as? [String: Any])?["id"] as? String }).first else { continue }
            pending.append(Pending(event: event, placeId: placeId))
        }
        let venues = try await places(Array(Set(pending.map(\.placeId))))

        var concerts: [Concert] = []
        for item in pending {
            let event = item.event
            guard let id = event["id"] as? String, let name = event["name"] as? String,
                  let begin = (event["life-span"] as? [String: Any])?["begin"] as? String,
                  let venue = venues[item.placeId]
            else { continue }
            let relations = event["relations"] as? [[String: Any]] ?? []
            let billed = relations.compactMap { $0["artist"] as? [String: Any] }
            let performers = billed.compactMap { ($0["name"] as? String).map { ConcertPerformer(name: $0) } }
            // Which of the listener's artists play: by id, so a festival lists each one once.
            let mine = billed.compactMap { ($0["id"] as? String).flatMap { artists[$0] } }
            guard !mine.isEmpty else { continue }
            concerts.append(Concert(
                id: "mb:" + id,
                name: name,
                artists: Array(NSOrderedSet(array: mine)) as? [String] ?? mine,
                performers: performers.isEmpty ? mine.map { ConcertPerformer(name: $0) } : performers,
                venue: venue,
                localDate: begin,
                localTime: event["time"] as? String,
                timeZone: nil,
                status: event["cancelled"] as? Bool == true ? .cancelled : .scheduled,
                source: "musicbrainz"
            ))
        }
        return concerts
    }

    /// An event's official website and ticket page, when MusicBrainz has them. Fetched when
    /// the concert's page is opened, not for every listing.
    static func links(eventId: String) async throws -> ConcertLinks {
        let id = eventId.hasPrefix("mb:") ? String(eventId.dropFirst(3)) : eventId
        let reply = try await get("event/\(id)", ["inc": "url-rels"])
        var links = ConcertLinks()
        for relation in reply["relations"] as? [[String: Any]] ?? [] {
            guard let url = (relation["url"] as? [String: Any])?["resource"] as? String else { continue }
            let type = (relation["type"] as? String ?? "").lowercased()
            if type.contains("ticket") { links.tickets = links.tickets ?? url }
            if type.contains("official homepage") { links.website = links.website ?? url }
        }
        return links
    }

    // MARK: Places

    private static let placeCache = PlaceCache()

    /// Venues by MusicBrainz place id, with coordinates, city and country (from Apple's map
    /// data: MusicBrainz names the district, not the country). Venues seen before come from
    /// disk; the rest are asked for `placesPerRequest` at a time.
    static func places(_ ids: [String]) async throws -> [String: ConcertVenue] {
        var result: [String: ConcertVenue] = [:]
        var missing: [String] = []
        for id in ids {
            if let known = await placeCache.get(id) { result[id] = known } else { missing.append(id) }
        }
        for start in stride(from: 0, to: missing.count, by: placesPerRequest) {
            let batch = Array(missing[start ..< min(start + placesPerRequest, missing.count)])
            let reply = try await get("place", ["query": batch.map { "pid:" + $0 }.joined(separator: " OR "), "limit": "100"])
            for place in reply["places"] as? [[String: Any]] ?? [] {
                guard let id = place["id"] as? String, batch.contains(id), let venue = await venue(place) else { continue }
                result[id] = venue
                await placeCache.set(id, venue)
            }
        }
        await placeCache.save()
        return result
    }

    /// One venue's details from MusicBrainz.
    static func place(_ id: String) async throws -> ConcertVenue? {
        try await places([id])[id]
    }

    private static func venue(_ place: [String: Any]) async -> ConcertVenue? {
        guard let name = place["name"] as? String,
              let coordinates = place["coordinates"] as? [String: Any],
              let latitude = number(coordinates["latitude"]), let longitude = number(coordinates["longitude"])
        else { return nil }
        let found = await MainActor.run { MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)) }
        let address = try? await found?.mapItems.first?.addressRepresentations
        let code = address?.region?.identifier
        return ConcertVenue(
            name: name,
            address: place["address"] as? String,
            city: address?.cityName ?? (place["area"] as? [String: Any])?["name"] as? String,
            region: nil,
            countryCode: code,
            countryName: Geo.countryName(code) ?? address?.regionName,
            latitude: latitude,
            longitude: longitude
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? String { return Double(value) }
        return nil
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// A concert's website and ticket page, filled in when its page is opened.
struct ConcertLinks: Hashable {
    var website: String?
    var tickets: String?
}

/// Venues already placed on the map, kept on disk: venues don't move, and placing one costs a
/// MusicBrainz request and an Apple Maps lookup. Only venues that have no country are asked
/// for again (Apple Maps may have been unreachable).
private actor PlaceCache {
    private var venues: [String: ConcertVenue]?
    private var dirty = false
    private var file: URL { AppPaths.root.appendingPathComponent("concert-places.json") }

    private func loaded() -> [String: ConcertVenue] {
        if let venues { return venues }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: ConcertVenue].self, from: $0) } ?? [:]
        venues = read
        return read
    }

    func get(_ id: String) -> ConcertVenue? {
        guard let venue = loaded()[id], venue.countryCode != nil else { return nil }
        return venue
    }

    func set(_ id: String, _ venue: ConcertVenue) {
        var all = loaded()
        all[id] = venue
        venues = all
        dirty = true
    }

    func save() {
        guard dirty, let venues, let data = try? JSONEncoder().encode(venues) else { return }
        try? data.write(to: file, options: .atomic)
        dirty = false
    }
}
