import SwiftUI

/// Context menu for albums, artists and playlists.
struct ItemMenu: View {
    let item: YTItem
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .song(let song) = item {
            SongMenu(song: song)
        } else {
            Button("Play", systemImage: "play") { model.play(item) }
            Button("Shuffle", systemImage: "shuffle") { model.play(item, shuffled: true) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                Task { model.player.playNext(await model.songs(of: item)) }
            }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                Task { model.player.enqueue(await model.songs(of: item)) }
            }
            AddToSharedQueueButton { await model.songs(of: item) }
            Divider()
            Button(model.library.isSaved(item) ? "Remove from Library" : "Add to Library",
                   systemImage: model.library.isSaved(item) ? "minus.circle" : "plus.circle") {
                model.library.toggleSaved(item)
            }
            if case .artist(let artist) = item {
                Divider()
                HideArtistButtons(artists: [ArtistRef(name: artist.title, id: artist.id)])
            } else {
                Button("Download", systemImage: "arrow.down.circle") { model.download(item) }
            }
        }
    }
}

/// Artwork card used in shelves and grids.
struct ItemCard: View {
    let item: YTItem
    var size: CGFloat = 160

    @Environment(AppModel.self) private var model
    @ViewState private var hovering = false

    private var isArtist: Bool {
        if case .artist = item { return true }
        return false
    }

