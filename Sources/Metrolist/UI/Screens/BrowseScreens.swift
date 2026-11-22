import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var extra: [ItemSection] = []
    @ViewState private var continuation: String?
    @ViewState private var loadingMore = false
    @ViewState private var exhausted = false

    var body: some View {
        AsyncContent(id: model.account.isSignedIn) {
            try await YTMusic.home()
        } content: { home in
            ScrollView {
                LazyVStack(spacing: 0) {
                SectionsView(sections: home.sections + extra)
                    .padding(.vertical, 16)
                if !exhausted, (extra.isEmpty ? home.continuation : continuation) != nil {
                    ProgressView()
                        .padding()
                        .task(id: extra.isEmpty ? home.continuation : continuation) { loadMore(from: extra.isEmpty ? home.continuation : continuation) }
                }
                }
            }
        }
        .navigationTitle("Home")
    }

    private func loadMore(from token: String?) {
        guard let token, !loadingMore else { return }
        loadingMore = true
        Task {
            defer { loadingMore = false }
            guard let page = try? await YTMusic.home(continuation: token), !page.sections.isEmpty else {
                exhausted = true
                return
            }
            extra += page.sections
            continuation = page.continuation
            exhausted = page.continuation == nil
        }
    }
}

struct ExploreView: View {
    var body: some View {
        AsyncContent(id: "explore") {
            async let explore = YTMusic.explore()
            async let charts = YTMusic.charts()
            let first = try await explore
            return first + ((try? await charts) ?? [])
        } content: { sections in
            ScrollView {
                SectionsView(sections: sections)
                    .padding(.vertical, 16)
            }
        }
        .navigationTitle("Explore")
    }
}

/// A generic "See All" destination.
struct BrowseView: View {
    let endpoint: BrowseEndpoint
    let title: String

    var body: some View {
        AsyncContent(id: endpoint) {
            try await YTMusic.sections(for: endpoint)
        } content: { sections in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(sections) { section in
                        if section.isList {
                            SectionView(section: section)
                        } else {
                            if !section.title.isEmpty {
                                Text(section.title).font(.title2.bold()).padding(.horizontal, 24)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
                                ForEach(section.items) { ItemCard(item: $0) }
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .navigationTitle(title)
    }
}

struct SearchView: View {
    let query: String
    @Environment(AppModel.self) private var model
    @ViewState private var filter: SearchFilter = .all
    @ViewState private var extra: [YTItem] = []
    @ViewState private var continuation: String?
    @ViewState private var loadingMore = false
    @ViewState private var exhausted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.allCases) { option in
                    if option == filter {
                        Button(option.title) { filter = option }
                            .buttonStyle(.glassProminent)
                    } else {
                        Button(option.title) { filter = option }
                            .buttonStyle(.glass)
                    }
                }
                Spacer()
            }
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)

            AsyncContent(id: [query, filter.rawValue]) {
                try await YTMusic.search(query, filter: filter)
            } content: { results in
                ScrollView {
                    if results.sections.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .padding(.top, 80)
                    } else if filter == .all {
                        SectionsView(sections: results.sections)
                            .padding(.vertical, 12)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(results.sections.flatMap(\.items) + extra) { ItemRow(item: $0) }
                            if !exhausted, (extra.isEmpty ? results.continuation : continuation) != nil {
                                ProgressView()
                                    .padding()
                                    .task(id: extra.isEmpty ? results.continuation : continuation) { loadMore(from: extra.isEmpty ? results.continuation : continuation) }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .navigationTitle("“\(query)”")
        .onChange(of: filter) {
            extra = []
            continuation = nil
            exhausted = false
        }
    }

    private func loadMore(from token: String?) {
        guard let token, !loadingMore else { return }
        loadingMore = true
        let activeFilter = filter
        Task {
            defer { loadingMore = false }
            let page = try? await YTMusic.search(query, filter: activeFilter, continuation: token)
            guard activeFilter == filter else { return }
            let items = page?.sections.flatMap(\.items) ?? []
            extra += items
            continuation = page?.continuation
            exhausted = items.isEmpty || page?.continuation == nil
        }
    }
}

struct AlbumView: View {
    let browseId: String
    @Environment(AppModel.self) private var model
    /// Apple Music's animated cover for this album, when that setting is on and one exists.
    @ViewState private var motion: URL?

    var body: some View {
        AsyncContent(id: browseId) {
            try await YTMusic.album(browseId)
        } content: { page in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(
                        artwork: page.album.thumbnail,
                        kind: "Album",
                        title: page.album.title,
                        subtitle: "",
                        artists: page.album.artists,
                        description: page.subtitle,
                        motion: model.settings.animatedAlbumCovers ? motion : nil,
                        details: songSummary(page.songs)
                    ) {
                        CollectionActions(item: .album(page.album), songs: page.songs)
                    }
                    // No filter field here: albums, EPs and singles are short. Playlists have one.
                    SongList(songs: page.songs, numbered: true, showArtwork: false, showAlbum: false)
                        .padding(.horizontal, 14)
                    if let description = page.description, !description.isEmpty {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 24)
                    }
                    SectionsView(sections: page.sections)
                }
                .padding(.bottom, 16)
                .background(alignment: .top) { ArtworkBackdrop(url: page.album.thumbnail) }
            }
            .navigationTitle(page.album.title)
            .task(id: "\(browseId)|\(model.settings.animatedAlbumCovers)") {
                motion = nil
                guard model.settings.animatedAlbumCovers else { return }
                // Soundtracks and compilations often have no album artist on YouTube Music.
                let artist = page.album.artists.first?.name ?? "Various Artists"
                motion = await AppleMusicArtwork.shared.album(title: page.album.title, artist: artist)?.video
            }
        }
    }
}

