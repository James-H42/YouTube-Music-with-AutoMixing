import MapKit
import Observation

/// Finds a city, region or country from what the listener types, with Apple Maps' suggestions.
/// Only the typed text goes to Apple; the Mac's own location is never asked for.
@MainActor
@Observable
final class LocationSearch: NSObject, MKLocalSearchCompleterDelegate {
    struct Suggestion: Identifiable, Hashable {
        var title: String
        var subtitle: String
        var id: String { title + "|" + subtitle }
    }

    var query = "" {
        didSet { completer.queryFragment = query.trimmingCharacters(in: .whitespaces) }
    }
    private(set) var suggestions: [Suggestion] = []
    @ObservationIgnored private var completions: [String: MKLocalSearchCompletion] = [:]
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.resultTypes = .address
        completer.delegate = self
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results.map { ($0.title, $0.subtitle, $0) }
        MainActor.assumeIsolated {
            completions = [:]
            suggestions = results.prefix(8).map { title, subtitle, completion in
                let suggestion = Suggestion(title: title, subtitle: subtitle)
                completions[suggestion.id] = completion
                return suggestion
            }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { suggestions = [] }
    }

    func resolve(_ suggestion: Suggestion) async -> ConcertLocation? {
        guard let completion = completions[suggestion.id] else { return await Self.resolve(suggestion.title + ", " + suggestion.subtitle) }
        return await Self.resolve(MKLocalSearch.Request(completion: completion))
    }

    /// A place from free text ("Manchester", "Kent", "Japan").
    static func resolve(_ text: String) async -> ConcertLocation? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = .address
        return await resolve(request)
    }

    private static func resolve(_ request: MKLocalSearch.Request) async -> ConcertLocation? {
        guard let response = try? await MKLocalSearch(request: request).start(), let item = response.mapItems.first else { return nil }
        let placemark = item.placemark
        guard let code = placemark.isoCountryCode else { return nil }
        let country = Geo.countryName(code) ?? placemark.country ?? code
        let name = item.name ?? placemark.locality ?? country
        let coordinate = placemark.coordinate
        let span = response.boundingRegion.span
        let reach = max(span.latitudeDelta, span.longitudeDelta * cos(coordinate.latitude * .pi / 180)) * 111 / 2
        return location(name: name, locality: placemark.locality, region: placemark.administrativeArea ?? placemark.subAdministrativeArea,
                        countryCode: code, countryName: country, placemarkCountry: placemark.country,
                        latitude: coordinate.latitude, longitude: coordinate.longitude, reachKm: reach)
    }

    /// Decides whether a found place is a city, a region or a whole country.
    static func location(name: String, locality: String?, region: String?, countryCode: String, countryName: String, placemarkCountry: String?,
                         latitude: Double, longitude: Double, reachKm: Double) -> ConcertLocation {
        let kind: ConcertLocation.Kind
        if ArtistName.same(name, countryName) || placemarkCountry.map({ ArtistName.same(name, $0) }) == true || (locality == nil && region == nil) {
            kind = .country
        } else if let locality, ArtistName.key(name).contains(ArtistName.key(locality)) || ArtistName.key(locality).contains(ArtistName.key(name)) {
            kind = .city
        } else if let region, ArtistName.same(name, region), reachKm <= 90 {
            // A city that is its own state or prefecture: Tokyo, Berlin, Vienna, Hamburg.
            kind = .city
        } else {
            kind = .region
        }
        return ConcertLocation(name: kind == .country ? countryName : name, kind: kind, latitude: latitude, longitude: longitude,
                               countryCode: countryCode.uppercased(), countryName: countryName,
                               radiusKm: kind == .region ? min(max(reachKm, 25), 400) : nil)
    }
}
