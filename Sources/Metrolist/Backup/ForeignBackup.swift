import Foundation

/// What another music app's backup holds, in the terms this app uses.
struct ForeignSong {
    var id: String
    var title: String
    var artists: [ArtistRef]
    var albumId: String?
    var albumName: String?
    var duration: Int?
    var thumbnail: String?
    var explicit = false
    var liked = false
    var likedAt: Int64?
}

struct ForeignPlaylist {
    var name: String
    /// The YouTube playlist this mirrors, for playlists saved from YouTube Music.
    var browseId: String?
    var songIds: [String]
}

struct ForeignBookmark {
    var id: String
    var name: String
    var thumbnail: String?
}

struct ForeignLibrary {
    var family: String
    var songs: [ForeignSong] = []
    var playlists: [ForeignPlaylist] = []
    /// Songs and when they were played (milliseconds since 1970).
    var plays: [(songId: String, at: Int64)] = []
    var artists: [ForeignBookmark] = []
    var albums: [ForeignBookmark] = []
}

enum ForeignBackupError: LocalizedError {
    case unsupported, tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupported: "That file isn't a backup this app can read. Supported: Metrolist and InnerTune (Android), ViMusic and Kreate."
        case .tooLarge: "That backup is too large."
        }
    }
}

/// Reads the library out of another app's backup: a ZIP holding its SQLite database (as
/// Metrolist's Android app makes), or the bare database. The mappings follow Metrolist's own
/// importers (`ForeignLibraryImport.kt`). The database is read from a temporary copy,
/// read-only, and only data (never anything executable) is taken from it.
enum ForeignBackup {
    static let maxFileBytes = 700 * 1024 * 1024

