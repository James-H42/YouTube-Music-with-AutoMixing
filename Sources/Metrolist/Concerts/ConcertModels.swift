import Foundation

/// Where the listener wants to see concerts: a place they typed and chose themselves. The app
/// never reads the Mac's location. Saved on this Mac only.
struct ConcertLocation: Codable, Hashable {
    enum Kind: String, Codable { case city, region, country }

    var name: String
    var kind: Kind
    var latitude: Double
    var longitude: Double
    /// ISO 3166-1 alpha-2 ("GB", "JP", "US").
    var countryCode: String
    var countryName: String
    /// For a region: about how far it reaches from its centre.
    var radiusKm: Double?

    /// "London, United Kingdom", or just "Japan" for a country.
    var title: String { kind == .country || name == countryName ? countryName : "\(name), \(countryName)" }
}

/// One performer on a bill.
struct ConcertPerformer: Codable, Hashable, Identifiable {
    var name: String
    /// The YouTube channel (also the YouTube Music artist page), when the ticket seller gives it.
    var channelId: String?
    var imageURL: String?
    var id: String { name.lowercased() }
}

struct ConcertVenue: Codable, Hashable {
    var name: String
    var address: String?
    var city: String?
    var region: String?
    var countryCode: String?
    var countryName: String?
    var latitude: Double?
    var longitude: Double?
    var url: String?

    /// "Manchester, United Kingdom".
    var place: String { [city, countryName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ") }
}

/// An upcoming concert, from Ticketmaster or MusicBrainz.
struct Concert: Codable, Hashable, Identifiable {
    enum Status: String, Codable { case scheduled, onSaleSoon, cancelled, postponed, rescheduled }

    var id: String
    /// The event's own name ("Coldplay: Music of the Spheres World Tour").
    var name: String
    /// The artists from the listener's library this concert was found for.
    var artists: [String]
    /// The whole bill, headliner first, when known.
    var performers: [ConcertPerformer]
    var venue: ConcertVenue
    /// The day at the venue ("2026-12-04").
    var localDate: String
    /// The start time at the venue ("19:30:00"), when announced.
    var localTime: String?
    /// The venue's time zone ("Europe/London").
    var timeZone: String?
    var status: Status = .scheduled
    /// The official ticket page (the ticket seller's own).
    var ticketURL: String?
    var ticketSeller: String?
    /// The event's own website, when it has one (festivals mostly).
    var websiteURL: String?
    var imageURL: String?
    var priceRange: String?
    /// When general sale starts, if that is still to come.
    var onSale: Date?
    var notes: String?
    /// "ticketmaster" or "musicbrainz".
    var source: String

    /// Kilometres from the chosen location, set when concerts are ranked.
    var distanceKm: Double?

    /// The concert's start as an instant (midday when only the day is known), for sorting.
    var start: Date {
        let zone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = localDate.split(separator: "-").compactMap { Int($0) }
        let time = (localTime ?? "12:00:00").split(separator: ":").compactMap { Int($0) }
        guard day.count == 3 else { return .distantFuture }
        return calendar.date(from: DateComponents(year: day[0], month: day[1], day: day[2], hour: time.first ?? 12, minute: time.count > 1 ? time[1] : 0)) ?? .distantFuture
    }

    /// "Coldplay", or "Coldplay, Maggie Rogers" when several followed artists play.
    var headline: String { artists.isEmpty ? (performers.first?.name ?? name) : artists.joined(separator: ", ") }

    /// The listener's artist named in the event, else the event name.
    var title: String {
        guard let first = performers.first?.name else { return name }
        return name.localizedCaseInsensitiveContains(first) || name.count > 60 ? first : name
    }
}

// MARK: - Distances

enum Geo {
    /// One name per country whatever the source calls it ("Great Britain" → "United Kingdom").
    static func countryName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return Locale(identifier: "en_GB").localizedString(forRegionCode: code.uppercased())
    }

    /// Great-circle distance in kilometres.
    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians, dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// "3 km", "120 km", "1,240 km"; miles where the Mac uses them.
    static func describe(_ km: Double, metric: Bool = Locale.current.measurementSystem == .metric) -> String {
        let value = metric ? km : km / 1.609_344
        let unit = metric ? "km" : "mi"
        if value < 1 { return "under 1 \(unit)" }
        return "\(value.rounded().formatted(.number.precision(.fractionLength(0)))) \(unit)"
    }
}

// MARK: - Ranking

/// Picks the concerts that belong to a location and orders them: by distance band (nearest
/// band first), then soonest first within each band.
enum ConcertRanking {
    struct Group: Identifiable, Hashable {
        var title: String
        var concerts: [Concert]
        var id: String { title }
    }

    enum Order: String, CaseIterable, Identifiable {
        case soonest, nearest
        var id: String { rawValue }
        var label: String { self == .soonest ? "Soonest First" : "Nearest First" }
    }

    /// A city counts as "around" it within this distance (London to Reading or Luton, Manchester
    /// to Salford or Stockport).
    static let aroundKm = 40.0
    /// A short trip: Manchester to Liverpool, Leeds or Sheffield; London to Brighton or Oxford.
    static let shortTripKm = 150.0

