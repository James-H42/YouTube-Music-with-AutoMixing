import SwiftUI

/// Context menu shared by every song row and card.
struct SongMenu: View {
    let song: Song
    var localPlaylistId: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.player.playNext([song]) }
        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { model.player.enqueue([song]) }
        Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { model.player.playRadio(for: song) }
        Divider()
        Button(model.library.isLiked(song.id) ? "Remove from Liked Songs" : "Add to Liked Songs",
               systemImage: model.library.isLiked(song.id) ? "heart.slash" : "heart") {
            model.library.toggleLike(song)
        }
        Menu("Add to Playlist", systemImage: "text.badge.plus") {
            Button("New Playlist…", systemImage: "plus") {
                let playlist = model.library.createPlaylist(name: song.title, songs: [song])
                model.sidebar = .localPlaylist(playlist.id)
            }
            if !model.library.playlists.isEmpty { Divider() }
            ForEach(model.library.playlists) { playlist in
                Button(playlist.name) { model.library.add([song], toPlaylist: playlist.id) }
            }
        }
        if let localPlaylistId {
            Button("Remove from Playlist", systemImage: "minus.circle") {
                model.library.remove(songId: song.id, fromPlaylist: localPlaylistId)
            }
        }
        Divider()
        if model.media.state(for: song.id) == .none {
            Button("Download", systemImage: "arrow.down.circle") { model.download([song]) }
        } else {
            Button("Remove Download", systemImage: "trash") { model.media.removeDownload(song.id) }
        }
        Divider()
        if let albumId = song.album?.id {
            Button("Go to Album", systemImage: "square.stack") { model.push(.album(albumId)) }
        }
        ForEach(Array(song.artists.enumerated()), id: \.offset) { _, artist in
            Button(song.artists.count > 1 ? "Go to \(artist.name)" : "Go to Artist", systemImage: "music.mic") {
                model.openArtist(artist)
            }
        }
        Button("Copy Link", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("https://music.youtube.com/watch?v=\(song.id)", forType: .string)
        }
    }
}

/// Small status glyph showing whether a song is available offline.
struct DownloadBadge: View {
    let songId: String
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.media.state(for: songId) {
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.secondary)
                .help("Downloaded")
        case .downloading(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .help("Downloading")
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
                .help("Waiting to download")
        case .none:
            if model.media.failed.contains(songId) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .help("Download failed")
            }
        }
    }
}

/// Animated bars shown on the row that is currently playing.
struct PlayingIndicator: View {
    var animating: Bool

    var body: some View {
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: animating)
            .foregroundStyle(.tint)
            .font(.system(size: 13, weight: .semibold))
    }
}

struct SongRow: View {
    let song: Song
    var number: Int?
    var showArtwork = true
    var showAlbum = true
    var localPlaylistId: String?
    let onPlay: () -> Void

    @Environment(AppModel.self) private var model
    @ViewState private var hovering = false

    private var isCurrent: Bool { model.player.currentSong?.isSameTrack(as: song) ?? false }
    private var unavailableOffline: Bool {
        !NetworkStatus.shared.isOnline && !model.media.isAvailableOffline(song.id)
    }

    var body: some View {
        let _ = Diagnostics.hit("SongRow")
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(song.title)
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    if song.explicit {
                        Image(systemName: "e.square.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Explicit")
                    }
                }
                ArtistLinks(artists: song.artists)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showAlbum, let album = song.album {
                Button {
                    if let id = album.id { model.push(.album(id)) }
                } label: {
                    Text(album.name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(album.id == nil)
                .frame(maxWidth: 220, alignment: .leading)
                .layoutPriority(-1)
            }

            DownloadBadge(songId: song.id)
                .frame(width: 18)

            Button {
                model.library.toggleLike(song)
            } label: {
                Image(systemName: model.library.isLiked(song.id) ? "heart.fill" : "heart")
                    .foregroundStyle(model.library.isLiked(song.id) ? AnyShapeStyle(.pink) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .opacity(hovering || model.library.isLiked(song.id) ? 1 : 0)
            .help(model.library.isLiked(song.id) ? "Remove from Liked Songs" : "Add to Liked Songs")

            Text(song.duration.map { formatDuration(Double($0)) } ?? "")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        .opacity(unavailableOffline ? 0.4 : 1)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onPlay)
        .contextMenu { SongMenu(song: song, localPlaylistId: localPlaylistId) }
    }

    @ViewBuilder
    private var leading: some View {
        ZStack {
            if showArtwork {
                ArtworkView(url: song.thumbnail, size: 40, cornerRadius: 5)
                    .overlay {
                        if hovering || isCurrent {
                            RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.45))
                        }
                    }
            } else if !hovering, !isCurrent, let number {
                Text("\(number)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if isCurrent, !hovering {
                PlayingIndicator(animating: model.player.isPlaying)
                    .foregroundStyle(showArtwork ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            } else if hovering {
                Button {
                    if isCurrent { model.player.togglePlayPause() } else { onPlay() }
                } label: {
                    Image(systemName: isCurrent && model.player.isPlaying ? "pause.fill" : "play.fill")
                        .foregroundStyle(showArtwork ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 40, height: showArtwork ? 40 : 28)
    }
}

/// A vertical list of songs that plays the whole list from the chosen row.
struct SongList: View {
    let songs: [Song]
    var numbered = false
    var showArtwork = true
    var showAlbum = true
    var localPlaylistId: String?

    @Environment(AppModel.self) private var model

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                SongRow(
                    song: song,
                    number: numbered ? index + 1 : nil,
                    showArtwork: showArtwork,
                    showAlbum: showAlbum,
                    localPlaylistId: localPlaylistId
                ) {
                    model.player.play(songs, startAt: index)
                }
            }
        }
    }
}