/// Audio releases found for a playlist's music videos (video id → song), observed by the page.
@MainActor
@Observable
final class AudioSwaps {
    private(set) var found: [String: Song] = [:]
    @ObservationIgnored private var asked: Set<String> = []

    /// Starts looking up audio releases for these songs, and returns once the first rows are
    /// answered or `maxWait` has passed, whichever is sooner; the rest keep arriving.
    func start(playlistId: String, songs: [Song], firstRows: Int, maxWait: Double) async {
        let videos = songs.filter { $0.isVideo && !asked.contains($0.id) }
        guard !videos.isEmpty else { return }
        asked.formUnion(videos.map(\.id))
        let first = Set(videos.prefix(firstRows).map(\.id))
        let ready = AsyncStream<Void>.makeStream()
        var answered = Set<String>()
        Task {
            await YTMusic.audioVersions(forPlaylist: playlistId, videos: videos) { [weak self] answers in
                self?.found.merge(answers.compactMapValues { $0 }) { $1 }
                answered.formUnion(answers.keys)
                if first.isSubset(of: answered) { ready.continuation.yield() }
            }
            ready.continuation.finish()
        }
        Task {
            try? await Task.sleep(for: .seconds(maxWait))
            ready.continuation.finish()
        }
        for await _ in ready.stream { break }
    }
}

struct PlaylistView: View {
    let playlistId: String
    @Environment(AppModel.self) private var model
    @ViewState private var extra: [Song] = []
    @ViewState private var continuation: String?
    @ViewState private var loadingMore = false
    @ViewState private var exhausted = false
    @ViewState private var filter = ""
    /// Audio releases found for the playlist's music videos.
    @ViewState private var swaps = AudioSwaps()

    /// With "Prefer audio versions" on, music videos are shown (and played) as their audio
    /// release. The page waits up to this long for the first rows' answers, so they don't
    /// visibly change after appearing; later rows are swapped as answers arrive.
    private static let firstRows = 15
    private static let maxWait = 1.2