    /// Concerts in the location (for a city: anywhere in its country, nearest bands first),
    /// grouped and ordered. Concerts without coordinates are placed by country only.
    static func groups(_ concerts: [Concert], near location: ConcertLocation, order: Order = .soonest, now: Date = Date()) -> [Group] {
        let upcoming = located(concerts, near: location, now: now)
        if order == .nearest {
            let sorted = upcoming.sorted { ($0.distanceKm ?? .infinity, $0.start) < ($1.distanceKm ?? .infinity, $1.start) }
            return sorted.isEmpty ? [] : [Group(title: "Nearest to \(location.name)", concerts: sorted)]
        }
        let byDate: (Concert, Concert) -> Bool = { $0.start == $1.start ? ($0.distanceKm ?? .infinity) < ($1.distanceKm ?? .infinity) : $0.start < $1.start }
        var groups: [Group] = []
        func add(_ title: String, _ filter: (Concert) -> Bool, _ pool: inout [Concert]) {
            let chosen = pool.filter(filter).sorted(by: byDate)
            pool.removeAll(where: filter)
            if !chosen.isEmpty { groups.append(Group(title: title, concerts: chosen)) }
        }
        var pool = upcoming
        switch location.kind {
        case .city:
            add("In and around \(location.name)", { ($0.distanceKm ?? .infinity) <= aroundKm }, &pool)
            add("Within \(Geo.describe(shortTripKm)) of \(location.name)", { ($0.distanceKm ?? .infinity) <= shortTripKm }, &pool)
            add("Elsewhere in \(location.countryName)", { _ in true }, &pool)
        case .region:
            let reach = max(location.radiusKm ?? 60, 25)
            // In the region by its name (Ticketmaster names US states and Canadian provinces), or
            // by distance from its centre (counties, which venues don't name).
            add("In \(location.name)", { ($0.distanceKm ?? .infinity) <= reach || $0.venue.region.map { ArtistName.same($0, location.name) } == true }, &pool)
            add("Elsewhere in \(location.countryName)", { _ in true }, &pool)
        case .country:
            add("In \(location.countryName)", { _ in true }, &pool)
        }
        return groups
    }

    /// The upcoming concerts in the location's country, each with its distance.
    static func located(_ concerts: [Concert], near location: ConcertLocation, now: Date = Date()) -> [Concert] {
        let startOfToday = Calendar.current.startOfDay(for: now)
        return concerts.compactMap { concert in
            guard concert.start >= startOfToday, concert.status != .cancelled else { return nil }
            guard concert.venue.countryCode?.uppercased() == location.countryCode.uppercased() else { return nil }
            var placed = concert
            if let lat = concert.venue.latitude, let lon = concert.venue.longitude {
                placed.distanceKm = Geo.distanceKm(location.latitude, location.longitude, lat, lon)
            }
            return placed
        }
    }

    /// One entry per show: the same artist at the same venue on the same day from two sources
    /// is one concert (Ticketmaster's, which has tickets, is kept), with the artists merged.
    static func merge(_ concerts: [Concert]) -> [Concert] {
        var kept: [Concert] = []
        for concert in concerts.sorted(by: { ($0.source == "ticketmaster" ? 0 : 1) < ($1.source == "ticketmaster" ? 0 : 1) }) {
            if let index = kept.firstIndex(where: { same($0, concert) }) {
                for artist in concert.artists where !kept[index].artists.contains(where: { $0.caseInsensitiveCompare(artist) == .orderedSame }) {
                    kept[index].artists.append(artist)
                }
                for performer in concert.performers where !kept[index].performers.contains(where: { $0.id == performer.id }) {
                    kept[index].performers.append(performer)
                }
                if kept[index].websiteURL == nil { kept[index].websiteURL = concert.websiteURL }
            } else {
                kept.append(concert)
            }
        }
        return kept
    }

    private static func same(_ a: Concert, _ b: Concert) -> Bool {
        if a.id == b.id { return true }
        guard a.localDate == b.localDate else { return false }
        if let la = a.venue.latitude, let oa = a.venue.longitude, let lb = b.venue.latitude, let ob = b.venue.longitude {
            if Geo.distanceKm(la, oa, lb, ob) > 2 { return false }
        } else if ArtistName.key(a.venue.name) != ArtistName.key(b.venue.name) {
            return false
        }
        // A festival day lists many artists; the same bill in two sources shares one of them.
        let names = Set(a.performers.map(\.name).map(ArtistName.key) + a.artists.map(ArtistName.key))
        return b.performers.contains { names.contains(ArtistName.key($0.name)) } || b.artists.contains { names.contains(ArtistName.key($0)) }
    }
}

/// Comparing artist names across services: case, accents, "&"/"and" and a leading "The" don't
/// matter; scripts are compared as they are (YOASOBI and ヨアソビ are different names).
enum ArtistName {
    static func key(_ name: String) -> String {
        var text = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en"))
        text = text.replacingOccurrences(of: "&", with: " and ").replacingOccurrences(of: "+", with: " and ")
        if text.hasPrefix("the ") { text.removeFirst(4) }
        let kept = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(kept))
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let first = key(a), second = key(b)
        return !first.isEmpty && first == second
    }
}
