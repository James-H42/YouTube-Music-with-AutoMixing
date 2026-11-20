import Foundation

/// High-level YouTube Music API built on the WEB_REMIX InnerTube client.
enum YTMusic {
    private static var api: InnerTube { .shared }

    // MARK: - Home & browse

    static func home(continuation: String? = nil) async throws -> HomePage {
        let json: JSON
        if let continuation {
            json = try await api.post("browse", body: [:], query: ["ctoken": continuation, "continuation": continuation, "type": "next"])
        } else {
            json = try await api.post("browse", body: ["browseId": "FEmusic_home"])
        }
        let list = continuation == nil
            ? json.first("sectionListRenderer")
            : json["continuationContents"]["sectionListContinuation"]
        return HomePage(
            sections: ContentFilter.shared.filter(Parser.sections(list["contents"])),
            continuation: list["continuations"][0]["nextContinuationData"]["continuation"].string
        )
    }

    static func explore() async throws -> [ItemSection] {
        let json = try await api.post("browse", body: ["browseId": "FEmusic_explore"])
        return Parser.sections(json["contents"])
    }

    static func charts() async throws -> [ItemSection] {
        let json = try await api.post("browse", body: ["browseId": "FEmusic_charts"])
        return Parser.sections(json["contents"])
    }

    static func sections(for endpoint: BrowseEndpoint) async throws -> [ItemSection] {
        var body: [String: Any] = ["browseId": endpoint.browseId]
        body["params"] = endpoint.params
        let json = try await api.post("browse", body: body)
        return Parser.sections(json["contents"])
    }

    // MARK: - Search

    static func searchSuggestions(_ input: String) async throws -> [String] {
        let json = try await api.post("music/get_search_suggestions", body: ["input": input])
        return json.collect(["searchSuggestionRenderer"]).compactMap { $0.value["suggestion"].text }
    }

    static func search(_ query: String, filter: SearchFilter = .all, continuation: String? = nil, hidingBlocked: Bool = true) async throws -> SearchResults {
        if let continuation {
            let json = try await api.post("search", body: [:], query: ["ctoken": continuation, "continuation": continuation, "type": "next"])
            let shelf = json["continuationContents"]["musicShelfContinuation"]
            let items = shelf["contents"].array.compactMap(Parser.item).filter { !hidingBlocked || !ContentFilter.shared.isBlocked($0) }
            return SearchResults(
                sections: items.isEmpty ? [] : [ItemSection(title: "", items: items, isList: true)],
                continuation: shelf["continuations"][0]["nextContinuationData"]["continuation"].string
            )
        }
        var body: [String: Any] = ["query": query]
        body["params"] = filter.params
        // The "All" tab only carries a handful of songs; ask for the song results alongside it.
        async let moreSongs: [YTItem] = filter == .all
            ? ((try? await search(query, filter: .songs))?.sections.flatMap(\.items) ?? [])
            : []
        let json = try await api.post("search", body: body)
        var sections = filter == .all ? Parser.searchSections(json["contents"]) : Parser.sections(json["contents"])
        let extra = await moreSongs
        if filter == .all, !extra.isEmpty {
            // The same recording often appears under two ids; one row per title and artist.
            func name(_ item: YTItem) -> String { "\(item.title)|\(item.subtitle)".lowercased() }
            var seen = Set((sections.first { $0.title == "Top result" }?.items ?? []).filter { $0.song != nil }.map(name))
            if let index = sections.firstIndex(where: { $0.title == "Songs" }) {
                sections[index].items.forEach { seen.insert(name($0)) }
                for item in extra where sections[index].items.count < 10 && seen.insert(name(item)).inserted {
                    sections[index].items.append(item)
                }
            } else {
                let songs = Array(extra.filter { seen.insert(name($0)).inserted }.prefix(10))
                let place = sections.first?.title == "Top result" ? 1 : 0
                if !songs.isEmpty { sections.insert(ItemSection(title: "Songs", items: songs, isList: true), at: place) }
            }
        }
        return SearchResults(
            sections: hidingBlocked ? ContentFilter.shared.filter(sections) : sections,
            continuation: filter == .all ? nil : json.first("musicShelfRenderer")["continuations"][0]["nextContinuationData"]["continuation"].string
        )
    }

