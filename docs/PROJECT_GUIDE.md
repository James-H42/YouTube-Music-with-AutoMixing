# Project guide for agents

Read this first when continuing development. It gives the state of the project, how the code is
organised, the rules the owner has set (with their reasons), how to build and test, and what is
still open. Features are described for users in `README.md`; this guide does not repeat them.

Last updated: 2026-11-21. Update the "Status" and "Open items" sections at the end of any
session that changes them, and keep the rest in step with the code.

## What this is

A native macOS (26+) YouTube Music client in SwiftUI with Liquid Glass, modelled on the Android
app Metrolist (GPL-3.0). Its distinguishing feature is **AutoMix**: on-device analysis and
DJ-style transitions between songs. It also has Metrolist v14's features (equaliser, lyrics
sources, scrobbling, backups and imports, content filters, Device Connect with an Android
phone), a shared queue for guests on the local network, and a music-video player.

One Swift package, one executable target (`Sources/Metrolist`), no third-party dependencies.
Swift 6.2 tools, Swift 5 language mode. About 29,000 lines.

## Working rules from the owner

- **Never commit or push** unless asked in that session. Leave changes uncommitted on `dev` and
  summarise them. The owner reviews and commits.
- **No features that need a paid third-party account** (for example Spotify Premium, now
  required to create a Spotify developer app). Use public pages, or Exportify inside the app.
- **Music videos:**
  - Only YouTube Music's official music videos (`MUSIC_VIDEO_TYPE_OMV`, which includes official
    live performances) count as videos. Fan and channel uploads (`UGC`) that stand in for songs,
    such as leaks ("Mama's Boyfriend", "Never See Me Again"), are treated as audio.
  - A music video inside any playlist, album or library list plays as its **audio release**
    (with "Prefer audio versions" on, the default). The owner has asked for this twice; check it
    after any change to playback or queueing (`--videoplayertest` covers it).
  - Only a video started on its own (search results, an artist's video shelves, the Music Videos
    downloads list) plays as a video and opens the full-screen video player.
  - Music videos are **never mixed** by AutoMix, into or out of. After a chosen video, Autoplay
    lines up only music videos.
- **AutoMix by ear:** the owner judges transitions against Spotify's Mix and Apple Music's AutoMix
  on a set of approved pairs. Their current plans are approved: check any planner change with
  `--mixplan A B` on those pairs, and say so if a plan changes. The pairs and the owner's
  preferences are listed under "AutoMix reference pairs" below. Agents cannot hear the result;
  say that measurements are all you checked.
- **Privacy:**
  - Device Connect and the shared queue are off by default, and pairing opens only on request.
  - The advertised device name must not contain the owner's name.
  - Credentials stay in the Keychain or in owner-only files, never in backups or the repository.
- **Design:** native macOS conventions with Liquid Glass. The player must not disturb a window
  tiled by macOS: never change the title bar's height while it is open (see `WindowChrome.swift`).

## Build, run and test

- `swift build` builds `.build/debug/Metrolist`.
- `Scripts/make-dist.sh` builds the release app the owner tests, `dist/Metrolist.app`, plus
  `dist/Metrolist.zip`. `build/Metrolist.app` (from `Scripts/make-app.sh`) is usually stale.
  Rebuild `dist/` after changes the owner will try.
- **Sandboxed agent sessions:** `swift build` and running the binary need the Bash sandbox off.
  The build service can't write `.build` inside it, and the app's networking ignores the sandbox
  proxy (everything reports offline).
- **Never test against the owner's data.** Set `METROLIST_HOME=/tmp/claude/<name>` for every
  test run. The real data is in `~/Library/Application Support/Metrolist`. For offline test
  songs, copy `Media/*.webm`, `media.json`, `Lyrics/` and `library.json` from there into the
  test home. The AutoMix suites expect `METROLIST_HOME=/tmp/claude/mixhome`.
- **Keychain:** a run with `METROLIST_HOME` set (or `METROLIST_TEST_KEYCHAIN=1`) uses a
  throwaway Keychain service (`Keychain.isTestRun`). Otherwise the debug binary reads the app's
  real Keychain items and macOS shows a password prompt that hangs it; unattended runs (the
  owner away overnight) must never get one. Set both anyway.
