import Foundation
import Observation
import Security
import SwiftUI

enum SidebarItem: Hashable {
    case home, explore
    case liked, downloads, albums, artists, savedPlaylists, history
    case localPlaylist(String)
    case remotePlaylist(String)
}

enum Route: Hashable {
    case album(String)
    case artist(String)
    case playlist(String)
    case browse(BrowseEndpoint, title: String)
    case search(String)
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case lyrics = "Lyrics"
    case queue = "Up Next"

    var id: String { rawValue }
}

/// The signed-in YouTube Music account, if any. Signing in is optional: it personalises the
/// home feed and exposes the account's playlists.
@MainActor
@Observable
final class AccountStore {
    private(set) var account: YTMusic.Account?
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    @ObservationIgnored private let library: LibraryStore

    private static let service = "Metrolist.YouTubeCookie"

    init(library: LibraryStore) {
        self.library = library
        if let cookie = Self.loadCookie() {
            InnerTube.shared.cookie = cookie
            Task { await refresh() }
        }
    }

    var isSignedIn: Bool { InnerTube.shared.isSignedIn }

    func signIn(cookie: String) {
        InnerTube.shared.cookie = cookie
        Self.saveCookie(cookie)
        resetPlaybackIdentity()
        Task { await refresh() }
    }

    func signOut() {
        InnerTube.shared.cookie = nil
        Self.saveCookie(nil)
        account = nil
        resetPlaybackIdentity()
    }

    /// Starts the anonymous playback identity afresh, so nothing from before a sign-in or
    /// sign-out carries over to the streams requested after it.
    private func resetPlaybackIdentity() {
        InnerTube.shared.resetStreamVisitorData()
        Task { await StreamResolver.shared.clearBlock() }
    }

    /// Loads the account and merges its liked songs, albums, artists and playlists into the
    /// app's own library.
    func refresh() async {
        guard isSignedIn, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        account = (try? await YTMusic.account()) ?? account

        async let likedTask = try? YTMusic.allPlaylistSongs("LM")
        async let albumTask = try? YTMusic.libraryItems("FEmusic_liked_albums")
        async let artistTask = try? YTMusic.libraryItems("FEmusic_library_corpus_artists")
        async let playlistTask = try? YTMusic.libraryItems("FEmusic_liked_playlists")
        let (liked, albums, artists, playlists) = await (likedTask, albumTask, artistTask, playlistTask)

        library.mergeRemote(
            liked: liked,
            albums: albums?.compactMap { if case .album(let album) = $0 { album } else { nil } },
            artists: artists?.compactMap { if case .artist(let artist) = $0 { artist } else { nil } },
            playlists: playlists?.compactMap {
                // "Liked Music" is the Liked Songs section; "Episodes for Later" is podcasts.
                if case .playlist(let playlist) = $0, playlist.id != "LM", playlist.id != "SE" { playlist } else { nil }
            }
        )
        lastSync = Date()
    }

    /// The session is kept in a file only this user can read. The Keychain isn't used because
    /// it re-prompts for every rebuild of an ad-hoc signed app.
    private static var sessionFile: URL { AppPaths.root.appendingPathComponent("session") }

    private static func loadCookie() -> String? {
        if let data = try? Data(contentsOf: sessionFile), let cookie = String(data: data, encoding: .utf8), !cookie.isEmpty {
            return cookie
        }
        // One-time move of a session saved by an earlier build.
        guard !UserDefaults.standard.bool(forKey: "sessionMigrated") else { return nil }
        UserDefaults.standard.set(true, forKey: "sessionMigrated")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let cookie = String(data: data, encoding: .utf8)
        else { return nil }
        saveCookie(cookie)
        return cookie
    }

    private static func saveCookie(_ cookie: String?) {
        guard let cookie else {
            try? FileManager.default.removeItem(at: sessionFile)
            return
        }
        FileManager.default.createFile(atPath: sessionFile.path, contents: Data(cookie.utf8), attributes: [.posixPermissions: 0o600])
    }
}

