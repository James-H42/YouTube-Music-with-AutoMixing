import Foundation

/// Converts InnerTube renderer JSON into app models.
enum Parser {
    struct Run {
        var text: String
        var browseId: String?
        var pageType: String?
        var videoId: String?
        var musicVideoType: String?

        var isSeparator: Bool {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed == "•" || trimmed == "," || trimmed == "&" || trimmed.isEmpty
        }

        var isArtist: Bool {
            pageType == "MUSIC_PAGE_TYPE_ARTIST" || pageType == "MUSIC_PAGE_TYPE_USER_CHANNEL" || pageType == "MUSIC_PAGE_TYPE_LIBRARY_ARTIST"
        }
        var isAlbum: Bool { pageType == "MUSIC_PAGE_TYPE_ALBUM" }
    }

    private static let typeLabels: Set<String> = [
        "Song", "Video", "Album", "Single", "EP", "Playlist", "Artist", "Episode", "Podcast", "Profile", "Station",
    ]

    // MARK: - Primitives

    static func thumbnail(_ json: JSON) -> String? {
        let thumbnails = json.first("thumbnails").array
        return thumbnails.max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }?["url"].string
    }

    static func pageType(_ endpoint: JSON) -> String? {
        endpoint["browseEndpoint"]["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string
    }

    /// Library pages link artists as "MPLA<channel id>"; the public page uses the bare id.
    static func artistId(_ browseId: String?) -> String? {
        guard let browseId, browseId.hasPrefix("MPLAUC") else { return browseId }
        return String(browseId.dropFirst(4))
    }

    static func musicVideoType(_ endpoint: JSON) -> String? {
        endpoint["watchEndpoint"]["watchEndpointMusicSupportedConfigs"]["watchEndpointMusicConfig"]["musicVideoType"].string
    }

    static func isVideoType(_ type: String?) -> Bool {
        guard let type else { return false }
        return type != "MUSIC_VIDEO_TYPE_ATV"
    }

    static func runs(_ text: JSON) -> [Run] {
        text["runs"].array.compactMap { run in
            guard let value = run["text"].string else { return nil }
            let endpoint = run["navigationEndpoint"]
            return Run(
                text: value,
                browseId: artistId(endpoint["browseEndpoint"]["browseId"].string),
                pageType: pageType(endpoint),
                videoId: endpoint["watchEndpoint"]["videoId"].string,
                musicVideoType: musicVideoType(endpoint)
            )
        }
    }

    /// Splits runs on the " • " bullets YouTube Music uses between metadata fields.
    static func groups(_ runs: [Run]) -> [[Run]] {
        var result: [[Run]] = [[]]
        for run in runs {
            if run.text.trimmingCharacters(in: .whitespaces) == "•" {
                result.append([])
            } else {
                result[result.count - 1].append(run)
            }
        }
        return result.filter { !$0.isEmpty }
    }

    static func seconds(_ text: String?) -> Int? {
        guard let text, text.range(of: #"^\d+(:\d{2}){1,2}$"#, options: .regularExpression) != nil else { return nil }
        return text.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    private static func groupText(_ group: [Run]) -> String {
        group.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    }

    private static func isMetadataGroup(_ group: [Run]) -> Bool {
        let text = groupText(group)
        if typeLabels.contains(text) || seconds(text) != nil { return true }
        if text.range(of: #"^\d{4}$"#, options: .regularExpression) != nil { return true }
        return text.range(of: #"\b(plays|views|subscribers|songs|tracks|likes|monthly audience)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func artists(in groups: [[Run]]) -> [ArtistRef] {
        let all = groups.flatMap { $0 }
        let linked = all.filter(\.isArtist)
        if !linked.isEmpty {
            // Include unlinked collaborators that sit in the same group as a linked artist.
            if let group = groups.first(where: { $0.contains(where: \.isArtist) }) {
                return group.filter { !$0.isSeparator && !$0.isAlbum }.map { ArtistRef(name: $0.text, id: $0.browseId) }
            }
            return linked.map { ArtistRef(name: $0.text, id: $0.browseId) }
        }
        guard let group = groups.first(where: { !isMetadataGroup($0) && !$0.contains(where: \.isAlbum) }) else { return [] }
        return group.filter { !$0.isSeparator }.map { ArtistRef(name: $0.text.trimmingCharacters(in: .whitespaces), id: nil) }
    }

    private static func album(in groups: [[Run]]) -> AlbumRef? {
        groups.flatMap { $0 }.first(where: \.isAlbum).map { AlbumRef(name: $0.text, id: $0.browseId) }
    }

    private static func year(in groups: [[Run]]) -> String? {
        groups.map(groupText).first { $0.range(of: #"^\d{4}$"#, options: .regularExpression) != nil }
    }

    private static func isExplicit(_ badges: JSON) -> Bool {
        badges.array.contains { $0["musicInlineBadgeRenderer"]["icon"]["iconType"].string == "MUSIC_EXPLICIT_BADGE" }
    }

    // MARK: - Items

    static func item(_ wrapper: JSON) -> YTItem? {
        if wrapper["musicResponsiveListItemRenderer"].exists {
            return responsiveItem(wrapper["musicResponsiveListItemRenderer"])
        }
        if wrapper["musicTwoRowItemRenderer"].exists {
            return twoRowItem(wrapper["musicTwoRowItemRenderer"])
        }
        return nil
    }

    static func responsiveItem(_ renderer: JSON) -> YTItem? {
        let columns = renderer["flexColumns"].array.map {
            runs($0["musicResponsiveListItemFlexColumnRenderer"]["text"])
        }
        guard let titleRuns = columns.first, let titleRun = titleRuns.first else { return nil }
        let title = titleRuns.map(\.text).joined()
        let detailGroups = columns.dropFirst().flatMap { groups($0) }
        let thumb = thumbnail(renderer["thumbnail"])
        let explicit = isExplicit(renderer["badges"])
        let playEndpoint = renderer["overlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]

        let videoId = renderer["playlistItemData"]["videoId"].string
            ?? titleRun.videoId
            ?? playEndpoint["watchEndpoint"]["videoId"].string

        if let videoId {
            let fixed = renderer["fixedColumns"][0]["musicResponsiveListItemFixedColumnRenderer"]["text"].text
            let duration = seconds(fixed) ?? detailGroups.map(groupText).compactMap(seconds).first
            let type = titleRun.musicVideoType ?? musicVideoType(playEndpoint)
            return .song(Song(
                id: videoId,
                title: title,
                artists: artists(in: detailGroups),
                album: album(in: detailGroups),
                duration: duration,
                thumbnail: thumb,
                explicit: explicit,
                isVideo: isVideoType(type),
                setVideoId: renderer["playlistItemData"]["playlistSetVideoId"].string
            ))
        }

        let endpoint = renderer["navigationEndpoint"]
        guard let browseId = artistId(endpoint["browseEndpoint"]["browseId"].string) else { return nil }
        let described = detailGroups.filter { !typeLabels.contains(groupText($0)) }
        switch pageType(endpoint) {
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST":
            return .artist(ArtistItem(
                id: browseId,
                title: title,
                thumbnail: thumb,
                subtitle: described.map(groupText).first
            ))
        case "MUSIC_PAGE_TYPE_ALBUM":
            return .album(AlbumItem(
                id: browseId,
                playlistId: playEndpoint["watchPlaylistEndpoint"]["playlistId"].string,
                title: title,
                artists: artists(in: detailGroups),
                year: year(in: detailGroups),
                thumbnail: thumb,
                explicit: explicit
            ))
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            return .playlist(PlaylistItem(
                id: browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId,
                title: title,
                author: described.first.map(groupText),
                subtitle: described.dropFirst().map(groupText).joined(separator: " • "),
                thumbnail: thumb
            ))
        default:
            return nil
        }
    }

    static func twoRowItem(_ renderer: JSON) -> YTItem? {
        guard let title = renderer["title"].text else { return nil }
        let subtitleGroups = groups(runs(renderer["subtitle"]))
        let thumb = thumbnail(renderer["thumbnailRenderer"])
        let endpoint = renderer["navigationEndpoint"]
        let explicit = isExplicit(renderer["subtitleBadges"])

        if let videoId = endpoint["watchEndpoint"]["videoId"].string {
            return .song(Song(
                id: videoId,
                title: title,
                artists: artists(in: subtitleGroups),
                album: album(in: subtitleGroups),
                thumbnail: thumb,
                explicit: explicit,
                isVideo: isVideoType(musicVideoType(endpoint))
            ))
        }

        guard let browseId = artistId(endpoint["browseEndpoint"]["browseId"].string) else { return nil }
        let described = subtitleGroups.filter { !typeLabels.contains(groupText($0)) }
        switch pageType(endpoint) {
        case "MUSIC_PAGE_TYPE_ALBUM":
            let playlistId = renderer["thumbnailOverlay"].first("watchPlaylistEndpoint")["playlistId"].string
                ?? renderer["menu"].first("watchPlaylistEndpoint")["playlistId"].string
            return .album(AlbumItem(
                id: browseId,
                playlistId: playlistId,
                title: title,
                artists: artists(in: subtitleGroups),
                year: year(in: subtitleGroups),
                thumbnail: thumb,
                explicit: explicit
            ))
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST":
            return .artist(ArtistItem(id: browseId, title: title, thumbnail: thumb, subtitle: described.map(groupText).first))
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            return .playlist(PlaylistItem(
                id: browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId,
                title: title,
                author: described.first.map(groupText),
                subtitle: described.dropFirst().map(groupText).joined(separator: " • "),
                thumbnail: thumb
            ))
        default:
            return nil
        }
    }

    /// A row from the watch queue (`playlistPanelVideoRenderer`).
    static func panelVideo(_ renderer: JSON) -> Song? {
        guard let videoId = renderer["videoId"].string, let title = renderer["title"].text else { return nil }
        let bylineGroups = groups(runs(renderer["longBylineText"]))
        return Song(
            id: videoId,
            title: title,
            artists: artists(in: bylineGroups),
            album: album(in: bylineGroups),
            duration: seconds(renderer["lengthText"].text),
            thumbnail: thumbnail(renderer["thumbnail"]),
            explicit: isExplicit(renderer["badges"]),
            isVideo: isVideoType(musicVideoType(renderer["navigationEndpoint"])),
            setVideoId: renderer["playlistSetVideoId"].string
        )
    }

    // MARK: - Sections

    private static let sectionKeys: Set<String> = [
        "musicCarouselShelfRenderer", "musicShelfRenderer", "gridRenderer",
        "musicPlaylistShelfRenderer", "musicCardShelfRenderer",
    ]

    static func sections(_ json: JSON) -> [ItemSection] {
        json.collect(sectionKeys).compactMap { key, value in
            let section: ItemSection
            switch key {
            case "musicCarouselShelfRenderer":
                let header = value["header"]["musicCarouselShelfBasicHeaderRenderer"]
                let items = value["contents"].array.compactMap(item)
                let isList = value["contents"][0]["musicResponsiveListItemRenderer"].exists
                section = ItemSection(
                    title: header["title"].text ?? "",
                    items: items,
                    more: browseEndpoint(header["moreContentButton"]["buttonRenderer"]["navigationEndpoint"]),
                    isList: isList
                )
            case "musicShelfRenderer":
                section = ItemSection(
                    title: value["title"].text ?? "",
                    items: value["contents"].array.compactMap(item),
                    more: browseEndpoint(value["bottomEndpoint"]),
                    isList: true
                )
            case "musicPlaylistShelfRenderer":
                section = ItemSection(title: "", items: value["contents"].array.compactMap(item), isList: true)
            case "gridRenderer":
                section = ItemSection(
                    title: value["header"]["gridHeaderRenderer"]["title"].text ?? "",
                    items: value["items"].array.compactMap(item)
                )
            default:
                let top = cardItem(value)
                // Rows under an artist card omit the artist's name.
                let rows: [YTItem] = value["contents"].array.compactMap(item).map { row in
                    guard case .song(var song) = row, song.artists.isEmpty, case .artist(let artist)? = top else { return row }
                    song.artists = [ArtistRef(name: artist.title, id: artist.id)]
                    return .song(song)
                }
                section = ItemSection(title: "Top result", items: [top].compactMap { $0 } + rows, isList: true)
            }
            return section.items.isEmpty ? nil : section
        }
    }

    /// Sections of the search page's "All" tab. YouTube Music sends the results after the top
    /// one as a flat run of single-row sections, each row labelled with its kind ("Song",
    /// "Artist"…); they are gathered here into one titled section per kind, in the order the
    /// kinds first appear.
    static func searchSections(_ json: JSON) -> [ItemSection] {
        let entries = json.first("sectionListRenderer")["contents"].array
        guard entries.contains(where: { $0["itemSectionRenderer"].exists }) else { return sections(json) }
        var result: [ItemSection] = []
        var position: [String: Int] = [:]
        for entry in entries {
            let rows = entry["itemSectionRenderer"]["contents"].array
            guard entry["itemSectionRenderer"].exists else {
                result += sections(entry)
                continue
            }
            for row in rows {
                let renderer = row["musicResponsiveListItemRenderer"]
                let label = runs(renderer["flexColumns"][1]["musicResponsiveListItemFlexColumnRenderer"]["text"]).first?.text ?? ""
                let title: String
                switch label {
                case "Song": title = "Songs"
                case "Video": title = "Videos"
                case "Artist": title = "Artists"
                case "Album", "Single", "EP": title = "Albums"
                case "Playlist": title = "Playlists"
                default: continue
                }
                guard let found = item(row) else { continue }
                if let index = position[title] {
                    if !result[index].items.contains(found) { result[index].items.append(found) }
                } else {
                    position[title] = result.count
                    result.append(ItemSection(title: title, items: [found], isList: true))
                }
            }
        }
        return result
    }

    private static func browseEndpoint(_ endpoint: JSON) -> BrowseEndpoint? {
        guard let browseId = endpoint["browseEndpoint"]["browseId"].string else { return nil }
        return BrowseEndpoint(browseId: browseId, params: endpoint["browseEndpoint"]["params"].string)
    }

    /// The highlighted "top result" card on the search page.
    private static func cardItem(_ card: JSON) -> YTItem? {
        guard let titleRun = runs(card["title"]).first else { return nil }
        let subtitleGroups = groups(runs(card["subtitle"]))
        let thumb = thumbnail(card["thumbnail"])
        if let videoId = titleRun.videoId {
            return .song(Song(
                id: videoId,
                title: titleRun.text,
                artists: artists(in: subtitleGroups),
                album: album(in: subtitleGroups),
                duration: subtitleGroups.map(groupText).compactMap(seconds).first,
                thumbnail: thumb,
                explicit: isExplicit(card["subtitleBadges"]),
                isVideo: isVideoType(titleRun.musicVideoType)
            ))
        }
        guard let browseId = titleRun.browseId else { return nil }
        let described = subtitleGroups.filter { !typeLabels.contains(groupText($0)) }
        switch titleRun.pageType {
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST":
            return .artist(ArtistItem(id: browseId, title: titleRun.text, thumbnail: thumb, subtitle: described.map(groupText).first))
        case "MUSIC_PAGE_TYPE_ALBUM":
            return .album(AlbumItem(
                id: browseId,
                playlistId: card.first("watchPlaylistEndpoint")["playlistId"].string,
                title: titleRun.text,
                artists: artists(in: subtitleGroups),
                year: year(in: subtitleGroups),
                thumbnail: thumb
            ))
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            return .playlist(PlaylistItem(
                id: browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId,
                title: titleRun.text,
                author: described.first.map(groupText),
                thumbnail: thumb
            ))
        default:
            return nil
        }
    }

    static func continuation(_ json: JSON) -> String? {
        json.first("nextContinuationData")["continuation"].string
            ?? json.first("nextRadioContinuationData")["continuation"].string
            ?? json.first("continuationItemRenderer")["continuationEndpoint"]["continuationCommand"]["token"].string
    }
}