- **Parallel agents:** another agent may be using the main checkout and the `/tmp/claude`
  homes. Work in a worktree (see the owner's memory note) and on APFS clones of test homes
  (`cp -cR /tmp/claude/mixhome /tmp/claude/<yours>`).
- `swift build` sometimes reports success in about 3 s without recompiling a file that was just
  edited. If a change seems missing, touch the file and build again.
- Offscreen captures (`--snapshot`, `--albumshot`, `METROLIST_VIDEOSHOT`) don't draw Liquid
  Glass, vibrant text or `AVPlayerLayer` video. That is the capture method, not a layout bug.
  Ask the owner to check those visually.

### Test commands

All are flags to the built binary (`.build/debug/Metrolist <flag>`). Most print PASS/FAIL lines.

| Area | Commands |
|---|---|
| General | `--featuretest` (offline, needs a test home), `--probe [query]`, `--snapshot dir` (options: `--sound`, `--storage`, `--videocontrols`, `--nov19screens`) |
| AutoMix | `--mixplan A B` (add `--samples` to look up sample links, `--debug` for detail), `--mixtest A B`, `--mixplay`, `--analyze id`, `--playnexttest`, `--videomixtest` |
| Video | `--videoplayertest [query]` (live, end to end), `--videosynctest [query]`, `--videotest query` (`METROLIST_VIDEOQUALITY=2160`), `--videotypes query`, `--typeprobe id…`, `--typerefreshtest` |
| Streams | `--qualitytest id`, `--audioswap playlistId`, `--matchwhy videoId` (each step of finding a video's audio release), `--ciphertest`, `--potoken` |
| Artwork | `--amtest artist [album]…`, `--albumshot dir "album"`, `--facetest image` |
| Sound | `--soundtest [--live]` (live: AutoEQ catalogue), `--bitperfecttest [--live [videoId]]` (live: sets and restores the default output's rate, format and hog mode), `--outputs`, `--outputtest`, `--chaintest` |
| Library | `--backup`, `--restore`, `--inspect`, `--importforeign`, `--importplaylist`, `--lyricsprobe id`, `--blocktest`, `--scrobbletest`, `--exportifytest` |
| Devices | `--dctest`, `--sqtest`, `--sqnettest`, `--sqmixtest A B`, `--dcserve s`, `--sqjoin host port`, `--discordtest` |
| Window | `METROLIST_WINDOWTEST=1` (real main window, full-screen player, tiling) |
| Concerts | `--concerttest [--live]` (offline: parsing, merging, ranking for London/Manchester/a region/the UK/Tokyo/Japan/New York/the US; live: Apple Maps places, MusicBrainz tours, and Ticketmaster when `METROLIST_TICKETMASTER_KEY` is set), `--snapshot dir --concerts`, `--rawpost endpoint client file 'json'` (raw InnerTube replies, for research) |

**Known baseline failures:** `--playnexttest` (3 checks) and `--videomixtest` (1 check) expect
the transition label "Sample match", but it is now "Known sample". These failures predate the
video work and aren't regressions.

## Architecture

```
Sources/Metrolist/
  main.swift          command-line test flags, then starts the app
  App/                AppModel (state shared by the app), AppSettings, AppPaths, app entry, tests
  InnerTube/          YouTube Music API, stream resolution, Apple Music artwork
  Playback/           PlayerController (queue), AudioEngine, MediaStore, video picture
  Mix/                AutoMix: analysis, planning, mixing engine, sequencing, sample lookups
  Library/            LibraryStore, scrobbling, Discord, content filter
  Lyrics/             lyrics sources, parsing, romanisation
  Backup/             own backups, imports from other apps and services
  DeviceConnect/      Metrolist's Device Connect protocol, shared queue
  UI/                 SwiftUI: RootView, Screens/, Player/, Components/, SettingsView
```

### Data and state

- `AppModel.shared` owns `AppSettings`, `LibraryStore`, `MediaStore`, `PlayerController` and the
  account. Views read it from the environment.
- Everything on disk lives under `AppPaths.root` (`~/Library/Application Support/Metrolist`, or
  `METROLIST_HOME`):
  - `library.json`: songs by id, likes, playlists and history.
  - `Media/` and `media.json`: audio, both cached and downloaded.
  - `Videos/` and `videos.json`: the pictures of downloaded music videos.
  - `Analysis/`: AutoMix's track analysis.
  - `mixes.json`: transitions edited by hand.
  - `player.json`: the queue.
  - `mix.log`: why each transition did or did not happen.
- `Song` (`InnerTube/Models.swift`):
  - `isVideo` is anything but an audio track.
  - `videoType` is YouTube Music's own type. It is nil for songs saved before 2026-11-20, which
    `App/VideoTypeRefresh.swift` fills in at launch.
  - `isMusicVideo` is true only for the official type.

### YouTube access (`InnerTube/`)

- `InnerTube.swift` is the transport. It sends browse requests as WEB_REMIX, signed in when the
  account is connected. Playback uses spoofed native-device identities (`YouTubeClient.swift`):
  VISIONOS first, then ANDROID_VR. Those identities use a separate anonymous visitor identity
  and never carry account cookies.
- `StreamResolver.swift` finds an Opus/WebM audio stream. When YouTube bot-checks every
  anonymous identity, it falls back to the signed-in route:
  - The WEB_REMIX identity with the account's cookies.
  - `PlayerCipher.swift`, which runs yt-dlp's EJS solver (`EJSSolver.swift`) in
    JavaScriptCore.
  - PO tokens from `PoToken.swift`.

  If streaming breaks, first check whether YouTube changed its player script (solver errors).
  The auto-mode classifier has refused to run `--ciphertest` from the CLI before, so ask the
  owner to run it.
- `MediaHTTP.swift` fetches media in bounded byte ranges (the size each identity's own app
  uses), falling back between IPv6 and IPv4. Audio and video downloads both use it.
- `YTMusic.swift` is the high-level API: search, browse, album, playlist, queue and radio,
  `audioCounterpart` (a video's audio release), and `videoTypes` (`music/get_queue`, 50 ids
  per request; a removed id makes the whole batch fail with 404).
  - Matching a video to its release (`searchedAudioVersion`): the songs search first; it misses
    some releases entirely (RADWIMPS' "DASAI DAZAI"), so then the albums the general search
    lists, then the artist's page. Titles compare by `titleKeys`: each part of "Title / Artist -
    English title / Artist" once artist credits go, 「」 contents, and Japanese or Korean
    readings ("正解" finds "Seikai"). " / " only splits when a part is the artist, so medleys
    don't match. A release labelled as another arrangement (`versionTags`: "18FES ver.",
    "Chorus") is used only when the plain one isn't found.
  - `AudioVersionCache.matcherVersion` drops "none" answers from older matchers; raise it when
    matching improves.
- `AppleMusicArtwork.swift` gets artist pictures and animated album covers through Apple's
  public web-player token and the iTunes search. Compilations are credited to "Various
  Artists" on Apple. Results are cached with version-prefixed keys ("v2|…").

### Playback (`Playback/`)

- `PlayerController.swift` (largest file) owns the queue, Autoplay (radio continuation), Play
  Next, shuffle and repeat, persistence and Now Playing. It drives AutoMix: `prepareMix`
  analyses and plans the current and next track, and the transition is handed to the engine
  about 30 s ahead (`gaplessKey`).
- **Audio versions:** with "Prefer audio versions" on, a video not chosen by the listener is
  swapped for its audio release, ahead of time when it is next (`resolveNextAudioVersion`) and
  when it starts (`loadCurrent`). `chosenVideos` holds the exceptions. The player's lookup
  accepts a release of another length (`strictLength: false`), because music videos add intros.
- `MediaStore.swift` holds audio files: a cache with a size limit plus pinned downloads. It
  streams a file while it downloads (`ProgressiveDownload`) and tags downloads (`WebMTagger`).
  A music video's sound is stored here too; `storage` splits the totals into songs and music
  videos the way the sidebar lists them, and Settings → Storage shows them apart.
- `AudioEngine.swift` and `Mix/MixEngine.swift` handle sound: WebM demuxing, Opus decoding,
  two decks with time-stretch and pitch, then the mixer, `MasterEQ` and `Limiter`.
- **Bit-perfect output** (`BitPerfect.swift`, from LastWave-Native): `AudioEngine.configure`
  calls `BitPerfectOutput.prepare` before starting on a track, which sets the device to the
  source rate (or LastWave's simplest fallback, `OutputRate.best`), its deepest physical format
  and optionally hog mode, saving what it changed; turning it off or quitting restores it.
  `AppSettings.mixes`/`normalizes` and `MasterEQ.bypassed` take AutoMix, normalisation, the EQ
  and limiter out. `PlayerController.updateVolumeRouting` moves the slider to the device's own
  volume (and follows the volume keys). The deck's plain chain is sample-identical at unity
  (checked by `--bitperfecttest`).
  Hog mode makes macOS move the system default output elsewhere (the built-in speakers). So
  every place that picks the device goes through `OutputDevices.playbackDevice(chosen:)`, which
  keeps the app on the held device (`BitPerfectOutput.pinnedDefault`); the engine re-applies
  its device after every configuration change; releasing gives the default back. The ⓘ hover
  explanations in Sound settings are `InfoTip` / `.info(_:)` (`UI/Components/InfoTip.swift`).
- **Video picture** (`NowPlayingVideo.swift`):
  - The sound always comes from the audio engine. The picture is the same video played muted
    in an `AVPlayer` and timed to the engine's clock with `setRate(_:time:atHostTime:)`.
    Setting `rate` repeatedly does not work.
  - The picture plays from the downloaded file when there is one, otherwise from
    `VideoStreamResolver` at the "Video quality" setting.
  - HLS from VISIONOS goes up to 1080p; 1440p and 2160p come from AV1 MP4 files on Macs that
    decode AV1 in hardware.
- `VideoDownloads.swift` saves the best picture file when a music video is downloaded. Its
  audio downloads separately through `MediaStore`.

### AutoMix (`Mix/`)

Described in README "AutoMix". In short:
- `TrackAnalysis.swift` analyses tempo, beats, key, harmony, sections and the waveform.
- `MixPlanner.swift` proposes and ranks transitions. Tempo and pitch moves happen in an
  approach *before* the overlap, on the outgoing song.
- `SampleDatabase.swift` looks up sample links on MusicBrainz, or on Genius with a token.
- `MixSequencer.swift` orders the songs Autoplay lines up.
- `MixPlan.swift` holds the plans, which `MixEngine` plays.

### UI (`UI/`)

- `RootView.swift`: the sidebar (Home, Explore, Shared Queue, then Liked Songs, Albums, Artists,
  Playlists, Downloads, Music Videos, History, and the playlists), the navigation stack, the
  player bar, and the full-screen player overlay.
- `Player/NowPlayingViews.swift` has `ExpandedPlayerView`: the cover layout, or
  `VideoStageView` (`Player/VideoPlayerView.swift`) while a music video shows its picture.
  `VideoStageView` is edge to edge, with auto-hiding glass controls, a quality menu and
  macOS full screen.
- `Components/WindowChrome.swift` hides only the toolbar's items while the player is open,
  never the toolbar itself. It also makes the title bar transparent then: macOS 26 draws the
  page's title-bar background (`NSTitlebarBackgroundView`, with the scroll edge effect) above
  all content, which showed as a grey band over the player.
- `Screens/ConcertViews.swift` with `Concerts/`: the Concerts page (sidebar), a concert's page
  (`Route.concert`), the artist page's Concerts section, the place picker and the Ticketmaster
  key sheet. `ConcertStore` gathers the listener's artists (followed, then most played),
  `Ticketmaster` (attraction ids cached 14 days in `concert-artists.json`; events by country,
  20 attractions a request, in memory for 6 hours) and `MusicBrainzEvents` (1 request/s; asked
  in batches: 8 artist names, 25 artists' events and 20 venues a request; venues kept on disk in
  `concert-places.json`; an event's links fetched only when its page opens; 503 "busy" answers
  retried after `Retry-After`, up to 8 times). The two sources run at the same time. Concerts
  without a picture get the headliner's (Apple Music banner when that setting is on, else
  YouTube Music). Venue country and city come from `MKReverseGeocodingRequest`. `ConcertRanking` bands by distance
  (40 km, 150 km, country) and sorts soonest first. `LocationSearch` uses Apple Maps; the
  Mac's location is never read.
- `Screens/`: album, artist, playlist, search, library screens, and imports.
  - `Components/ItemViews.swift`: `PageHeader`, whose cover scales from 170 to 320 pt with the
    page's width.
  - `Components/SongViews.swift`: `SongList`, where row clicks are not "chosen" except with
    `playsVideos`.

## Status (2026-11-21)

Everything up to the music-video work and album header redesign is committed on `dev`
(`14aa15f`). The 2026-11-21 overnight batch is **uncommitted on branch
`claude/session-2026-11-21`**, in the worktree `.claude/worktrees/session-2026-11-21` (another
agent was using the main checkout). It contains:
- Bit-perfect output, exclusive output, the signal path and AutoEQ headphone search, from
  LastWave-Native (README "From LastWave" says what was left out and why).
- The grey band over the full-screen player fixed (transparent title bar while it is open).
- Better matching of playlist videos to their audio release (DASAI DAZAI and Japanese titles).
- Songs and music videos counted and cleared apart in Settings → Storage.
- The video player's transport buttons centred in the control bar.
- Artist names under song cards and album rows link to the artist.
- Test runs never read the real Keychain.
- Afternoon follow-up: exclusive output no longer drifts to the built-in speakers; ⓘ hover
  explanations in Sound settings; Concerts (Ticketmaster with the owner's free key, plus
  MusicBrainz), chosen by the owner over a no-account or Bandsintown route.
- Late afternoon feedback (done): Concerts' empty prompt centred; MusicBrainz search batched
  (30 artists in about 12 s, was over a minute) and covering 150 artists, not 40; artist
  pictures for listings without one; the back button no longer shows over the full-screen and
  video players (`navigationBarBackButtonHidden` while the player is open: SwiftUI's back item
  ignores `NSToolbarItem.isHidden`); albums, EPs and singles no longer have a song filter
  (playlists keep theirs).
- Merging with the AutoMix branch: see `docs/MERGE_GUIDE_session-2026-11-21.md`.

This copy of the guide is in the worktree; the original in the main checkout is unchanged.

Design notes for earlier work are in `docs/`:
- Metrolist v14 integration plan
- Phase 8 build status
- Device Connect protocol review
- Shared queue design
- Casting threat model (casting was left out on purpose)
- AutoMix and queueing technical paper (PDF)

## Open items

Waiting on the owner:
- Review and commit (or merge) branch `claude/session-2026-11-21`.
- A visual check of the full-screen player's title bar (no grey band) in a maximised and a
  tiled window; offscreen captures can't show it. Window tiling itself couldn't be exercised
  (the debug build has no Window › Fill item); the window frame stays the same.
- Listening with bit-perfect output on, ideally with a USB DAC: the rate shown in Audio MIDI
  Setup should follow the song (48 kHz), and the signal path should say bit-perfect.
- A visual check of the music-video player in the real app: the controls on glass, title text,
  auto-hide, the quality menu and macOS full screen.
- A Ticketmaster key: the live Ticketmaster checks (`--concerttest --live` with
  `METROLIST_TICKETMASTER_KEY`) have never run. Unverified: that `attractionId` accepts a
  comma-separated list (a 400 falls back to one artist a request) and Japan coverage (expected
  none). Also a look at the Concerts page in the real app (glass, hover popovers, sidebar row).
- A shared-queue test with a real Android phone, and the signed-in guests option.
- A real Discord test (the stand-in passes).
- Real Last.fm and ListenBrainz accounts, a real Metrolist Android `.backup`, and AirPlay
  hardware.
- Whether the AutoMix video issue they once described as video → song still happens. The
  reproduction showed song → video, and that case is fixed.

Not done:
- Unison and KuGou lyrics sources.
- Tidal and Amazon playlist import.
- SimpMusic and Prism backup importers.
- A list of AI music artists better than AiSList (owner undecided).

Known limits:
- Without a Ticketmaster key, Concerts lists few shows: MusicBrainz's volunteers enter few
  upcoming concerts (on 2026-11-21, of slayr, Creepy Nuts, Kid Cudi, Coldplay and Fontaines D.C.
  only slayr's London date was there). MusicBrainz also sheds load with 503s at busy times.
- Bit-perfect output pauses AutoMix: its time-stretcher sits in the song's path whenever
  AutoMix is on, so the two can't both hold.
- The video control bar's transport is exactly centred while both side groups fit in half the
  bar; below about 560 pt (Up Next open in a small window) it shifts rather than overlap.
- Some playlist videos still have no match: when the release has another title altogether, or
  only another arrangement exists at a very different length.
- A fixed video quality reloads the picture, so the cover flashes briefly.
- Auto quality starts low and climbs.
- AVFoundation reports a wrong (longer) length for saved AV1 files. Playback and sync are
  unaffected.

## AutoMix reference pairs

Approved by the owner on 2026-11-14. Video ids are cached in the owner's data. Run each with
`--mixplan`.
- P.Y.T. (y32ejtuxSjM) → Good Life (GTmbyuTKT_c): a sample, slowed to 67 % speed but pitched up
  about 2 semitones.
- BIRDBRAIN (dBLzh47wdrU) → keep me going (V4HdD2Fu_64).
- Harder Better Faster Stronger (JhulBGMA7G4) → Stronger (2ulp_AMut14).
- Defying Gravity (WTgNu7XHrrU) → God Is (G8u3P7Xqlvo).
- Starships (_cUM4SlY2_o) → One More Time (fa5IWHDbftI).
- POP DAT THANG → Ni**as In Paris (Lu-edhQJBWI).
- Body (JiNxvNtlBPM) → Mo Bamba / New Person Same Old Mistakes.
- CARNIVAL (2VPAdf9dkmQ) → EVIL J0RDAN (4xtwjLqdaj0).
- One More Time (Radio Edit) (WYhv-hR6Q2U) → Robot Rock (l4L78W66kCI).

The owner's preferences for transitions:
- Tempo and pitch moves go on the outgoing song, gradually, before the overlap.
- The incoming song is audible from the start of the overlap.
- Fade shapes are preferred over long full-level blends.
- Echo should be clean, not a wash.
- Auditioning a proposal must not save it as the pair's transition.
- Lowering the audio evidence needed when a sample link is known was tried and rejected: it
  invented matches.
