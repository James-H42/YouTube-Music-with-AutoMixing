import Foundation

/// Ticketmaster's Discovery API (developer.ticketmaster.com): official listings with ticket
/// links and line-ups for the UK, Ireland, the US, Canada, Mexico, Australia, New Zealand and
/// much of Europe. Needs the listener's own free key, kept in the Keychain.
///
/// Only the country is sent with a search, never the chosen city or its coordinates: distances
/// are worked out on this Mac. Requests are made when the listener opens or refreshes
/// Concerts, kept under 5 a second, and their results are kept for a few hours only, as
/// Ticketmaster's terms ask.
enum Ticketmaster {
    enum Failure: LocalizedError {
        case noKey, badKey, quota, http(Int), offline

        var errorDescription: String? {
            switch self {
            case .noKey: "Add a Ticketmaster key in Settings › Integrations to see concerts."
            case .badKey: "Ticketmaster didn't accept the key. Check it in Settings › Integrations."
            case .quota: "Today's Ticketmaster allowance (5,000 lookups) is used up. It resets tomorrow."
            case .http(let code): "Ticketmaster answered with an error (\(code))."
            case .offline: "Couldn't reach Ticketmaster."
            }
        }
    }

    static let keychainAccount = "ticketmaster.apiKey"
    static let signUpPage = URL(string: "https://developer-acct.ticketmaster.com/user/register")!

    /// The key: from the Keychain, or METROLIST_TICKETMASTER_KEY for checks.
    static var apiKey: String? {
        if let key = ProcessInfo.processInfo.environment["METROLIST_TICKETMASTER_KEY"], !key.isEmpty { return key }
        return Keychain.get(keychainAccount)
    }

    private static let base = "https://app.ticketmaster.com/discovery/v2/"
    private static let pacer = Pacer(interval: 0.22)

    /// One GET; the key is added here. Answers the JSON object.
    static func get(_ path: String, _ query: [String: String], key: String? = nil) async throws -> [String: Any] {
        guard let key = key ?? apiKey else { throw Failure.noKey }
        var components = URLComponents(string: base + path)!
        components.queryItems = (query.merging(["apikey": key, "locale": "*"]) { a, _ in a })
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        await pacer.wait()
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw Failure.offline }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401, 403: throw Failure.badKey
        case 429: throw Failure.quota
        default: throw Failure.http(status)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Checks a key with one small request.
    static func verify(_ key: String) async -> Failure? {
        do {
            _ = try await get("events.json", ["size": "1", "classificationName": "music"], key: key)
            return nil
        } catch let failure as Failure {
            return failure
        } catch {
            return .offline
        }
    }

    // MARK: Artists

    /// Ticketmaster's id for an artist, or nil when it lists none by that exact name. A
    /// YouTube channel id, when known, settles between namesakes.
    static func attractionId(for name: String, channelId: String?) async throws -> String? {
        let reply = try await get("attractions.json", ["keyword": name, "classificationName": "music", "size": "20"])
        let attractions = embedded(reply, "attractions")
        return bestAttraction(attractions, name: name, channelId: channelId)
    }

    static func bestAttraction(_ attractions: [[String: Any]], name: String, channelId: String?) -> String? {
        let named = attractions.filter { ArtistName.same($0["name"] as? String ?? "", name) }
        if let channelId, let exact = named.first(where: { youtubeChannels($0).contains(channelId) }) {
            return exact["id"] as? String
        }
        // Namesakes: the one with the most upcoming shows.
        return named.max { upcoming($0) < upcoming($1) }?["id"] as? String
    }

    private static func upcoming(_ attraction: [String: Any]) -> Int {
        (attraction["upcomingEvents"] as? [String: Any])?["_total"] as? Int ?? 0
    }

    /// Channel ids in an attraction's YouTube links ("…/channel/UC…").
    static func youtubeChannels(_ attraction: [String: Any]) -> [String] {
        let links = ((attraction["externalLinks"] as? [String: Any])?["youtube"] as? [[String: Any]]) ?? []
        return links.compactMap { link in
            guard let url = link["url"] as? String, let range = url.range(of: "/channel/") else { return nil }
            let id = url[range.upperBound...].prefix { $0 != "/" && $0 != "?" }
            return id.hasPrefix("UC") ? String(id) : nil
        }
    }

