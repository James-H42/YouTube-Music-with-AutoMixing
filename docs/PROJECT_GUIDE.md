# Project guide for agents

Read this first when continuing development. It gives the state of the project, how the code is
organised, the rules the owner has set (with their reasons), how to build and test, and what is
still open. Features are described for users in `README.md`; this guide does not repeat them.

Last updated: 2026-11-22 (morning, merged branch). Update the "Status" and "Open items" sections at
the end of any session that changes them, and keep the rest in step with the code.

## What this is

A native macOS (26+) YouTube Music client in SwiftUI with Liquid Glass, modelled on the Android
app Metrolist (GPL-3.0). Its distinguishing feature is **AutoMix**: on-device analysis and
DJ-style transitions between songs. It also has Metrolist v14's features (equaliser, lyrics
sources, scrobbling, backups and imports, content filters, Device Connect with an Android
phone), a shared queue for guests on the local network, a music-video player, bit-perfect
output and Concerts.

One Swift package, one executable target (`Sources/Metrolist`), no third-party dependencies.
Swift 6.2 tools, Swift 5 language mode. About 36,000 lines.

## Working rules from the owner

- **Never commit or push** unless asked in that session. Leave changes uncommitted and
  summarise them. The owner reviews and commits. Commits the owner asks for are made under the
  owner's own git profile (James-H42), with no Claude co-author line.
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
- **Saved custom transitions are not the owner's taste.** On 2026-11-21 the owner said the
  transitions saved as their own during the training process were accidental clicks. They were
  cleared (`mixes.json`, backup `mixes.backup-2026-11-21-misclicks.json`), and their copy
  `Tools/ml/data/owner-mixes.IGNORE-misclicks.tsv` must not be used to check or fit anything.
- **Privacy:**
  - Device Connect and the shared queue are off by default, and pairing opens only on request.
  - The advertised device name must not contain the owner's name.
  - Credentials stay in the Keychain or in owner-only files, never in backups or the repository.
- **Design:** native macOS conventions with Liquid Glass. The player must not disturb a window
  tiled by macOS: never change the title bar's height while it is open (see `WindowChrome.swift`).

## Build, run and test

- `swift build` builds `.build/debug/Metrolist`.
- `Scripts/make-dist.sh` builds the release app the owner tests, `dist/Metrolist.app`, plus
  `dist/Metrolist.zip`. It bundles `Models/` (both models, about 216 MB) and keeps the previous
  app as `dist/.Metrolist-previous-<time>.app`. `build/Metrolist.app` (from
  `Scripts/make-app.sh`) is usually stale. Rebuild `dist/` after changes the owner will try.
- **Sandboxed agent sessions:** `swift build` and running the binary need the Bash sandbox off.
  The build service can't write `.build` inside it, and the app's networking ignores the sandbox
  proxy (everything reports offline).
- **Never test against the owner's data.** Set `METROLIST_HOME=/tmp/claude/<name>` for every
  test run. With it set, the app's settings go to a separate domain
  (`app.metrolist.mac.automix.tests`, `AppPaths.settings`). Without it, a test run from the
  packaged app writes into the owner's own preferences: tests switch Autoplay off, and on
  2026-11-21 the owner's Autoplay was found off. The real data is in `~/Library/Application Support/Metrolist`. For offline test
  songs, copy `Media/*.webm`, `media.json`, `Lyrics/` and `library.json` from there into the
  test home. The AutoMix suites expect `METROLIST_HOME=/tmp/claude/mixhome`.
