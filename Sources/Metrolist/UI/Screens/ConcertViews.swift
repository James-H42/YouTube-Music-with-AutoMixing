import AppKit
import SwiftUI

// MARK: - Concerts page

/// Concerts from the listener's artists near a place they chose, nearest first, soonest first
/// within each distance band. Laid out like the rest of the app: a picture card per concert in
/// a grid, under bold section titles.
struct ConcertsView: View {
    @Environment(AppModel.self) private var model
    @Bindable private var store = ConcertStore.shared
    @ViewState private var choosingPlace = false
    @ViewState private var addingKey = false

    private var artists: [ConcertArtist] {
        ConcertStore.artists(followed: model.library.artists, history: model.library.history, playCounts: model.library.playCounts)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if store.location == nil {
                    ContentUnavailableView {
                        Label("Choose Where to Look", systemImage: "mappin.and.ellipse")
                    } description: {
                        Text("Type a city, region or country to see concerts from the artists you follow and listen to. Metrolist+ never reads your Mac's location.")
                    } actions: {
                        Button("Choose a Location…") { choosingPlace = true }
                            .buttonStyle(.glassProminent)
                    }
                    // Centred in the page, following the window as it is resized.
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    if !store.hasKey { keyBanner }
                    if let problem = store.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 24)
                    }
                    let groups = store.groups
                    if groups.isEmpty, !store.loading {
                        ContentUnavailableView("No Upcoming Concerts", systemImage: "music.mic",
                                               description: Text(artists.isEmpty
                                                   ? "Follow some artists or play some songs, and their concerts will show here."
                                                   : "None of your artists have announced concerts in \(store.location?.countryName ?? "this country") yet."))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(groups) { group in
                        ConcertGroupView(group: group)
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .navigationTitle("Concerts")
        .navigationSubtitle(store.location.map { "Near \($0.title)" } ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Picker("Order", selection: $store.order) {
                    ForEach(ConcertRanking.Order.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(store.location == nil)
                Button {
                    Task { await store.refresh(artists: artists, force: true, applePictures: model.settings.appleArtistImages) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.loading || store.location == nil)
                .help("Look for new concerts")
            }
        }
        .task(id: store.location) { await store.refresh(artists: artists, applePictures: model.settings.appleArtistImages) }
        .sheet(isPresented: $addingKey) { TicketmasterKeySheet() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { choosingPlace = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "location.fill").foregroundStyle(.tint)
                    Text(store.location?.title ?? "Choose a Location").fontWeight(.semibold)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .help("Change where concerts are looked for")
            .popover(isPresented: $choosingPlace, arrowEdge: .bottom) {
                LocationPicker { place in
                    store.location = place
                    choosingPlace = false
                }
            }
            if store.loading {
                ProgressView().controlSize(.small)
                if let progress = store.progress, progress.total > 0 {
                    // Both sources count each artist, so a share reads better than "n of m".
                    Text(progress.done >= progress.total ? "Finishing…" : "Checking your artists… \(progress.done * 100 / progress.total)%")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var keyBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "ticket").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Add official listings").font(.headline)
                Text("Concerts here come from MusicBrainz, which misses many shows. A free Ticketmaster key adds official listings with tickets and line-ups for the UK, Ireland, Europe, North America, Australia and New Zealand.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Add Key…") { addingKey = true }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 24)
    }
}

/// A titled band of concerts ("In and around London") as a grid of cards.
struct ConcertGroupView: View {
    let group: ConcertRanking.Group

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.title).font(.title2.bold())
                Text("\(group.concerts.count)").font(.title3).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 24)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
                ForEach(group.concerts) { ConcertCard(concert: $0) }
            }
            .padding(.horizontal, 24)
        }
    }
}

/// A concert as a card: its picture with the date on it, then who, where and how far.
struct ConcertCard: View {
    let concert: Concert
    @Environment(AppModel.self) private var model
    @ViewState private var hovering = false