    // MARK: - Album / playlist / artist

    static func album(_ browseId: String) async throws -> AlbumPage {
        let json = try await api.post("browse", body: ["browseId": browseId])
        var header = json.first("musicResponsiveHeaderRenderer")
        if !header.exists { header = json.first("musicDetailHeaderRenderer") }
        guard let title = header["title"].text else { throw YTError.parse("the album") }

        let artistRuns = Parser.runs(header["straplineTextOne"]).filter { !$0.isSeparator }
        let artists = artistRuns.map { ArtistRef(name: $0.text, id: $0.browseId) }
        let subtitleGroups = Parser.groups(Parser.runs(header["subtitle"])).map { $0.map(\.text).joined() }
        let thumbnail = Parser.thumbnail(header["thumbnail"])

        var playlistId: String?
        if let canonical = json["microformat"]["microformatDataRenderer"]["urlCanonical"].string,
           let items = URLComponents(string: canonical)?.queryItems {
            playlistId = items.first { $0.name == "list" }?.value
        }
        playlistId = playlistId ?? header.first("watchPlaylistEndpoint")["playlistId"].string ?? header.first("playlistId").string

        let album = AlbumItem(
            id: browseId,
            playlistId: playlistId,
            title: title,
            artists: artists,
            year: subtitleGroups.first { $0.range(of: #"^\d{4}$"#, options: .regularExpression) != nil },
            thumbnail: thumbnail
        )

        var songs: [Song] = json.first("musicShelfRenderer")["contents"].array.compactMap { row in
            guard var song = Parser.item(row)?.song else { return nil }
            if song.artists.isEmpty { song.artists = artists }
            song.thumbnail = song.thumbnail ?? thumbnail
            song.album = AlbumRef(name: title, id: browseId)
            return song
        }

        // The album page links some tracks to their music video (often a clean or radio edit).
        // The album's own playlist always points at the real album recordings, so use its ids.
        if let playlistId, let tracks = try? await allPlaylistSongs(playlistId), !tracks.isEmpty {
            var unused = tracks
            for index in songs.indices {
                let wanted = normalized(songs[index].title)
                let match: Song?
                if tracks.count == songs.count {
                    match = tracks[index]
                } else if let found = unused.firstIndex(where: { normalized($0.title) == wanted }) {
                    match = unused.remove(at: found)
                } else {
                    match = nil
                }
                guard let match else { continue }
                songs[index].id = match.id
                songs[index].isVideo = false
                songs[index].setVideoId = match.setVideoId
                songs[index].duration = match.duration ?? songs[index].duration
                songs[index].explicit = songs[index].explicit || match.explicit
            }
        }

        return AlbumPage(
            album: album,
            description: header["description"]["musicDescriptionShelfRenderer"]["description"].text,
            subtitle: (subtitleGroups + [header["secondSubtitle"].text ?? ""]).filter { !$0.isEmpty }.joined(separator: " • "),
            songs: songs,
            sections: Parser.sections(json["contents"]).filter { !$0.isList }
        )
    }

    static func playlist(_ id: String) async throws -> PlaylistPage {
        let browseId = id.hasPrefix("VL") ? id : "VL" + id
        let playlistId = id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
        let json = try await api.post("browse", body: ["browseId": browseId])
        var header = json.first("musicResponsiveHeaderRenderer")
        if !header.exists { header = json.first("musicDetailHeaderRenderer") }

        let shelf = json.first("musicPlaylistShelfRenderer")
        let rows = shelf["contents"].array
        let songs = rows.compactMap { Parser.item($0)?.song }
        let author = header["straplineTextOne"].text ?? header["facepile"].first("content").string

        return PlaylistPage(
            playlist: PlaylistItem(
                id: playlistId,
                title: header["title"].text ?? "Playlist",
                author: author,
                subtitle: header["secondSubtitle"].text,
                thumbnail: Parser.thumbnail(header["thumbnail"]) ?? songs.first?.thumbnail
            ),
            description: header["description"]["musicDescriptionShelfRenderer"]["description"].text,
            songs: songs,
            continuation: rows.last?["continuationItemRenderer"]["continuationEndpoint"]["continuationCommand"]["token"].string
                ?? shelf["continuations"][0]["nextContinuationData"]["continuation"].string
        )
    }

    static func playlistContinuation(_ token: String) async throws -> (songs: [Song], continuation: String?) {
        let json = try await api.post(
            "browse",
            body: ["continuation": token],
            query: ["ctoken": token, "continuation": token, "type": "next"]
        )
        let rows = json.collect(["musicResponsiveListItemRenderer"])
        let songs = rows.compactMap { Parser.responsiveItem($0.value)?.song }
        return (songs, Parser.continuation(json))
    }

    /// Loads every song of a playlist, following continuations.
    static func allPlaylistSongs(_ id: String, limit: Int = 5_000) async throws -> [Song] {
        let page = try await playlist(id)
        var songs = page.songs
        var token = page.continuation
        while let current = token, songs.count < limit {
            let next = try await playlistContinuation(current)
            if next.songs.isEmpty { break }
            songs += next.songs
            token = next.continuation
        }
        return songs
    }

    static func artist(_ browseId: String) async throws -> ArtistPage {
        let json = try await api.post("browse", body: ["browseId": browseId])
        var header = json["header"]["musicImmersiveHeaderRenderer"]
        if !header.exists { header = json["header"]["musicVisualHeaderRenderer"] }
        if !header.exists { header = json["header"]["musicHeaderRenderer"] }
        guard let title = header["title"].text else { throw YTError.parse("the artist") }

        return ArtistPage(
            artist: ArtistItem(
                id: browseId,
                title: title,
                thumbnail: Parser.thumbnail(header["thumbnail"]) ?? Parser.thumbnail(header["foregroundThumbnail"]),
                subtitle: header["subscriptionButton"].first("subscriberCountText").text
            ),
            description: header["description"].text,
            sections: Parser.sections(json["contents"]),
            radioPlaylistId: header["startRadioButton"].first("watchPlaylistEndpoint")["playlistId"].string
                ?? header["startRadioButton"].first("watchEndpoint")["playlistId"].string,
            shufflePlaylistId: header["playButton"].first("watchPlaylistEndpoint")["playlistId"].string
                ?? header["playButton"].first("watchEndpoint")["playlistId"].string
        )
    }

    // MARK: - Queue / radio

    static func queue(
        videoId: String? = nil,
        playlistId: String? = nil,
        params: String? = nil,
        continuation: String? = nil
    ) async throws -> QueuePage {
        var body: [String: Any] = [
            "isAudioOnly": true,
            "enablePersistentPlaylistPanel": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        body["videoId"] = videoId
        body["playlistId"] = playlistId
        body["params"] = params
        body["continuation"] = continuation
        let json = try await api.post("next", body: body)

        var panel = json["continuationContents"]["playlistPanelContinuation"]
        if !panel.exists { panel = json.first("playlistPanelRenderer") }

        var page = QueuePage(songs: [])
        for entry in panel["contents"].array {
            if let song = Parser.panelVideo(entry["playlistPanelVideoRenderer"]) {
                page.songs.append(song)
            } else if entry["playlistPanelVideoWrapperRenderer"].exists {
                let wrapper = entry["playlistPanelVideoWrapperRenderer"]
                guard let primary = Parser.panelVideo(wrapper["primaryRenderer"]["playlistPanelVideoRenderer"]) else { continue }
                page.songs.append(primary)
                for counterpart in wrapper["counterpart"].array {
                    guard let other = Parser.panelVideo(counterpart["counterpartRenderer"]["playlistPanelVideoRenderer"]) else { continue }
                    page.counterparts[primary.id] = other
                    page.counterparts[other.id] = primary
                }
            } else if entry["automixPreviewVideoRenderer"].exists {
                let endpoint = entry["automixPreviewVideoRenderer"].first("watchPlaylistEndpoint")
                page.automixPlaylistId = endpoint["playlistId"].string
                page.automixParams = endpoint["params"].string
            }
        }
        page.continuation = panel["continuations"][0]["nextRadioContinuationData"]["continuation"].string
            ?? panel["continuations"][0]["nextContinuationData"]["continuation"].string

        let tabs = json["contents"]["singleColumnMusicWatchNextResultsRenderer"]["tabbedRenderer"]["watchNextTabbedResultsRenderer"]["tabs"].array
        page.lyricsBrowseId = tabs
            .map { $0["tabRenderer"]["endpoint"] }
            .first { Parser.pageType($0) == "MUSIC_PAGE_TYPE_TRACK_LYRICS" }?["browseEndpoint"]["browseId"].string
        return page
    }

    /// YouTube Music's video type (`MUSIC_VIDEO_TYPE_OMV`, `…_UGC`, `…_ATV`…) of up to 50
    /// videos in one request, as the web player's "add to queue" asks for them. Ids it doesn't
    /// answer for (removed videos) are left out.
    static func videoTypes(_ videoIds: [String]) async throws -> [String: String] {
        let json = try await api.post("music/get_queue", body: ["videoIds": Array(videoIds.prefix(50))])
        var types: [String: String] = [:]
        for entry in json["queueDatas"].array {
            let content = entry["content"]
            let renderers = [content["playlistPanelVideoRenderer"], content["playlistPanelVideoWrapperRenderer"]["primaryRenderer"]["playlistPanelVideoRenderer"]]
                + content["playlistPanelVideoWrapperRenderer"]["counterpart"].array.map { $0["counterpartRenderer"]["playlistPanelVideoRenderer"] }
            for renderer in renderers where renderer.exists {
                guard let song = Parser.panelVideo(renderer), let type = song.videoType else { continue }
                types[song.id] = type
            }
        }
        return types
    }

    /// The endless radio seeded by a single song.
    static func radio(for videoId: String) async throws -> QueuePage {
        try await queue(videoId: videoId, playlistId: "RDAMVM" + videoId, params: "wAEB")
    }

    static func plainLyrics(videoId: String) async throws -> String? {
        let page = try await queue(videoId: videoId)
        guard let browseId = page.lyricsBrowseId else { return nil }
        let json = try await api.post("browse", body: ["browseId": browseId])
        return json.first("musicDescriptionShelfRenderer")["description"].text
    }

    // MARK: - Audio counterpart

    /// Finds the audio (art-track) release matching a music video, so the app never plays a
    /// video's soundtrack when a proper song version exists.
    /// `strictLength` off (playlists, radio, Autoplay): a release of another length is taken
    /// when it's the closest match, since music videos often add intros or skits.
    static func audioCounterpart(for song: Song, strictLength: Bool = true) async -> Song? {
        guard song.isVideo else { return nil }
        // When the item names its album, the album's own track list is authoritative: it is
        // the distributor's audio for exactly that edition (explicit or clean).
        if let albumId = song.album?.id, let page = try? await album(albumId) {
            let wanted = normalized(baseTitle(song.title))
            if let track = page.songs.first(where: { normalized(baseTitle($0.title)) == wanted }), track.id != song.id {
                return track
            }
        }
        if let page = try? await queue(videoId: song.id),
           let counterpart = page.counterparts[song.id], !counterpart.isVideo {
            return counterpart
        }
        return await searchedAudioVersion(for: song, strictLength: strictLength)
    }

    /// The audio release of a music video found by searching YouTube Music's songs: one
    /// request. The title (without decorations), the version (live, remix…) and an artist
    /// must agree, and the length must be within 20 seconds of the video's.
    ///
    /// With `strictLength` off (playlists), a release whose length differs more is still
    /// taken when nothing closer matches: music videos often add intros or skits.
    static func searchedAudioVersion(for song: Song, strictLength: Bool = true) async -> Song? {
        guard song.isVideo else { return nil }
        // Uploads titled "Artist - Song" name the real artist in the title, not as the uploader.
        let unbracketed = song.title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        let titleArtist = unbracketed.range(of: " - ").map { String(unbracketed[..<$0.lowerBound]) }
        let query = ([baseTitle(song.title)] + (titleArtist.map { [$0] } ?? song.artists.prefix(1).map(\.name))).joined(separator: " ")
        guard let results = try? await search(query, filter: .songs) else { return nil }
        let wantedTitle = normalized(baseTitle(song.title))
        let wantedArtists = song.artists.map { normalized($0.name) }.filter { !$0.isEmpty }
        let titleBlob = normalized(song.title)
        let wantedVariant = variantKeywords(song.title)
        guard !wantedTitle.isEmpty else { return nil }

        let matches = results.sections.flatMap(\.items).compactMap(\.song).prefix(8).filter { candidate in
            guard !candidate.isVideo,
                  normalized(baseTitle(candidate.title)) == wantedTitle,
                  variantKeywords(candidate.title) == wantedVariant
            else { return false }
            // The uploader of a video isn't always the artist, so also accept an artist named in its title.
            return candidate.artists.map { normalized($0.name) }.contains { artist in
                !artist.isEmpty && (wantedArtists.contains { $0.contains(artist) || artist.contains($0) } || titleBlob.contains(artist))
            }
        }
        guard let length = song.duration else { return matches.first }
        // Prefer the edit whose length matches the video; never swap in a clearly different cut.
        let close = matches.filter { abs(($0.duration ?? length) - length) <= 20 }
        if close.isEmpty, !strictLength {
            return matches.min { abs(($0.duration ?? length) - length) < abs(($1.duration ?? length) - length) }
        }
        return close
            .min { first, second in
                // An explicit video maps to the explicit recording. Otherwise, between equally
                // titled cuts, the explicit one is the original album version.
                if first.explicit != second.explicit { return first.explicit }
                // Prefer a track that belongs to an album over a stand-alone single or edit.
                if (first.album != nil) != (second.album != nil) { return first.album != nil }
                return abs((first.duration ?? length) - length) < abs((second.duration ?? length) - length)
            }
    }

    /// Audio releases for the music videos of a playlist, keyed by the video's id, reported
    /// as they are found (first rows first). Signed-in queues can pair each video with its
    /// song version, so that is asked first, in one request; the rest are searched, several
    /// at a time, and every answer (including "none") is remembered on disk.
    /// `found` receives answers as they come: a song, or nil inside the optional for "none".
    static func audioVersions(forPlaylist playlistId: String?, videos: [Song], found: @escaping @MainActor ([String: Song?]) -> Void) async {
        var wanted = videos.filter(\.isVideo)
        guard !wanted.isEmpty else { return }
        let cache = AudioVersionCache.shared
        let known = await cache.lookup(wanted.map(\.id))
        if !known.isEmpty { await found(known) }
        wanted.removeAll { known[$0.id] != nil }
        guard !wanted.isEmpty else { return }

        // Only signed-in queues carry the pairs; an anonymous one never does, so skip it.
        if let playlistId, api.isSignedIn {
            let id = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
            if let page = try? await queue(playlistId: id), !page.counterparts.isEmpty {
                let ids = Set(wanted.map(\.id))
                let paired = page.counterparts.filter { ids.contains($0.key) && !$0.value.isVideo && $0.value.id != $0.key }
                if !paired.isEmpty {
                    await cache.store(paired.mapValues { Optional($0) })
                    await found(paired.mapValues { Optional($0) })
                    wanted.removeAll { paired[$0.id] != nil }
                }
            }
        }

        // Searches, eight at a time, in the order the songs are listed.
        await withTaskGroup(of: (String, Song?).self) { group in
            var next = 0
            func launch() {
                guard next < wanted.count else { return }
                let video = wanted[next]
                next += 1
                group.addTask { (video.id, await searchedAudioVersion(for: video, strictLength: false)) }
            }
            for _ in 0 ..< min(8, wanted.count) { launch() }
            var batch: [String: Song?] = [:]
            for await (id, audio) in group {
                batch[id] = audio
                // Report in small batches so the list doesn't redraw for every song.
                if batch.count >= 4 || next >= wanted.count {
                    await cache.store(batch)
                    await found(batch)
                    batch = [:]
                }
                launch()
            }
            if !batch.isEmpty {
                await cache.store(batch)
                await found(batch)
            }
        }
    }

    /// The bare song title: no "Artist - " prefix, bracketed decorations or featured-artist credits.
    private static func baseTitle(_ title: String) -> String {
        // Brackets go first: a dash inside "(Radio Edit - feat. X)" is not an "Artist - Title" split.
        var result = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        if let dash = result.range(of: " - ") { result = String(result[dash.upperBound...]) }
        result = result.replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring)\s.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Words that make a recording a different performance; both sides must agree on them.
    private static func variantKeywords(_ title: String) -> Set<String> {
        let keywords = ["live", "cover", "remix", "karaoke", "acoustic", "instrumental", "slowed", "sped", "reverb", "nightcore", "8d", "demo", "mashup"]
        let lowered = title.lowercased()
        return Set(keywords.filter { lowered.range(of: "\\b\($0)\\b", options: .regularExpression) != nil })
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "&", with: "and")
            .filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Account

    struct Account: Codable {
        var name: String
        var email: String?
        var thumbnail: String?
    }

    static func account() async throws -> Account? {
        let json = try await api.post("account/account_menu", body: [:])
        let header = json.first("activeAccountHeaderRenderer")
        guard let name = header["accountName"].text else { return nil }
        return Account(name: name, email: header["email"].text, thumbnail: Parser.thumbnail(header["accountPhoto"]))
    }

    /// Every item on one of the account's library pages (albums, artists or playlists).
    static func libraryItems(_ browseId: String) async throws -> [YTItem] {
        var json = try await api.post("browse", body: ["browseId": browseId])
        var items = Parser.sections(json["contents"]).flatMap(\.items)
        var token = Parser.continuation(json["contents"])
        var rounds = 0
        while let current = token, rounds < 30 {
            json = try await api.post(
                "browse", body: ["continuation": current],
                query: ["ctoken": current, "continuation": current, "type": "next"]
            )
            let more: [YTItem] = json.collect(["musicTwoRowItemRenderer", "musicResponsiveListItemRenderer"]).compactMap {
                $0.key == "musicTwoRowItemRenderer" ? Parser.twoRowItem($0.value) : Parser.responsiveItem($0.value)
            }
            if more.isEmpty { break }
            items += more
            token = Parser.continuation(json)
            rounds += 1
        }
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Adds or removes an album, playlist or artist in the account's YouTube Music library.
    static func setInLibrary(_ item: YTItem, saved: Bool) async throws {
        switch item {
        case .song(let song):
            try await setLiked(saved, videoId: song.id)
        case .album(let album):
            var playlistId = album.playlistId
            if playlistId == nil { playlistId = try await YTMusic.album(album.id).album.playlistId }
            guard let playlistId else { return }
            _ = try await api.post(saved ? "like/like" : "like/removelike", body: ["target": ["playlistId": playlistId]])
        case .playlist(let playlist):
            _ = try await api.post(saved ? "like/like" : "like/removelike", body: ["target": ["playlistId": playlist.id]])
        case .artist(let artist):
            _ = try await api.post(saved ? "subscription/subscribe" : "subscription/unsubscribe", body: ["channelIds": [artist.id]])
        }
    }

    /// Tells YouTube Music a song was played, so it appears in the account's history and
    /// feeds its recommendations. Returns the HTTP status of the statistics ping.
    ///
    /// As in Metrolist, the tracking address comes from a signed-in WEB_REMIX player request
    /// made for this purpose, never from the anonymous device identity the audio is streamed
    /// with: reporting a spoofed device's playback session with the account's cookies links
    /// the two, and that is what makes YouTube treat the account as a bot.
    @discardableResult
    static func reportPlayback(videoId: String) async throws -> Int {
        guard api.isSignedIn else { return 0 }
        let json = try await api.post("player", client: .webRemix, body: ["videoId": videoId])
        guard let base = json["playbackTracking"]["videostatsPlaybackUrl"]["baseUrl"].string,
              var components = URLComponents(string: base.replacingOccurrences(of: "https://s.youtube.com", with: "https://music.youtube.com")),
              let host = components.host, host.hasSuffix("youtube.com"), components.path == "/api/stats/playback"
        else { throw YTError.parse("playback tracking") }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let nonce = String((0 ..< 16).map { _ in alphabet.randomElement()! })
        var items = (components.queryItems ?? []).filter { !["cpn", "ver", "c"].contains($0.name) }
        items += [
            URLQueryItem(name: "ver", value: "2"),
            URLQueryItem(name: "c", value: YouTubeClient.webRemix.clientName),
            URLQueryItem(name: "cpn", value: nonce),
        ]
        components.queryItems = items
        guard let url = components.url else { throw YTError.parse("playback tracking") }
        return try await api.authorizedGet(url)
    }

    // MARK: - Account playlists

    /// Creates a playlist on the signed-in account and returns its id. It is private, so it
    /// shows on the listener's own devices and nowhere else.
    static func createPlaylist(title: String, description: String = "", videoIds: [String]) async throws -> String {
        guard api.isSignedIn else { throw YTError.parse("a playlist: not signed in") }
        // Long lists go in batches: the first with the playlist, the rest added afterwards.
        let first = Array(videoIds.prefix(100))
        let json = try await api.post("playlist/create", body: [
            "title": String(title.prefix(150)), "description": String(description.prefix(300)),
            "privacyStatus": "PRIVATE", "videoIds": first,
        ])
        guard let id = json["playlistId"].string, !id.isEmpty else { throw YTError.parse("the new playlist") }
        var rest = Array(videoIds.dropFirst(first.count))
        while !rest.isEmpty {
            try await addToPlaylist(id, videoIds: Array(rest.prefix(100)))
            rest.removeFirst(min(100, rest.count))
        }
        return id
    }

    static func addToPlaylist(_ playlistId: String, videoIds: [String]) async throws {
        guard !videoIds.isEmpty else { return }
        let actions = videoIds.map { ["action": "ACTION_ADD_VIDEO", "addedVideoId": $0, "dedupeOption": "DEDUPE_OPTION_SKIP"] }
        try await editPlaylist(playlistId, actions: actions)
    }

    /// Removes songs by video id. The playlist is read first, because removing needs the id of
    /// each entry (`setVideoId`), not only the song's.
    static func removeFromPlaylist(_ playlistId: String, videoIds: Set<String>) async throws {
        let entries = try await allPlaylistSongs(playlistId).filter { videoIds.contains($0.id) }
        let actions: [[String: Any]] = entries.compactMap { song in
            song.setVideoId.map { ["action": "ACTION_REMOVE_VIDEO", "removedVideoId": song.id, "setVideoId": $0] }
        }
        guard !actions.isEmpty else { return }
        try await editPlaylist(playlistId, actions: actions)
    }

    static func renamePlaylist(_ playlistId: String, to name: String) async throws {
        try await editPlaylist(playlistId, actions: [["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": String(name.prefix(150))]])
    }

    private static func editPlaylist(_ playlistId: String, actions: [[String: Any]]) async throws {
        guard api.isSignedIn else { throw YTError.parse("the playlist: not signed in") }
        let id = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let json = try await api.post("browse/edit_playlist", body: ["playlistId": id, "actions": actions])
        if let status = json["status"].string, status != "STATUS_SUCCEEDED" { throw YTError.parse("the playlist change (\(status))") }
    }

    static func setLiked(_ liked: Bool, videoId: String) async throws {
        _ = try await api.post(liked ? "like/like" : "like/removelike", body: ["target": ["videoId": videoId]])
    }
}
