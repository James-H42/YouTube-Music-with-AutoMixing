import Foundation
import Observation
import SwiftUI

struct LocalPlaylist: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var songIds: [String]
    var createdAt: Date
    /// The copy of this playlist on the YouTube Music account, once it has been added there.
    /// Songs added, removed or renamed here are changed there too.
    var remoteId: String?
}

/// A playlist in the sidebar: one kept in this app, or one from the YouTube Music library.
enum SidebarPlaylist: Identifiable, Hashable {
    case local(LocalPlaylist)
    case remote(PlaylistItem)

    /// Stable across launches; used to remember the order the listener arranged.
    var id: String {
        switch self {
        case .local(let playlist): "local:" + playlist.id
        case .remote(let playlist): "remote:" + playlist.id
        }
    }
}

struct HistoryEntry: Codable, Hashable {
    var songId: String
    var date: Date
}

private struct LibraryData: Codable {
    var songs: [String: Song] = [:]
    var liked: [String] = []
    var playlists: [LocalPlaylist] = []
    var albums: [AlbumItem] = []
    var artists: [ArtistItem] = []
    var savedPlaylists: [PlaylistItem] = []
    var history: [HistoryEntry] = []
    var playCounts: [String: Int] = [:]
    /// Ids last seen in the YouTube Music library, per kind, used to merge without duplicating
    /// and to notice items removed on another device.
    var synced: [String: [String]] = [:]
    /// The listener's order of the sidebar's playlists (`SidebarPlaylist.id`s). Playlists
    /// not in it yet (new ones) follow, in the order they were added.
    var sidebarOrder: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        songs = (try? container.decode([String: Song].self, forKey: .songs)) ?? [:]
        liked = (try? container.decode([String].self, forKey: .liked)) ?? []
        playlists = (try? container.decode([LocalPlaylist].self, forKey: .playlists)) ?? []
        albums = (try? container.decode([AlbumItem].self, forKey: .albums)) ?? []
        artists = (try? container.decode([ArtistItem].self, forKey: .artists)) ?? []
        savedPlaylists = (try? container.decode([PlaylistItem].self, forKey: .savedPlaylists)) ?? []
        history = (try? container.decode([HistoryEntry].self, forKey: .history)) ?? []
        playCounts = (try? container.decode([String: Int].self, forKey: .playCounts)) ?? [:]
        synced = (try? container.decode([String: [String]].self, forKey: .synced)) ?? [:]
        sidebarOrder = (try? container.decode([String].self, forKey: .sidebarOrder)) ?? []
    }
}