/// Root application state shared by every window.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings: AppSettings
    let library: LibraryStore
    let media: MediaStore
    let player: PlayerController
    let account: AccountStore

    var sidebar: SidebarItem? = .home {
        didSet { if sidebar != oldValue { path = [] } }
    }
    var path: [Route] = []
    var searchText = ""
    var showInspector = false
    var inspectorTab: InspectorTab = .lyrics
    var showExpandedPlayer = false
    /// The transition editor for the playing song and the next one.
    var showMixEditor = false
    var isBusy = false

    private init() {
        settings = AppSettings()
        library = LibraryStore()
        media = MediaStore()
        media.settings = settings
        media.songProvider = { [library] id in library.song(id) }
        media.tagPendingDownloads()
        player = PlayerController(media: media, library: library, settings: settings)
        account = AccountStore(library: library)
    }

    // MARK: - Navigation

    func open(_ item: YTItem) {
        switch item {
        case .song(let song): player.play(song: song)
        case .album(let album): push(.album(album.id))
        case .artist(let artist): push(.artist(artist.id))
        case .playlist(let playlist): push(.playlist(playlist.id))
        }
    }

    func push(_ route: Route) {
        showExpandedPlayer = false
        if path.last != route { path.append(route) }
    }

    /// Opens the album, single or EP a song belongs to.
    func openAlbum(for song: Song) {
        if let id = song.album?.id {
            push(.album(id))
            return
        }
        Task {
            // Songs from mixes and search don't always carry their release: ask the watch queue.
            let page = try? await YTMusic.queue(videoId: song.id)
            if let id = page?.songs.first(where: { $0.id == song.id })?.album?.id ?? page?.songs.first?.album?.id {
                push(.album(id))
            } else if let artist = song.artists.first {
                openArtist(artist)
            }
        }
    }

    /// Opens an artist's page; artists listed without a link are looked up by name.
    func openArtist(_ artist: ArtistRef) {
        if let id = artist.id {
            push(.artist(id))
            return
        }
        Task {
            let results = try? await YTMusic.search(artist.name, filter: .artists)
            let match = results?.sections.flatMap(\.items).compactMap { item -> ArtistItem? in
                if case .artist(let found) = item { found } else { nil }
            }.first
            if let match { push(.artist(match.id)) } else { push(.search(artist.name)) }
        }
    }

    /// True when this song, or something from this album/playlist/artist, is what's playing.
    func isCurrent(_ item: YTItem) -> Bool {
        guard let playing = player.currentSong else { return false }
        switch item {
        case .song(let song): return playing.isSameTrack(as: song)
        case .album(let album): return player.sourceId == item.id || playing.album?.id == album.id
        case .playlist, .artist: return player.sourceId == item.id
        }
    }

    func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        if case .search = path.last { path.removeLast() }
        path.append(.search(query))
    }

    func toggleInspector(_ tab: InspectorTab) {
        if showInspector, inspectorTab == tab {
            showInspector = false
        } else {
            inspectorTab = tab
            showInspector = true
        }
    }

    // MARK: - Collection actions

    /// Loads every song of an album or playlist.
    func songs(of item: YTItem) async -> [Song] {
        switch item {
        case .song(let song):
            return [song]
        case .album(let album):
            return (try? await YTMusic.album(album.id).songs) ?? []
        case .playlist(let playlist):
            return (try? await YTMusic.allPlaylistSongs(playlist.id)) ?? []
        case .artist(let artist):
            guard let page = try? await YTMusic.artist(artist.id) else { return [] }
            if let radio = page.shufflePlaylistId ?? page.radioPlaylistId,
               let queue = try? await YTMusic.queue(playlistId: radio), !queue.songs.isEmpty {
                return queue.songs
            }
            return page.sections.first { $0.isList }?.items.compactMap(\.song) ?? []
        }
    }

    func play(_ item: YTItem, shuffled: Bool = false) {
        if case .song(let song) = item {
            player.play(song: song)
            return
        }
        Task {
            isBusy = true
            let songs = await songs(of: item)
            isBusy = false
            player.play(songs, shuffled: shuffled, source: item.id)
        }
    }

    func download(_ songs: [Song]) {
        library.remember(songs)
        media.download(songs.map(\.id))
    }

    func download(_ item: YTItem) {
        Task {
            isBusy = true
            let songs = await songs(of: item)
            isBusy = false
            if !library.isSaved(item), item.song == nil { library.toggleSaved(item) }
            download(songs)
        }
    }

    func shutdown() {
        player.saveState()
        library.saveNow()
    }
}
