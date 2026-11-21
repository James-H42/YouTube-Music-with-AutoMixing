# Project guide for agents

Read this first when continuing development. It gives the state of the project, how the code is
organised, the rules the owner has set (with their reasons), how to build and test, and what is
still open. Features are described for users in `README.md`; this guide does not repeat them.

Last updated: 2026-11-21 (evening). Update the "Status" and "Open items" sections at the end of any
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
  `dist/Metrolist.zip`. `build/Metrolist.app` (from `Scripts/make-app.sh`) is usually stale.
  Rebuild `dist/` after changes the owner will try.
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
- Tests that touch Device Connect must set `Keychain.service` to a test name first. Otherwise
  the debug binary reads the app's real Keychain items and macOS shows a prompt that hangs it.
- `swift build` sometimes reports success in about 3 s without recompiling a file that was just
  edited. If a change seems missing, touch the file and build again.
- Offscreen captures (`--snapshot`, `--albumshot`, `METROLIST_VIDEOSHOT`) don't draw Liquid
  Glass, vibrant text or `AVPlayerLayer` video. That is the capture method, not a layout bug.
  Ask the owner to check those visually.

### Test commands

All are flags to the built binary (`.build/debug/Metrolist <flag>`). Most print PASS/FAIL lines.

| Area | Commands |
|---|---|
| General | `--featuretest` (offline, needs a test home), `--probe [query]`, `--snapshot dir` |
| AutoMix | `--mixplan A B` (add `--samples` to look up sample links, `--debug` for detail), `--mixtest A B`, `--mixplay`, `--analyze id`, `--playnexttest`, `--videomixtest` |
| AutoMix measurement (use `swift build -c release`) | `--mixaudit groups.csv` / `--approved` / `--pairs-file f` (with `--lookup`, `--standout x`, `--no-gate`, `--ramp 0`, `--stems`, `--features out.tsv [--augment 1.25:0,…]`), `--analysisaudit labelsDir`, `--beatmodeltest refDir`, `--dumppcm dir`; `Tools/run_audits.sh BINARY HOME OUT` runs them all |
| Queue (live) | `--radiotest [--no-order]`: Start Radio with Autoplay on and off, Play Next and Add to Queue order, a radio replaced while loading, Autoplay's order after a Play Next song (release build, about 5 min), settings kept apart |
| Stems | `--vocalresidue FILE [START…]` (vocal left after the deck's subtraction, measured by separating again), `--stemtest FILE START DIR` (Core ML against PyTorch with `Tools/ml/check_stems.py`, alignment with playback, removal through the deck's own code), `--mixtest A B --stems --lead 25` (a real transition with stems; `--ahead` separates first, as the player does; a short `--lead` without it exercises late stems). Set `METROLIST_MODELS=<repo>/Models` when the binary is built outside the repository |
| Video | `--videoplayertest [query]` (live, end to end), `--videosynctest [query]`, `--videotest query` (`METROLIST_VIDEOQUALITY=2160`), `--videotypes query`, `--typeprobe id…`, `--typerefreshtest` |
| Streams | `--qualitytest id`, `--audioswap playlistId`, `--ciphertest`, `--potoken` |
| Artwork | `--amtest artist [album]…`, `--albumshot dir "album"`, `--facetest image` |
| Sound | `--soundtest`, `--outputs`, `--outputtest`, `--chaintest` |
| Library | `--backup`, `--restore`, `--inspect`, `--importforeign`, `--importplaylist`, `--lyricsprobe id`, `--blocktest`, `--scrobbletest`, `--exportifytest` |
| Devices | `--dctest`, `--sqtest`, `--sqnettest`, `--sqmixtest A B`, `--dcserve s`, `--sqjoin host port`, `--discordtest` |
| Window | `METROLIST_WINDOWTEST=1` (real main window, full-screen player, tiling) |

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
    Play Next song when one waits). It drives AutoMix: `prepareMix`
  analyses and plans the current and next track, and the transition is handed to the engine
  about 30 s ahead (`gaplessKey`).
- **Audio versions:** with "Prefer audio versions" on, a video not chosen by the listener is
  swapped for its audio release, ahead of time when it is next (`resolveNextAudioVersion`) and
  when it starts (`loadCurrent`). `chosenVideos` holds the exceptions. The player's lookup
  accepts a release of another length (`strictLength: false`), because music videos add intros.
- `MediaStore.swift` holds audio files: a cache with a size limit plus pinned downloads. It
  streams a file while it downloads (`ProgressiveDownload`) and tags downloads (`WebMTagger`).
- `AudioEngine.swift` and `Mix/MixEngine.swift` handle sound: WebM demuxing, Opus decoding,
  two decks with time-stretch and pitch, then the mixer, `MasterEQ` and `Limiter`.
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

### UI (`UI/`)

