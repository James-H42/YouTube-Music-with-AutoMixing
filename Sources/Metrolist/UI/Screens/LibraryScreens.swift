import SwiftUI

/// Header and song list shared by the local library screens.
struct LocalSongsScreen<Extra: View>: View {
    let title: String
    let kind: String
    let symbol: String
    let tint: Color
    let songs: [Song]
    var emptyTitle = "Nothing Here Yet"
    var emptyMessage = ""
    var localPlaylistId: String?
    var playsVideos = false
    @ViewBuilder var extraActions: () -> Extra

    @Environment(AppModel.self) private var model
    @ViewState private var filter = ""

    private var visible: [Song] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return songs }
        return songs.filter { $0.matchesFilter(text) }
    }

    private var totalDuration: String {
        let seconds = songs.reduce(0) { $0 + ($1.duration ?? 0) }
        guard seconds > 0 else { return "" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? " • \(hours) hr \(minutes) min" : " • \(minutes) min"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom, spacing: 24) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: 150, height: 150)
                        .overlay {
                            Image(systemName: symbol)
                                .font(.system(size: 56, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: tint.opacity(0.35), radius: 14, y: 6)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(kind.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(title)
                            .font(.system(size: 34, weight: .bold))
                            .lineLimit(2)
                        Text("\(songs.count) song\(songs.count == 1 ? "" : "s")\(totalDuration)")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            CollectionActions(item: nil, songs: songs)
                            extraActions()
                        }
                        .padding(.top, 6)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                if songs.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: symbol, description: Text(emptyMessage))
                        .padding(.top, 40)
                } else {
                    FilterField(text: $filter, shown: visible.count, total: songs.count)
                        .padding(.horizontal, 24)
                    SongList(songs: visible, localPlaylistId: localPlaylistId, playsVideos: playsVideos)
                        .padding(.horizontal, 14)
                }
            }
            .padding(.bottom, 16)
        }
        .navigationTitle(title)
    }
}

extension LocalSongsScreen where Extra == EmptyView {
    init(title: String, kind: String, symbol: String, tint: Color, songs: [Song], emptyTitle: String = "Nothing Here Yet", emptyMessage: String = "") {
        self.init(title: title, kind: kind, symbol: symbol, tint: tint, songs: songs, emptyTitle: emptyTitle, emptyMessage: emptyMessage, localPlaylistId: nil) { EmptyView() }
    }
}

struct LikedSongsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LocalSongsScreen(
            title: "Liked Songs", kind: "Library", symbol: "heart.fill", tint: .pink,
            songs: model.library.likedSongs,
            emptyTitle: "No Liked Songs",
            emptyMessage: "Songs you like appear here."
        )
    }
}

struct DownloadsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let songs = model.library.songs(model.media.downloadedIds.filter { !model.media.isVideoDownload($0) })
        LocalSongsScreen(
            title: "Downloads", kind: "Available Offline", symbol: "arrow.down.circle.fill", tint: .blue,
            songs: songs,
            emptyTitle: "No Downloads",
            emptyMessage: "Download songs, albums or playlists to listen without an internet connection."
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.media.activeDownloadCount > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(model.media.activeDownloadCount) song\(model.media.activeDownloadCount == 1 ? "" : "s")…")
                        .font(.callout)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
            }
        }
    }
}

/// Downloaded music videos and live performances, kept apart from downloaded songs.
struct MusicVideoDownloadsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let videos = VideoDownloads.shared
        let songs = model.library.songs(model.media.downloadedIds.filter { model.media.isVideoDownload($0) })
        let missing = songs.filter { !videos.isDownloaded($0.id) && !videos.isDownloading($0.id) }
        LocalSongsScreen(
            title: "Music Videos", kind: "Available Offline", symbol: "film.stack.fill", tint: .pink,
            songs: songs,
            emptyTitle: "No Music Videos",
            emptyMessage: "Download a music video or live performance to watch it without an internet connection.",
            localPlaylistId: nil,
            playsVideos: true
        ) {
            if !missing.isEmpty {
                // Saved before pictures were kept, or the picture failed: fetch just those.
                Button("Download Pictures", systemImage: "film") { missing.forEach { videos.download($0.id) } }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .help("\(missing.count) of these have only their sound saved")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if videos.activeCount > 0 {
                let total = videos.progress.values.reduce(0, +) / Double(max(1, videos.activeCount))
                HStack(spacing: 8) {
                    ProgressView(value: total).controlSize(.small).frame(width: 80)
                    Text("Downloading \(videos.activeCount) video\(videos.activeCount == 1 ? "" : "s")…")
                        .font(.callout)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .padding(.top, 8)
            }
        }
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LocalSongsScreen(
            title: "History", kind: "Recently Played", symbol: "clock.fill", tint: .indigo,
            songs: model.library.history,
            emptyTitle: "No History",
            emptyMessage: "Songs you play appear here.",
            localPlaylistId: nil
        ) {
            Button("Clear", systemImage: "trash") { model.library.clearHistory() }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(model.library.history.isEmpty)
        }
    }
}

