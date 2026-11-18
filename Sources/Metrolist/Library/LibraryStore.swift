import Foundation
import Observation
import SwiftUI

struct LocalPlaylist: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var songIds: [String]
    var createdAt: Date
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
            let all = Dictionary((data.savedPlaylists + playlists).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            data.savedPlaylists = merged("playlists", local: data.savedPlaylists.map(\.id), remote: playlists.map(\.id)).compactMap { all[$0] }
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
                data.songs[song.id] = existing
            } else {
                data.songs[song.id] = song
            }
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
        data.playlists[index].songIds += songs.map(\.id).filter { !existing.contains($0) }
        scheduleSave()
    }

    func remove(songId: String, fromPlaylist id: String) {
        guard let index = data.playlists.firstIndex(where: { $0.id == id }) else { return }
        data.playlists[index].songIds.removeAll { $0 == songId }
        scheduleSave()
    }

    func moveSongs(inPlaylist id: String, from source: IndexSet, to destination: Int) {
        guard let index = data.playlists.firstIndex(where: { $0.id == id }) else { return }
        data.playlists[index].songIds.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    func renamePlaylist(_ id: String, to name: String) {
        guard let index = data.playlists.firstIndex(where: { $0.id == id }) else { return }
        data.playlists[index].name = name
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
