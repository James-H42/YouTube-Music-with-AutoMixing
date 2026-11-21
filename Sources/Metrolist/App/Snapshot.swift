import AppKit
import SwiftUI

/// Renders the main screens offscreen to PNG files, for checking layout without launching
/// the app: `METROLIST_HOME=/tmp/x Metrolist --snapshot <output directory>`.
@MainActor
enum Snapshot {
    static func run() async {
        let directory = URL(fileURLWithPath: CommandLine.arguments.drop { $0 != "--snapshot" }.dropFirst().first ?? "snapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let dark = CommandLine.arguments.contains("--dark")
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let model = AppModel.shared
        model.player.volume = 0
        if CommandLine.arguments.contains("--automix") { model.settings.autoMix = true }

        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

        func capture<Content: View>(_ name: String, size: CGSize, settle: Double = 3, plain: Bool = false, @ViewBuilder _ content: () -> Content) async {
            let window = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                styleMask: plain ? [.borderless] : [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            if plain {
                window.isOpaque = false
                window.backgroundColor = .clear
            }
            let host = NSHostingView(rootView: content().environment(model).frame(width: size.width, height: size.height))
            window.contentView = host
            window.orderBack(nil)
            await wait(settle)
            host.layoutSubtreeIfNeeded()
            guard let frame = window.contentView?.superview ?? window.contentView,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: directory.appendingPathComponent("\(name).png"))
                print("wrote \(name).png")
            }
            window.orderOut(nil)
            window.close()
        }

        let main = CGSize(width: 1180, height: 760)

        if CommandLine.arguments.contains("--bartest") {
            await barTest(model: model, size: main)
            return
        }
        if CommandLine.arguments.contains("--clicktest") {
            await clickTest(model: model, size: main)
            return
        }

        if CommandLine.arguments.contains("--sound") {
            // `--snapshot dir --sound`: the Sound settings (with bit-perfect output on and off)
            // and the AutoEQ headphone search.
            for on in [false, true] {
                model.settings.bitPerfect = on
                await capture("settings-sound\(on ? "-bitperfect" : "")", size: CGSize(width: 520, height: 980), settle: 2) { SoundSettings() }
            }
            model.settings.bitPerfect = false
            await capture("autoeq-search", size: CGSize(width: 520, height: 480), settle: 5) { HeadphoneSearchSheet { _ in } }
            return
        }
        if CommandLine.arguments.contains("--concerts") {
            // `--snapshot dir --concerts`: Concerts from London and Manchester on the check's
            // sample concerts, a concert's page, the place picker, the key sheet, the settings
            // and (live, from MusicBrainz) YOASOBI's concerts on an artist page, from Tokyo.
            let store = ConcertStore.shared
            let event = (try? JSONSerialization.jsonObject(with: Data(ConcertTest.fixture.utf8))) as? [String: Any] ?? [:]
            var sample = ConcertTest.sample
            if let detailed = Ticketmaster.concert(from: event, artists: ["K8vZ917G1x0": "Wolf Alice"]) { sample.append(detailed) }
            for (name, place) in [("london", ConcertTest.london), ("manchester", ConcertTest.manchesterCity)] {
                store.location = place
                store.preview(sample)
                await capture("concerts-\(name)", size: main, settle: 4) { NavigationStack { ConcertsView() } }
            }
            await capture("concert-detail", size: CGSize(width: 980, height: 1100), settle: 2) { NavigationStack { ConcertDetailView(id: "tm:G5vYZ123") } }
            // A listing without a picture (as MusicBrainz's are) gets the artist's picture.
            store.location = ConcertTest.london
            let bare = Concert(id: "mb:snapshot", name: "Halfblood Tour: London", artists: ["slayr"], performers: [ConcertPerformer(name: "slayr")],
                               venue: ConcertVenue(name: "Electric Ballroom", city: "London", countryCode: "GB", countryName: "United Kingdom", latitude: 51.5397, longitude: -0.1430),
                               localDate: "2027-12-08", localTime: "19:00:00", source: "musicbrainz")
            store.preview([bare])
            await store.findPictures(for: [bare], apple: false)
            await capture("concerts-picture", size: CGSize(width: 900, height: 520), settle: 4) { NavigationStack { ConcertsView() } }
            store.location = nil
            // Wide, to check the prompt stays in the middle of the page.
            await capture("concerts-no-location", size: CGSize(width: 1400, height: 600), settle: 1) { NavigationStack { ConcertsView() } }
            await capture("concerts-picker", size: CGSize(width: 360, height: 420), settle: 1) { LocationPicker { _ in } }
            await capture("concerts-key", size: CGSize(width: 440, height: 440), settle: 1) { TicketmasterKeySheet() }
            await capture("settings-concerts", size: CGSize(width: 520, height: 360), settle: 1) { Form { ConcertSettings() }.formStyle(.grouped) }
            store.location = ConcertTest.tokyo
            await capture("artist-concerts", size: CGSize(width: 900, height: 520), settle: 25) {
                ScrollView { ArtistConcertsSection(artist: ConcertArtist(name: "YOASOBI", channelId: nil)).padding(.vertical, 20) }
            }
            store.location = nil
            return
        }
        if CommandLine.arguments.contains("--storage") {
            // `--snapshot dir --storage`: the Storage settings, for the test home's files.
            await capture("settings-storage", size: CGSize(width: 520, height: 640), settle: 1) { StorageSettings() }
            let split = model.media.storage
            print("songs downloaded \(split.downloadedSongs.count) (\(split.downloadedSongs.bytes) B), cached \(split.cachedSongs.count) (\(split.cachedSongs.bytes) B)")
            print("music videos: sound downloaded \(split.downloadedVideoSound.count) (\(split.downloadedVideoSound.bytes) B), cached \(split.cachedVideoSound.count) (\(split.cachedVideoSound.bytes) B), pictures \(VideoDownloads.shared.records.count) (\(VideoDownloads.shared.bytes) B)")
            if CommandLine.arguments.contains("--clearvideos") {
                model.media.clearCache(musicVideos: true)
                let after = model.media.storage
                print("after clearing the music video cache: songs cached \(after.cachedSongs.count), music video sound cached \(after.cachedVideoSound.count), downloads \(after.downloadedSongs.count)+\(after.downloadedVideoSound.count)")
            }
            return
        }
        if CommandLine.arguments.contains("--videocontrols") {
            // `--snapshot dir --videocontrols`: the floating controls of the video player at
            // several widths, on black, to check that the transport buttons are centred.
            for width in [760.0, 600, 520] {
                await capture("video-controls-\(Int(width))", size: CGSize(width: width, height: 130), settle: 1) {
                    VideoControls(showQueue: .constant(false), isFullScreen: false, toggleFullScreen: {})
                        .background(.black)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            await diagnose(model: model, size: main)
            return
        }
        if CommandLine.arguments.contains("--sqscreens") {
            // `--snapshot dir --sqscreens`: the shared-queue screens, with a guest's song in the queue.
            Keychain.service = "Metrolist.sqscreens.\(UUID().uuidString)"
            let size = CGSize(width: 560, height: 640)
            await capture("sharedqueue-start", size: size, settle: 1) { SharedQueueHostView() }
            SharedQueue.shared.start()
            await wait(2)
            await capture("sharedqueue-running", size: CGSize(width: 560, height: 820), settle: 1) { SharedQueueHostView() }
            await capture("sharedqueue-join", size: size, settle: 3) { SharedQueueJoinView() }
            await capture("sharedqueue-request", size: CGSize(width: 420, height: 380), settle: 1) {
                PairingRequestSheet(request: DCPairingRequest(requestId: "x", peerId: "phone", peerName: "Phone", sas: "418203", expires: Date().addingTimeInterval(300)), endpoint: .guests)
            }
            model.settings.autoplay = false
            model.player.applyRemoteQueue(["y32ejtuxSjM", "GTmbyuTKT_c"].map { model.library.song($0) ?? Song(id: $0, title: $0) }, index: 0, position: 0, playing: false, restart: true)
            SharedQueue.shared.policy.record(guest: DeviceConnect.guests.peerKey("someone"), songIds: ["GTmbyuTKT_c"])
            await capture("sharedqueue-queue", size: CGSize(width: 380, height: 300), settle: 2) { QueueView() }
            model.sidebar = .sharedQueue
            await capture("sharedqueue-main", size: main, settle: 3) { RootView() }
            DeviceConnect.guests.shutdown()
            return
        }
        if CommandLine.arguments.contains("--nov19screens") {
            // `--snapshot dir --nov19screens`: screens changed on 2026-11-19 (Apple Music artwork off).
            model.settings.appleArtistImages = false
            model.settings.animatedArtistArtwork = false
            model.settings.animatedAlbumCovers = false
            model.settings.preferAudioVersions = true
            let artists = (try? await YTMusic.search(ProcessInfo.processInfo.environment["SNAP_ARTIST"] ?? "Kanye West", filter: .artists).sections.flatMap(\.items)) ?? []
            if let artist = artists.compactMap({ if case .artist(let found) = $0 { found } else { nil } }).first {
                if let page = try? await YTMusic.artist(artist.id) { print("banner:", page.artist.thumbnail ?? "none") }
                await capture("artist-page", size: main, settle: 6) { NavigationStack { ArtistView(browseId: artist.id) } }
            }
            let albums = (try? await YTMusic.search("Currents Tame Impala", filter: .albums).sections.flatMap(\.items)) ?? []
            if let album = albums.compactMap({ if case .album(let found) = $0 { found } else { nil } }).first {
                await capture("album-page", size: main, settle: 6) { NavigationStack { AlbumView(browseId: album.id) } }
            }
            await capture("playlist-videos-swapped", size: main, settle: 8) { NavigationStack { PlaylistView(playlistId: "PLOhV0FrFphUdkuWPE2bzJEsGxXMRKVkoM") } }
            let library = model.library
            if library.playlists.isEmpty {
                _ = library.createPlaylist(name: "Liked Songs - Spotify")
                _ = library.createPlaylist(name: "Road trip")
                library.mergeRemote(liked: nil, albums: nil, artists: nil, playlists: [PlaylistItem(id: "PLdemo", title: "From YouTube Music")])
                library.moveSidebarPlaylists(from: IndexSet(integer: 2), to: 0)
            }
            await capture("sidebar-arranged", size: CGSize(width: 240, height: 560), settle: 1) { SidebarView() }
            struct FilterDemo: View {
                @State var text = "touch"
                var body: some View { FilterField(text: $text, shown: 4, total: 312).padding(20) }
            }
            await capture("filter-count", size: CGSize(width: 520, height: 70), settle: 1) { FilterDemo() }
            await capture("settings-general", size: CGSize(width: 580, height: 520), settle: 1) { GeneralSettings() }
            await capture("settings-integrations-discord", size: CGSize(width: 580, height: 700), settle: 1) { IntegrationsSettings() }
            return
        }

        if CommandLine.arguments.contains("--newscreens") {
            // `--snapshot dir --newscreens [songId]`: every screen added by the v14 integration.
            let settingsSize = CGSize(width: 580, height: 520)
            await capture("settings-sound", size: settingsSize, settle: 1) { SoundSettings() }
            await capture("settings-lyrics", size: settingsSize, settle: 1) { LyricsSettings() }
            await capture("settings-content", size: settingsSize, settle: 1) { ContentSettings() }
            await capture("settings-integrations", size: CGSize(width: 580, height: 640), settle: 1) { IntegrationsSettings() }
            await capture("settings-devices", size: CGSize(width: 580, height: 560), settle: 1) { DevicesSettings() }
            await capture("pairing-request", size: CGSize(width: 420, height: 340), settle: 1) {
                PairingRequestSheet(request: DCPairingRequest(requestId: "x", peerId: "phone", peerName: "Phone", sas: "062889", expires: Date().addingTimeInterval(300)))
            }
            MasterEQ.shared.choose(EQProfile.presets[3])
            MasterEQ.shared.enabled = true
            await capture("equalizer", size: CGSize(width: 680, height: 600), settle: 1) { EqualizerView() }
            MasterEQ.shared.enabled = false
            MasterEQ.shared.choose(.flat)
            await capture("playlist-import", size: CGSize(width: 620, height: 520), settle: 1) { PlaylistImportSheet() }
            if let id = CommandLine.arguments.drop(while: { $0 != "--newscreens" }).dropFirst().first, !id.hasPrefix("--") {
                model.settings.autoplay = false
                model.player.play(song: model.library.song(id) ?? Song(id: id, title: id))
                for _ in 0 ..< 100 where model.player.lyrics == nil { await wait(0.1) }
                model.player.pause()
                await capture("lyrics-search", size: CGSize(width: 560, height: 460), settle: 6) { LyricsSearchSheet() }
                await capture("lyrics-editor", size: CGSize(width: 640, height: 560), settle: 2) { LyricsEditorSheet() }
                await capture("player-bar", size: CGSize(width: 1180, height: 120), settle: 1) { PlayerBar() }
            }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--lyricsreplan") {
            // `--snapshot dir --lyricsreplan idA idB`: edits the first song's lyrics and checks that
            // the pair is planned again, while a transition saved by hand stays as it was.
            let ids = CommandLine.arguments.dropFirst(flag + 1).filter { !$0.hasPrefix("--") }.prefix(2)
            model.settings.autoMix = true
            model.settings.autoplay = false
            let player = model.player
            player.play(ids.map { model.library.song($0) ?? Song(id: $0, title: $0) })
            for _ in 0 ..< 600 where player.nextMixCandidates.isEmpty { await wait(0.1) }
            player.pause()
            let before = player.nextMixCandidates
            print("before: \(before.count) proposals, best \(before.first?.id.uuidString.prefix(8) ?? "-") leaving A at \(before.first.map { String(format: "%.1f", $0.outStart) } ?? "-") s, lyrics: \(player.lyrics?.provider ?? "none") \(player.lyrics?.lines.count ?? 0) lines")
            var edited = player.lyrics ?? Lyrics(provider: "User", isSynced: true, lines: [])
            // Singing only in the first thirty seconds: the planner has to look elsewhere for vocals.
            edited.lines = edited.lines.filter { $0.start < 30 }
            if edited.lines.isEmpty { edited.lines = [LyricLine(id: 0, start: 1, end: 5, text: "test line")] }
            edited.isSynced = true
            player.saveEditedLyrics(edited)
            for _ in 0 ..< 600 where player.nextMixCandidates.first?.id == before.first?.id || player.nextMixCandidates.isEmpty { await wait(0.1) }
            let after = player.nextMixCandidates
            print("after:  \(after.count) proposals, best \(after.first?.id.uuidString.prefix(8) ?? "-") leaving A at \(after.first.map { String(format: "%.1f", $0.outStart) } ?? "-") s, lyrics: \(player.lyrics?.provider ?? "none") \(player.lyrics?.lines.count ?? 0) lines")
            print(after.first?.id != before.first?.id ? "PASS: the pair was planned again after the edit" : "FAIL: the plan was not replaced")
            // A saved transition is never touched by a lyrics change.
            player.applyMixPreset(.fade)
            player.keepAuditionedMix()
            let kept = player.nextMixPlan?.signature
            player.discardEditedLyrics()
            await wait(8)
            print(player.nextMixPlan?.signature == kept ? "PASS: the transition saved by hand was untouched" : "FAIL: the saved transition changed")
            print("user lyrics removed:", !(await LyricsService.shared.hasUserCopy(ids.first ?? "")))
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--mixeditor") {
            // `--snapshot dir --mixeditor idA idB [--preset name]`: the transition editor for a pair.
            let ids = CommandLine.arguments.dropFirst(flag + 1).filter { !$0.hasPrefix("--") }.prefix(2)
            model.settings.autoMix = true
            model.settings.autoplay = false
            model.player.play(ids.map { model.library.song($0) ?? Song(id: $0, title: $0) })
            for _ in 0 ..< 600 where model.player.nextMixPlan == nil { await wait(0.1) }
            model.player.pause()
            await capture("mix-editor-auto", size: CGSize(width: 620, height: 900), settle: 2) { MixEditorView() }
            for (preset, lane) in [(MixPreset.blend, MixLane.bass), (.rise, .filter), (.loop, .volume), (.echo, .echo)] {
                model.player.applyMixPreset(preset)
                await capture("mix-editor-\(preset.rawValue)", size: CGSize(width: 620, height: 900), settle: 1) { MixEditorView(initialLane: lane) }
            }
            model.player.applyMixPreset(.auto)
            model.showExpandedPlayer = true
            await capture("mix-expanded", size: main, settle: 2) { RootView() }
            model.showExpandedPlayer = false
            await capture("mix-bar", size: main, settle: 2) { RootView() }
            return
        }
        await capture("1-home", size: main, settle: 5) { RootView() }

        // Start a song (muted) so the player, lyrics and queue have content.
        if let song = try? await YTMusic.search("Ed Sheeran Shape of You", filter: .songs).sections.first?.items.compactMap(\.song).first {
            model.player.play(song: song)
            await wait(6)
            model.player.seek(to: 31)
            await wait(1.5)
        }
        model.showInspector = true
        model.inspectorTab = .lyrics
        if let album = model.player.currentSong?.album?.id { model.path = [.album(album)] }
        await capture("2-album-lyrics", size: main, settle: 4) { RootView() }

        model.inspectorTab = .queue
        model.path = [.search("daft punk")]
        await capture("3-search-queue", size: main, settle: 4) { RootView() }

        model.showInspector = false
        model.path = []
        model.showExpandedPlayer = true
        await capture("4-expanded", size: main, settle: 3) { RootView() }
        model.showExpandedPlayer = false

        await capture("5-mini", size: CGSize(width: 300, height: 300), settle: 2, plain: true) { MiniPlayerView() }
        await capture("6-menubar", size: CGSize(width: 320, height: 330), settle: 2) { MenuBarPlayerView() }
        model.sidebar = .home
        if let album = model.player.currentSong?.album?.id { model.path = [.album(album)] }
        await capture("8-narrow", size: CGSize(width: 700, height: 520), settle: 4) { RootView() }
        model.path = []
        model.sidebar = .downloads
        await capture("7-downloads", size: main, settle: 2) { RootView() }
        model.player.pause()
        model.player.volume = 1
    }

    /// Measures how often views rebuild and how long the main thread stalls during playback.
    static func diagnose(model: AppModel, size: CGSize) async {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView().environment(model).frame(width: size.width, height: size.height))
        window.orderBack(nil)
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        await wait(5)
        if let song = try? await YTMusic.search("Daft Punk Get Lucky", filter: .songs).sections.first?.items.compactMap(\.song).first {
            model.player.play(song: song)
        }
        await wait(6)

        func measure(_ label: String, seconds: Double) async {
            Diagnostics.counts = [:]
            Diagnostics.enabled = true
            var worst = 0.0
            var last = Date()
            let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
                let now = Date()
                worst = max(worst, now.timeIntervalSince(last))
                last = now
            }
            await wait(seconds)
            timer.invalidate()
            Diagnostics.enabled = false
            let rates = Diagnostics.counts.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.1f", Double($0.value) / seconds))/s" }
            print("\(label): worst main-thread stall \(Int(worst * 1000)) ms | rebuilds: \(rates.joined(separator: ", "))")
        }