    var body: some View {
        AsyncContent(id: playlistId) {
            let page = try await YTMusic.playlist(playlistId)
            await prepareAudioVersions(for: page.songs)
            return page
        } content: { page in
            let all = (page.songs + extra).map { swaps.found[$0.id] ?? $0 }
            let text = filter.trimmingCharacters(in: .whitespaces)
            let songs = text.isEmpty ? all : all.filter { $0.matchesFilter(text) }
            let more = !exhausted && (extra.isEmpty ? page.continuation : continuation) != nil
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(
                        artwork: page.playlist.thumbnail,
                        kind: "Playlist",
                        title: page.playlist.title,
                        subtitle: [page.playlist.author, page.playlist.subtitle].compactMap { $0 }.joined(separator: " • "),
                        description: page.description
                    ) {
                        CollectionActions(item: .playlist(page.playlist), songs: all)
                        Button("Save as Local Playlist", systemImage: "square.and.arrow.down.on.square") {
                            Task {
                                let everything = ((try? await YTMusic.allPlaylistSongs(playlistId)) ?? all).map { swaps.found[$0.id] ?? $0 }
                                let created = model.library.createPlaylist(name: page.playlist.title, songs: everything)
                                model.sidebar = .localPlaylist(created.id)
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .help("Save a copy as a local playlist")
                    }
                    if !all.isEmpty {
                        // The count is of the songs loaded so far until the whole list is in;
                        // typing a filter loads the rest.
                        FilterField(text: $filter, shown: songs.count, total: all.count, loading: !text.isEmpty && more)
                            .padding(.horizontal, 24)
                    }
                    LazyVStack(spacing: 0) {
                        SongList(songs: songs)
                        if more {
                            ProgressView()
                                .padding()
                                .task(id: extra.isEmpty ? page.continuation : continuation) { loadMore(from: extra.isEmpty ? page.continuation : continuation) }
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 16)
                .background(alignment: .top) { ArtworkBackdrop(url: page.playlist.thumbnail) }
            }
            .navigationTitle(page.playlist.title)
            .task(id: text.isEmpty ? "" : "filter") {
                // A filter covers the whole playlist: fetch what isn't loaded yet.
                guard !text.isEmpty else { return }
                while !exhausted, let token = extra.isEmpty ? page.continuation : continuation, !Task.isCancelled {
                    if loadingMore { try? await Task.sleep(for: .milliseconds(100)); continue }
                    await loadPage(token)
                }
            }
        }
    }

    private func prepareAudioVersions(for songs: [Song]) async {
        guard model.settings.preferAudioVersions else { return }
        await swaps.start(playlistId: playlistId, songs: songs, firstRows: Self.firstRows, maxWait: Self.maxWait)
    }

    private func loadMore(from token: String?) {
        guard let token, !loadingMore else { return }
        Task { await loadPage(token) }
    }

    private func loadPage(_ token: String) async {
        guard !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let next = try? await YTMusic.playlistContinuation(token), !next.songs.isEmpty else {
            exhausted = true
            return
        }
        extra += next.songs
        continuation = next.continuation
        exhausted = next.continuation == nil
        Task { await prepareAudioVersions(for: next.songs) }
    }
}

struct ArtistView: View {
    let browseId: String
    @Environment(AppModel.self) private var model

    var body: some View {
        AsyncContent(id: browseId) {
            try await YTMusic.artist(browseId)
        } content: { page in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ArtistHero(page: page)
                    if let description = page.description, !description.isEmpty {
                        ExpandableText(text: description, title: "About \(page.artist.title)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 720, alignment: .leading)
                            .padding(.horizontal, 24)
                    }
                    ArtistConcertsSection(artist: ConcertArtist(name: page.artist.title, channelId: browseId.hasPrefix("UC") ? browseId : nil, thumbnail: page.artist.thumbnail))
                    SectionsView(sections: page.sections)
                }
                .padding(.bottom, 16)
            }
            .ignoresSafeArea(edges: .top)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationTitle(page.artist.title)
        }
    }
}

/// The top of an artist page, laid out as in Apple Music for macOS: a full-width picture
/// (Apple Music's artist picture or animated picture when those settings are on, otherwise
/// YouTube Music's banner), darkened at the bottom, with the name in large type over it,
/// a round play button beside it and the other actions on the right.
struct ArtistHero: View {
    let page: ArtistPage
    @Environment(AppModel.self) private var model
    @ViewState private var apple: AppleMusicArtwork.ArtistArt?
    @ViewState private var videoReady = false

    private var settings: AppSettings { model.settings }

    /// Apple's wide banner fits the header as it is; a square portrait (Apple's or
    /// YouTube's) is cropped around the faces in it.
    private var picture: (url: String?, banner: Bool) {
        if settings.appleArtistImages, let banner = apple?.banner { return (banner.absoluteString, true) }
        if settings.appleArtistImages, let image = apple?.image { return (image.absoluteString, false) }
        return (page.artist.thumbnail, false)
    }

    private var video: URL? { settings.animatedArtistArtwork ? apple?.video : nil }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .bottomLeading) {
                FillImage(url: picture.url, alignment: picture.banner ? .center : .top, findFaces: !picture.banner)
                if let video {
                    LoopingVideoView(url: video) { videoReady = true }
                        .allowsHitTesting(false)
                }
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.35), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .clear, location: 0.5),
                    .init(color: .black.opacity(0.75), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

                HStack(alignment: .center, spacing: 16) {
                    Button {
                        model.play(.artist(page.artist))
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Color.accentColor))
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .help("Play")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.artist.title)
                            .font(.system(size: min(56, max(30, geometry.size.width / 18)), weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
                            .textSelection(.enabled)
                        if let subscribers = page.artist.subtitle {
                            Text("\(subscribers) subscribers")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    Spacer(minLength: 12)
                    actions
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
            }
            .frame(width: geometry.size.width, height: height)
            .clipped()
        }
        .frame(height: 400)
        .environment(\.colorScheme, .dark)
        .task(id: "\(page.artist.title)|\(settings.appleArtistImages)|\(settings.animatedArtistArtwork)") {
            videoReady = false
            guard settings.appleArtistImages || settings.animatedArtistArtwork else { apple = nil; return }
            apple = await AppleMusicArtwork.shared.artist(named: page.artist.title, includeVideo: settings.animatedArtistArtwork)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                model.play(.artist(page.artist), shuffled: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            if let radio = page.radioPlaylistId {
                Button {
                    Task {
                        if let queue = try? await YTMusic.queue(playlistId: radio) { model.player.play(queue.songs) }
                    }
                } label: {
                    Label("Radio", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            Button {
                model.library.toggleSaved(.artist(page.artist))
            } label: {
                Image(systemName: model.library.isSaved(.artist(page.artist)) ? "checkmark" : "plus")
            }
            .help(model.library.isSaved(.artist(page.artist)) ? "Remove from Library" : "Add to Library")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.glass)
        .controlSize(.large)
        .fixedSize()
    }
}
