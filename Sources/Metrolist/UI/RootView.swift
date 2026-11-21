import SwiftUI

/// The floating player bar plus any playback error, pinned to the bottom of a page.
struct PlayerBarInset: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            if let message = model.player.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .capsule)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(5))
                        if model.player.errorMessage == message { model.player.errorMessage = nil }
                    }
            }
            MixingBadge()
            PlayerBar()
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: model.player.errorMessage)
        .animation(.snappy, value: model.player.mixActivity != nil)
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    /// A sidebar entry. Selecting it switches section; clicking it again while it is already
    /// selected pops back to that section's first page.
    private func row(_ title: String, _ symbol: String, _ item: SidebarItem, badge: Int = 0) -> some View {
        Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .simultaneousGesture(TapGesture().onEnded {
                if model.sidebar == item, !model.path.isEmpty { model.path = [] }
            })
            .badge(badge)
            // The tag must be the outermost modifier, or the list can't select the row.
            .tag(item)
    }
    @ViewState private var creating = false
    @ViewState private var newName = ""

    var body: some View {
        let _ = Diagnostics.hit("Sidebar")
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Section {
                row("Home", "house", SidebarItem.home)
                row("Explore", "safari", SidebarItem.explore)
                row("Concerts", "ticket", SidebarItem.concerts)
                row("Shared Queue", "person.2.wave.2", SidebarItem.sharedQueue, badge: DeviceConnect.guests.connected.count)
            }

            Section("Library") {
                row("Liked Songs", "heart", SidebarItem.liked)
                row("Albums", "square.stack", SidebarItem.albums)
                row("Artists", "music.mic", SidebarItem.artists)
                row("Playlists", "music.note.list", SidebarItem.savedPlaylists)
                row("Downloads", "arrow.down.circle", SidebarItem.downloads, badge: model.media.activeDownloadCount)
                row("Music Videos", "film.stack", SidebarItem.musicVideos, badge: VideoDownloads.shared.activeCount)
                row("History", "clock", SidebarItem.history)
            }

            Section("Playlists") {
                // Local playlists and those from the YouTube Music library, in one list the
                // listener can drag into any order.
                ForEach(model.library.sidebarPlaylists) { entry in
                    switch entry {
                    case .local(let playlist):
                        row(playlist.name, model.uploadingPlaylists.contains(playlist.id) ? "arrow.triangle.2.circlepath" : "music.note.list", SidebarItem.localPlaylist(playlist.id))
                            .contextMenu {
                                Button("Play", systemImage: "play") {
                                    model.player.play(model.library.songs(playlist.songIds))
                                }
                                Button("Download", systemImage: "arrow.down.circle") {
                                    model.download(model.library.songs(playlist.songIds))
                                }
                                if model.account.isSignedIn {
                                    if playlist.remoteId == nil {
                                        Button("Add to YouTube Music", systemImage: "icloud.and.arrow.up") {
                                            Task { await model.addToYouTubeMusic(playlist.id) }
                                        }
                                        .disabled(model.uploadingPlaylists.contains(playlist.id))
                                    } else {
                                        Text("On YouTube Music")
                                    }
                                }
                                Divider()
                                Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                                    if model.sidebar == .localPlaylist(playlist.id) { model.sidebar = .liked }
                                    model.library.deletePlaylist(playlist.id)
                                }
                            }
                    case .remote(let playlist):
                        row(playlist.title, "music.note.list", SidebarItem.remotePlaylist(playlist.id))
                            .contextMenu { ItemMenu(item: .playlist(playlist)) }
                    }
                }
                .onMove { model.library.moveSidebarPlaylists(from: $0, to: $1) }
                Button {
                    newName = ""
                    creating = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        .safeAreaInset(edge: .bottom) {
            if model.account.isSyncing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Syncing library…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .alert("New Playlist", isPresented: $creating) {
            TextField("Playlist name", text: $newName)
            Button("Create") {
                let trimmed = newName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                let playlist = model.library.createPlaylist(name: trimmed)
                model.sidebar = .localPlaylist(playlist.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var suggestions: [String] = []

    var body: some View {
        let _ = Diagnostics.hit("RootView")
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } detail: {
            // The bar is attached to each page individually: anything placed around the
            // NavigationStack is dropped when a destination is pushed inside a split view.
            NavigationStack(path: $model.path) {
                rootContent
                    .safeAreaInset(edge: .bottom, spacing: 0) { PlayerBarInset() }
                    .navigationDestination(for: Route.self) { route in
                        destination(for: route)
                            .safeAreaInset(edge: .bottom, spacing: 0) { PlayerBarInset() }
                            // The full-screen player and the video player cover the page, but the
                            // page's back button lives in the title bar above them: hide it there.
                            .navigationBarBackButtonHidden(model.showExpandedPlayer)
                    }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Songs, albums, artists")
        .searchSuggestions {
            ForEach(suggestions, id: \.self) { suggestion in
                Label(suggestion, systemImage: "magnifyingglass")
                    .searchCompletion(suggestion)
            }
        }
        .onSubmit(of: .search) { model.submitSearch() }
        .task(id: model.searchText) {
            let text = model.searchText.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else {
                suggestions = []
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            if let found = try? await YTMusic.searchSuggestions(text), !Task.isCancelled {
                suggestions = Array(found.filter { $0.lowercased() != text.lowercased() }.prefix(7))
            }
        }
        .inspector(isPresented: $model.showInspector) {
            NowPlayingInspector()
                .inspectorColumnWidth(min: 280, ideal: 360, max: 520)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Left out while the full-screen player covers the window.
                if !model.showExpandedPlayer {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        model.toggleInspector(model.inspectorTab)
                    } label: {
                        Label("Now Playing", systemImage: "sidebar.trailing")
                    }
                    .help("Show or hide lyrics and Up Next")
                }
            }
        }
        // Not `.toolbar(.hidden, for: .windowToolbar)`: that also hides the traffic lights.
        .background { ImmersiveWindowChrome(immersive: model.showExpandedPlayer) }
        .overlay {
            if model.showExpandedPlayer {
                // Under the (emptied) title bar too, so the player fills the whole window.
                ExpandedPlayerView()
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: Bindable(model).showMixEditor) {
            MixEditorView().environment(model)
        }
        .modifier(PairingRequestPresenter())
        .sheet(isPresented: Bindable(model).showPlaylistImport) {
            PlaylistImportSheet().environment(model)
        }
        .sheet(isPresented: Bindable(model).showLyricsSearch) {
            LyricsSearchSheet().environment(model)
        }
        .sheet(isPresented: Bindable(model).showLyricsEditor) {
            LyricsEditorSheet().environment(model)
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .album(let id): AlbumView(browseId: id)
        case .artist(let id): ArtistView(browseId: id)
        case .playlist(let id): PlaylistView(playlistId: id)
        case .browse(let endpoint, let title): BrowseView(endpoint: endpoint, title: title)
        case .search(let query): SearchView(query: query)
        case .concert(let id): ConcertDetailView(id: id)
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        switch model.sidebar ?? .home {
        case .home:
            HomeView()
        case .explore:
            ExploreView()
        case .concerts:
            ConcertsView()
        case .sharedQueue:
            SharedQueueView()
                .navigationTitle("Shared Queue")
        case .liked:
            LikedSongsView()
        case .downloads:
            DownloadsView()
        case .musicVideos:
            MusicVideoDownloadsView()
        case .history:
            HistoryView()
        case .albums:
            LibraryGridView(title: "Albums", items: model.library.albums.map(YTItem.album), symbol: "square.stack")
        case .artists:
            LibraryGridView(title: "Artists", items: model.library.artists.map(YTItem.artist), symbol: "music.mic")
        case .savedPlaylists:
            LibraryGridView(title: "Playlists", items: model.library.savedPlaylists.map(YTItem.playlist), symbol: "music.note.list")
        case .localPlaylist(let id):
            LocalPlaylistView(playlistId: id)
        case .remotePlaylist(let id):
            PlaylistView(playlistId: id)
        }
    }
}