    var body: some View {
        VStack(alignment: isArtist ? .center : .leading, spacing: 6) {
            ArtworkView(url: item.thumbnail, size: size, cornerRadius: 10, circular: isArtist)
                .overlay(alignment: .bottomTrailing) {
                    let current = model.isCurrent(item)
                    if hovering || current {
                        Button {
                            if current { model.player.togglePlayPause() } else { model.play(item) }
                        } label: {
                            Image(systemName: current && model.player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 38, height: 38)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .padding(8)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                        .help(current && model.player.isPlaying ? "Pause" : "Play")
                    }
                }
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

            VStack(alignment: isArtist ? .center : .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(isArtist ? .center : .leading)
                if case .album(let album) = item, !album.artists.isEmpty {
                    HStack(spacing: 0) {
                        ArtistLinks(artists: album.artists)
                        if let year = album.year { Text(" • \(year)").lineLimit(1) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: size, alignment: isArtist ? .center : .leading)
        .contentShape(.rect)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .onTapGesture {
            // A song's cover leads to its album, single or EP; the play button starts it.
            if case .song(let song) = item { model.openAlbum(for: song) } else { model.open(item) }
        }
        .contextMenu { ItemMenu(item: item) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Where a horizontal shelf is scrolled to, and whether more lies off either edge.
struct ShelfMetrics: Equatable {
    var offset: CGFloat = 0
    var width: CGFloat = 0
    var hasLeading = false
    var hasTrailing = false
}

/// One titled section: a horizontal shelf of cards, or a multi-column list of songs.
struct SectionView: View {
    let section: ItemSection
    @Environment(AppModel.self) private var model
    @ViewState private var shelfPosition = ScrollPosition()
    @ViewState private var shelf = ShelfMetrics()

    private var songs: [Song] { section.items.compactMap(\.song) }

    /// Translucent Liquid Glass button floating over the edge of a shelf.
    private func shelfArrow(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .offset(y: -22)
        .help(help)
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }

    var body: some View {
        let _ = Diagnostics.hit("SectionView")
        VStack(alignment: .leading, spacing: 10) {
            if !section.title.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(section.title)
                        .font(.title2.bold())
                    Spacer()
                    if let more = section.more {
                        Button("See All") { model.push(.browse(more, title: section.title)) }
                            .buttonStyle(.link)
                    }
                }
                .padding(.horizontal, 24)
            }

            if section.isList, songs.count == section.items.count {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        SongRow(song: song, showAlbum: false) {
                            // A lone search/quick-pick result starts a radio; a real list plays in order.
                            if songs.count <= 3 { model.player.play(song: song) } else { model.player.play(songs, startAt: index, chosen: true) }
                        }
                    }
                }
                .padding(.horizontal, 14)
            } else if section.isList {
                LazyVStack(spacing: 0) {
                    ForEach(section.items) { item in
                        ItemRow(item: item)
                    }
                }
                .padding(.horizontal, 14)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(section.items) { item in
                            ItemCard(item: item)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .contentMargins(.horizontal, 24, for: .scrollContent)
                .scrollIndicators(.never)
                .scrollPosition($shelfPosition)
                .onScrollGeometryChange(for: ShelfMetrics.self) { geometry in
                    ShelfMetrics(
                        offset: geometry.contentOffset.x,
                        width: geometry.containerSize.width,
                        hasLeading: geometry.visibleRect.minX > 8,
                        hasTrailing: geometry.visibleRect.maxX < geometry.contentSize.width - 8
                    )
                } action: { _, metrics in
                    shelf = metrics
                }
                .overlay(alignment: .leading) {
                    if shelf.hasLeading {
                        shelfArrow("chevron.left", help: "Scroll back") {
                            withAnimation(.snappy) { shelfPosition.scrollTo(x: shelf.offset - shelf.width * 0.85) }
                        }
                        .padding(.leading, 10)
                    }
                }
                .overlay(alignment: .trailing) {
                    if shelf.hasTrailing {
                        shelfArrow("chevron.right", help: "Scroll forward") {
                            withAnimation(.snappy) { shelfPosition.scrollTo(x: shelf.offset + shelf.width * 0.85) }
                        }
                        .padding(.trailing, 10)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: shelf)
            }
        }
    }
}

/// A list row for mixed content (search results).
struct ItemRow: View {
    let item: YTItem
    @Environment(AppModel.self) private var model
    @ViewState private var hovering = false

    var body: some View {
        if case .song(let song) = item {
            SongRow(song: song) { model.player.play(song: song) }
        } else {
            HStack(spacing: 12) {
                ArtworkView(url: item.thumbnail, size: 40, cornerRadius: 5, circular: { if case .artist = item { true } else { false } }())
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1)
                    Text(kind + (item.subtitle.isEmpty ? "" : " • " + item.subtitle))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .onTapGesture { model.open(item) }
            .contextMenu { ItemMenu(item: item) }
        }
    }

    private var kind: String {
        switch item {
        case .album: "Album"
        case .artist: "Artist"
        case .playlist: "Playlist"
        case .song: "Song"
        }
    }
}

struct SectionsView: View {
    let sections: [ItemSection]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(sections) { section in
                SectionView(section: section)
            }
        }
    }
}

/// Loads a value asynchronously and shows progress, an error with retry, or the content.
struct AsyncContent<Value, Content: View>: View {
    let id: AnyHashable
    let load: () async throws -> Value
    @ViewBuilder let content: (Value) -> Content

    @ViewState private var value: Value?
    @ViewState private var error: Error?
    @ViewState private var attempt = 0

    var body: some View {
        Group {
            if let value {
                content(value)
            } else if let error {
                ContentUnavailableView {
                    Label(isOffline(error) ? "You're Offline" : "Couldn't Load", systemImage: isOffline(error) ? "wifi.slash" : "exclamationmark.triangle")
                } description: {
                    Text(isOffline(error) ? "Your downloads and library are still available." : error.localizedDescription)
                } actions: {
                    Button("Try Again") { attempt += 1 }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: [id, AnyHashable(attempt)]) {
            error = nil
            do {
                value = try await load()
            } catch is CancellationError {
            } catch {
                if value == nil { self.error = error }
            }
        }
    }

    private func isOffline(_ error: Error) -> Bool {
        if case YTError.offline = error { return true }
        return (error as? URLError)?.code == .notConnectedToInternet
    }
}

/// Large header for album, playlist and artist pages.
struct PageHeader<Actions: View>: View {
    let artwork: String?
    var circular = false
    let kind: String
    let title: String
    let subtitle: String
    var artists: [ArtistRef] = []
    var description: String?
    /// Animated artwork played over the still one once it can be shown (album pages).
    var motion: URL?
    /// Song count and length ("12 songs, 48 min"), as Apple Music and Spotify show them.
    var details: String?
    @ViewBuilder let actions: () -> Actions
    @ViewState private var width: CGFloat = 900

    /// Like Apple Music's and Spotify's album and playlist pages, the cover grows with the
    /// window (from 170 to 320 points, about 30% of the page's width) and the title with it;
    /// on a narrow page it goes, so the title and buttons keep their room.
    var body: some View {
        let art: CGFloat = width < 480 ? 0 : min(320, max(170, ((width - 48) * 0.3).rounded()))
        let titleSize: CGFloat = art >= 280 ? 44 : art >= 220 ? 38 : art > 0 ? 30 : 24
        layout(artSize: art, titleSize: titleSize)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func layout(artSize: CGFloat, titleSize: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: artSize > 200 ? 28 : 18) {
            if artSize > 0 {
                ArtworkView(url: artwork, size: artSize, cornerRadius: artSize > 200 ? 14 : 12, circular: circular, pixelSize: 1000)
                    .overlay {
                        if let motion {
                            LoopingVideoView(url: motion)
                                .clipShape(RoundedRectangle(cornerRadius: artSize > 200 ? 14 : 12, style: .continuous))
                                .allowsHitTesting(false)
                        }
                    }
                    .shadow(color: .black.opacity(0.3), radius: 22, y: 10)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(kind.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: titleSize, weight: .bold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .textSelection(.enabled)
                if !artists.isEmpty {
                    ArtistLinks(artists: artists)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.tint)
                } else if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                // YouTube Music's own subtitle often has the count and length already.
                let extra = description?.localizedCaseInsensitiveContains("song") == true ? nil : details
                let line = [description, extra].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " • ")
                if !line.isEmpty {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .help(line)
                }
                HStack(spacing: 10) {
                    actions()
                }
                .fixedSize()
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Play / Shuffle / save / download buttons shown under a page header.
struct CollectionActions: View {
    let item: YTItem?
    let songs: [Song]
    @Environment(AppModel.self) private var model

    private var allDownloaded: Bool {
        !songs.isEmpty && songs.allSatisfy { model.media.isDownloaded($0.id) }
    }

    var body: some View {
        Button {
            model.player.play(songs)
        } label: {
            Label("Play", systemImage: "play.fill").frame(minWidth: 70)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(songs.isEmpty)

        Button {
            model.player.play(songs, shuffled: true)
        } label: {
            Label("Shuffle", systemImage: "shuffle").frame(minWidth: 70)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .disabled(songs.isEmpty)

        if let item {
            Button {
                model.library.toggleSaved(item)
            } label: {
                Image(systemName: model.library.isSaved(item) ? "checkmark" : "plus")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .help(model.library.isSaved(item) ? "Remove from Library" : "Add to Library")
        }

        Button {
            if allDownloaded {
                songs.forEach { model.media.removeDownload($0.id) }
            } else {
                if let item, !model.library.isSaved(item) { model.library.toggleSaved(item) }
                model.download(songs)
            }
        } label: {
            Image(systemName: allDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .disabled(songs.isEmpty)
        .help(allDownloaded ? "Remove Downloads" : "Download for Offline Listening")
    }
}

/// "12 songs, 48 min" or "34 songs, 1 hr 52 min", for page headers.
func songSummary(_ songs: [Song]) -> String? {
    guard !songs.isEmpty else { return nil }
    let count = "\(songs.count) song\(songs.count == 1 ? "" : "s")"
    let seconds = songs.reduce(0) { $0 + ($1.duration ?? 0) }
    guard seconds > 0 else { return count }
    let hours = seconds / 3600, minutes = (seconds % 3600 + 30) / 60
    return count + ", " + (hours > 0 ? "\(hours) hr \(minutes) min" : "\(max(1, minutes)) min")
}