    // MARK: Events

    /// Upcoming music events for these attractions, in one country or (nil) anywhere. Asks for
    /// several attractions at a time; `artists` maps attraction ids to the listener's names.
    static func events(attractionIds: [String], countryCode: String?, artists: [String: String], limit: Int = 600) async throws -> [Concert] {
        var concerts: [Concert] = []
        for batch in stride(from: 0, to: attractionIds.count, by: 20).map({ Array(attractionIds[$0 ..< min($0 + 20, attractionIds.count)]) }) {
            var page = 0
            while true {
                var query = ["attractionId": batch.joined(separator: ","), "sort": "date,asc", "size": "200", "page": "\(page)", "classificationName": "music"]
                if let countryCode { query["countryCode"] = countryCode }
                let reply: [String: Any]
                do {
                    reply = try await get("events.json", query)
                } catch Failure.http(400) where batch.count > 1 {
                    // A list of artists refused: ask about each one alone.
                    for id in batch {
                        concerts += try await events(attractionIds: [id], countryCode: countryCode, artists: artists, limit: limit - concerts.count)
                    }
                    break
                }
                concerts += embedded(reply, "events").compactMap { concert(from: $0, artists: artists) }
                let info = reply["page"] as? [String: Any]
                let pages = info?["totalPages"] as? Int ?? 1
                page += 1
                // Ticketmaster serves no further than the 1,000th result.
                if page >= pages || (page + 1) * 200 > 1_000 || concerts.count >= limit { break }
            }
        }
        return concerts
    }

    static func embedded(_ reply: [String: Any], _ key: String) -> [[String: Any]] {
        (reply["_embedded"] as? [String: Any])?[key] as? [[String: Any]] ?? []
    }

    /// One event as a concert. `artists` names the listener's artists by attraction id.
    static func concert(from event: [String: Any], artists: [String: String], now: Date = Date()) -> Concert? {
        guard let id = event["id"] as? String, let name = event["name"] as? String else { return nil }
        let dates = event["dates"] as? [String: Any] ?? [:]
        let start = dates["start"] as? [String: Any] ?? [:]
        guard let day = start["localDate"] as? String else { return nil }
        let attractions = embedded(event, "attractions")
        let venueInfo = embedded(event, "venues").first ?? [:]

        let mine = attractions.compactMap { ($0["id"] as? String).flatMap { artists[$0] } }
        // Ticketmaster lists a tour or festival as an attraction too ("The Clearing Tour",
        // "Reading Festival"): that is the event, not someone on the bill.
        let isEvent: ([String: Any]) -> Bool = { attraction in
            guard let title = attraction["name"] as? String, !mine.contains(where: { ArtistName.same($0, title) }) else { return false }
            let words = title.lowercased().split { !$0.isLetter }
            return words.contains { ["tour", "festival", "fest", "weekender"].contains($0) } && ArtistName.key(name).contains(ArtistName.key(title))
        }
        let performers = attractions.filter { !isEvent($0) }.compactMap { attraction -> ConcertPerformer? in
            guard let name = attraction["name"] as? String else { return nil }
            return ConcertPerformer(name: name, channelId: youtubeChannels(attraction).first, imageURL: bestImage(attraction["images"]))
        }

        let location = venueInfo["location"] as? [String: Any]
        let address = venueInfo["address"] as? [String: Any]
        let city = (venueInfo["city"] as? [String: Any])?["name"] as? String
        let state = venueInfo["state"] as? [String: Any]
        let country = venueInfo["country"] as? [String: Any]
        let venue = ConcertVenue(
            name: venueInfo["name"] as? String ?? "Venue to be announced",
            address: [address?["line1"] as? String, address?["line2"] as? String, city, venueInfo["postalCode"] as? String]
                .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", "),
            city: city,
            region: state?["name"] as? String,
            countryCode: country?["countryCode"] as? String,
            countryName: Geo.countryName(country?["countryCode"] as? String) ?? country?["name"] as? String,
            latitude: number(location?["latitude"]),
            longitude: number(location?["longitude"]),
            url: venueInfo["url"] as? String
        )