        await measure("home, playing", seconds: 6)
        if let album = model.player.currentSong?.album?.id { model.path = [.album(album)] }
        await wait(3)
        await measure("album page, playing", seconds: 6)
        model.showInspector = true
        model.inspectorTab = .lyrics
        await wait(2)
        await measure("album page + lyrics inspector", seconds: 6)
        model.showInspector = false
        model.sidebar = .liked
        await wait(2)
        await measure("liked songs, playing", seconds: 6)
        model.player.pause()
        model.player.volume = 1
    }

    /// Sends real mouse clicks to every sidebar row and reports which section each selects.
    static func clickTest(model: AppModel, size: CGSize) async {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView().environment(model).frame(width: size.width, height: size.height))
        window.orderBack(nil)
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        await wait(4)

        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        guard let root = window.contentView?.superview ?? window.contentView,
              let table = tables(in: root).min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
        else { print("sidebar table not found"); return }

        func click(row: Int) async {
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.minX + 60, y: rect.midY), to: nil)
            // Queue both halves of the click first: a table's mouse-down handler waits for the
            // matching mouse-up, so they have to be pumped through the app's event loop.
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            while let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.15), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            await wait(0.3)
        }

        print("sidebar rows: \(table.numberOfRows)")
        // Select each row the way AppKit does after a click and see which section it maps to.
        // A row whose tag the list can't see leaves the selection unchanged.
        for row in 0 ..< table.numberOfRows {
            model.sidebar = nil
            await wait(0.15)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await wait(0.25)
            print("row \(row) → \(model.sidebar.map { "\($0)" } ?? "(not selectable)")")
        }

        // Re-clicking the selected tab should pop pushed pages.
        model.sidebar = .albums
        await wait(0.5)
        model.path = [.search("test")]
        await wait(1)
        if let row = (0 ..< table.numberOfRows).first(where: { table.selectedRowIndexes.contains($0) }) {
            await click(row: row)
            print("re-click on selected tab: path count \(model.path.count) (expect 0)")
        }
    }

    /// Sweeps real mouse clicks across the player bar and reports where each control answers:
    /// `--snapshot dir --bartest [songId] [--gap ms]`. With a gap, the button is held for that
    /// long while the app keeps running, as a real click is.
    static func barTest(model: AppModel, size: CGSize) async {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView().environment(model).frame(width: size.width, height: size.height))
        window.orderBack(nil)
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        let arguments = CommandLine.arguments
        let gap = arguments.firstIndex(of: "--gap").flatMap { Double(arguments[$0 + 1]) }.map { $0 / 1000 } ?? 0
        model.settings.autoMix = false
        model.settings.autoplay = false
        if let flag = arguments.firstIndex(of: "--bartest"), flag + 1 < arguments.count, !arguments[flag + 1].hasPrefix("--") {
            let id = arguments[flag + 1]
            let song = model.library.song(id) ?? Song(id: id, title: id)
            model.player.play([song, song, song])
        }
        await wait(5)
        model.player.volume = 0.6
        let player = model.player

        func state() -> [String: String] {
            [
                "shuffle": "\(player.shuffle)", "repeat": "\(player.repeatMode)", "playing": "\(player.isPlaying)",
                "volume": String(format: "%.2f", player.volume), "automix": "\(model.settings.autoMix)",
                "inspector": model.showInspector ? "\(model.inspectorTab)" : "-", "expanded": "\(model.showExpandedPlayer)",
                "path": "\(model.path.count)", "liked": "\(player.currentSong.map { model.library.isLiked($0.id) } ?? false)",
                "track": "\(player.currentIndex ?? -1)", "editor": "\(model.showMixEditor)",
            ]
        }
        func pump(_ seconds: Double) {
            while let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(seconds), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        func send(_ type: NSEvent.EventType, _ point: NSPoint) {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        var hits: [String: (x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat, n: Int)] = [:]
        var rows: [CGFloat: String] = [:]
        let step: CGFloat = 3
        var y: CGFloat = 14
        while y <= 66 {
            var line = ""
            var x: CGFloat = arguments.firstIndex(of: "--from").flatMap { Double(arguments[$0 + 1]) }.map { CGFloat($0) } ?? 240
            while x < (arguments.firstIndex(of: "--to").flatMap { Double(arguments[$0 + 1]) }.map { CGFloat($0) } ?? size.width - 10) {
                let before = state()
                let point = NSPoint(x: x, y: y)
                if arguments.contains("--trace") { FileHandle.standardError.write(Data("\(x),\(y)\n".utf8)) }
                send(.leftMouseDown, point)
                if gap > 0 { pump(gap) }
                send(.leftMouseUp, point)
                if arguments.contains("--trace") { FileHandle.standardError.write(Data("sent\n".utf8)) }
                pump(0.05)
                if arguments.contains("--trace") { FileHandle.standardError.write(Data("pumped\n".utf8)) }
                let after = state()
                if arguments.contains("--trace") { FileHandle.standardError.write(Data("after\n".utf8)) }
                let changed = after.filter { before[$0.key] != $0.value }.keys.sorted()
                // A click on the volume slider is not a button press.
                let name = changed.first { $0 != "playing" || changed.count == 1 } ?? ""
                line += name.isEmpty ? "." : String(name.prefix(1))
                if arguments.contains("--trace") { FileHandle.standardError.write(Data("  \(changed) buffering \(player.isBuffering) playing \(player.isPlaying)\n".utf8)) }
                if !name.isEmpty {
                    var entry = hits[name] ?? (x, x, y, y, 0)
                    entry = (min(entry.x0, x), max(entry.x1, x), min(entry.y0, y), max(entry.y1, y), entry.n + 1)
                    hits[name] = entry
                    // Put everything back for the next point.
                    model.showExpandedPlayer = false
                    model.showInspector = false
                    model.showMixEditor = false
                    model.path = []
                    model.settings.autoMix = false
                    if player.shuffle { player.toggleShuffle() }
                    player.repeatMode = .off
                    if after["liked"] != before["liked"] { player.toggleLikeCurrent() }
                    if after["track"] != before["track"], let index = Int(before["track"] ?? "") , index >= 0 { player.jump(to: index) }
                    if after["playing"] != before["playing"] { player.togglePlayPause() }
                    player.volume = 0.6
                    pump(0.05)
                }
                x += step
            }
            rows[y] = line
            FileHandle.standardError.write(Data("row \(y) \(line)\n".utf8))
            y += step
        }
        for key in rows.keys.sorted(by: >) { print(String(format: "y=%2.0f ", key) + rows[key]!) }
        for (name, hit) in hits.sorted(by: { $0.value.x0 < $1.value.x0 }) {
            print(String(format: "%@: x %.0f–%.0f (%.0f wide), y %.0f–%.0f (%.0f tall), %d points", name, hit.x0, hit.x1, hit.x1 - hit.x0 + step, hit.y0, hit.y1, hit.y1 - hit.y0 + step, hit.n))
        }
        player.pause()
    }
}
