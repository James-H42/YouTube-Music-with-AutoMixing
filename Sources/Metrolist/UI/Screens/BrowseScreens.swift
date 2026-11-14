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
                        description: page.subtitle
                    ) {
                        CollectionActions(item: .album(page.album), songs: page.songs)
                    }
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
        }
    }
}

struct PlaylistView: View {
    let playlistId: String
    @Environment(AppModel.self) private var model
    @ViewState private var extra: [Song] = []
    @ViewState private var continuation: String?
    @ViewState private var loadingMore = false
    @ViewState private var exhausted = false

    var body: some View {
        AsyncContent(id: playlistId) {
            try await YTMusic.playlist(playlistId)
        } content: { page in
            let songs = page.songs + extra
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(
                        artwork: page.playlist.thumbnail,
                        kind: "Playlist",
                        title: page.playlist.title,
                        subtitle: [page.playlist.author, page.playlist.subtitle].compactMap { $0 }.joined(separator: " • "),
                        description: page.description
                    ) {
                        CollectionActions(item: .playlist(page.playlist), songs: songs)
                        Button("Save as Local Playlist", systemImage: "square.and.arrow.down.on.square") {
                            Task {
                                let all = (try? await YTMusic.allPlaylistSongs(playlistId)) ?? songs
                                let created = model.library.createPlaylist(name: page.playlist.title, songs: all)
                                model.sidebar = .localPlaylist(created.id)
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .help("Save a copy as a local playlist")
                    }
                    LazyVStack(spacing: 0) {
                        SongList(songs: songs)
                        if !exhausted, (extra.isEmpty ? page.continuation : continuation) != nil {
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
        }
    }

    private func loadMore(from token: String?) {
        guard let token, !loadingMore else { return }
        loadingMore = true
        Task {
            defer { loadingMore = false }
            guard let next = try? await YTMusic.playlistContinuation(token), !next.songs.isEmpty else {
                exhausted = true
                return
            }
            extra += next.songs
            continuation = next.continuation
            exhausted = next.continuation == nil
        }
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
                    PageHeader(
                        artwork: page.artist.thumbnail,
                        circular: true,
                        kind: "Artist",
                        title: page.artist.title,
                        subtitle: page.artist.subtitle.map { "\($0) subscribers" } ?? "",
                        description: page.description
                    ) {
                        Button {
                            model.play(.artist(page.artist), shuffled: true)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(minWidth: 70)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)

                        if let radio = page.radioPlaylistId {
                            Button {
                                Task {
                                    if let queue = try? await YTMusic.queue(playlistId: radio) { model.player.play(queue.songs) }
                                }
                            } label: {
                                Label("Radio", systemImage: "dot.radiowaves.left.and.right").frame(minWidth: 70)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                        }

                        Button {
                            model.library.toggleSaved(.artist(page.artist))
                        } label: {
                            Image(systemName: model.library.isSaved(.artist(page.artist)) ? "checkmark" : "plus")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .help(model.library.isSaved(.artist(page.artist)) ? "Remove from Library" : "Add to Library")
                    }
                    SectionsView(sections: page.sections)
                }
                .padding(.bottom, 16)
                .background(alignment: .top) { ArtworkBackdrop(url: page.artist.thumbnail) }
            }
            .navigationTitle(page.artist.title)
        }
    }
}
