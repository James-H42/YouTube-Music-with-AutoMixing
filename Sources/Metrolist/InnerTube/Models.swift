import Foundation

struct ArtistRef: Codable, Hashable {
    var name: String
    var id: String?
}

struct AlbumRef: Codable, Hashable {
    var name: String
    var id: String?
}

struct Song: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var artists: [ArtistRef] = []
    var album: AlbumRef?
    var duration: Int?
    var thumbnail: String?
    var explicit = false
    /// True when the item is a music video or user upload rather than an audio (art-track) release.
    var isVideo = false
    /// YouTube Music's kind of video (`MUSIC_VIDEO_TYPE_OMV`, `…_UGC`, `…_ATV`…). Nil for
    /// songs saved before it was kept.
    var videoType: String?
    var setVideoId: String?
    /// YouTube Music greys this song out (removed, or not available in this country).
    /// Optional so libraries saved before it existed still load.
    var unavailable: Bool?

    var artistText: String { artists.map(\.name).joined(separator: ", ") }

    /// A music video or live performance from the artist or label: it plays with its picture
    /// and is never mixed. Fan and channel uploads that stand in for songs (`UGC`: leaks,
    /// lyric videos, re-uploads) are videos only in name and play as audio.
    var isMusicVideo: Bool { isVideo && Song.pictureTypes.contains(videoType ?? "") }
    static let pictureTypes: Set<String> = ["MUSIC_VIDEO_TYPE_OMV"]

    /// True for the same recording even when YouTube lists it under another video id
    /// (album track vs. single, or the copy saved in Liked Music).
    func isSameTrack(as other: Song) -> Bool {
        if id == other.id { return true }
        guard !title.isEmpty, title.caseInsensitiveCompare(other.title) == .orderedSame,
              let artist = artists.first?.name, let otherArtist = other.artists.first?.name
        else { return false }
        return artist.caseInsensitiveCompare(otherArtist) == .orderedSame
    }
}

struct AlbumItem: Codable, Hashable, Identifiable {
    var id: String
    var playlistId: String?
    var title: String
    var artists: [ArtistRef] = []
    var year: String?
    var thumbnail: String?
    var explicit = false
}

struct ArtistItem: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var thumbnail: String?
    var subtitle: String?
}

struct PlaylistItem: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var author: String?
    var subtitle: String?
    var thumbnail: String?
}

enum YTItem: Codable, Hashable, Identifiable {
    case song(Song)
    case album(AlbumItem)
    case artist(ArtistItem)
    case playlist(PlaylistItem)

    var id: String {
        switch self {
        case .song(let song): "song:\(song.id)"
        case .album(let album): "album:\(album.id)"
        case .artist(let artist): "artist:\(artist.id)"
        case .playlist(let playlist): "playlist:\(playlist.id)"
        }
    }

    var title: String {
        switch self {
        case .song(let song): song.title
        case .album(let album): album.title
        case .artist(let artist): artist.title
        case .playlist(let playlist): playlist.title
        }
    }

    var subtitle: String {
        switch self {
        case .song(let song):
            song.artistText
        case .album(let album):
            ([album.artists.map(\.name).joined(separator: ", "), album.year ?? ""]).filter { !$0.isEmpty }.joined(separator: " • ")
        case .artist(let artist):
            artist.subtitle ?? "Artist"
        case .playlist(let playlist):
            playlist.author ?? playlist.subtitle ?? "Playlist"
        }
    }

    var thumbnail: String? {
        switch self {
        case .song(let song): song.thumbnail
        case .album(let album): album.thumbnail
        case .artist(let artist): artist.thumbnail
        case .playlist(let playlist): playlist.thumbnail
        }
    }

    var song: Song? {
        if case .song(let song) = self { return song }
        return nil
    }
}

struct BrowseEndpoint: Hashable {
    var browseId: String
    var params: String?
}

struct ItemSection: Identifiable {
    let id = UUID()
    var title: String
    var items: [YTItem]
    var more: BrowseEndpoint?
    /// Vertical song list rather than a horizontally scrolling shelf.
    var isList = false
}

struct AlbumPage {
    var album: AlbumItem
    var description: String?
    var subtitle: String?
    var songs: [Song]
    var sections: [ItemSection]
}

struct PlaylistPage {
    var playlist: PlaylistItem
    var description: String?
    var songs: [Song]
    var continuation: String?
}

struct ArtistPage {
    var artist: ArtistItem
    var description: String?
    var sections: [ItemSection]
    var radioPlaylistId: String?
    var shufflePlaylistId: String?
}

struct HomePage {
    var sections: [ItemSection]
    var continuation: String?
}

struct QueuePage {
    var songs: [Song]
    var continuation: String?
    var lyricsBrowseId: String?
    /// Audio/video pairs advertised by YouTube Music: video id → its counterpart.
    var counterparts: [String: Song] = [:]
    /// Endpoint for the automatic radio that follows the current item.
    var automixPlaylistId: String?
    var automixParams: String?
}

enum SearchFilter: String, CaseIterable, Identifiable {
    case all, songs, videos, albums, artists, playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .songs: "Songs"
        case .videos: "Videos"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        }
    }

    var params: String? {
        switch self {
        case .all: nil
        case .songs: "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
        case .videos: "EgWKAQIQAWoKEAkQChAFEAMQBA=="
        case .albums: "EgWKAQIYAWoKEAkQChAFEAMQBA=="
        case .artists: "EgWKAQIgAWoKEAkQChAFEAMQBA=="
        case .playlists: "EgeKAQQoAEABagoQAxAEEAoQCRAF"
        }
    }
}

struct SearchResults {
    var sections: [ItemSection]
    var continuation: String?
}

extension String {
    /// Rewrites Google image CDN URLs to request a square of roughly `size` pixels.
    func resizedThumbnail(_ size: Int) -> String {
        guard contains("googleusercontent.com") || contains("ggpht.com") else { return self }
        if let range = range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
            return replacingCharacters(in: range, with: "=w\(size)-h\(size)")
        }
        if let range = range(of: #"=s\d+"#, options: .regularExpression) {
            return replacingCharacters(in: range, with: "=s\(size)")
        }
        return self
    }
}

func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}