        var status = Concert.Status.scheduled
        switch (dates["status"] as? [String: Any])?["code"] as? String {
        case "canceled", "cancelled": status = .cancelled
        case "postponed": status = .postponed
        case "rescheduled": status = .rescheduled
        default: break
        }
        let sale = ((event["sales"] as? [String: Any])?["public"] as? [String: Any])?["startDateTime"] as? String
        let onSale = sale.flatMap { ISO8601DateFormatter().date(from: $0) }.flatMap { $0 > now ? $0 : nil }
        if status == .scheduled, onSale != nil { status = .onSaleSoon }

        // The event's own website: that tour or festival's homepage.
        let website = attractions.first { isEvent($0) && homepage($0) != nil }.flatMap(homepage)

        let ticketURL = event["url"] as? String
        return Concert(
            id: "tm:" + id,
            name: name,
            artists: mine,
            performers: performers,
            venue: venue,
            localDate: day,
            localTime: (start["timeTBA"] as? Bool == true || start["noSpecificTime"] as? Bool == true) ? nil : start["localTime"] as? String,
            timeZone: dates["timezone"] as? String ?? venueInfo["timezone"] as? String,
            status: status,
            ticketURL: ticketURL,
            ticketSeller: seller(ticketURL),
            websiteURL: website,
            imageURL: bestImage(event["images"]),
            priceRange: priceRange(event["priceRanges"]),
            onSale: onSale,
            notes: (event["pleaseNote"] as? String) ?? (event["info"] as? String),
            source: "ticketmaster"
        )
    }

    private static func homepage(_ attraction: [String: Any]) -> String? {
        (((attraction["externalLinks"] as? [String: Any])?["homepage"] as? [[String: Any]])?.first?["url"] as? String)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? String { return Double(value) }
        return nil
    }

    /// The widest 16:9 picture (the event's banner), else the widest.
    static func bestImage(_ value: Any?) -> String? {
        let images = value as? [[String: Any]] ?? []
        let wide = images.filter { ($0["ratio"] as? String) == "16_9" }
        return (wide.isEmpty ? images : wide).max { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }?["url"] as? String
    }

    /// "£45 – £95", from the first price range.
    static func priceRange(_ value: Any?) -> String? {
        guard let range = (value as? [[String: Any]])?.first, let currency = range["currency"] as? String else { return nil }
        let low = number(range["min"]), high = number(range["max"])
        // "£45 – £95", or "£45.00 – £95.50" when any amount has pence.
        let whole = [low, high].compactMap { $0 }.allSatisfy { $0 == $0.rounded() }
        let style = FloatingPointFormatStyle<Double>.Currency(code: currency).precision(.fractionLength(whole ? 0 : 2))
        switch (low, high) {
        case let (low?, high?) where abs(low - high) < 0.01: return low.formatted(style)
        case let (low?, high?): return "\(low.formatted(style)) – \(high.formatted(style))"
        case let (low?, nil): return "From \(low.formatted(style))"
        default: return nil
        }
    }

    /// Ticketmaster's events can be sold by its sister sites; name the one the link goes to.
    static func seller(_ url: String?) -> String? {
        guard let host = url.flatMap(URL.init(string:))?.host?.lowercased() else { return nil }
        if host.contains("livenation") { return "Live Nation" }
        if host.contains("ticketweb") { return "TicketWeb" }
        if host.contains("universe") { return "Universe" }
        if host.contains("frontgate") { return "Front Gate Tickets" }
        return "Ticketmaster"
    }
}

/// Spaces requests out: each `wait` returns at least `interval` after the previous one.
actor Pacer {
    private let interval: Double
    private var next = Date.distantPast

    init(interval: Double) { self.interval = interval }

    func wait() async {
        let now = Date()
        let at = max(now, next)
        next = at.addingTimeInterval(interval)
        let delay = at.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
    }
}