/// The user's local library: liked songs, playlists, saved albums/artists and listening
/// history. Stored as JSON so everything, including downloads' metadata, works offline.
@MainActor
@Observable
final class LibraryStore {
    private var data = LibraryData()
    private var likedIds: Set<String> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        if let raw = try? Data(contentsOf: AppPaths.library),
           let decoded = try? JSONDecoder().decode(LibraryData.self, from: raw) {
            data = decoded
        }
        likedIds = Set(data.liked)
    }

    // MARK: - YouTube Music library sync

    /// Folds the signed-in account's library into the local one. Items the account no longer
    /// has are dropped; items added locally and not yet on the account are kept.
    func mergeRemote(liked: [Song]?, albums: [AlbumItem]?, artists: [ArtistItem]?, playlists: [PlaylistItem]?) {
        func merged(_ kind: String, local: [String], remote: [String]) -> [String] {
            let previous = Set(data.synced[kind] ?? [])
            let incoming = Set(remote)
            data.synced[kind] = remote
            return local.filter { !previous.contains($0) && !incoming.contains($0) } + remote
        }
        if let liked {
            remember(liked)
            data.liked = merged("liked", local: data.liked, remote: liked.map(\.id))
            likedIds = Set(data.liked)
        }
        if let albums {
            let all = Dictionary((data.albums + albums).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            data.albums = merged("albums", local: data.albums.map(\.id), remote: albums.map(\.id)).compactMap { all[$0] }
        }
        if let artists {
            let all = Dictionary((data.artists + artists).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            data.artists = merged("artists", local: data.artists.map(\.id), remote: artists.map(\.id)).compactMap { all[$0] }
        }
        if let playlists {
            let seenBefore = Set(data.synced["playlists"] ?? [])
            let all = Dictionary((data.savedPlaylists + playlists).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            data.savedPlaylists = merged("playlists", local: data.savedPlaylists.map(\.id), remote: playlists.map(\.id)).compactMap { all[$0] }
            // An account copy deleted on another device: the local playlist stays, unlinked.
            // Only when the copy was on the account before and a list that isn't empty (a
            // failed request) no longer has it; a copy too new to be listed stays linked.
            let incoming = Set(playlists.map(\.id))
            if !incoming.isEmpty {
                for index in data.playlists.indices {
                    guard let remote = data.playlists[index].remoteId, seenBefore.contains(remote), !incoming.contains(remote) else { continue }
                    data.playlists[index].remoteId = nil
                }
            }
            // A link lost earlier (or a copy made by an earlier build): an account playlist
            // with the same name and the same number of songs is this playlist's copy.
            for index in data.playlists.indices where data.playlists[index].remoteId == nil {
                if let copy = accountCopy(of: data.playlists[index], among: playlists) {
                    data.playlists[index].remoteId = copy.id
                }
            }
        }
        scheduleSave()
    }

    // MARK: - Songs

    func song(_ id: String) -> Song? { data.songs[id] }

    func songs(_ ids: [String]) -> [Song] { ids.compactMap { data.songs[$0] } }

    /// Stores song metadata so it can be shown later without a network connection.
    func remember(_ songs: [Song]) {
        for song in songs {
            if var existing = data.songs[song.id] {
                existing.title = song.title
                if !song.artists.isEmpty { existing.artists = song.artists }
                existing.album = song.album ?? existing.album
                existing.duration = song.duration ?? existing.duration
                existing.thumbnail = song.thumbnail ?? existing.thumbnail
                // The kind of video (official music video, upload, art track) when the page
                // said; entries saved before it was kept get it this way too.
                if let type = song.videoType {
                    existing.videoType = type
                    existing.isVideo = song.isVideo
                }
                data.songs[song.id] = existing
            } else {
                data.songs[song.id] = song
            }
        }
        scheduleSave()
    }

    /// Saved videos whose kind isn't known yet (saved before it was kept).
    var untypedVideoIds: [String] {
        data.songs.values.filter { $0.isVideo && $0.videoType == nil }.map(\.id).sorted()
    }

    /// Tests: forget a song's type, as in a library saved before it was kept.
    func setVideoTypesForTesting(_ id: String) { data.songs[id]?.videoType = nil; data.songs[id]?.isVideo = true }

    /// Stores what YouTube Music says each video is. An empty type means it was asked and
    /// had no answer (a removed video): it stays as it was, and isn't asked about again.
    func setVideoTypes(_ types: [String: String]) {
        for (id, type) in types where data.songs[id] != nil {
            data.songs[id]?.videoType = type
            if !type.isEmpty { data.songs[id]?.isVideo = Parser.isVideoType(type) }
        }
        scheduleSave()
    }

    // MARK: - Likes

    var likedSongs: [Song] { songs(data.liked) }

    func isLiked(_ id: String) -> Bool { likedIds.contains(id) }

    func toggleLike(_ song: Song) {
        let liked: Bool
        if let index = data.liked.firstIndex(of: song.id) {
            data.liked.remove(at: index)
            likedIds.remove(song.id)
            liked = false
        } else {
            remember([song])
            data.liked.insert(song.id, at: 0)
            likedIds.insert(song.id)
            liked = true
        }
        scheduleSave()
        if InnerTube.shared.isSignedIn {
            Task { try? await YTMusic.setLiked(liked, videoId: song.id) }
        }
    }

    // MARK: - Playlists

    var playlists: [LocalPlaylist] { data.playlists }

    func playlist(_ id: String) -> LocalPlaylist? { data.playlists.first { $0.id == id } }

    @discardableResult
    func createPlaylist(name: String, songs: [Song] = []) -> LocalPlaylist {
        remember(songs)
        let playlist = LocalPlaylist(id: UUID().uuidString, name: name, songIds: songs.map(\.id), createdAt: Date())
        data.playlists.append(playlist)
        scheduleSave()
        return playlist
    }

    func add(_ songs: [Song], toPlaylist id: String) {
        guard let index = data.playlists.firstIndex(where: { $0.id == id }) else { return }
        remember(songs)
        let existing = Set(data.playlists[index].songIds)
        let added = songs.map(\.id).filter { !existing.contains($0) }
        data.playlists[index].songIds += added
        scheduleSave()
        if let remote = data.playlists[index].remoteId { mirror { try await YTMusic.addToPlaylist(remote, videoIds: added) } }
    }

    func remove(songId: String, fromPlaylist id: String) {
        guard let index = data.playlists.firstIndex(where: { $0.id == id }) else { return }
        data.playlists[index].songIds.removeAll { $0 == songId }
        scheduleSave()
        if let remote = data.playlists[index].remoteId { mirror { try await YTMusic.removeFromPlaylist(remote, videoIds: [songId]) } }
    }

    func moveSongs(inPlaylist id: String, from source: IndexSet, to destination: Int) {
        guard let index = data.playlists.firstIndex(where: { $0.id == id }) else { return }
        data.playlists[index].songIds.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    func renamePlaylist(_ id: String, to name: String) {
        guard let index = data.playlists.firstIndex(where: { $0.id == id }) else { return }
        data.playlists[index].name = name
        if let remote = data.playlists[index].remoteId {
            if let saved = data.savedPlaylists.firstIndex(where: { $0.id == remote }) { data.savedPlaylists[saved].title = name }
            mirror { try await YTMusic.renamePlaylist(remote, to: name) }
        }
        scheduleSave()
    }

    /// Repeats a change on the account's copy of a playlist. A failure is reported but the
    /// local change stands.
    @ObservationIgnored var onMirrorFailure: ((String) -> Void)?
    private func mirror(_ change: @escaping () async throws -> Void) {
        guard InnerTube.shared.isSignedIn else { return }
        Task {
            do { try await change() } catch { onMirrorFailure?("The change couldn't be copied to YouTube Music: \(error.localizedDescription)") }
        }
    }

    /// Records that a local playlist now has a copy on the account, and lists that copy with
    /// the library's playlists so it shows in Playlists as on other devices.
    func link(_ id: String, toRemote remote: PlaylistItem) {
        guard let index = data.playlists.firstIndex(where: { $0.id == id }) else { return }
        data.playlists[index].remoteId = remote.id
        if !data.savedPlaylists.contains(where: { $0.id == remote.id }) { data.savedPlaylists.insert(remote, at: 0) }
        saveNow()
    }

    /// The account playlist that is already a copy of a local one: the only one with the
    /// same name and the same number of songs that no other local playlist is linked to.
    func accountCopy(of playlist: LocalPlaylist, among candidates: [PlaylistItem]? = nil) -> PlaylistItem? {
        let taken = Set(data.playlists.compactMap(\.remoteId))
        let matches = (candidates ?? data.savedPlaylists).filter { item in
            !taken.contains(item.id) && item.title == playlist.name
                && Self.trackCount(of: item) == playlist.songIds.count
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// "811 tracks" or "1,204 songs" in a library listing's text, which for the account's own
    /// playlists sits where other playlists show their author.
    static func trackCount(of item: PlaylistItem) -> Int? {
        for text in [item.subtitle, item.author].compactMap({ $0 }) {
            guard let match = text.firstMatch(of: #/([0-9][0-9,.]*)\s+(?:tracks?|songs?)/#) else { continue }
            return Int(match.1.filter(\.isNumber))
        }
        return nil
    }

    // MARK: - Sidebar order

    /// Every playlist shown in the sidebar, in the listener's order. A YouTube Music playlist
    /// that is the account copy of a local one is shown once, as the local one.
    var sidebarPlaylists: [SidebarPlaylist] {
        let linked = Set(data.playlists.compactMap(\.remoteId))
        let all = data.playlists.map(SidebarPlaylist.local) + data.savedPlaylists.filter { !linked.contains($0.id) }.map(SidebarPlaylist.remote)
        let rank = Dictionary(data.sidebarOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // Stable: arranged ones by their position, then the rest in their natural order.
        return all.enumerated().sorted { a, b in
            let (ra, rb) = (rank[a.element.id], rank[b.element.id])
            switch (ra, rb) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    func moveSidebarPlaylists(from source: IndexSet, to destination: Int) {
        var ids = sidebarPlaylists.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        data.sidebarOrder = ids
        scheduleSave()
    }

    func deletePlaylist(_ id: String) {
        data.playlists.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - Saved albums, artists and remote playlists

    var albums: [AlbumItem] { data.albums }
    var artists: [ArtistItem] { data.artists }
    var savedPlaylists: [PlaylistItem] { data.savedPlaylists }

    func isSaved(_ item: YTItem) -> Bool {
        switch item {
        case .album(let album): data.albums.contains { $0.id == album.id }
        case .artist(let artist): data.artists.contains { $0.id == artist.id }
        case .playlist(let playlist): data.savedPlaylists.contains { $0.id == playlist.id }
        case .song(let song): isLiked(song.id)
        }
    }

    func toggleSaved(_ item: YTItem) {
        if item.song == nil, InnerTube.shared.isSignedIn {
            let saved = !isSaved(item)
            Task { try? await YTMusic.setInLibrary(item, saved: saved) }
        }
        switch item {
        case .album(let album):
            if let index = data.albums.firstIndex(where: { $0.id == album.id }) { data.albums.remove(at: index) } else { data.albums.insert(album, at: 0) }
        case .artist(let artist):
            if let index = data.artists.firstIndex(where: { $0.id == artist.id }) { data.artists.remove(at: index) } else { data.artists.insert(artist, at: 0) }
        case .playlist(let playlist):
            if let index = data.savedPlaylists.firstIndex(where: { $0.id == playlist.id }) { data.savedPlaylists.remove(at: index) } else { data.savedPlaylists.insert(playlist, at: 0) }
        case .song(let song):
            toggleLike(song)
        }
        scheduleSave()
    }

    // MARK: - History

    var history: [Song] {
        var seen = Set<String>()
        return data.history.compactMap { entry in
            guard seen.insert(entry.songId).inserted else { return nil }
            return data.songs[entry.songId]
        }
    }

    var mostPlayed: [Song] {
        data.playCounts.sorted { $0.value > $1.value }.prefix(50).compactMap { data.songs[$0.key] }
    }

    func recordPlay(_ song: Song) {
        remember([song])
        data.history.insert(HistoryEntry(songId: song.id, date: Date()), at: 0)
        if data.history.count > 1_000 { data.history.removeLast(data.history.count - 1_000) }
        data.playCounts[song.id, default: 0] += 1
        scheduleSave()
    }

    func clearHistory() {
        data.history = []
        data.playCounts = [:]
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        if let raw = try? JSONEncoder().encode(data) {
            try? raw.write(to: AppPaths.library, options: .atomic)
        }
    }
}

// MARK: - Importing and restoring

struct ImportSummary {
    var songs = 0
    var likes = 0
    var playlists = 0
    var plays = 0
    var skipped = 0
    var artists = 0
    var albums = 0

    var text: String {
        "\(songs) songs, \(likes) liked, \(playlists) playlists, \(artists) artists, \(albums) albums and \(plays) plays imported"
            + (skipped > 0 ? "; \(skipped) local or non-YouTube songs left out" : "")
    }
}

extension LibraryStore {
    /// Merges another app's library into this one. Nothing already here is removed, and songs
    /// that aren't YouTube videos (files stored on the old phone) are left out.
    @discardableResult
    func importForeign(_ foreign: ForeignLibrary) -> ImportSummary {
        var summary = ImportSummary()
        var wanted = Set<String>()
        var songs: [Song] = []
        for item in foreign.songs {
            guard ForeignBackup.isYouTubeVideoId(item.id) else { summary.skipped += 1; continue }
            wanted.insert(item.id)
            songs.append(Song(
                id: item.id, title: item.title.isEmpty ? item.id : item.title, artists: item.artists,
                album: item.albumName.map { AlbumRef(name: $0, id: item.albumId) }, duration: item.duration,
                thumbnail: item.thumbnail, explicit: item.explicit
            ))
        }
        // Songs already known keep their own details.
        remember(songs.filter { data.songs[$0.id] == nil })
        summary.songs = songs.count

        let newLikes = foreign.songs.filter { $0.liked && wanted.contains($0.id) && !likedIds.contains($0.id) }
            .sorted { ($0.likedAt ?? 0) > ($1.likedAt ?? 0) }.map(\.id)
        data.liked += newLikes
        likedIds.formUnion(newLikes)
        summary.likes = newLikes.count

        for playlist in foreign.playlists {
            let ids = playlist.songIds.filter { wanted.contains($0) }
            if ids.isEmpty, let browse = playlist.browseId, !browse.isEmpty {
                // A playlist saved from YouTube Music: keep the link rather than a copy.
                if !data.savedPlaylists.contains(where: { $0.id == browse }) {
                    data.savedPlaylists.append(PlaylistItem(id: browse, title: playlist.name))
                    summary.playlists += 1
                }
                continue
            }
            guard !ids.isEmpty else { continue }
            if let existing = data.playlists.first(where: { $0.name == playlist.name }) {
                add(ids.compactMap { data.songs[$0] }, toPlaylist: existing.id)
            } else {
                createPlaylist(name: playlist.name, songs: ids.compactMap { data.songs[$0] })
            }
            summary.playlists += 1
        }

        var counts: [String: Int] = [:]
        var entries: [HistoryEntry] = []
        // Importing the same backup twice must not count its plays twice.
        let known = Set(data.history.map { "\($0.songId)|\(Int($0.date.timeIntervalSince1970))" })
        for play in foreign.plays where wanted.contains(play.songId) && !known.contains("\(play.songId)|\(play.at / 1000)") {
            counts[play.songId, default: 0] += 1
            entries.append(HistoryEntry(songId: play.songId, date: Date(timeIntervalSince1970: Double(play.at) / 1000)))
        }
        for (id, count) in counts { data.playCounts[id, default: 0] += count }
        data.history = Array((data.history + entries.suffix(1_000)).sorted { $0.date > $1.date }.prefix(1_000))
        summary.plays = entries.count

        for artist in foreign.artists where !data.artists.contains(where: { $0.id == artist.id }) && artist.id.hasPrefix("UC") {
            data.artists.append(ArtistItem(id: artist.id, title: artist.name, thumbnail: artist.thumbnail))
            summary.artists += 1
        }
        for album in foreign.albums where !data.albums.contains(where: { $0.id == album.id }) && album.id.hasPrefix("MPREb") {
            data.albums.append(AlbumItem(id: album.id, title: album.name, thumbnail: album.thumbnail))
            summary.albums += 1
        }
        scheduleSave()
        return summary
    }

    /// Reads the library file again, after a restore has replaced it.
    func reloadFromDisk() {
        saveTask?.cancel()
        data = LibraryData()
        if let raw = try? Data(contentsOf: AppPaths.library), let decoded = try? JSONDecoder().decode(LibraryData.self, from: raw) { data = decoded }
        likedIds = Set(data.liked)
    }
}