    var body: some View {
        Button {
            model.push(.concert(concert.id))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    FillImage(url: ConcertStore.shared.image(for: concert), alignment: .top, findFaces: concert.imageURL == nil)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12).fill(.black.opacity(hovering ? 0.12 : 0))
                        }
                    DateTile(concert: concert, compact: true)
                        .padding(10)
                    if let badge = ConcertStatusBadge.text(concert) {
                        ConcertStatusBadge(text: badge, concert: concert)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .topTrailing)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(concert.headline).font(.headline).lineLimit(1)
                    Text([concert.venue.name, concert.venue.city].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Text(ConcertFormat.cardDetail(concert))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(concert.name) — \(ConcertFormat.longDate(concert))")
        .accessibilityElement(children: .combine)
    }
}

/// The day of a concert as a little calendar page: month, day, weekday.
struct DateTile: View {
    let concert: Concert
    var compact = false

    var body: some View {
        let parts = ConcertFormat.dateParts(concert)
        VStack(spacing: 0) {
            Text(parts.month).font(.system(size: compact ? 10 : 12, weight: .bold)).foregroundStyle(.red)
            Text(parts.day).font(.system(size: compact ? 22 : 30, weight: .bold)).monospacedDigit()
            Text(parts.weekday).font(.system(size: compact ? 10 : 12, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(width: compact ? 48 : 64, height: compact ? 58 : 76)
        .glassEffect(.regular, in: .rect(cornerRadius: compact ? 10 : 14))
        .accessibilityLabel(ConcertFormat.longDate(concert))
    }
}

struct ConcertStatusBadge: View {
    let text: String
    let concert: Concert

    static func text(_ concert: Concert) -> String? {
        switch concert.status {
        case .scheduled: nil
        case .onSaleSoon: "On sale soon"
        case .cancelled: "Cancelled"
        case .postponed: "Postponed"
        case .rescheduled: "Rescheduled"
        }
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(Capsule().fill(concert.status == .onSaleSoon ? Color.blue : Color.orange))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }
}

// MARK: - Choosing a place

/// Typing a place with Apple Maps' suggestions. Picking one sets where concerts are looked for.
struct LocationPicker: View {
    let chosen: (ConcertLocation) -> Void
    @ViewState private var search = LocationSearch()
    @ViewState private var resolving: String?
    @ViewState private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where should concerts be?").font(.headline)
            TextField("City, region or country", text: $search.query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { Task { await pickTyped() } }
            if failed {
                Text("Couldn't find that place. Try a city, county, state or country.").font(.caption).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(search.suggestions) { suggestion in
                    Button {
                        Task {
                            resolving = suggestion.id
                            defer { resolving = nil }
                            if let place = await search.resolve(suggestion) { chosen(place) } else { failed = true }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "mappin.circle").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.title).lineLimit(1)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if resolving == suggestion.id { ProgressView().controlSize(.small) }
                        }
                        .padding(.vertical, 5)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("A city shows its own concerts first, then those a short trip away, then the rest of the country. Only the country is sent to Ticketmaster; distances are worked out on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { focused = true }
    }

    private func pickTyped() async {
        let text = search.query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        failed = false
        if let place = await LocationSearch.resolve(text) { chosen(place) } else { failed = true }
    }
}

// MARK: - A concert

/// Everything about one concert: when, where, tickets, the event's website and the line-up,
/// each artist linking to their page here so they can be listened to.
struct ConcertDetailView: View {
    let id: String
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let concert = ConcertStore.shared.concert(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    hero(concert)
                    actions(concert)
                    details(concert)
                    lineUp(concert)
                    Text(concert.source == "ticketmaster"
                         ? "Listing from Ticketmaster. Tickets are sold by \(concert.ticketSeller ?? "Ticketmaster"), not by Metrolist+."
                         : "Listing from MusicBrainz, entered by its volunteers. Check the date with the venue before you travel.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
            }
            .ignoresSafeArea(edges: .top)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationTitle(concert.headline)
            .task(id: id) {
                // MusicBrainz links are fetched on opening; a picture if the list had none.
                await ConcertStore.shared.completeLinks(id)
                await ConcertStore.shared.findPictures(for: [concert], apple: model.settings.appleArtistImages)
            }
        } else {
            ContentUnavailableView("Concert Not Found", systemImage: "ticket", description: Text("Its listing has expired. Go back to Concerts and refresh."))
        }
    }

    private func hero(_ concert: Concert) -> some View {
        ZStack(alignment: .bottomLeading) {
            FillImage(url: ConcertStore.shared.image(for: concert), alignment: .top, findFaces: concert.imageURL == nil)
            LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.35), .init(color: .black.opacity(0.8), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: 16) {
                DateTile(concert: concert)
                VStack(alignment: .leading, spacing: 4) {
                    if let badge = ConcertStatusBadge.text(concert) { ConcertStatusBadge(text: badge, concert: concert) }
                    Text(concert.title)
                        .font(.system(size: 34, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    Text("\(ConcertFormat.longDate(concert)) · \(concert.venue.name)")
                        .font(.title3)
                        .opacity(0.85)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            }
            .padding(24)
        }
        .frame(height: 340)
        .clipped()
    }

    private func actions(_ concert: Concert) -> some View {
        HStack(spacing: 10) {
            if let tickets = concert.ticketURL.flatMap(URL.init(string:)), concert.status != .cancelled {
                Button {
                    openURL(tickets)
                } label: {
                    Label(concert.status == .onSaleSoon ? "Ticket Details" : "Get Tickets", systemImage: "ticket.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .help("Opens \(concert.ticketSeller ?? "the ticket seller")'s official page")
            }
            if let website = concert.websiteURL.flatMap(URL.init(string:)) {
                Button { openURL(website) } label: { Label("Event Website", systemImage: "safari") }
                    .buttonStyle(.glass).controlSize(.large)
            }
            Button { ConcertCalendar.add(concert) } label: { Label("Add to Calendar", systemImage: "calendar.badge.plus") }
                .buttonStyle(.glass).controlSize(.large)
            if let maps = ConcertFormat.mapsURL(concert.venue) {
                Button { openURL(maps) } label: { Label("Directions", systemImage: "map") }
                    .buttonStyle(.glass).controlSize(.large)
            }
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 24)
    }

    private func details(_ concert: Concert) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Date", ConcertFormat.longDate(concert), "calendar")
            row("Time", ConcertFormat.time(concert), "clock")
            row("Venue", [concert.venue.name, concert.venue.address?.isEmpty == false ? concert.venue.address : concert.venue.place].compactMap { $0 }.joined(separator: "\n"), "building.columns")
            if let distance = concert.distanceKm ?? ConcertStore.shared.distance(to: concert), let location = ConcertStore.shared.location {
                row("Distance", "\(Geo.describe(distance)) from \(location.name)", "location")
            }
            if let price = concert.priceRange { row("Prices", price + " (set by the seller; fees may apply)", "sterlingsign.circle") }
            if let onSale = concert.onSale { row("On sale", onSale.formatted(date: .complete, time: .shortened), "bell") }
            if let notes = concert.notes, !notes.isEmpty { row("Good to know", notes, "info.circle") }
        }
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 24)
    }

    private func row(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(title).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func lineUp(_ concert: Concert) -> some View {
        if !concert.performers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Line-up").font(.title2.bold()).padding(.horizontal, 24)
                VStack(spacing: 0) {
                    ForEach(Array(concert.performers.enumerated()), id: \.element.id) { index, performer in
                        PerformerRow(performer: performer, role: index == 0 ? "Headliner" : "Also playing",
                                     image: performer.imageURL ?? ConcertStore.shared.artistImages[ArtistName.key(performer.name)])
                        if index < concert.performers.count - 1 { Divider().padding(.leading, 76) }
                    }
                }
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 24)
            }
        }
    }
}

/// One artist on the bill: their page here, and a button to listen to them.
private struct PerformerRow: View {
    let performer: ConcertPerformer
    let role: String
    let image: String?
    @Environment(AppModel.self) private var model
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: image, size: 48, circular: true)
            VStack(alignment: .leading, spacing: 2) {
                Button { model.openArtist(ArtistRef(name: performer.name, id: performer.channelId)) } label: {
                    Text(performer.name).font(.headline).underline(hovering)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .pointerStyle(.link)
                .help("Go to \(performer.name)")
                Text(role).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { listen() } label: { Label("Listen", systemImage: "play.fill") }
                .buttonStyle(.glass)
                .help("Play \(performer.name)")
            Button { model.openArtist(ArtistRef(name: performer.name, id: performer.channelId)) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Go to \(performer.name)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func listen() {
        if let id = performer.channelId {
            model.play(.artist(ArtistItem(id: id, title: performer.name)))
            return
        }
        Task {
            let results = try? await YTMusic.search(performer.name, filter: .artists)
            let match = results?.sections.flatMap(\.items).compactMap { item -> ArtistItem? in
                if case .artist(let found) = item, ArtistName.same(found.title, performer.name) { found } else { nil }
            }.first
            if let match { model.play(.artist(match)) } else { model.openArtist(ArtistRef(name: performer.name, id: nil)) }
        }
    }
}

// MARK: - On an artist's page

/// An artist's upcoming concerts on their page: those in the chosen country first.
struct ArtistConcertsSection: View {
    let artist: ConcertArtist
    @Environment(AppModel.self) private var model
    @ViewState private var tour: [Concert]?
    @ViewState private var showingAll = false

    private var ordered: [Concert] {
        guard let tour else { return [] }
        guard let location = ConcertStore.shared.location else { return tour }
        let near = ConcertRanking.located(tour, near: location).sorted { ($0.distanceKm ?? .infinity, $0.start) < ($1.distanceKm ?? .infinity, $1.start) }
        let nearIds = Set(near.map(\.id))
        return near + tour.filter { !nearIds.contains($0.id) }
    }

    var body: some View {
        Group {
            if !ordered.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Concerts").font(.title2.bold())
                        if let location = ConcertStore.shared.location {
                            Text("nearest to \(location.name) first").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if ordered.count > 4 {
                            Button(showingAll ? "Show Fewer" : "Show All (\(ordered.count))") { withAnimation(.snappy) { showingAll.toggle() } }
                                .buttonStyle(.link)
                        }
                    }
                    .padding(.horizontal, 24)
                    VStack(spacing: 0) {
                        let shown = showingAll ? ordered : Array(ordered.prefix(4))
                        ForEach(shown) { concert in
                            ConcertRow(concert: concert)
                            if concert.id != shown.last?.id { Divider().padding(.leading, 82) }
                        }
                    }
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 24)
                }
            }
        }
        .task(id: artist) { tour = await ConcertStore.shared.tour(of: artist) }
    }
}

/// A concert as a row: date tile, venue and city, distance, then a chevron to its page.
struct ConcertRow: View {
    let concert: Concert
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.push(.concert(concert.id)) } label: {
            HStack(spacing: 14) {
                DateTile(concert: concert, compact: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(concert.venue.name).font(.headline).lineLimit(1)
                    Text([concert.venue.place, ConcertFormat.time(concert)].filter { !$0.isEmpty }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let badge = ConcertStatusBadge.text(concert) { ConcertStatusBadge(text: badge, concert: concert) }
                if let distance = concert.distanceKm ?? ConcertStore.shared.distance(to: concert) {
                    Text(Geo.describe(distance)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The Ticketmaster key

/// Getting and saving a free Ticketmaster key, step by step.
struct TicketmasterKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var key = ""
    @ViewState private var checking = false
    @ViewState private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Ticketmaster Key", systemImage: "ticket").font(.title2.bold())
            Text("Official concert listings come from Ticketmaster's free developer service. The key is free: no payment details are needed and it allows 5,000 lookups a day.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Create a free account at developer.ticketmaster.com.")
                step(2, "Open My Apps; an app with a key is made for you.")
                step(3, "Copy its Consumer Key and paste it below.")
            }
            Link("Open developer.ticketmaster.com", destination: Ticketmaster.signUpPage)
            SecureField("Consumer Key", text: $key)
                .textFieldStyle(.roundedBorder)
            if let message {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            Text("The key is kept in your Keychain on this Mac and is never included in backups.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if ConcertStore.shared.hasKey {
                    Button("Remove Key", role: .destructive) {
                        ConcertStore.shared.setKey(nil)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if checking { ProgressView().controlSize(.small) } else { Text("Check and Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").font(.callout.bold()).frame(width: 20, height: 20).background(Circle().fill(.quaternary))
            Text(text)
        }
    }

    private func save() async {
        checking = true
        defer { checking = false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure = await Ticketmaster.verify(trimmed) {
            message = failure.errorDescription
            return
        }
        ConcertStore.shared.setKey(trimmed)
        dismiss()
    }
}

// MARK: - Formatting

enum ConcertFormat {
    private static func zone(_ concert: Concert) -> TimeZone { concert.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current }

    static func dateParts(_ concert: Concert) -> (month: String, day: String, weekday: String) {
        let formatter = DateFormatter()
        formatter.timeZone = zone(concert)
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        let month = formatter.string(from: concert.start).uppercased()
        formatter.setLocalizedDateFormatFromTemplate("d")
        let day = formatter.string(from: concert.start)
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return (month, day, formatter.string(from: concert.start))
    }

    /// "Saturday 5 December 2026", at the venue.
    static func longDate(_ concert: Concert) -> String {
        var style = Date.FormatStyle(date: .complete, time: .omitted)
        style.timeZone = zone(concert)
        return concert.start.formatted(style)
    }

    /// "19:30", with the listener's own time beside it when the venue is in another time zone.
    static func time(_ concert: Concert) -> String {
        guard concert.localTime != nil else { return "Time to be announced" }
        var venue = Date.FormatStyle(date: .omitted, time: .shortened)
        venue.timeZone = zone(concert)
        let there = concert.start.formatted(venue)
        guard zone(concert).secondsFromGMT(for: concert.start) != TimeZone.current.secondsFromGMT(for: concert.start) else { return there }
        let here = concert.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened))
        return "\(there) local time (\(here) your time)"
    }

    /// "19:30 · 3 km" under a card.
    static func cardDetail(_ concert: Concert) -> String {
        var parts: [String] = []
        if concert.localTime != nil { parts.append(time(concert).components(separatedBy: " local").first ?? "") }
        if let distance = concert.distanceKm { parts.append(Geo.describe(distance)) }
        if let price = concert.priceRange { parts.append(price) }
        return parts.isEmpty ? concert.venue.place : parts.joined(separator: " · ")
    }

    /// Apple Maps at the venue.
    static func mapsURL(_ venue: ConcertVenue) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")!
        var items = [URLQueryItem(name: "q", value: venue.name)]
        if let lat = venue.latitude, let lon = venue.longitude {
            items.append(URLQueryItem(name: "ll", value: "\(lat),\(lon)"))
        } else if venue.place.isEmpty {
            return nil
        } else {
            items[0] = URLQueryItem(name: "q", value: "\(venue.name), \(venue.place)")
        }
        components.queryItems = items
        return components.url
    }
}

/// Adds a concert to Calendar by handing it an event file; Calendar asks which calendar.
enum ConcertCalendar {
    static func ics(_ concert: Concert) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
        }
        let stamp = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: false)
        func utc(_ date: Date) -> String { date.formatted(stamp).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "") + "Z" }
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Metrolist+//Concerts//EN", "BEGIN:VEVENT",
                     "UID:\(concert.id)@metrolist", "DTSTAMP:\(utc(Date()))", "SUMMARY:\(escape(concert.name))",
                     "LOCATION:\(escape([concert.venue.name, concert.venue.address ?? concert.venue.place].filter { !$0.isEmpty }.joined(separator: ", ")))"]
        if concert.localTime != nil {
            lines += ["DTSTART:\(utc(concert.start))", "DTEND:\(utc(concert.start.addingTimeInterval(3 * 3600)))"]
        } else {
            let day = concert.localDate.replacingOccurrences(of: "-", with: "")
            lines += ["DTSTART;VALUE=DATE:\(day)"]
        }
        if let url = concert.ticketURL ?? concert.websiteURL { lines.append("URL:\(url)") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func add(_ concert: Concert) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(concert.title.replacingOccurrences(of: "/", with: "-")) \(concert.localDate).ics")
        guard (try? ics(concert).write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        NSWorkspace.shared.open(file)
    }
}