    static func isYouTubeVideoId(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func read(_ url: URL) throws -> ForeignLibrary {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { throw ForeignBackupError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("metrolist-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var candidates: [URL] = []
        if data.prefix(16) == SQLiteReader.header {
            let copy = scratch.appendingPathComponent("source.db")
            try data.write(to: copy)
            candidates = [copy]
        } else {
            let archive = try ZipReader(data: data, limits: ZipLimits(maxEntries: 4_096, maxEntryBytes: 512 * 1024 * 1024, maxTotalBytes: 600 * 1024 * 1024))
            for (index, entry) in archive.entries.enumerated() where !entry.isDirectory {
                // Names are never used as paths: each candidate gets a name of our own.
                let lower = entry.name.lowercased()
                guard !lower.contains("exoplayer"), !lower.hasSuffix("-wal"), !lower.hasSuffix("-shm"), entry.size >= 100 else { continue }
                let contents = try archive.contents(of: entry)
                guard contents.prefix(16) == SQLiteReader.header else { continue }
                let copy = scratch.appendingPathComponent("candidate-\(index).db")
                try contents.write(to: copy)
                candidates.append(copy)
            }
        }
        for candidate in candidates {
            if let database = SQLiteReader(path: candidate.path), let library = read(database) { return library }
        }
        throw ForeignBackupError.unsupported
    }

    static func read(_ database: SQLiteReader) -> ForeignLibrary? {
        let tables = database.tables()
        func has(_ table: String, _ columns: String...) -> Bool {
            tables[table.lowercased()].map { $0.isSuperset(of: columns.map { $0.lowercased() }) } == true
        }
        if has("song", "id", "title", "liked"), has("playlist", "id", "name"), has("playlist_song_map", "playlistId", "songId", "position") {
            return readInnerTune(database, tables)
        }
        if has("song", "id", "title", "likedAt", "totalPlayTimeMs"), has("playlist", "id", "name"), has("songplaylistmap", "songId", "playlistId", "position") {
            return readViMusic(database, tables, kreate: false)
        }
        if has("songs", "id", "title", "liked_at", "total_playtime"), has("playlists", "id", "name"), has("song_playlist_map", "song_id", "playlist_id", "position") {
            return readViMusic(database, tables, kreate: true)
        }
        return nil
    }

    // MARK: InnerTune and Metrolist (Android)

    private static func readInnerTune(_ db: SQLiteReader, _ tables: [String: Set<String>]) -> ForeignLibrary {
        var artistsBySong: [String: [ArtistRef]] = [:]
        if tables["song_artist_map"] != nil, tables["artist"] != nil {
            for row in db.rows("SELECT m.songId AS songId, a.id AS id, a.name AS name FROM song_artist_map m JOIN artist a ON a.id = m.artistId ORDER BY m.songId, m.position") ?? [] {
                guard let name = row["name"]?.string, let song = row["songId"]?.string else { continue }
                artistsBySong[song, default: []].append(ArtistRef(name: name, id: channelId(row["id"]?.string)))
            }
        }
        var library = ForeignLibrary(family: "Metrolist / InnerTune")
        for row in db.rows("SELECT * FROM song") ?? [] {
            guard let id = row["id"]?.string else { continue }
            var duration = row["duration"]?.int.map(Int.init)
            if let value = duration, value <= 0 { duration = nil }
            library.songs.append(ForeignSong(
                id: id, title: row["title"]?.string ?? "", artists: artistsBySong[id] ?? [],
                albumId: row["albumId"]?.string, albumName: row["albumName"]?.string, duration: duration,
                thumbnail: row["thumbnailUrl"]?.string, explicit: row["explicit"]?.int == 1,
                liked: row["liked"]?.int == 1, likedAt: row["likedDate"]?.int
            ))
        }
        var members: [String: [String]] = [:]
        for row in db.rows("SELECT playlistId, songId FROM playlist_song_map ORDER BY playlistId, position, id") ?? [] {
            if let playlist = row["playlistId"]?.string, let song = row["songId"]?.string { members[playlist, default: []].append(song) }
        }
        for row in db.rows("SELECT * FROM playlist") ?? [] {
            guard let id = row["id"]?.string else { continue }
            let browse = row["isLocal"]?.int == 1 ? nil : row["browseId"]?.string
            library.playlists.append(ForeignPlaylist(name: row["name"]?.string ?? "Playlist", browseId: browse?.isEmpty == true ? nil : browse, songIds: members[id] ?? []))
        }
        if tables["event"] != nil {
            for row in db.rows("SELECT songId, timestamp FROM event ORDER BY timestamp") ?? [] {
                if let song = row["songId"]?.string, let at = row["timestamp"]?.int { library.plays.append((song, at)) }
            }
        }
        library.artists = bookmarks(db, tables, table: "artist", name: "name", thumbnail: "thumbnailUrl", marker: "bookmarkedAt")
        library.albums = bookmarks(db, tables, table: "album", name: "title", thumbnail: "thumbnailUrl", marker: "bookmarkedAt")
        return library
    }

    // MARK: ViMusic and Kreate

    private static func readViMusic(_ db: SQLiteReader, _ tables: [String: Set<String>], kreate: Bool) -> ForeignLibrary {
        // Table and column names of the two apps (Metrolist's `ViMusicNames`).
        let n = kreate
            ? (song: "songs", artistsText: "artists", duration: "duration", thumbnail: "thumbnail_url", likedAt: "liked_at", songArtistMap: "song_artist_map", artist: "artists",
               songAlbumMap: "song_album_map", album: "albums", playlist: "playlists", browseId: "browse_id", songPlaylistMap: "song_playlist_map", songId: "song_id",
               artistId: "artist_id", albumId: "album_id", playlistId: "playlist_id", event: "playback_history", eventTimestamp: "created_at", bookmarkedAt: "bookmarked_at")
            : (song: "Song", artistsText: "artistsText", duration: "durationText", thumbnail: "thumbnailUrl", likedAt: "likedAt", songArtistMap: "SongArtistMap", artist: "Artist",
               songAlbumMap: "SongAlbumMap", album: "Album", playlist: "Playlist", browseId: "browseId", songPlaylistMap: "SongPlaylistMap", songId: "songId",
               artistId: "artistId", albumId: "albumId", playlistId: "playlistId", event: "Event", eventTimestamp: "timestamp", bookmarkedAt: "bookmarkedAt")
        var library = ForeignLibrary(family: kreate ? "Kreate" : "ViMusic")
        var artistsBySong: [String: [ArtistRef]] = [:]
        if tables[n.songArtistMap.lowercased()] != nil, tables[n.artist.lowercased()] != nil {
            for row in db.rows("SELECT m.\(n.songId) AS songId, a.id AS id, a.name AS name FROM \(n.songArtistMap) m JOIN \(n.artist) a ON a.id = m.\(n.artistId) ORDER BY m.rowid") ?? [] {
                if let name = row["name"]?.string, !name.isEmpty, let song = row["songId"]?.string { artistsBySong[song, default: []].append(ArtistRef(name: name, id: channelId(row["id"]?.string))) }
            }
        }
        var albumsBySong: [String: (String, String?)] = [:]
        if tables[n.songAlbumMap.lowercased()] != nil, tables[n.album.lowercased()] != nil {
            for row in db.rows("SELECT m.\(n.songId) AS songId, a.id AS id, a.title AS title FROM \(n.songAlbumMap) m JOIN \(n.album) a ON a.id = m.\(n.albumId)") ?? [] {
                if let song = row["songId"]?.string { albumsBySong[song] = (row["id"]?.string ?? "", row["title"]?.string) }
            }
        }
        for row in db.rows("SELECT * FROM \(n.song)") ?? [] {
            guard let id = row["id"]?.string else { continue }
            // A negative time marks a dislike; only positive ones are likes.
            let likedAt = row[n.likedAt]?.int.flatMap { $0 > 0 ? $0 : nil }
            var artists = artistsBySong[id] ?? []
            if artists.isEmpty, let text = row[n.artistsText]?.string, !text.isEmpty { artists = [ArtistRef(name: text, id: nil)] }
            library.songs.append(ForeignSong(
                id: id, title: row["title"]?.string ?? "", artists: artists, albumId: albumsBySong[id]?.0, albumName: albumsBySong[id]?.1,
                duration: row[n.duration]?.string.flatMap(parseDuration), thumbnail: row[n.thumbnail]?.string, liked: likedAt != nil, likedAt: likedAt
            ))
        }
        var members: [Int64: [String]] = [:]
        for row in db.rows("SELECT \(n.playlistId) AS playlistId, \(n.songId) AS songId FROM \(n.songPlaylistMap) ORDER BY \(n.playlistId), position") ?? [] {
            if let playlist = row["playlistId"]?.int, let song = row["songId"]?.string { members[playlist, default: []].append(song) }
        }
        for row in db.rows("SELECT * FROM \(n.playlist)") ?? [] {
            let browse = row[n.browseId]?.string.map { $0.hasPrefix("VL") ? String($0.dropFirst(2)) : $0 }
            library.playlists.append(ForeignPlaylist(name: row["name"]?.string ?? "Playlist", browseId: browse?.isEmpty == true ? nil : browse, songIds: members[row["id"]?.int ?? -1] ?? []))
        }
        if tables[n.event.lowercased()] != nil {
            for row in db.rows("SELECT \(n.songId) AS songId, \(n.eventTimestamp) AS ts FROM \(n.event) ORDER BY ts") ?? [] {
                if let song = row["songId"]?.string, let at = row["ts"]?.int { library.plays.append((song, at)) }
            }
        }
        library.artists = bookmarks(db, tables, table: n.artist, name: "name", thumbnail: n.thumbnail, marker: n.bookmarkedAt)
        library.albums = bookmarks(db, tables, table: n.album, name: "title", thumbnail: n.thumbnail, marker: n.bookmarkedAt)
        return library
    }

    // MARK: Helpers

    private static func bookmarks(_ db: SQLiteReader, _ tables: [String: Set<String>], table: String, name: String, thumbnail: String, marker: String) -> [ForeignBookmark] {
        guard tables[table.lowercased()]?.contains(marker.lowercased()) == true else { return [] }
        // Table names come from the fixed lists above, never from the file.
        return (db.rows("SELECT * FROM \(table) WHERE \(marker) IS NOT NULL") ?? []).compactMap { row in
            guard let id = row["id"]?.string, let title = row[name]?.string, !title.isEmpty else { return nil }
            return ForeignBookmark(id: id, name: title, thumbnail: row[thumbnail]?.string)
        }
    }

    /// Channel ids of artists look like "UC…"; other ids are local to the old app.
    private static func channelId(_ id: String?) -> String? {
        guard let id, id.hasPrefix("UC") else { return nil }
        return id
    }

    /// "3:45" or "1:02:03" in seconds.
    static func parseDuration(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return Int(text) }
        let total = parts.reduce(0) { $0 * 60 + $1 }
        return total > 0 ? total : nil
    }
}