struct LocalPlaylistView: View {
    let playlistId: String
    @Environment(AppModel.self) private var model
    @ViewState private var renaming = false
    @ViewState private var name = ""

    var body: some View {
        if let playlist = model.library.playlist(playlistId) {
            LocalSongsScreen(
                title: playlist.name, kind: "Playlist", symbol: "music.note.list", tint: .orange,
                songs: model.library.songs(playlist.songIds),
                emptyTitle: "Empty Playlist",
                emptyMessage: "Right-click any song and choose Add to Playlist.",
                localPlaylistId: playlist.id
            ) {
                Menu {
                    Button("Rename…", systemImage: "pencil") {
                        name = playlist.name
                        renaming = true
                    }
                    Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                        model.sidebar = .liked
                        model.library.deletePlaylist(playlist.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .alert("Rename Playlist", isPresented: $renaming) {
                TextField("Name", text: $name)
                Button("Rename") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { model.library.renamePlaylist(playlist.id, to: trimmed) }
                }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("Playlist Not Found", systemImage: "music.note.list")
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, artist, year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: "Recently Added"
        case .title: "Title"
        case .artist: "Artist"
        case .year: "Year"
        }
    }
}

/// Grid of saved albums, artists or playlists, with a remembered sort order per section.
struct LibraryGridView: View {
    let title: String
    let items: [YTItem]
    let symbol: String

    @AppStorage private var sortRaw: String
    @AppStorage private var descending: Bool
    @ViewState private var filter = ""

    init(title: String, items: [YTItem], symbol: String) {
        self.title = title
        self.items = items
        self.symbol = symbol
        _sortRaw = AppStorage(wrappedValue: LibrarySort.recent.rawValue, "librarySort.\(title)")
        _descending = AppStorage(wrappedValue: false, "librarySortDescending.\(title)")
    }

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .recent }

    /// "album", "artist" or "playlist", for the count beside the filter.
    private var noun: String { String(title.lowercased().dropLast(title.hasSuffix("s") ? 1 : 0)) }

    /// Sort keys that make sense for what this grid shows.
    private var options: [LibrarySort] {
        switch items.first {
        case .album: [.recent, .title, .artist, .year]
        case .playlist: [.recent, .title, .artist]
        default: [.recent, .title]
        }
    }

    private func artistKey(_ item: YTItem) -> String {
        switch item {
        case .album(let album): album.artists.first?.name ?? ""
        case .playlist(let playlist): playlist.author ?? ""
        default: ""
        }
    }

    private func yearKey(_ item: YTItem) -> String {
        if case .album(let album) = item { return album.year ?? "" }
        return ""
    }

    /// Ignores a leading "The" so "The Beatles" files under B.
    private func sortName(_ text: String) -> String {
        let lowered = text.lowercased()
        return lowered.hasPrefix("the ") ? String(lowered.dropFirst(4)) : lowered
    }

    private var visible: [YTItem] {
        var result = items
        let text = filter.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(text) || $0.subtitle.localizedCaseInsensitiveContains(text)
            }
        }
        let byTitle: (YTItem, YTItem) -> Bool = {
            sortName($0.title).localizedStandardCompare(sortName($1.title)) == .orderedAscending
        }
        switch sort {
        case .recent:
            break
        case .title:
            result.sort(by: byTitle)
        case .artist:
            result.sort {
                // Within one artist, follow the discography: oldest release first.
                let order = sortName(artistKey($0)).localizedStandardCompare(sortName(artistKey($1)))
                if order != .orderedSame { return order == .orderedAscending }
                return yearKey($0) == yearKey($1) ? byTitle($0, $1) : yearKey($0) < yearKey($1)
            }
        case .year:
            result.sort { yearKey($0) == yearKey($1) ? byTitle($0, $1) : yearKey($0) < yearKey($1) }
        }
        return descending ? result.reversed() : result
    }

    var body: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView("No \(title)", systemImage: symbol, description: Text("Use the + button on any page to add it to your library."))
                    .padding(.top, 120)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
                    ForEach(visible) { ItemCard(item: $0) }
                }
                .padding(24)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(items.isEmpty ? "" : filter.isEmpty ? "\(items.count) \(noun)\(items.count == 1 ? "" : "s")" : FilterCount.text(shown: visible.count, total: items.count, noun: noun))
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                HStack(spacing: 6) {
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    if !filter.isEmpty {
                        Text(FilterCount.text(shown: visible.count, total: items.count, noun: noun))
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                Menu {
                    Picker("Sort By", selection: $sortRaw) {
                        ForEach(options) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle(sort == .recent ? "Oldest First" : "Reverse Order", isOn: $descending)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort \(title.lowercased())")
            }
        }
    }
}
