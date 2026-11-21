import Foundation

/// `--featuretest`: offline checks for the features added on 2026-11-19. Run it with
/// `METROLIST_HOME` pointing at a throwaway folder: it writes a library there.
@MainActor
enum FeatureTests {
    private static var failures = 0

    private static func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "PASS" : "FAIL") \(label)\(ok ? "" : " — \(detail())")")
        if !ok { failures += 1 }
    }

    static func run() {
        // METROLIST_RELINKCHECK=1 with METROLIST_HOME holding a copy of a real library: runs
        // one sync's merge with the playlists already listed and prints the result.
        if ProcessInfo.processInfo.environment["METROLIST_RELINKCHECK"] == "1" {
            let library = LibraryStore()
            library.mergeRemote(liked: nil, albums: nil, artists: nil, playlists: library.savedPlaylists)
            for playlist in library.playlists { print("local “\(playlist.name)” (\(playlist.songIds.count)) → \(playlist.remoteId ?? "not linked")") }
            print("sidebar:", library.sidebarPlaylists.map { entry -> String in
                switch entry { case .local(let p): "local:\(p.name)"; case .remote(let p): "account:\(p.title)" }
            })
            exit(0)
        }
        albumQueue()
        sidebarOrder()
        csvParsing()
        filterCounts()
        headerCrop()
        stemTiming()
        print(failures == 0 ? "all feature checks passed" : "\(failures) feature check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// 2026-11-21: stems in a transition. The outgoing vocals leave just before the incoming
    /// ones start, never with both heard for a quarter of the overlap; stems that arrive after a
    /// deck has read ahead change only what it reads next, faded in; a side without stems swaps
    /// its bass on the EQ.
    private static func stemTiming() {
        // 16 beats; the incoming sings from 37 % of the overlap, the outgoing throughout.
        let later = MixEngine.vocalHandOver(singingA: [0 ... 1], singingB: [0.37 ... 0.9], beats: 16, span: 8)
        let cut = later.curve?.points.first { $0.y < 0.001 }?.x ?? -1
        check(later.curve != nil && cut <= 0.37 && cut > 0.3 && later.curve!.value(at: 0.25) > 0.99,
              "the outgoing vocals stay until the beat before the incoming vocals, then leave", "out at \(cut)")
        let straight = MixEngine.vocalHandOver(singingA: [0 ... 1], singingB: [0 ... 1], beats: 16, span: 8)
        let first = straight.curve?.points.first { $0.y < 0.001 }?.x ?? -1
        check(first > 0 && first <= 1.0 / 16, "when both sing from the start, within the first beat", "out at \(first)")
        let brief = MixEngine.vocalHandOver(singingA: [0 ... 0.5], singingB: [0.45 ... 1], beats: 16, span: 8)
        check(brief.curve == nil, "less than a second of both singing leaves the outgoing vocals alone", String(format: "%.1f s together", brief.together))
        var lanes = StemLanes()
        lanes.vocals = MixCurve([(0, 1), (0.25, 0), (1, 0)])
        let onTime = MixEngine.stemGains(lanes, start: 100, span: 10, beats: 16, readFrom: 95)
        check(abs(onTime(101.25)[3] - 0.5) < 0.01, "stems in place in time follow the plan", "\(onTime(101.25)[3])")
        // The deck has already read up to 103 s (30 % of the overlap): from there the move fades in
        // over a beat instead of jumping to "vocals out".
        let late = MixEngine.stemGains(lanes, start: 100, span: 10, beats: 16, readFrom: 103)
        check(late(103.01)[3] > 0.9 && late(103.7)[3] < 0.01 && abs(late(103.3)[3] - 0.52) < 0.05,
              "late stems fade in from where the deck has read to, over a beat", "\(late(103.01)[3]) \(late(103.3)[3]) \(late(103.7)[3])")
        var plan = MixPlan(preset: .auto, outStart: 100, inPoint: 10, sync: true, beats: 16, seconds: 8, periodA: 0.5, periodB: 0.5,
                           outgoing: DeckLanes(volume: MixCurve([(0, 1), (1, 0)])), incoming: DeckLanes(volume: MixCurve([(0, 0), (1, 1)])))
        plan.outgoingStems = StemLanes(bass: MixCurve([(0, 1), (0.5, 1), (0.53, 0), (1, 0)]))
        plan.incomingStems = StemLanes(bass: MixCurve([(0, 0), (0.5, 0), (0.53, 1), (1, 1)]))
        plan.outgoing.bass = .constant(1)
        plan.incoming.bass = .constant(1)
        let fallback = MixEngine.withoutStems(plan, outgoing: true, incoming: false)
        check(fallback.outgoing.bass.isConstant && fallback.incoming.bass.value(at: 0.2) < 0.01 && fallback.incoming.bass.value(at: 0.8) > 0.99,
              "a side without its stems swaps its bass on the EQ")
    }

    private static func song(_ id: String, album: String?) -> Song {
        Song(id: id, title: id, artists: [ArtistRef(name: "A", id: nil)], album: album.map { AlbumRef(name: $0, id: $0) })
    }

    /// Task 7: a queue made of one album stops at its end; anything else keeps Autoplay.
    private static func albumQueue() {
        let album = [song("a1", album: "MPREb_x"), song("a2", album: "MPREb_x"), song("a3", album: "MPREb_x")]
        check(PlayerController.albumId(of: album, source: nil) == "MPREb_x", "three tracks of one album are an album queue")
        check(PlayerController.albumId(of: [song("p", album: "MPREb_y")], source: "MPREb_y") == "MPREb_y", "a queue started from an album page is an album queue")
        check(PlayerController.albumId(of: album + [song("b", album: "MPREb_z")], source: nil) == nil, "a playlist mixing albums is not")
        check(PlayerController.albumId(of: [song("s", album: "MPREb_x")], source: nil) == nil, "a single song (radio) is not")
        check(PlayerController.albumId(of: album, source: "VLPL123") == "MPREb_x", "an album's songs played from a playlist page still count")
    }

    /// Tasks 6 and 9: the sidebar order is kept, and a local playlist with an account copy
    /// is listed once.
    private static func sidebarOrder() {
        try? FileManager.default.removeItem(at: AppPaths.library)
        let library = LibraryStore()
        let first = library.createPlaylist(name: "First")
        let second = library.createPlaylist(name: "Second")
        library.mergeRemote(liked: nil, albums: nil, artists: nil, playlists: [PlaylistItem(id: "PLremote", title: "Remote")])
        check(library.sidebarPlaylists.map(\.id) == ["local:\(first.id)", "local:\(second.id)", "remote:PLremote"], "default order: local then account playlists",
              library.sidebarPlaylists.map(\.id).description)
        library.moveSidebarPlaylists(from: IndexSet(integer: 2), to: 0)
        library.moveSidebarPlaylists(from: IndexSet(integer: 2), to: 1)
        let arranged = library.sidebarPlaylists.map(\.id)
        check(arranged == ["remote:PLremote", "local:\(second.id)", "local:\(first.id)"], "dragging rearranges the list", arranged.description)
        let third = library.createPlaylist(name: "Third")
        check(library.sidebarPlaylists.last?.id == "local:\(third.id)", "a new playlist goes at the end")
        library.saveNow()
        let reloaded = LibraryStore()
        check(reloaded.sidebarPlaylists.map(\.id) == library.sidebarPlaylists.map(\.id), "the order survives a restart")

        reloaded.link(first.id, toRemote: PlaylistItem(id: "PLcopy", title: "First"))
        let ids = reloaded.sidebarPlaylists.map(\.id)
        check(!ids.contains("remote:PLcopy") && ids.contains("local:\(first.id)"), "an uploaded playlist is listed once in the sidebar", ids.description)
        check(reloaded.savedPlaylists.contains { $0.id == "PLcopy" }, "and appears with the account's playlists (Playlists page)")
        // A sync sees the copy on the account; a later one no longer does (deleted on
        // another device): unlink, keep the local playlist.
        reloaded.mergeRemote(liked: nil, albums: nil, artists: nil, playlists: [PlaylistItem(id: "PLremote", title: "Remote"), PlaylistItem(id: "PLcopy", title: "First")])
        check(reloaded.playlist(first.id)?.remoteId == "PLcopy", "a sync that sees the copy keeps the link")
        reloaded.mergeRemote(liked: nil, albums: nil, artists: nil, playlists: [PlaylistItem(id: "PLremote", title: "Remote")])
        check(reloaded.playlist(first.id)?.remoteId == nil, "a copy deleted elsewhere unlinks the local playlist")

        // A failed request (no playlists at all) and a copy too new to be listed keep links.
        reloaded.link(second.id, toRemote: PlaylistItem(id: "PLnew", title: "Second"))
        reloaded.mergeRemote(liked: nil, albums: nil, artists: nil, playlists: [PlaylistItem(id: "PLremote", title: "Remote")])
        check(reloaded.playlist(second.id)?.remoteId == "PLnew", "a copy not listed yet stays linked")
        reloaded.mergeRemote(liked: nil, albums: nil, artists: nil, playlists: [PlaylistItem(id: "PLremote", title: "Remote"), PlaylistItem(id: "PLnew", title: "Second")])
        reloaded.mergeRemote(liked: nil, albums: nil, artists: nil, playlists: [])
        check(reloaded.playlist(second.id)?.remoteId == "PLnew", "an empty list (failed request) keeps the link")

        // The case seen on 2026-11-20: the link was lost, the copy is listed separately.
        try? FileManager.default.removeItem(at: AppPaths.library)
        let fresh = LibraryStore()
        let liked = fresh.createPlaylist(name: "Liked Songs - Spotify", songs: (0 ..< 3).map { song("v\($0)", album: nil) })
        let other = fresh.createPlaylist(name: "Same Name", songs: [song("w", album: nil)])
        fresh.mergeRemote(liked: nil, albums: nil, artists: nil, playlists: [
            PlaylistItem(id: "PLBbS0ZVq4_W0", title: "Liked Songs - Spotify", author: "3 tracks"),
            PlaylistItem(id: "PLsomeone", title: "Same Name", author: "Someone", subtitle: "12 tracks"),
        ])
        check(fresh.playlist(liked.id)?.remoteId == "PLBbS0ZVq4_W0", "a lost link is restored by name and song count")
        check(fresh.playlist(other.id)?.remoteId == nil, "a same-named playlist with another song count isn't linked")
        let sidebar = fresh.sidebarPlaylists.map(\.id)
        check(sidebar.filter { $0.contains("PLBbS0ZVq4_W0") }.isEmpty && sidebar.count == 3, "and the sidebar lists it once", sidebar.description)
        check(LibraryStore.trackCount(of: PlaylistItem(id: "x", title: "x", subtitle: "Someone • 1,204 songs")) == 1204, "song counts with separators are read")
    }

    /// Artist header: a square portrait in a wide header is cropped around the faces.
    private static func headerCrop() {
        let area = CGSize(width: 1500, height: 400)
        let square = CGSize(width: 1000, height: 1000)
        let top = FillImage.placement(of: square, in: area, focus: nil, alignment: .top)
        check(top.width == 1500 && top.height == 1500 && top.minY == 0, "no faces, top alignment: the top of the picture", "\(top)")
        let face = FillImage.placement(of: square, in: area, focus: CGPoint(x: 0.5, y: 0.4), alignment: .top)
        check(abs(face.minY - (200 - 600)) < 0.5, "a face 40% down is centred in the header", "\(face)")
        let low = FillImage.placement(of: square, in: area, focus: CGPoint(x: 0.5, y: 0.98), alignment: .top)
        check(low.minY == -1100, "never past the bottom edge", "\(low)")
        let wide = FillImage.placement(of: CGSize(width: 3000, height: 800), in: area, focus: nil, alignment: .center)
        check(wide.width == 1500 && abs(wide.height - 400) < 0.5, "a banner of about the header's shape fits whole", "\(wide)")
    }

    /// Task 1: video-id columns, other separators and Excel's `sep=` line.
    private static func csvParsing() {
        let file = "Title,Artist,Album,YouTube Video ID\n\"A, B\",X,\"\",iCEToNLagMc\nNo id,Y,Z,\n"
        let tracks = PlaylistImporter.parseCSV(file)
        check(tracks.count == 2 && tracks[0].videoId == "iCEToNLagMc" && tracks[0].title == "A, B" && tracks[0].album == nil && tracks[1].videoId == nil,
              "the YouTube Video ID column is read", tracks.description)
        let semicolon = PlaylistImporter.parseCSV("\u{FEFF}Track name;Artist name(s);Duration (ms)\nSong;Someone;215000\n")
        check(semicolon.first?.title == "Song" && semicolon.first?.duration == 215, "semicolon-separated file with a byte-order mark", semicolon.description)
        let directive = PlaylistImporter.parseCSV("sep=;\nTitle;Artist\nSong, with comma;Someone\n")
        check(directive.first?.title == "Song, with comma", "a sep=; line chooses the separator", directive.description)
        let tabs = PlaylistImporter.parseCSV("title\tartist\turl\nSong\tSomeone\thttps://music.youtube.com/watch?v=UlKjIWvPNWY&list=x\n")
        check(tabs.first?.videoId == "UlKjIWvPNWY", "tab-separated file with a YouTube link", tabs.description)
        check(PlaylistImporter.youTubeVideoId("https://youtu.be/ATpVIK55l1c?t=3") == "ATpVIK55l1c", "youtu.be links")
        check(PlaylistImporter.youTubeVideoId("https://evil.example/watch?v=ATpVIK55l1c") == nil, "links to other sites are ignored")
    }

    /// Task 10: the count shown beside a filter.
    private static func filterCounts() {
        check(FilterCount.text(shown: 3, total: 120, noun: "song") == "3 of 120 songs", "a filtered count reads “3 of 120 songs”", FilterCount.text(shown: 3, total: 120, noun: "song"))
        check(FilterCount.text(shown: 1, total: 1, noun: "song") == "1 of 1 song", "singular", FilterCount.text(shown: 1, total: 1, noun: "song"))
        check(FilterCount.text(shown: 2, total: 9, noun: "playlist") == "2 of 9 playlists", "other kinds of item")
    }
}