- **Settings still written to `UserDefaults.standard`** (`OutputDevices`, `ConcertStore`,
  `BlockedContent`, `Scrobbler`, `LyricsService`, Device Connect and a few others) go to the
  running binary's own domain whatever `METROLIST_HOME` says: `app.metrolist.mac.automix` for
  the packaged app, `~/Library/Preferences/Metrolist.plist` for `.build/*/Metrolist` (a binary
  without a bundle takes its file name as the domain). So never run tests from
  `dist/Metrolist.app/Contents/MacOS/Metrolist`, and to keep `Metrolist.plist` untouched too,
  run a copy of the binary under another name (the merge checks used `Metrolist-merge`, with
  `METROLIST_MODELS=<repo>/Models`).
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
| AutoMix measurement (use `swift build -c release`) | `--mixaudit groups.csv` / `--approved` / `--pairs-file f` (with `--lookup`, `--standout x`, `--no-gate`, `--ramp 0`, `--stems`, `--features out.tsv [--augment 1.25:0,…]`), `--analysisaudit labelsDir`, `--beatmodeltest refDir`, `--dumppcm dir`; `Tools/run_audits.sh BINARY HOME OUT` runs them all |
| Queue (live) | `--radiotest [--no-order]`: Start Radio with Autoplay on and off, Play Next and Add to Queue order, a radio replaced while loading, Autoplay's order after a Play Next song (release build, about 5 min), settings kept apart |
| Stems | `--vocalresidue FILE [START…]` (vocal left after the deck's subtraction, measured by separating again), `--stemtest FILE START DIR` (Core ML against PyTorch with `Tools/ml/check_stems.py`, alignment with playback, removal through the deck's own code), `--mixtest A B --stems --lead 25` (a real transition with stems; `--ahead` separates first, as the player does; a short `--lead` without it exercises late stems; use the release build, because the debug build separates too slowly for stems to arrive within the overlap). Set `METROLIST_MODELS=<repo>/Models` when the binary is built outside the repository |
| Video | `--videoplayertest [query]` (live, end to end), `--videosynctest [query]`, `--videotest query` (`METROLIST_VIDEOQUALITY=2160`), `--videotypes query`, `--typeprobe id…`, `--typerefreshtest` |
| Streams | `--qualitytest id`, `--audioswap playlistId`, `--matchwhy videoId` (each step of finding a video's audio release), `--ciphertest`, `--potoken` |
| Artwork | `--amtest artist [album]…`, `--albumshot dir "album"`, `--facetest image` |
| Sound | `--soundtest [--live]` (live: AutoEQ catalogue), `--bitperfecttest [--live [videoId]]` (live: sets and restores the default output's rate, format and hog mode), `--outputs`, `--outputtest`, `--chaintest` |
| Library | `--backup`, `--restore`, `--inspect`, `--importforeign`, `--importplaylist`, `--lyricsprobe id`, `--blocktest`, `--scrobbletest`, `--exportifytest` |
| Devices | `--dctest`, `--sqtest`, `--sqnettest`, `--sqmixtest A B`, `--dcserve s`, `--sqjoin host port`, `--discordtest` |
| Window | `METROLIST_WINDOWTEST=1` (real main window, full-screen player, tiling; prints the title bar's visible text). Add `METROLIST_WINDOWTEST_PUSH=1` to open a page first, `_CONCERTS=1` to start on the Concerts page (its toolbar buttons must stay hidden under the player), `_FULLSCREEN=1` to try macOS full screen (a test-launched app can't activate, so it doesn't engage), `_MIX="idA idB"` for a real muted transition with pictures, `_SHOWCASE="idA idB"` for the README screenshots. Pictures go to the test home: `window-*.png` (`cacheDisplay`, no glass or blur) and `screen-*.png` (the window as composited on screen, via `CGWindowListCreateImage` looked up at run time; no screen-recording permission needed for the app's own windows; `screencapture -l` fails without it) |
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
  Playback/           PlayerController (queue), AudioEngine, MediaStore, video picture, bit-perfect output
  Mix/                AutoMix: analysis, planning, mixing engine, sequencing, sample lookups, beat model, stems
  Concerts/           Ticketmaster and MusicBrainz concert listings, place search
  Library/            LibraryStore, scrobbling, Discord, content filter
  Lyrics/             lyrics sources, parsing, romanisation
  Backup/             own backups, imports from other apps and services
  DeviceConnect/      Metrolist's Device Connect protocol, shared queue
  UI/                 SwiftUI: RootView, Screens/, Player/, Components/, SettingsView
Models/               Core ML models: Beat This! (in git), HT-Demucs stems (git-ignored)
Tools/                AutoMix ground truth (groundtruth/) and Python ML tools (ml/)
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
  - `concert-artists.json`, `concert-places.json`: Concerts' caches.
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
  Next, shuffle and repeat, persistence and Now Playing.
  - Start Radio (`playRadio`) sets `radioSeed`: the radio fills the queue at once and keeps
    going whatever the Autoplay setting says. Radio and Autoplay pages carry the queue's
    generation, so a page asked for an earlier queue is dropped.
  - Queue order: Play Next songs first, then songs added with Add to Queue, then Autoplay's or
    the radio's. `sequenceAutoQueue` orders Autoplay's songs to follow the song before them (a
    Play Next song when one waits).
  - It drives AutoMix: `prepareMix` analyses and plans the current and next track, and the
    transition is handed to the engine about 30 s ahead (`gaplessKey`).
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
  - **With AutoMix:** everything AutoMix does goes through `settings.mixes` (AutoMix on and
    bit-perfect off): `mixPair`, so no plan, no tempo ramp and no stems; `sequencesAutoQueue`;
    and the stem model's warm-up at launch. A deck gets a `StemMix` only from a cued
    transition. `reapplyOutputMode()` reloads the playing song when the setting changes, which
    cancels a cued mix and its stems.
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

Described in README "AutoMix" and in depth in `docs/paper/automix-paper.pdf`.

**The components and how they fit together.** Ten parts, each with one job:

| Part | Kind | Job | Code |
|---|---|---|---|
| Track analysis | signal processing | tempo, beats, bars, key, per-beat harmony and tone colour, sections, loudness; once per song, cached as analysis version 7 | `TrackAnalysis.swift` |
| Beat model | neural network (Beat This!, Core ML) | corrects a grid the tracker counted at 2:3 or 3:2 of the real beat; nothing else | `BeatModel.swift` |
| Lyrics and sample data | online lookups | line-timed lyrics; sample links from MusicBrainz, or Genius with a token | `Lyrics/`, `SampleDatabase.swift` |
| Planner | search and scoring | proposes up to six plans per pair (blends, lyric matches, sound matches, sample and tempo matches, ramps, fade) and ranks them | `MixPlanner.swift` |
| Sample gate | logistic model | decides whether an unlinked match at another speed is real shared material | `SampleGate` in `MixPlanner.swift` |
| Tempo limit and ramps | rules from DJ statistics | Tempo matches stay within 20 % and 2 semitones; 12–20 % gaps get a slow ramp | `tempoMatchMaxStretch`, `rampMaxStretch` |
| Stem separator | neural network (HT-Demucs, Core ML) | splits the two stretches an overlap covers into vocals, drums, bass and other, ahead of time | `StemSeparator.swift` |
| Mix engine | signal processing | two decks: approach, start on the audio clock, phase lock, lanes, stems, hand-over, settle | `MixEngine.swift`, `Playback/AudioEngine.swift` |
| Sequencer | conditional logit | re-orders Autoplay's next five songs so each mixes well out of the last | `MixSequencer.swift` |
| Editor and player | UI | show the plan and its reason, let the listener edit it, animate the transition | `UI/Player/MixEditorView.swift`, `AutoMixViews.swift`, `MixTransitionViews.swift` |

They act at four moments. (1) When a song is cached, analysis and the beat model describe it.
(2) When Autoplay adds songs, the sequencer orders them. (3) When a song becomes next, the planner
reads both analyses, lyrics and the sample database, filters through the sample gate and the tempo
limit, ranks the plans and picks one; with stems on, the separator processes the overlap's two
stretches straight away. (4) About 30 s plus the approach before the mix point, the player hands
the plan to the engine, which performs it; the editor and the full-screen player read the same
plan. The plan (`MixPlan`) is the contract between them: mix points, length, beat periods,
approach, pitch, tempo curve, per-deck lanes, stem lanes, reason and notes.

In short:
- `TrackAnalysis.swift` analyses tempo, beats, key, harmony, sections and the waveform.
- `MixPlanner.swift` proposes and ranks transitions. Tempo and pitch moves happen in an
  approach *before* the overlap, on the outgoing song.
- `SampleDatabase.swift` looks up sample links on MusicBrainz, or on Genius with a token.
- `MixSequencer.swift` orders the songs Autoplay lines up.
- `BeatModel.swift` runs the Beat This! beat and bar-line model (MIT licence) through Core ML,
  from `Models/` (bundled by `make-dist.sh`; `METROLIST_BEATMODEL=off` disables it). Analysis is
  version 7. The model only corrects a pulse the built-in tracker counted at 2:3 or 3:2; giving
  it a larger role was measured and made mixes worse (see `Tools/ml/README.md`).
- `Tools/groundtruth/` holds style groups (`groups.csv`, for audits only; the app never reads
  them), the common-mixes set and model-made reference labels (`silver/`).
- **Reference mixes** (2026-11-21) are documented in `docs/AUTOMIX_REFERENCE_MIXES.md`:
  - What Spotify Mix, Apple AutoMix and real DJs do, with measured statistics.
  - The curated pairs (`reference-mixes.tsv`), Spotify's "Mixed By" playlists and DJ-mixed
    albums.
  - How to resolve, download and audit them through YouTube Music.
  - `Tools/ml/reference_mixes.py` fetches and analyses the sources again. `Tools/ml/` holds the
  Python tools for labelling, converting and comparing models. The owner-derived sets (their
  hand-edited transitions and play history) are in the git-ignored `Tools/ml/data/`.
- `MixPlan.swift` holds the plans, which `MixEngine` plays.
- **Learned parts (2026-11-21)**, trained on the reference mixes (`docs/AUTOMIX_REFERENCE_MIXES.md`):
  - `SampleGate` (MixPlanner.swift) decides whether an unlinked match at another speed is
    shared material (logistic, `Tools/ml/train_gate.py`). Without that evidence the match is
    offered as "Tempo match" (`MixReason.tempo`), not "Sample match".
  - Tempo ramps bridge 12–20 % gaps when nothing else lines up (`MixPlanner.rampMaxStretch`).
  - `MixSequencer.fit` uses weights learned from DJ sequences (`Tools/ml/train_sequencer.py`).
- **Stems:**
  - `StemSeparator.swift` runs HT-Demucs (MIT) through Core ML from `Models/HTDemucs.mlpackage`.
    The model is about 200 MB and git-ignored; make it with `Tools/ml/convert_demucs.py Models`.
    `make-dist.sh` bundles it when present.
  - fp16 doesn't work: its output is wrong.
  - `MixPlanner.withStems` adds per-stem lanes to synced plans (Mosaikbox rules).
  - The player separates a transition's two stretches as soon as it is decided
    (`MixEngine.separateStemsAhead`, cached in `StemSeparator`). `MixEngine.prepareStems` takes
    them when the transition is cued, decides the vocal hand-over on the vocal stems
    (`vocalHandOver`: the outgoing vocals leave on the beat before the incoming ones start, when
    both sing for over a second), and gives each deck an `AudioEngine.StemMix`. The deck
    subtracts `(1 − gain) × stem` from what it reads.
  - Decks read 3 s ahead (`AudioEngine.pump`), and stems change only what is read after they
    are set. Late stems start from the deck's `readPosition`, faded in (`stemGains`). A side
    whose stems weren't in place when the overlap began swaps its bass on the EQ
    (`withoutStems`), because a stem plan switches the EQ bass swap off.
  - Opus decoding (`AudioDecode`) runs 3.5 ms ahead of playback's packet times;
    `AudioDecode.stereo` returns that offset. Analysis beat times share the offset; it cancels in
    transitions, so it was left alone.

**AutoMix documentation and evidence.** Keep these; they hold how AutoMix was developed and
why it works the way it does:
- `docs/AUTOMIX_REFERENCE_MIXES.md` (in git): reference mixes, measured statistics, how to
  fetch and audit them.
- `docs/AUTOMIX_BRANCH_MERGE_GUIDE.md` (in git): what the AutoMix branch changed, its evening
  fixes and their causes, and its after-merge checks.
- `Tools/ml/README.md` (in git): the beat model, its conversion gotchas and its measurements.
- `docs/automix-progress.md` (git-ignored, copied by hand): the session-by-session log of the
  AutoMix redevelopment, with every measurement.
- `docs/Metrolist AutoMix and Queueing - Technical Paper.pdf` (in git).
- `Tools/ml/data/` (git-ignored, 4.3 GB, cloned from the AutoMix worktree): audit results
  (`audit-results/final2` and earlier), the gate's training sets, reference resolutions, test
  audio and model checkpoints.
- Still only in `.claude/worktrees/automix-all-styles`: the Python environments
  (`Tools/ml/.venv`, `.venv-convert`, `.venv-stems`; remake them from
  `Tools/ml/requirements*.txt`) and the backup of the AutoMix system before the 2026-11-21
  redevelopment (`.source-backup-automix-2026-11-21/`).

### UI (`UI/`)

- `RootView.swift`: the sidebar (Home, Explore, Shared Queue, then Liked Songs, Albums, Artists,
  Playlists, Downloads, Music Videos, History, and the playlists), the navigation stack, the
  player bar, and the full-screen player overlay.
- `Player/NowPlayingViews.swift` has `ExpandedPlayerView`: the cover layout, or
  `VideoStageView` (`Player/VideoPlayerView.swift`) while a music video shows its picture.
  `VideoStageView` is edge to edge, with auto-hiding glass controls, a quality menu and
  macOS full screen. The queue shows "Radio: similar songs keep coming" while
  `player.radioSeed` is set, otherwise the Autoplay line.
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

## Status (2026-11-22, merged branch)

Everything up to the music-video work and album header redesign is committed on `dev`
(`14aa15f`). The two branches of 2026-11-21 were each committed at the owner's request and
merged on branch **`claude/merge-2026-11-21`** (worktree `.claude/worktrees/merge-2026-11-21`).
Nothing is pushed, and `dev` and `main` are unchanged.

| Branch | Commit | Its notes |
|---|---|---|
| `claude/session-2026-11-21` | `b46475e` | `docs/OVERNIGHT_PROGRESS.md`, `docs/MERGE_GUIDE_session-2026-11-21.md` |
| `claude/automix-all-styles` | `fbe479e` | `docs/automix-progress.md`, `docs/AUTOMIX_REFERENCE_MIXES.md`, `docs/AUTOMIX_BRANCH_MERGE_GUIDE.md`, `Tools/ml/README.md` |
| `claude/merge-2026-11-21` | the merge of the two | this guide |

### 2026-11-22 (morning): final fixes, measurements again, ready for `dev` and `main`

The owner will commit this branch onto `dev` and merge `dev` into `main` through a GitHub pull
request. `origin/dev` (`14aa15f`) and `origin/main` (`ca2cecd`) are both ancestors of this branch,
so `dev` fast-forwards and the pull request has no conflicts. Nothing is committed or pushed.
Prepared in the worktree, both git-ignored: `COMMIT_MESSAGE.txt` and `PR_DESCRIPTION.md`. Before
fast-forwarding `dev`, the main checkout's untracked `docs/PROJECT_GUIDE.md` (the 2026-11-20
version) must be moved aside, or git refuses to overwrite it. The repository root also holds
`albums`, an 820 KB raw search response ("Grand Theft Auto VI") committed by mistake in `14aa15f`;
the owner decides whether to `git rm` it.

| Change | Check |
|---|---|
| The Concerts page's sort menu and refresh button showed over the full-screen player: the page updates them after its list refreshes, which un-hid them. `ImmersiveWindowChrome` now observes each hidden item's `isHidden` and hides it again | window test with the new `METROLIST_WINDOWTEST_CONCERTS=1`: hidden 1.5 s and 5.5 s after the player opens (before: back at 5.5 s), shown again after it closes |
| An empty toolbar band over a music video in macOS full screen whenever the controls showed: `TitlebarFader` set the title bar's alpha back to 1. It now keeps it at 0 while the window is in full screen and restores it when the video player goes. The night's `.autoHideToolbar` change did not take effect | builds; not testable from a test run (it can't enter full screen) |
| MONTERO → Body, now a 7 s fade | the owner heard it: "works and sounds good" |
| Every figure in the paper, README, social drafts and notes measured again on the current build, songs analysed from scratch | table in `docs/paper/FACTS.md`; outputs in `Tools/ml/data/audit-results/2026-11-22/` |
| Paper: author "Claude Opus 5.5, extended thinking at xhigh"; components table and "How the parts work together"; limitations of AutoMix and of the research field, with the sources' text read again; Spotify and Apple quotes corrected; 10 pages | compiled, every page checked |
| Social drafts: the components and how they fit together; today's figures; LinkedIn post 2,930 characters | |
| Guide: components table in the AutoMix section; `docs/README.md` (new index); `.gitignore` lets `docs/paper/FACTS.md` in | |

What the measurements changed: the learned Autoplay order's gain is no longer statistically clear
(29.9 % against 27.8 % first choice, mean reciprocal rank +0.020 with a 95 % interval of −0.002 to
0.040; it read 30.1 % against 27.3 % on 2026-11-21). Unconfirmed "Sample match" is 33 → 6 % of
style pairs and 24 → 5 % of history (notes said 2 %). Stems: a 20 s stretch takes 2.8 s, not 5 to
7 s; the first segment took 0.68 s, so the "about 20 s first run" was not reproduced. Vocal residue
after one pass is −44 to −57 dB and a second pass gains 0 to 7 dB. Without the limit, 61 of 91
distinct Tempo matches move tempo more than 25 %. The 21 November "pulse, octave, phase" beat-model
role is no longer in the code and is no longer quoted. Unchanged: beat F 0.796 / 0.814 / 0.953,
vocaloid tempo 46 → 56 %, the tempo-limit plan counts, stem parity (worst 112.0 dB), the approved
plans.

Checks on 2026-11-22 (current code): `--featuretest` 47/47; `--radiotest` 14/14 (live, release);
`--playnexttest` and `--videomixtest` only the 4 known label failures; window test transition view
PASS ×2; stems ahead ready in 0.0 s and stems late via the EQ then 3.9 s (release build: the debug
build separates too slowly for the late path); approved pairs byte-identical with and without
stems; `--stemtest` worst 112.0 dB; `--beatmodeltest` 6/6.

**The merge.** Git found two conflicts: `AppSettings.swift` (kept bit-perfect's `bitPerfect`,
`exclusiveOutput`, `mixes`, `normalizes`, and the AutoMix branch's `mixOptions` with `stems:`)
and this guide (merged by hand). `PlayerController.swift`, `AudioEngine.swift`,
`LibraryBackup.swift`, `SettingsView.swift`, `main.swift` and `README.md` merged cleanly and
were checked by reading against both merge guides: every change from both sides is there, no
command-line flag is defined twice, and every README line both branches added is kept. One
change beyond the textual merge, as the AutoMix guide asked: the stem model's warm-up at launch
checks `settings.mixes`, so it isn't loaded while bit-perfect output pauses AutoMix. The
git-ignored stem model, `Tools/ml/data/` (APFS clone) and the ignored notes
(`docs/automix-progress.md`, `docs/OVERNIGHT_PROGRESS.md`,
`docs/MERGE_GUIDE_session-2026-11-21.md`) were copied in by hand; they are byte-identical to
their sources.

**Checks on the merged build (2026-11-21, 22:10–22:25).** Every run had `METROLIST_HOME` in
`/tmp/claude/mg-*`, `METROLIST_TEST_KEYCHAIN=1`, and a renamed copy of the binary
(`Metrolist-merge-debug`/`-release`).

| Check | Result |
|---|---|
| `swift build`, `swift build -c release` | build; only the existing Swift 6 concurrency warnings |
| `--featuretest` (fresh home) | 38 PASS, including the 6 stem-timing checks |
| `--radiotest` (live, release, fresh home) | 12 PASS |
| `--playnexttest` (clone of `mixhome`) | 17 PASS, 3 FAIL: the known "Sample match"/"Known sample" label checks |
| `--videomixtest` (clone of `mixhome`) | 5 PASS, 1 FAIL: the known label check |
| `--mixaudit --approved` and `--approved --stems` (clones of `styleshome`) | byte-identical to `/tmp/claude/approved-check/after-plain.tsv` and `after---stems.tsv` (10 pairs; 9 use stems) |
| Stems in time: `--mixtest 4tlUwgtgdZA -3PKrJgxHK8 --stems --lead 5 --ahead` | "stems ready in 0.0 s (separated ahead)", no "not in place" line |
| Stems late: the same with `--lead 3`, no `--ahead` | "stems not in place … the bass swap is made with the EQ", then ready in 3.5 s, read 5.9 s into the overlap (late) |
| `--stemtest` (4tlUwgtgdZA at 60 s) and `Tools/ml/check_stems.py` | PASS, lag 0; against PyTorch worst stem 112.0 dB (PASS needs 40) |
| `--bitperfecttest` (offline) | 22/22, including "AutoMix is paused but its setting kept" and "nothing processes the samples" |
| `--soundtest` | 17 PASS |
| `--concerttest` / `--concerttest --live` | 54 PASS / all PASS, Ticketmaster skipped (no key); 30 artists through MusicBrainz in 40 s |
| `--outputtest` | all 3 outputs accepted |
| `--videoplayertest` (live) | 24/24 |
| `METROLIST_WINDOWTEST=1 METROLIST_WINDOWTEST_PUSH=1` | no `navigationStack.back` item while the full-screen player is open; it is back after closing; frame unchanged |
| `--snapshot dir --concerts` | the empty prompt is centred; slayr's listing without a picture shows the artist's |
| Bit-perfect and AutoMix together (live, owner-approved; a temporary `--togethertest` built in a scratch copy, not in the branch) | 13/13: P.Y.T. → Good Life with AutoMix and stems on and bit-perfect on: nothing planned or prepared, no processing stages, the songs joined without a reload, no mix ran, no "cued" or "stems" lines in `mix.log`; turning bit-perfect off left the External Headphones as before (48 kHz, 32-bit float, which was already their deepest format, so nothing had to be switched or restored) |
| Owner's settings and data | `app.metrolist.mac.automix` and `Metrolist` preference domains byte-identical before and after (`autoplay` still `1`); nothing in `~/Library/Application Support/Metrolist` changed; output devices' rates unchanged |

Settings showing the orange "Paused while bit-perfect output is on" note when both are on was
checked by reading only (no capture renders the AutoMix section). A command-line run never gets
the app's quit-time restore of the output (`BitPerfectOutput.restoreAll` runs on
`willTerminate`), so live bit-perfect tests must switch the setting off before exiting.

Not run:
- The session guide's "owner placement 19 of 21": disregarded, as the AutoMix guide says (it
  measured the accidental custom transitions).
- The packaged `dist/Metrolist.app` (rebuilt here at 22:24, both models bundled, 217 MB) was
  not launched: as a bundle it uses the owner's real preference domain.

**After the merge (2026-11-21 night, uncommitted on this branch; owner's list from their test of
the merged app).** Working note: `docs/OVERNIGHT_2026-11-21_PROGRESS.md` (git-ignored).
- **Tempo match limited.** MONTERO → Body was planned as a "Tempo match" at 163 % speed and +7
  semitones (Body counted at double time, a ratio just inside the old 0.62–1.6 range). Tempo
  matches (gate closed, no shared material) now keep within 20 % and 2 semitones
  (`MixPlanner.tempoMatchMaxStretch`/`tempoMatchMaxShift`; `--mixaudit --tempo-cap x` to
  measure). MONTERO → Body is now a 7 s fade. Approved pairs byte-identical. Over 237 audit
  pairs (style groups and common mixes, same analyses before and after): Tempo matches 51 → 10
  (none over 20 %), plans stretching over 20 % 51 → 13 (samples, plus 3 tempo ramps at rates 1.22 to 1.23), fades 34 → 59, sound
  matches 25 → 38, synced 194 → 156. Two non-tempo plans changed as a side effect (dropped tempo
  matches no longer fill the planner's three slots): a rock pair's Sample match became a Sound
  match, and a J-pop sound match moved.
- **Page title over the full-screen player** removed: SwiftUI turned the window title back on as
  the page underneath updated; `ImmersiveWindowChrome` keeps it hidden (KVO on
  `titleVisibility`). Window test: no title text while the player is open, title-bar height
  unchanged.
- **ⓘ for "Keep the output to Metrolist alone"** works: the disabled toggle disabled its ⓘ
  too. Only the switch is disabled now (`LabeledContent`); the label dims; the explanation says
  it needs bit-perfect output.
- **Highlighted lyrics cut off** (Japanese beside a music video): `FlowLayout` kept a word whole
  even when wider than the column; it now breaks between syllables when a word doesn't fit
  (`FlowWord` layout value). `--featuretest` checks it.
- **Bar over a full-screen music video**: in macOS full screen the toolbar lives in its own
  window; while the player is open there it now auto-hides (`.autoHideToolbar`,
  `ImmersiveWindowChrome.presentation`, checked offline by `--featuretest`). A test-launched app
  can't make itself active to enter full screen, so the real thing is unverified.
- **New: transition view** (owner's design). During an AutoMix transition the next song's cover
  slides in beside the playing one, the backdrop splits between their colours, and at the
  hand-over the old cover slides away and the new one centres (`MixTransitionViews.swift`,
  `PlayerController.mixIncoming`). Checked through a real muted transition
  (`METROLIST_WINDOWTEST_MIX`); the owner saw it and approved.
- **Start Radio on the playing song** no longer restarts it: the radio replaces what comes
  after (`continueAsRadio`). `--radiotest` 14/14 with two new checks.
- **Found while testing (pre-existing since `dev` 14aa15f):** seeking, or the preview button,
  after a transition was cued lost it, and the next song followed after a gap
  (`MixEngine.seek` drops the cue; the player never re-cued). `PlayerController.seek` now
  resets `gaplessKey`.
- **New technical paper** on AutoMix version 2: `docs/paper/automix-paper.pdf` (source
  `automix-paper.tex`, IEEEtran, built with `tectonic -X compile`; sources of every fact in
  `docs/paper/FACTS.md`, git-ignored). The 14 November 2026 paper stays in `docs/` as the record
  of version 1.
- **README rewritten** as the GitHub page, with screenshots from the running app
  (`docs/images/`, made by `METROLIST_WINDOWTEST_SHOWCASE` in a home holding only two songs).
- Checks: `--featuretest` 47/47, `--radiotest` 14/14, `--playnexttest`/`--videomixtest` only
  the 4 known label failures, approved pairs byte-identical, window tests above.

**From `claude/session-2026-11-21` (2026-11-21 overnight and afternoon):**
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

**From `claude/automix-all-styles`: AutoMix for every style (2026-11-21, overnight; log in
`docs/automix-progress.md`).**
- Measurement tools:
  - `--mixaudit`, `--analysisaudit`, `--beatmodeltest`, `--dumppcm` and `Tools/run_audits.sh`.
  - Style groups (198 songs, 7 groups) and a common-mixes set (37 sample pairs and blends).
  - Model-made reference beat labels.
- Beat This! small runs in the app through Core ML. It corrects 2:3 pulse errors (vocaloid tempo
  right 46 % → 56 %, beat F 0.67 → 0.72). The approved pairs are unchanged.
- Planner: bars and section boundaries can follow bar-by-bar grids; overlaps are mapped correctly
  when one song is counted at half or double time; external grids can be supplied
  (`METROLIST_BEATGRIDS`).
- The sample-gate thresholds were measured and left as they were: tightening them raised fades
  from 24 % to 38 %.

**Reference mixes, learned parts and stems (2026-11-21 daytime, same branch; backup of the
system before it in `.source-backup-automix-2026-11-21/` in the AutoMix worktree).** Details
are in `docs/AUTOMIX_REFERENCE_MIXES.md` and `docs/automix-progress.md`.
- **Reference sets:** Spotify "Mixed By" playlists, DJ-mixed albums, MixesDB DJ histories and
  curated sample pairs. Songs were fetched into `/tmp/claude/refhome-{a,b,c}`.
- **Learned sample gate, "Tempo match" and tempo ramps.** Against the 05:50 build:
  - Approved plans are identical.
  - Owner placement was unchanged at 19/20/21 of 21, but that measure used the custom
    transitions the owner later said were accidental clicks; disregard it.
  - featuretest, playnexttest and videomixtest all pass.
  - 200 random style pairs:
    - "Sample match" 33 % → 6 % (49 are now "Tempo match").
    - Fades 24 % → 14 %, synced 74 % → 81 %.
    - Stretches over 12 % 35 % → 42 %, because ramps replace fades.
  - Results are in `Tools/ml/data/audit-results/final2`.
- **Learned Autoplay ordering:** 30.1 % against 27.3 % first-of-five on held-out DJ sequences.
- **Stems:** HT-Demucs on device, the "Mix with stems" setting (on by default when the model is
  installed) and Mosaikbox's rules.
  - Verified: numerically against PyTorch, aligned with playback to the sample, through a real
    muted engine transition, and on the approved pairs (mix points unchanged).
  - **Not yet heard by the owner.**

**Owner's listening test fixes (2026-11-21 evening, same branch).** The owner tested a
16-song sequence. Fixed:
- Start Radio queued only the song: it depended on Autoplay, which was off in the owner's
  stored settings although they had turned it on (set back on; tests now keep their settings
  apart).
- A radio replaced while loading got the old radio's songs; a swapped seed video came back as a
  duplicate.
- AutoMix now orders Autoplay's songs after a waiting Play Next song instead of not at all; Add
  to Queue goes before Autoplay's songs.
- Vocal bleed with stems: stems arrived late (the preview jumps 5 s ahead and separating takes
  3 to 5 s, and decks read 3 s ahead), and the outgoing vocals took a quarter of the overlap to
  leave. Now stems are separated ahead and cached, late ones start where the deck has read,
  the bass swap falls back to the EQ, and the vocals leave just before the incoming ones.
- The accidental custom transitions were cleared and are ignored (rules above).
- Verified on that branch: `--featuretest` 38 PASS, `--radiotest` 12 PASS (live), approved
  plans identical (10 pairs, with and without stems), `--playnexttest`/`--videomixtest` only the
  4 known label failures (the same as the build before), stems in time and late through a real
  muted transition, `--stemtest` PASS.

Design notes for earlier work are in the main checkout's `docs/` (git-ignored, not copied):
- Metrolist v14 integration plan
- Phase 8 build status
- Device Connect protocol review
- Shared queue design
- Casting threat model (casting was left out on purpose)
- AutoMix and queueing technical paper (PDF, also in git)

## Open items

Waiting on the owner:
- Commit branch `claude/merge-2026-11-21` onto `dev` and open the pull request into `main` (the
  owner's plan, 2026-11-22). See Status 2026-11-22 for the untracked guide in the main checkout
  and the stray `albums` file.
- A look at Settings › Playback with bit-perfect output and AutoMix both on: it should show
  AutoMix paused (the playback side was checked live on 2026-11-21).
- In the real app: a music video in macOS full screen (no band at the top while the controls
  show; fixed 2026-11-22, untestable from a test run); the Concerts page under the full-screen
  player (no sort menu or refresh button); a playlist or album page under the
  full-screen player (no title); the ⓘ beside "Keep the output to Metrolist alone" with
  bit-perfect off; Japanese word-synced lyrics beside a music video; scrubbing near a
  transition (it should still mix); listening to pairs that used to be big Tempo matches (now
  mostly fades or sound matches).
- `README.md` and `docs/images/` are new: review before pushing.
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

AutoMix for every style (waiting on the owner):
- A listening check of the pairs in the summary of `docs/automix-progress.md` against Apple
  Music, especially vocaloid songs whose tempo was corrected.
- Reference labels checked by ear: the current ones come from a model.

AutoMix learned parts and stems (waiting on the owner, 2026-11-21):
- **Listen with "Mix with stems" on and off.** Nine of the ten approved pairs now add stem moves
  (the mix points are unchanged): the outgoing vocals step aside when both songs sing, the
  basslines swap halfway, and the drums hand over in blends.
- **"Tempo match" is now limited to 20 % and 2 semitones** (2026-11-21 night, after the owner
  found MONTERO → Body at 163 % unnatural). On 2026-11-22 the owner heard MONTERO → Body (now a
  7 s fade) and judged it good. The other former Tempo matches haven't been heard.
- **Listen to stem transitions again** after the 2026-11-21 evening fixes, including with the
  preview button (which now starts 10 s ahead while stems are still being separated).
- **Hear the 12–20 % tempo ramps** on pairs that used to fade.

AutoMix learned parts and stems (not done):
- If vocals still bleed with the timing fixed: a stronger vocal model (HT-Demucs fine-tuned).
  Separating again finds only −44 to −57 dB of vocal left (2026-11-22, six songs), but the
  model can't see vocals it puts in "other".
- Other code still writes settings to `UserDefaults.standard` directly (`OutputDevices`,
  `BlockedContent`, `Scrobbler`, `LyricsService`, Device Connect, and `ConcertStore`); moving
  them to `AppPaths.settings` would keep tests off those too. `OutputDevices` matters most,
  because the bit-perfect and output tests choose devices.
- Stem-measured singing in the analysis itself, so mix points are chosen on it. The mid-band
  guess gets 44 % of bars wrong without lyrics. Separating a whole four-minute song would cost
  about 35 s on top of analysis (2.8 s per 20 s on 2026-11-22).
- Drum-pattern similarity for the drum rule. Today it applies to all blends and tempo matches.
- Re-weighting the clash penalty now that stems can remove a vocal clash.
- The Spotify and album songs (`refhome-b`, `refhome-c`) are analysed but not yet used for the
  gate's negatives. MixesDB sets are not yet resolved to songs.
- The learned Autoplay order's gain over the hand-set weights is within chance on 28 sequences
  (2026-11-22). More DJ-made sequences would settle whether it helps.
- Optional: the signal path's `processingStages` could say "AutoMix (stems)" while a stem
  transition plays.

AutoMix for every style (not done):
- Adapting the planner to the model's bar-by-bar grids. More accurate grids alone made mixes
  worse, because the planner is tuned to unbroken four-beat grids.
- Beat This! final (20 M parameters) instead of small (it agrees 0.85 on vocaloid bar lines).
- Fine-tuning on balanced, owner-checked labels; a beat-grid correction sheet in the editor.
- Local keys at the intro and outro, ending types, SoundAnalysis vocal detection, and sequencer
  changes (plan phases P2 e–g and P6).

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
