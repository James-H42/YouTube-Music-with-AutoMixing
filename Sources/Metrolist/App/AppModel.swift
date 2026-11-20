import Foundation
import Observation
import Security
import SwiftUI

enum SidebarItem: Hashable {
    case home, explore, sharedQueue
    case liked, downloads, musicVideos, albums, artists, savedPlaylists, history
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
    /// Sheets for choosing between lyric sources and for editing lyrics and their timing.
    var showPlaylistImport = false
    var showLyricsSearch = false
    var showLyricsEditor = false
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
        Scrobbler.shared.start()
        Task { await BlockedContent.shared.refreshAIList() }
        library.onMirrorFailure = { [weak player] message in player?.errorMessage = message }
        NowPlayingVideo.shared.controller = player
        NowPlayingVideo.shared.isEnabled = { [settings] in settings.showVideos }
        NowPlayingVideo.shared.preferredQuality = { [settings] in settings.videoQuality }
        // A music video or live performance chosen by the listener opens the full-screen
        // player, where its picture shows, as on YouTube Music.
        player.onChosenVideo = { [weak self] in
            guard let self, self.settings.showVideos else { return }
            withAnimation(.snappy) { self.showExpandedPlayer = true }
        }
    }

    // MARK: - Account playlists

    /// Local playlists being copied to the YouTube Music account right now.
    var uploadingPlaylists: Set<String> = []

    /// Copies a local playlist (an imported one, say) to the signed-in YouTube Music account,
    /// so it appears on other devices and in Playlists. Returns false if that failed.
    @discardableResult
    func addToYouTubeMusic(_ playlistId: String) async -> Bool {
        guard account.isSignedIn, let playlist = library.playlist(playlistId), playlist.remoteId == nil,
              !uploadingPlaylists.contains(playlistId) else { return false }
        uploadingPlaylists.insert(playlistId)
        defer { uploadingPlaylists.remove(playlistId) }
        // Already on the account (added before, and the link lost): link, don't copy again.
        if let copy = library.accountCopy(of: playlist) {
            library.link(playlistId, toRemote: copy)
            return true
        }
        do {
            let songs = library.songs(playlist.songIds)
            let id = try await YTMusic.createPlaylist(title: playlist.name, description: "Imported with Metrolist", videoIds: playlist.songIds)
            library.link(playlistId, toRemote: PlaylistItem(id: id, title: playlist.name, author: account.account?.name, thumbnail: songs.first?.thumbnail))
            return true
        } catch {
            player.errorMessage = "“\(playlist.name)” couldn't be added to YouTube Music: \(error.localizedDescription)"
            return false
        }
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

    // MARK: - Backup and restore

    /// Where a message about a backup is shown.
    private func tell(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.runModal()
    }

    /// File → Back Up Library…
    func backUpLibrary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Metrolist Backup \(Date().formatted(.iso8601.year().month().day())).zip"
        panel.message = "Saves your library, saved transitions, sample links, equalizer profiles, edited lyrics and preferences. Sign-ins, tokens and downloaded songs are not included."
        let accessory = NSButton(checkboxWithTitle: "Include song analysis (larger, saves re-analysing)", target: nil, action: nil)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.saveNow()
        do {
            let count = try LibraryBackup.create(at: url, includeAnalysis: accessory.state == .on)
            tell("Backup saved", "\(count) items were saved to \(url.lastPathComponent).")
        } catch {
            tell("The backup couldn't be saved", error.localizedDescription, style: .warning)
        }
    }

    /// File → Restore from Backup…
    func restoreLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = "Choose a Metrolist backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let info = try LibraryBackup.inspect(url)
            let confirm = NSAlert()
            confirm.messageText = "Restore this backup?"
            confirm.informativeText = "Made \(info.manifest.createdAt.formatted(date: .abbreviated, time: .shortened)), with \(info.files.count) items. It replaces your library, saved transitions, equalizer profiles, edited lyrics and preferences. A copy of what is there now is kept in Metrolist's Backups folder."
            confirm.addButton(withTitle: "Restore")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            library.saveNow()
            let result = try LibraryBackup.restore(from: url)
            library.reloadFromDisk()
            player.reloadSavedMixes()
            MasterEQ.shared.reload()
            BlockedContent.shared.reload()
            tell("Backup restored", "\(result.files) items were restored. Restart Metrolist so that the preferences take effect. What was replaced is in Backups/\(result.replacedCopy?.lastPathComponent ?? "").")
        } catch {
            tell("Nothing was restored", error.localizedDescription, style: .warning)
        }
    }

    /// File → Import Backup from Another App…
    func importForeignBackup() {
        let panel = NSOpenPanel()
        panel.message = "Choose a backup from Metrolist or InnerTune (Android), ViMusic or Kreate"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let foreign = try await Task.detached { try ForeignBackup.read(url) }.value
                let summary = library.importForeign(foreign)
                tell("Backup imported", "From \(foreign.family): \(summary.text).")
            } catch {
                tell("Nothing was imported", error.localizedDescription, style: .warning)
            }
        }
    }

    func shutdown() {
        DeviceConnect.shared.shutdown()
        // A shared queue ends when the app quits; nothing is left listening for guests.
        DeviceConnect.guests.shutdown()
        SharedQueueClient.shared.leave()
        player.saveState()
        library.saveNow()
    }
}
