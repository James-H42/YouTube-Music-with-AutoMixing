import Foundation

/// `METROLIST_HOME=/tmp/claude/x Metrolist --concerttest [--live]`: checks Concerts.
/// Offline: name matching, Ticketmaster parsing, merging two sources, and the ranking for a
/// city (London vs Manchester), a region, a country, Japan and the US, on concerts placed at
/// real venues. With `--live`: Apple Maps finds the places, MusicBrainz's tours are ranked,
/// and, when METROLIST_TICKETMASTER_KEY is set, Ticketmaster's are too.
@MainActor
enum ConcertTest {
    private static var failures = 0
    private static var skipped = 0

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        print(passed ? "PASS" : "FAIL", name, detail.isEmpty ? "" : "— \(detail)")
        if !passed { failures += 1 }
    }

    static func run() async {
        names()
        parsing()
        ranking()
        merging()
        classification()
        artistList()
        if CommandLine.arguments.contains("--live") { await live() }
        print(failures == 0 ? "ALL PASSED\(skipped > 0 ? " (\(skipped) skipped)" : "")" : "\(failures) FAILED")
    }

    // MARK: Places

    struct Place { var name: String; var lat: Double; var lon: Double; var code: String; var city = "" }
    static let o2 = Place(name: "The O2", lat: 51.5030, lon: 0.0032, code: "GB", city: "London")
    static let wembley = Place(name: "OVO Arena Wembley", lat: 51.5585, lon: -0.2817, code: "GB", city: "London")
    static let brighton = Place(name: "Brighton Centre", lat: 50.8215, lon: -0.1446, code: "GB", city: "Brighton")
    static let birmingham = Place(name: "Utilita Arena Birmingham", lat: 52.4797, lon: -1.9145, code: "GB", city: "Birmingham")
    static let manchester = Place(name: "AO Arena", lat: 53.4880, lon: -2.2440, code: "GB", city: "Manchester")
    static let salford = Place(name: "Lowry", lat: 53.4707, lon: -2.2963, code: "GB", city: "Salford")
    static let liverpool = Place(name: "M&S Bank Arena", lat: 53.3976, lon: -2.9910, code: "GB", city: "Liverpool")
    static let leeds = Place(name: "First Direct Arena", lat: 53.8020, lon: -1.5433, code: "GB", city: "Leeds")
    static let glasgow = Place(name: "OVO Hydro", lat: 55.8603, lon: -4.2857, code: "GB", city: "Glasgow")
    static let dublin = Place(name: "3Arena", lat: 53.3475, lon: -6.2286, code: "IE", city: "Dublin")
    static let paris = Place(name: "Accor Arena", lat: 48.8386, lon: 2.3785, code: "FR", city: "Paris")
    static let tokyoDome = Place(name: "Tokyo Dome", lat: 35.7056, lon: 139.7519, code: "JP", city: "Tokyo")
    static let saitama = Place(name: "Saitama Super Arena", lat: 35.8949, lon: 139.6309, code: "JP", city: "Saitama")
    static let fukuoka = Place(name: "Mizuho PayPay Dome", lat: 33.5954, lon: 130.3621, code: "JP", city: "Fukuoka")
    static let msg = Place(name: "Madison Square Garden", lat: 40.7505, lon: -73.9934, code: "US", city: "New York")
    static let barclays = Place(name: "Barclays Center", lat: 40.6826, lon: -73.9754, code: "US", city: "Brooklyn")
    static let kia = Place(name: "Kia Forum", lat: 33.9583, lon: -118.3419, code: "US", city: "Inglewood")

    static func show(_ id: String, _ artist: String, _ place: Place, _ day: String, status: Concert.Status = .scheduled) -> Concert {
        Concert(id: id, name: "\(artist) Live", artists: [artist], performers: [ConcertPerformer(name: artist)],
                venue: ConcertVenue(name: place.name, city: place.city.isEmpty ? nil : place.city, countryCode: place.code, countryName: Geo.countryName(place.code),
                                    latitude: place.lat, longitude: place.lon),
                localDate: day, localTime: "19:30:00", timeZone: "UTC", status: status, source: "ticketmaster")
    }

    static func location(_ name: String, _ kind: ConcertLocation.Kind, _ lat: Double, _ lon: Double, _ code: String, radius: Double? = nil) -> ConcertLocation {
        ConcertLocation(name: name, kind: kind, latitude: lat, longitude: lon, countryCode: code, countryName: Geo.countryName(code) ?? code, radiusKm: radius)
    }

    static let london = location("London", .city, 51.5072, -0.1276, "GB")
    static let manchesterCity = location("Manchester", .city, 53.4808, -2.2426, "GB")
    static let uk = location("United Kingdom", .country, 54.0, -2.0, "GB")
    static let greaterManchester = location("Greater Manchester", .region, 53.5, -2.3, "GB", radius: 30)
    static let tokyo = location("Tokyo", .city, 35.6762, 139.6503, "JP")
    static let japan = location("Japan", .country, 36.2, 138.25, "JP")
    static let newYork = location("New York", .city, 40.7128, -74.0060, "US")
    static let usa = location("United States", .country, 39.8, -98.6, "US")

    /// A fixed "today" so the checks don't age.
    static let today = ISO8601DateFormatter().date(from: "2026-11-21T09:00:00Z")!

    static let sample: [Concert] = [
        show("o2", "Coldplay", o2, "2027-06-20"),
        show("wembley", "Wolf Alice", wembley, "2027-02-11"),
        show("brighton", "Wolf Alice", brighton, "2027-02-09"),
        show("brum", "Coldplay", birmingham, "2027-01-15"),
        show("mcr", "Coldplay", manchester, "2026-12-05"),
        show("lowry", "Wolf Alice", salford, "2027-03-01"),
        show("lpool", "Wolf Alice", liverpool, "2027-02-15"),
        show("leeds", "Coldplay", leeds, "2026-12-01"),
        show("glasgow", "Wolf Alice", glasgow, "2026-12-10"),
        show("dublin", "Coldplay", dublin, "2026-12-12"),
        show("paris", "Coldplay", paris, "2026-12-20"),
        show("past", "Coldplay", o2, "2026-10-01"),
        show("cancelled", "Coldplay", o2, "2027-01-02", status: .cancelled),
        show("tokyo", "YOASOBI", tokyoDome, "2026-12-06"),
        show("saitama", "YOASOBI", saitama, "2027-01-20"),
        show("fukuoka", "YOASOBI", fukuoka, "2026-11-28"),
        show("msg", "Coldplay", msg, "2027-05-01"),
        show("brooklyn", "Wolf Alice", barclays, "2027-04-02"),
        show("la", "Coldplay", kia, "2027-03-03"),
    ]

    static func ids(_ group: ConcertRanking.Group?) -> [String] { group?.concerts.map(\.id) ?? [] }

    // MARK: Offline

    private static func names() {
        check("names: case, accents and \"the\" don't matter", ArtistName.same("The Beatles", "beatles") && ArtistName.same("Beyoncé", "BEYONCE"))
        check("names: \"&\" and \"and\" are the same", ArtistName.same("Simon & Garfunkel", "Simon and Garfunkel"))
        check("names: different scripts stay different", !ArtistName.same("YOASOBI", "ヨアソビ") && ArtistName.same("米津玄師", "米津玄師"))
        check("names: an empty name matches nothing", !ArtistName.same("", ""))
        let distance = Geo.distanceKm(london.latitude, london.longitude, manchesterCity.latitude, manchesterCity.longitude)
        check("distance: London to Manchester is about 262 km", abs(distance - 262) < 5, String(format: "%.0f km", distance))
        check("countries: Ticketmaster's \"Great Britain\" is shown as the United Kingdom", Geo.countryName("GB") == "United Kingdom" && Geo.countryName("jp") == "Japan")
    }

    static let fixture = """
    {"name":"Wolf Alice: The Clearing Tour","id":"G5vYZ123","url":"https://www.ticketmaster.co.uk/wolf-alice-the-clearing-tour-manchester/event/1F0060A8","pleaseNote":"Doors 6:30pm",
     "images":[{"ratio":"3_2","url":"https://s1.ticketm.net/small.jpg","width":305},{"ratio":"16_9","url":"https://s1.ticketm.net/wide.jpg","width":2048},{"ratio":"16_9","url":"https://s1.ticketm.net/mid.jpg","width":640}],
     "sales":{"public":{"startDateTime":"2026-12-01T10:00:00Z"}},
     "dates":{"start":{"localDate":"2027-03-01","localTime":"19:30:00","dateTBA":false,"timeTBA":false,"noSpecificTime":false},"timezone":"Europe/London","status":{"code":"onsale"}},
     "priceRanges":[{"type":"standard","currency":"GBP","min":45.0,"max":95.5}],
     "_embedded":{"venues":[{"name":"AO Arena","postalCode":"M3 1AR","timezone":"Europe/London","city":{"name":"Manchester"},"country":{"name":"Great Britain","countryCode":"GB"},
        "address":{"line1":"Victoria Station Approach"},"location":{"longitude":"-2.244","latitude":"53.488"},"url":"https://www.ticketmaster.co.uk/ao-arena"}],
       "attractions":[{"name":"Wolf Alice","id":"K8vZ917G1x0","externalLinks":{"youtube":[{"url":"https://www.youtube.com/channel/UCwolfalice0000000000000"}],"homepage":[{"url":"https://www.wolfalice.co.uk/"}]},
                       "images":[{"ratio":"16_9","url":"https://s1.ticketm.net/wolf.jpg","width":1024}]},
                      {"name":"The Clearing Tour","id":"K8tour","externalLinks":{"homepage":[{"url":"https://theclearingtour.example/"}]}},
                      {"name":"Support Act","id":"K8support","externalLinks":{"youtube":[{"url":"https://www.youtube.com/user/supportact"}]}}]}}
    """

    private static func parsing() {
        let event = (try? JSONSerialization.jsonObject(with: Data(fixture.utf8))) as? [String: Any] ?? [:]
        guard let concert = Ticketmaster.concert(from: event, artists: ["K8vZ917G1x0": "Wolf Alice"], now: today) else {
            check("ticketmaster: an event is read", false)
            return
        }
        check("ticketmaster: id, day, time and time zone", concert.id == "tm:G5vYZ123" && concert.localDate == "2027-03-01" && concert.localTime == "19:30:00" && concert.timeZone == "Europe/London")
        check("ticketmaster: the venue with its coordinates and address", concert.venue.name == "AO Arena" && concert.venue.latitude == 53.488 && concert.venue.address == "Victoria Station Approach, Manchester, M3 1AR")
        check("ticketmaster: the country is the United Kingdom", concert.venue.countryCode == "GB" && concert.venue.countryName == "United Kingdom", concert.venue.countryName ?? "nil")
        check("ticketmaster: the listener's artist is named", concert.artists == ["Wolf Alice"])
        check("ticketmaster: the bill without the tour itself, with YouTube channels where given", concert.performers.map(\.name) == ["Wolf Alice", "Support Act"]
              && concert.performers[0].channelId == "UCwolfalice0000000000000" && concert.performers[1].channelId == nil, concert.performers.map(\.name).joined(separator: ", "))
        check("ticketmaster: the official ticket page and its seller", concert.ticketURL?.hasPrefix("https://www.ticketmaster.co.uk/") == true && concert.ticketSeller == "Ticketmaster")
        check("ticketmaster: the event's own website (not the artist's)", concert.websiteURL == "https://theclearingtour.example/", concert.websiteURL ?? "nil")
        check("ticketmaster: the widest banner", concert.imageURL == "https://s1.ticketm.net/wide.jpg")
        check("ticketmaster: the price range", concert.priceRange?.contains("45") == true && concert.priceRange?.contains("95.50") == true && concert.priceRange?.contains("£") == true, concert.priceRange ?? "nil")
        check("ticketmaster: on sale soon, with the date", concert.status == .onSaleSoon && concert.onSale != nil)
        check("ticketmaster: the venue's notes", concert.notes == "Doors 6:30pm")
        let ics = ConcertCalendar.ics(concert)
        check("calendar: starts 19:30 in Manchester (19:30 UTC in March) and lasts three hours",
              ics.contains("DTSTART:20270301T193000Z") && ics.contains("DTEND:20270301T223000Z"), ics.components(separatedBy: "\r\n").filter { $0.hasPrefix("DT") }.joined(separator: " "))
        check("calendar: with the venue and the ticket link", ics.contains("LOCATION:AO Arena\\, Victoria Station Approach") && ics.contains("URL:https://www.ticketmaster.co.uk/"))
        var undated = concert
        undated.localTime = nil
        check("calendar: a show without a time is an all-day event", ConcertCalendar.ics(undated).contains("DTSTART;VALUE=DATE:20270301"))
        check("ticketmaster: Live Nation links are named so", Ticketmaster.seller("https://www.livenation.co.uk/show/1") == "Live Nation")

        let namesakes: [[String: Any]] = [
            ["id": "a", "name": "Muse", "upcomingEvents": ["_total": 2]],
            ["id": "b", "name": "MUSE", "upcomingEvents": ["_total": 40]],
            ["id": "c", "name": "Muse Tribute", "upcomingEvents": ["_total": 90]],
            ["id": "d", "name": "Muse", "externalLinks": ["youtube": [["url": "https://www.youtube.com/channel/UCmuse"]]]],
        ]
        check("ticketmaster: among namesakes, the one with that YouTube channel", Ticketmaster.bestAttraction(namesakes, name: "Muse", channelId: "UCmuse") == "d")
        check("ticketmaster: else the busiest exact namesake, never a tribute act", Ticketmaster.bestAttraction(namesakes, name: "Muse", channelId: nil) == "b")
        check("ticketmaster: no exact name, no artist", Ticketmaster.bestAttraction(namesakes, name: "Muse Tribute Band", channelId: nil) == nil)
    }

    private static func ranking() {
        // London: London's shows first, then a short trip, then the rest of the UK (Manchester
        // included); never Dublin or Paris, past or cancelled shows.
        let fromLondon = ConcertRanking.groups(sample, near: london, now: today)
        check("london: three bands, nearest first", fromLondon.map(\.title).count == 3 && fromLondon.first?.title == "In and around London", fromLondon.map(\.title).joined(separator: " | "))
        check("london: London's shows, soonest first", ids(fromLondon.first) == ["wembley", "o2"], ids(fromLondon.first).joined(separator: ","))
        check("london: Brighton is a short trip", ids(fromLondon.dropFirst().first) == ["brighton"])
        check("london: Manchester and the rest of the UK follow, soonest first", ids(fromLondon.last) == ["leeds", "mcr", "glasgow", "brum", "lpool", "lowry"], ids(fromLondon.last).joined(separator: ","))
        let everyId = Set(fromLondon.flatMap(\.concerts).map(\.id))
        check("london: no other country, past or cancelled show", everyId.isDisjoint(with: ["dublin", "paris", "past", "cancelled", "tokyo", "msg"]))

        // Manchester: the same UK shows, but Manchester's own and the north west come first.
        let fromManchester = ConcertRanking.groups(sample, near: manchesterCity, now: today)
        check("manchester: Manchester and Salford first", ids(fromManchester.first) == ["mcr", "lowry"], ids(fromManchester.first).joined(separator: ","))
        check("manchester: Liverpool, Leeds and Birmingham are a short trip", Set(ids(fromManchester.dropFirst().first)) == ["lpool", "leeds", "brum"], ids(fromManchester.dropFirst().first).joined(separator: ","))
        check("manchester: London still listed, further down", ids(fromManchester.last).contains("o2") && ids(fromManchester.last).contains("wembley"))
        check("manchester and london list the same UK shows", Set(fromManchester.flatMap(\.concerts).map(\.id)) == everyId)

        let nearest = ConcertRanking.groups(sample, near: manchesterCity, order: .nearest, now: today).first?.concerts ?? []
        check("nearest first: by distance", nearest.first?.id == "mcr" && zip(nearest, nearest.dropFirst()).allSatisfy { ($0.distanceKm ?? 0) <= ($1.distanceKm ?? 0) })
        check("distances are worked out for each show", nearest.allSatisfy { $0.distanceKm != nil })

        let region = ConcertRanking.groups(sample, near: greaterManchester, now: today)
        check("region: Greater Manchester's shows, then the UK", ids(region.first) == ["mcr", "lowry"] && region.last?.title == "Elsewhere in United Kingdom", region.map(\.title).joined(separator: " | "))

        let country = ConcertRanking.groups(sample, near: uk, now: today)
        check("country: one list for the UK, soonest first", country.count == 1 && ids(country.first).first == "leeds" && ids(country.first).count == 9, ids(country.first).joined(separator: ","))

        let fromTokyo = ConcertRanking.groups(sample, near: tokyo, now: today)
        check("tokyo: Tokyo Dome and Saitama around Tokyo, Fukuoka elsewhere in Japan",
              ids(fromTokyo.first) == ["tokyo", "saitama"] && ids(fromTokyo.last) == ["fukuoka"], fromTokyo.map { "\($0.title): \(ids($0))" }.joined(separator: " | "))
        check("japan: all three, soonest first", ids(ConcertRanking.groups(sample, near: japan, now: today).first) == ["fukuoka", "tokyo", "saitama"])

        let fromNewYork = ConcertRanking.groups(sample, near: newYork, now: today)
        check("new york: Brooklyn and Manhattan first, Los Angeles elsewhere in the US",
              ids(fromNewYork.first) == ["brooklyn", "msg"] && ids(fromNewYork.last) == ["la"], fromNewYork.map { "\($0.title): \(ids($0))" }.joined(separator: " | "))
        var california = sample
        if let index = california.firstIndex(where: { $0.id == "la" }) { california[index].venue.region = "California" }
        let fromCalifornia = ConcertRanking.groups(california, near: location("California", .region, 38.58, -121.49, "US", radius: 400), now: today)
        check("region: a US state takes its venues by name (Los Angeles is in California)", ids(fromCalifornia.first) == ["la"] && fromCalifornia.first?.title == "In California",
              fromCalifornia.map { "\($0.title): \(ids($0))" }.joined(separator: " | "))
        check("united states: one list",ids(ConcertRanking.groups(sample, near: usa, now: today).first) == ["la", "brooklyn", "msg"])
        check("nothing for a country without shows", ConcertRanking.groups(sample, near: location("Berlin", .city, 52.52, 13.40, "DE"), now: today).isEmpty)
    }

    private static func merging() {
        var fromTicketmaster = show("tm:1", "YOASOBI", tokyoDome, "2026-12-06")
        fromTicketmaster.ticketURL = "https://tickets.example/1"
        var fromMusicBrainz = show("mb:1", "YOASOBI", Place(name: "東京ドーム", lat: 35.705658, lon: 139.751914, code: "JP"), "2026-12-06")
        fromMusicBrainz.source = "musicbrainz"
        fromMusicBrainz.websiteURL = "https://yoasobi.example/tour"
        let otherNight = { var copy = fromMusicBrainz; copy.id = "mb:2"; copy.localDate = "2026-12-07"; return copy }()
        let merged = ConcertRanking.merge([fromMusicBrainz, fromTicketmaster, otherNight])
        check("merge: the same show from two sources is listed once", merged.count == 2, merged.map(\.id).joined(separator: ","))
        check("merge: Ticketmaster's copy (with tickets) is kept, with MusicBrainz's website", merged.first { $0.localDate == "2026-12-06" }.map { $0.id == "tm:1" && $0.websiteURL == "https://yoasobi.example/tour" } ?? false)
        var withFriend = show("tm:9", "Coldplay", o2, "2027-06-20")
        withFriend.performers.append(ConcertPerformer(name: "Maggie Rogers"))
        var friend = show("tm:9", "Maggie Rogers", o2, "2027-06-20")
        friend.performers = [ConcertPerformer(name: "Coldplay"), ConcertPerformer(name: "Maggie Rogers")]
        let one = ConcertRanking.merge([withFriend, friend])
        check("merge: two followed artists on one bill make one concert naming both", one.count == 1 && one.first?.artists == ["Coldplay", "Maggie Rogers"] && one.first?.headline == "Coldplay, Maggie Rogers")
    }

    private static func classification() {
        let city = LocationSearch.location(name: "London", locality: "London", region: "England", countryCode: "GB", countryName: "United Kingdom", placemarkCountry: "United Kingdom", latitude: 51.5, longitude: -0.12, reachKm: 30)
        let region = LocationSearch.location(name: "Greater Manchester", locality: nil, region: "England", countryCode: "GB", countryName: "United Kingdom", placemarkCountry: "United Kingdom", latitude: 53.5, longitude: -2.3, reachKm: 28)
        let country = LocationSearch.location(name: "United Kingdom", locality: nil, region: nil, countryCode: "gb", countryName: "United Kingdom", placemarkCountry: "United Kingdom", latitude: 54, longitude: -2, reachKm: 600)
        let japan = LocationSearch.location(name: "日本", locality: nil, region: nil, countryCode: "JP", countryName: "Japan", placemarkCountry: "日本", latitude: 36, longitude: 138, reachKm: 900)
        check("places: a city", city.kind == .city && city.title == "London, United Kingdom")
        let tokyo = LocationSearch.location(name: "Tokyo", locality: nil, region: "Tokyo", countryCode: "JP", countryName: "Japan", placemarkCountry: "Japan", latitude: 35.69, longitude: 139.69, reachKm: 70)
        let kent = LocationSearch.location(name: "Kent", locality: nil, region: "England", countryCode: "GB", countryName: "United Kingdom", placemarkCountry: "United Kingdom", latitude: 51.2, longitude: 0.7, reachKm: 50)
        check("places: a city that is its own prefecture (Tokyo) is a city", tokyo.kind == .city)
        check("places: a county is a region", kent.kind == .region)
        check("places: a region, with how far it reaches", region.kind == .region && region.radiusKm == 28)
        check("places: a country", country.kind == .country && country.countryCode == "GB" && country.title == "United Kingdom")
        check("places: a country named in its own language", japan.kind == .country && japan.name == "Japan")
    }

    private static func artistList() {
        let followed = [ArtistItem(id: "UCcoldplay", title: "Coldplay"), ArtistItem(id: "UCwolf", title: "Wolf Alice")]
        let songs = [
            Song(id: "s1", title: "Idol", artists: [ArtistRef(name: "YOASOBI", id: "UCyoasobi")]),
            Song(id: "s2", title: "Yellow", artists: [ArtistRef(name: "Coldplay", id: "UCcoldplay")]),
            Song(id: "s3", title: "Kick Back", artists: [ArtistRef(name: "Kenshi Yonezu", id: "UCyonezu")]),
            Song(id: "s4", title: "Unknown", artists: [ArtistRef(name: "Someone", id: nil)]),
        ]
        let artists = ConcertStore.artists(followed: followed, history: songs, playCounts: ["s1": 3, "s3": 9])
        check("artists: followed first, then the most played, each once", artists.map(\.name) == ["Coldplay", "Wolf Alice", "Kenshi Yonezu", "YOASOBI"], artists.map(\.name).joined(separator: ", "))
        check("artists: their YouTube Music pages are kept", artists.first?.channelId == "UCcoldplay")
    }

    // MARK: Live

    private static func live() async {
        print("live: Apple Maps")
        var found: [String: ConcertLocation] = [:]
        let expected: [(String, ConcertLocation.Kind, String)] = [
            ("London", .city, "GB"), ("Manchester", .city, "GB"), ("United Kingdom", .country, "GB"), ("Greater Manchester", .region, "GB"),
            ("Kent", .region, "GB"), ("Glasgow", .city, "GB"),
            ("Japan", .country, "JP"), ("Tokyo", .city, "JP"), ("Osaka", .city, "JP"),
            ("United States", .country, "US"), ("New York", .city, "US"), ("Los Angeles", .city, "US"), ("California", .region, "US"),
        ]
        for (text, kind, code) in expected {
            let place = await LocationSearch.resolve(text)
            found[text] = place
            check("maps: \(text) is a \(kind.rawValue) in \(code)", place?.kind == kind && place?.countryCode == code,
                  place.map { "\($0.kind.rawValue) \($0.title) \(String(format: "%.2f,%.2f", $0.latitude, $0.longitude))\($0.radiusKm.map { String(format: " reach %.0f km", $0) } ?? "")" } ?? "not found")
        }

        print("live: MusicBrainz")
        if let id = try? await MusicBrainzEvents.artistId(for: "YOASOBI") {
            let tour = (try? await MusicBrainzEvents.events(artistId: id, artist: "YOASOBI")) ?? []
            for concert in tour.prefix(4) { print("   \(concert.localDate) \(concert.venue.name), \(concert.venue.place) [\(concert.venue.countryCode ?? "?")]") }
            check("musicbrainz: YOASOBI's upcoming concerts", !tour.isEmpty, "\(tour.count)")
            if let tokyo = found["Tokyo"] {
                let groups = ConcertRanking.groups(tour, near: tokyo)
                print("   from Tokyo: " + groups.map { "\($0.title) (\($0.concerts.count))" }.joined(separator: " | "))
                check("musicbrainz: placed in Japan and ranked from Tokyo", !groups.isEmpty && groups.flatMap(\.concerts).allSatisfy { $0.venue.countryCode == "JP" })
                if let first = groups.first?.concerts.first, let last = groups.last?.concerts.last {
                    check("musicbrainz: the nearest band is nearer to Tokyo", (first.distanceKm ?? .infinity) <= (last.distanceKm ?? .infinity) || groups.count == 1)
                }
            }
        } else {
            check("musicbrainz: YOASOBI is found", false)
        }

        print("live: MusicBrainz in batches, through the store")
        if let london = found["London"] {
            let names = ["slayr", "Creepy Nuts", "Kid Cudi", "Coldplay", "Fontaines D.C.", "YOASOBI", "Daft Punk", "The Weeknd", "Kenshi Yonezu", "Wolf Alice",
                         "Sam Fender", "Arctic Monkeys", "The Killers", "Biffy Clyro", "Royel Otis", "Olivia Rodrigo", "Sabrina Carpenter", "Linkin Park", "Green Day", "Ed Sheeran",
                         "Kings of Leon", "Lewis Capaldi", "Travis Scott", "Playboi Carti", "Ken Carson", "Destroy Lonely", "Yeat", "Lil Uzi Vert", "Radiohead", "Blur"]
            let store = ConcertStore.shared
            let saved = (store.location, store.useMusicBrainz)
            store.location = london
            store.useMusicBrainz = true
            let started = Date()
            await store.refresh(artists: names.map { ConcertArtist(name: $0) }, force: true)
            let seconds = Date().timeIntervalSince(started)
            let near = ConcertRanking.located(store.concerts, near: london)
            for concert in near.prefix(6) { print("   \(concert.localDate) \(concert.headline) at \(concert.venue.name), \(concert.venue.place)") }
            print("   \(store.concerts.count) concerts worldwide, \(near.count) in the UK, \(String(format: "%.0f", seconds)) s\(store.problem.map { ", problem: \($0)" } ?? "")")
            check("store: 30 artists checked in under a minute", seconds < 60, String(format: "%.0f s", seconds))
            let slayr = near.first { $0.artists.contains("slayr") }
            check("store: slayr's London show is found", slayr != nil)
            if let slayr {
                check("store: it gets a picture of slayr", store.image(for: slayr) != nil, store.image(for: slayr) ?? "none")
                await store.completeLinks(slayr.id)
                print("   links: \(store.links[slayr.id].map { "\($0.website ?? "-") \($0.tickets ?? "-")" } ?? "none")")
            }
            store.location = saved.0
            store.useMusicBrainz = saved.1
        }

        print("live: Ticketmaster")
        guard Ticketmaster.apiKey != nil else {
            print("SKIP ticketmaster: set METROLIST_TICKETMASTER_KEY to check it")
            skipped += 1
            return
        }
        let artists = ["Coldplay", "Wolf Alice", "Lewis Capaldi", "Sam Fender", "Kings of Leon", "Olivia Rodrigo", "Sabrina Carpenter", "Linkin Park", "Green Day", "Ed Sheeran", "Arctic Monkeys", "The Killers", "Biffy Clyro", "Royel Otis", "Fontaines D.C."]
        var attractions: [String: String] = [:]
        for artist in artists {
            if let id = try? await Ticketmaster.attractionId(for: artist, channelId: nil) { attractions[id] = artist }
        }
        check("ticketmaster: artists are found", attractions.count >= artists.count / 2, "\(attractions.count) of \(artists.count)")
        for (code, places) in [("GB", ["London", "Manchester", "United Kingdom"]), ("US", ["New York", "United States"]), ("JP", ["Tokyo", "Japan"])] {
            do {
                let concerts = try await Ticketmaster.events(attractionIds: Array(attractions.keys), countryCode: code, artists: attractions)
                print("   \(code): \(concerts.count) concerts")
                check("ticketmaster: concerts in \(code) are in \(code)", concerts.allSatisfy { $0.venue.countryCode == code })
                for name in places {
                    guard let place = found[name] else { continue }
                    let groups = ConcertRanking.groups(concerts, near: place)
                    print("   from \(name): " + groups.map { "\($0.title) (\($0.concerts.count)): " + $0.concerts.prefix(3).map { "\($0.localDate) \($0.headline) @ \($0.venue.city ?? "?")" }.joined(separator: "; ") }.joined(separator: " | "))
                    let distances = groups.map { $0.concerts.compactMap(\.distanceKm).min() ?? .infinity }
                    check("ticketmaster: from \(name), nearer bands come first", zip(distances, distances.dropFirst()).allSatisfy { $0 <= $1 })
                }
                if code == "GB", let first = concerts.first {
                    check("ticketmaster: a UK concert has a ticket link and a line-up", first.ticketURL != nil && !first.performers.isEmpty, "\(first.headline): \(first.ticketURL ?? "no link")")
                }
            } catch {
                check("ticketmaster: concerts in \(code)", false, error.localizedDescription)
            }
        }
    }
}