- `RootView.swift`: the sidebar (Home, Explore, Shared Queue, then Liked Songs, Albums, Artists,
  Playlists, Downloads, Music Videos, History, and the playlists), the navigation stack, the
  player bar, and the full-screen player overlay.
- `Player/NowPlayingViews.swift` has `ExpandedPlayerView`: the cover layout, or
  `VideoStageView` (`Player/VideoPlayerView.swift`) while a music video shows its picture.
  `VideoStageView` is edge to edge, with auto-hiding glass controls, a quality menu and
  macOS full screen.
- `Components/WindowChrome.swift` hides only the toolbar's items while the player is open,
  never the toolbar itself.
- `Screens/`: album, artist, playlist, search, library screens, and imports.
  - `Components/ItemViews.swift`: `PageHeader`, whose cover scales from 170 to 320 pt with the
    page's width.
  - `Components/SongViews.swift`: `SongList`, where row clicks are not "chosen" except with
    `playsVideos`.

## Status (2026-11-20)

All work since the last commit (`51191bd`) is **uncommitted on `dev`**. It includes:
- Metrolist v14 phases 1–6, Device Connect (phase 8), and the shared queue.
- The 2026-11-19 batch of 13 tasks.
- The 2026-11-20 test-round fixes.
- The music-video work:
  - The full-screen video player and the quality setting.
  - Video downloads and the Music Videos sidebar entry.
  - The rules for official videos only and no mixing for videos.
  - The video type refresh.
  - The fix that plays playlist videos as their audio release.
- The album header redesign and the Apple Music compilation fix (animated GTA VI album cover).

**AutoMix for every style (2026-11-21, overnight, uncommitted on branch
`claude/automix-all-styles` in `.claude/worktrees/automix-all-styles`; log in
`docs/automix-progress.md` there).**
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
system before it in `.source-backup-automix-2026-11-21/`).** Details are in
`docs/AUTOMIX_REFERENCE_MIXES.md` and `docs/automix-progress.md`.
- **Reference sets:** Spotify "Mixed By" playlists, DJ-mixed albums, MixesDB DJ histories and
  curated sample pairs. Songs were fetched into `/tmp/claude/refhome-{a,b,c}`.
- **Learned sample gate, "Tempo match" and tempo ramps.** Against the 05:50 build:
  - Approved plans are identical.
  - Owner placement is unchanged at 19/20/21 of 21.
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

Design notes for earlier work are in `docs/`:
- Metrolist v14 integration plan
- Phase 8 build status
- Device Connect protocol review
- Shared queue design
- Casting threat model (casting was left out on purpose)
- AutoMix and queueing technical paper (PDF)

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
- Verified: `--featuretest` 38 PASS, `--radiotest` 12 PASS (live), approved plans identical
  (10 pairs, with and without stems), `--playnexttest`/`--videomixtest` only the 4 known label
  failures (the same as the build before), stems in time and late through a real muted
  transition, `--stemtest` PASS. `dist/Metrolist.app` rebuilt.
- **Merging with `claude/session-2026-11-21`:** `docs/AUTOMIX_BRANCH_MERGE_GUIDE.md`.

## Open items

Waiting on the owner:
- A visual check of the music-video player in the real app: the controls on glass, title text,
  auto-hide, the quality menu and macOS full screen.
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
- **Decide whether "Tempo match" (big tempo-eased jumps between unrelated songs) should stay.**
  It was kept for 4 saved transitions of this kind, which the owner has since said were
  accidental clicks, so nothing of the owner's supports it now. DJs rarely move tempo more than
  20 %. Several played in the owner's 2026-11-21 test, which they said mostly worked.
- **Listen to stem transitions again** after the 2026-11-21 evening fixes, including with the
  preview button (which now starts 10 s ahead while stems are still being separated).
- **Hear the 12–20 % tempo ramps** on pairs that used to fade.

AutoMix learned parts and stems (not done):
- If vocals still bleed with the timing fixed: a stronger vocal model (HT-Demucs fine-tuned).
  Separating again finds only −37 to −57 dB of vocal left, but the model can't see vocals it
  puts in "other".
- Other code still writes settings to `UserDefaults.standard` directly (`OutputDevices`,
  `BlockedContent`, `Scrobbler`, `LyricsService`, Device Connect, and the other branch's
  `ConcertStore`); moving them to `AppPaths.settings` would keep tests off those too.
- Stem-measured singing in the analysis itself, so mix points are chosen on it. The mid-band
  guess gets 44 % of bars wrong without lyrics. Separating a whole song costs about 20 s per
  song on top of analysis.
- Drum-pattern similarity for the drum rule. Today it applies to all blends and tempo matches.
- Re-weighting the clash penalty now that stems can remove a vocal clash.
- The Spotify and album songs (`refhome-b`, `refhome-c`) are analysed but not yet used for the
  gate's negatives. MixesDB sets are not yet resolved to songs.

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
