# macOS YouTube Music with AutoMix

A native macOS client for YouTube Music, written in SwiftUI with Liquid Glass, with
**AutoMix**: optional DJ-style transitions between songs. It is a complete app on its own and
needs no other software. It follows the design of the Android client
[Metrolist](https://github.com/MetrolistGroup/Metrolist) (GPL-3.0), and is licensed GPL-3.0
in the same way.

Features: search and browse, your library and playlists, synced lyrics, queue and Autoplay,
downloads, a mini player and menu-bar player, system Now Playing, and AutoMix with a
transition editor. The features of Metrolist v14 that suit a native Mac app have been added as
well (see "From Metrolist v14"). There is also a shared queue that people on your network can add
songs to. Data is kept in `~/Library/Application Support/Metrolist`.

## Build and run

Requires macOS 26+ and the Xcode Command Line Tools (full Xcode is not needed).

    Scripts/make-app.sh          # builds build/Metrolist.app
    open build/Metrolist.app

    Scripts/make-dist.sh [version]    # release build: dist/Metrolist.app and dist/Metrolist.zip

Release builds are for Apple silicon, ad-hoc signed and not notarised (see the disclaimer).

## Disclaimer

**This is an unofficial, independent project. It is not affiliated with, endorsed by or sponsored
by Google, YouTube, YouTube Music, Spotify, Apple, MusicBrainz, Genius, WhoSampled or the
Metrolist project.** All product and company names are trademarks of their respective owners
and are used only to say what this software works with.

- **Personal use only.** The app plays audio from YouTube Music through the same interfaces
  its own web client uses. It is provided for personal, non-commercial use with your own
  account. It is not a way to redistribute, record or download copyrighted music, and
  nothing here grants any right to the music. You are responsible for following the laws
  where you live and the terms of the services you use.
- **Terms of service.** Using an unofficial client, signing in with account cookies, and
  working around YouTube's bot checks (see "Playback identity and bot checks") may breach
  YouTube's Terms of Service and could lead to rate limits, blocked requests or action
  against your account. Use it at your own risk.
- **Your credentials stay on your Mac.** The signed-in session (account cookies) and the optional
  Genius token are stored in files in the app's data folder that only your user can read, and
  the cookies are used only for requests to YouTube. Last.fm and ListenBrainz sign-ins and
  Device Connect pairing keys are kept in the macOS Keychain, never in files or backups. Never
  commit any of these, and never share your data folder
  (`~/Library/Application Support/Metrolist`), which also holds your library,
  listening history and cached audio.
- **Online lookups.** If "Look up known samples online" is on, the title and artist of the
  playing and next songs are sent to musicbrainz.org (and to Genius if you add a token).
  Switch it off in Settings → AutoMix. Song titles, artists and lengths are also sent to the
  lyrics sources you leave on in Settings → Lyrics (BetterLyrics, LRCLIB, SimpMusic, lrc.red),
  and what you play to Last.fm or ListenBrainz if you sign in to them. The AI-artist blocklist
  is downloaded from GitHub when that is on, and the AutoEq headphone catalogue when you search
  it. Playlist import reads only the page you give it.
  Nothing else about you is sent.
- **Local network.** Device Connect and the shared queue are off until you switch them on. They
  listen only on the local network, and every new device needs a six-digit code that you
  approve on the Mac.
- **No warranty.** The software is provided "as is", without warranty of any kind, as the
  GNU General Public License v3.0 (see `LICENSE`) sets out. Transitions are produced by
  automatic analysis and may not sound as intended.
- **Third-party code and credit.** The design, and the way it talks to YouTube Music, follow
  the Metrolist Android app (GPL-3.0), whose authors deserve the credit for it.
  `InnerTube/EJSSolver.swift` bundles yt-dlp's EJS solver (Unlicense, with meriyah under ISC
  and astring under MIT). Their licences and credits apply to those parts. Two services are
  used, not bundled. Exportify (github.com/watsonbox/exportify, MIT) is opened in a window for
  exporting private Spotify playlists. AiSList (github.com/Override92/AiSList, CC BY-NC 4.0) is
  downloaded at run time when AI-artist blocking is on.
- **Releases.** Builds are ad-hoc signed and not notarised, so macOS
  will ask you to allow the app under System Settings → Privacy & Security. Distribute the
  source with any build you share, as the GPL requires.

## From Metrolist v14

Metrolist v14 (November 2026) added features to the Android app. The ones that fit this app and
leave AutoMix's transitions unchanged were brought in. The plan, and the reasoning for what was
left out, are in `docs/Metrolist v14 integration plan.md`.

- **Sound.** An equaliser (Window → Equalizer, ⇧⌘E) with presets, editable bands, a preamp and
  AutoEQ import. It sits after AutoMix's mixing, so transitions are unchanged, and is bypassed
  when flat. Loudness normalisation has Quiet, Normal and Loud targets and an optional boost of
  up to +3 dB. A limiter keeps added gain from clipping.
- **Lyrics.** SimpMusic and lrc.red join BetterLyrics, LRCLIB and YouTube Music. You can set the
  order sources are asked in, prefer word-synced lyrics, search every source, and edit timings.
  AutoMix re-plans pairs when a song's lyrics change.
- **Scrobbling.** Last.fm (with your own API key) and ListenBrainz, with offline listens queued.
  Under AutoMix a song counts from the hand-over.
- **Your data.** File → Back Up Library… and Restore… (no credentials are included). There are
  imports from Metrolist, InnerTube, ViMusic and Kreate backups. Playlists import from Spotify,
  Apple Music and Deezer addresses, or a CSV or text file. Private and collaborative Spotify
  playlists go through Exportify, opened inside the app.
- **Content filters.** Hide any artist (from a song's menu), and optionally block artists on the
  community AiSList of AI-generated channels (Settings → Content). Both apply to Autoplay,
  search and Home. AiSList mostly lists AI video channels, so it catches few AI music acts.
- **Output.** An output button in the player bar picks any speaker, including AirPlay ones;
  the Mac still renders the mix.
- **Device Connect.** A paired Android phone running Metrolist can control this Mac (Settings
  → Devices; off by default). The phone is the remote and AutoMix keeps running on the Mac.
  The security review is in `docs/Device Connect protocol review.md`.
- Casting to Google Cast, FCast and DLNA was left out; see `docs/Casting threat model.md`.

## From LastWave

LastWave (github.com/Clash-Projects/LastWave-Native) is an Android YouTube Music client with
audiophile features. Those that make sense on a Mac were brought across, adapted to Core Audio:

- **Bit-perfect output** (Settings → Sound). The output runs at the song's own sample rate
  (48 kHz for YouTube's streams) in its deepest format, so nothing is resampled. The equaliser,
  limiter, loudness normalisation and AutoMix are left out, and the volume slider sets the
  output's own volume. Optionally the output is kept to this app alone (exclusive "hog" mode).
  Everything is undone when the setting is turned off or the app quits. YouTube's audio is still
  lossy Opus; this keeps everything after the decoder from changing it.
- **Signal path.** Settings → Sound shows each stage and says whether the path is bit-perfect.
- **AutoEQ headphone search.** Equaliser → Profile → Find Your Headphones.

Left out: lossless add-ons (Tidal streams via third-party servers with DRM decryption, and a paid
service), DSD playback (no DSD sources) and the "Studio Master Clarity" enhancer (colours the sound).

## Concerts

Sidebar → Concerts lists upcoming concerts from the artists you follow and listen to most, near a
place you type (a city, county or state, or a whole country). The app never reads your Mac's
location; Apple Maps turns the typed place into coordinates. A city shows its own concerts first
(within 40 km), then those a short trip away (150 km), then the rest of the country, each band
soonest first; or nearest first. A concert's page has the date and local time, the venue with
directions, the official ticket page, the event's website when it has one, Add to Calendar, and
the line-up, each artist linking to their page here with a Listen button. Artist pages have a
Concerts section, nearest first.

Listings come from:
- **Ticketmaster's Discovery API** (official listings, ticket links and line-ups for the UK,
  Ireland, Europe, North America, Australia and New Zealand). It needs your own free key from
  developer.ticketmaster.com (no payment details; 5,000 lookups a day), added in Concerts or
  Settings → Integrations and kept in the Keychain. Only the country is sent with a search;
  distances are worked out on the Mac. Results are kept for six hours, as its terms ask.
- **MusicBrainz** (open, no key, every country including Japan, but volunteers enter the
  concerts, so many are missing). Asked about your 40 most listened-to artists, one request a
  second.

Not used: Bandsintown, which powers Spotify's concerts, only grants API access to artists'
teams with written approval; YouTube's own ticket shelf shows one event per artist, placed by
your IP address, so it can't follow a place you choose.

## AutoMix

Off by default. Click the AutoMix button in the player bar, the full-screen player or the mini
player to switch it (⌥⌘M); hold it, or press ⌥⌘E, for the transition editor. It is hidden while an
album plays in order, unless "Mix within albums" is on in Settings.

- `Mix/TrackAnalysis.swift` – on-device analysis of each cached track: tempo (autocorrelation
  checked at the half bar and bar), beat grid, bar phase, key, per-beat harmony (chroma), tone
  colour and band levels, section boundaries (Foote novelty) and a three-band waveform.
- `Mix/BeatModel.swift` – a small neural beat and bar-line tracker, Beat This! (Foscarin,
  Schlüter and Widmer, ISMIR 2024; MIT licence), run on the Mac through Core ML from
  `Models/BeatThis.mlpackage` (10 MB, about 3 s per song, once). It corrects the built-in grid
  where that counted the wrong pulse: a beat two-thirds or three-halves as long as the real one,
  common in fast vocaloid and J-pop songs, which beat-matches on the wrong beats. Everything
  else keeps the built-in grid; letting the model decide more was measured and made mixes worse
  (see `Tools/ml/README.md`). Without the model files the app uses the built-in tracker alone.
- `Mix/MixPlanner.swift` – proposes and ranks transitions for a pair: phrase-aligned beat-matched
  cross-fades anywhere in either song (scored for lost material, harmony, clashing vocals,
  energy, and length in seconds: two full songs on top of each other tire quickly), hand-overs on
  lyrics both songs share, dissolves between passages that sound alike, and a plain fade. "Fade
  only" in Settings keeps to the last one.
  It also looks for the next song having sampled the playing one. Speed and pitch are judged
  separately, because a producer can slow a sample with or without its pitch falling (Good Life
  runs P.Y.T. at two-thirds speed but *higher*): the tempo ratio gives the speed, and the harmony
  at that speed, tried at several pitches, gives the pitch. The playing song then eases to that
  speed and pitch over 12–40 s *before* the overlap (`MixPlan.approach`), as a DJ rides the pitch
  fader before bringing the next record in, and the two then run beat for beat with the next
  song untouched. Nothing bends while both are heard. Key nudges of a semitone or two are made
  the same way. What happened to each transition is recorded in `mix.log` in the data folder.
- `Mix/SampleDatabase.swift` – asks whether one of the two songs is documented as sampling
  the other, or both the same record. WhoSampled has no API and blocks automated requests, so
  the sources are MusicBrainz ("samples material" relationships; open, no account, patchy) and,
  if a token is entered in Settings, Genius's official API (far more complete, and it knows
  interpolations). Lookups run in the background at MusicBrainz's one request a second, once
  per song (`samples.json`); planning never waits, and the pair is planned again if a link
  turns up. A confirmed link names the transition "Known sample", ranks it first and offers
  the tempo move even when the tempos alone gave no clue. It does not lower the evidence
  needed to place the passage: that was tried and invented matches in unrelated pairs.
  Neither source says where the sample sits or how it was changed, so that still comes from
  the audio.
- `Mix/MixSequencer.swift` – orders what Autoplay lines up. The next five Autoplay songs are
  fetched (one at a time) and analysed ahead; they are then chained greedily by fit with the
  song before: tempo within beat-matching range (counting half and double time) weighs 50 %,
  key (same, relative or neighbouring; a diagonal step on the wheel; a semitone or two away
  if key matching is on) 30 %, a shared artist, credited or featured, 20 %, with a small pull
  towards Autoplay's own order. The weights were learned from DJ-made sequences
  (`Tools/ml/train_sequencer.py`). The songs are ordered to follow the song just before them,
  which is a Play Next song when one is waiting. The next song is left alone once its
  transition is near. Songs queued by hand, albums and playlists are never moved. Switch:
  Settings → "Order Autoplay songs for smoother mixes".
- `Mix/MixPlan.swift` – a transition as data: mix points, length in bars, the approach, tempo
  curve, an optional loop, and breakpoint curves for volume, bass, mids, highs, filter and echo
  on each deck. Presets: Fade, Blend (a cross-fade that hands the bass over), Rise, Cut and Echo
  Out (both switch on a bar line, placed on the phrase AutoMix chose), Loop.
- `Mix/MixEngine.swift` – two decks. Before the overlap the playing deck follows the approach
  (by position, so pausing and seeking are safe); the incoming track starts on an exact host
  time; a phase lock keeps the beats together; tempo and pitch ease back afterwards.
- `Mix/StemSeparator.swift` – with "Mix with stems" on, the two stretches of a beat-matched
  overlap are split into vocals, drums, bass and the rest by HT-Demucs (MIT licence) through
  Core ML, as soon as the transition is decided. In the overlap the outgoing vocals step aside
  on the beat before the incoming vocals start, the basslines swap halfway, and in blends the
  drums hand over. If the stems aren't ready in time, the bass swap is made with the EQ.
  Without the model (`Models/HTDemucs.mlpackage`, made with `Tools/ml/convert_demucs.py`)
  transitions play whole songs.
- `UI/Player/MixEditorView.swift` – the editor: drag a waveform to move its mix point, drag
  curve points, pick a preset or another of AutoMix's proposals. Picking a proposal or preset
  only tries it out for this play of the pair (Keep saves it); hand edits are kept per pair of
  songs in `mixes.json`.

Play Next: a song chosen with Play Next (from the Mac, or your phone through Device Connect)
is the next one played. Nothing moves it out of that place: AutoMix orders the Autoplay songs
after it to follow it, shuffle leaves it in front (and switching shuffle off keeps it),
and shared-queue guests' songs go behind it. Pressed while a transition is already audible, it
goes straight after the song fading in. AutoMix mixes into it. If the next song changes so late
that the best transition's mix point (or its tempo approach) has already gone by, the best
transition still ahead is used for that play only, and noted in `mix.log`. If none is left, the
song follows without one. The ranking, and your saved transitions, are not changed.
Check: `--playnexttest`.

Start Radio (in a song's menu) fills the queue with that song's YouTube Music radio at once,
whether or not Autoplay is on, and keeps adding to it. Add to Queue puts songs after the ones
you queued yourself but before what Autoplay or a radio lined up. Check: `--radiotest` (live).

Videos in the queue: with "Prefer audio versions" on, a video is played as its audio release when
one exists. That release is now looked up as soon as the video is next and put in the queue
then, so AutoMix analyses and plans against what will really play. When there is no release
(fan uploads, freestyles), the video's own audio is analysed and mixed like any song. The queue's
transition row says why a pair isn't mixed (looking up the audio version, same album, repeat
one) rather than always "same album". Check: `--videomixtest`.

Tests: `--analyze id…`, `--mixplan A B [--debug] [--samples | --assume-sample]`,
`--geniusparse song.json`, `--snapshot dir --bartest [id] [--gap ms]` (sweeps clicks over the
player bar and maps where each control answers), `--mixtest A B [--preset name] [--pick n]
[--interrupt]`, `--mixplay A B [--off]`, `--mixplay A B C… --autoqueue` (treats all but the first as Autoplay's and shows the order chosen), `--snapshot dir --mixeditor A B` (A/B: search text or
video ids).

## Playback identity and bot checks

Following the Android Metrolist app: audio is requested with anonymous device identities that never carry the
account's cookies and have their own visitor ID; listening history is reported once per listen
through a signed-in WEB_REMIX request made for that purpose. `StreamResolver` de-duplicates and
spaces out player requests, cools identities down after repeated failures, retries a bot check
once with a fresh identity and then backs off (1–10 minutes) instead of hammering the endpoint.
When YouTube bot-checks a whole connection it refuses every anonymous client, even with a
valid attestation token (its own website does the same in a signed-out browser). For that
case there is a signed-in fallback, on by default once signed in and switchable in Settings →
Account: `StreamResolver.resolveSignedIn` asks as YouTube Music's web client with the account's
cookies, `InnerTube/PoToken.swift` mints BotGuard PO tokens in a web view (as the Android app does),
and `InnerTube/PlayerCipher.swift` unscrambles the stream addresses by running yt-dlp's EJS
solver (`EJSSolver.swift`, pinned 0.8.0) in JavaScriptCore.

Checks: `--potoken [id]`, `--webprobe id`, `--ciphertest response.json [token] [out]`,
`--rawsearch query out.json` (search sections as parsed, plus the raw response).

Search: YouTube Music now sends the "All" tab as a top result followed by a flat run of
single-row sections; `Parser.searchSections` groups them by kind, and the song results are
fetched alongside to fill the Songs section out.

## Shared queue

**Shared Queue** in the sidebar (also the people button in the player bar, or Window → Shared Queue, ⇧⌘J) lets other people on your network add songs to what this Mac is
playing, in the way Spotify's Jam does. This Mac stays the player, so AutoMix mixes their songs
in like any other. Guests join from Metrolist on Android, through its device picker and this
Mac's "Shared queue" entry, or from this app on another Mac (the "Join a Shared Queue" side
of the same window). Design, research and security reasoning: `docs/Shared queue design.md`.

- **Off until you start it**, and never restored at launch. Ending it, or quitting, closes every
  guest connection and the listener.
- **Each new guest needs you.** "Let Someone Join" opens joining for 5 minutes, and the same
  six digits must be approved on both devices. Remembered guests can rejoin without a code
  while a shared queue is running. Removing a guest deletes their key and disconnects them.
- **Guests add songs; they don't take over.** Guests can add songs and remove the ones they
  added. "Let guests control playback" (off by default) also gives them play, pause, next,
  previous, volume and repeat. Seeking, clearing, reordering and taking playback to their phone
  are always refused.
- **Fair turns.** Contributors' queued songs alternate, and all of them come before Autoplay's.
  Limits per guest: 10 songs per request, 20 waiting, 30 per 10 minutes. Hidden artists stay
  hidden.
- **A separate identity.** Guests pair with a second, always-anonymous device identity, with its
  own Keychain items. Your own phone's Device Connect pairing (Settings → Devices) is
  unaffected. Metrolist only pairs devices on the same YouTube account, so by default Android
  guests must be signed out of YouTube Music in Metrolist. "Let guests join while signed in to
  YouTube Music" (off by default) answers each guest with their own account's label instead.
  No account details are exchanged, but their phone will then say this Mac "uses the same
  account".

Tests: `--sqtest` (every guest rule, and a guest Mac over the encrypted protocol in memory),
`--sqnettest` (the same over real sockets, with `lsof` checking listening ports), `--sqmixtest A B`
(AutoMix into a song a guest added), `--sqjoin address port`, `--snapshot dir --sqscreens`.

## Checks

Diagnostic switches on the binary (see also the AutoMix and playback sections):

    .build/debug/Metrolist --probe "query"     # live test of browse/search/stream/lyrics parsing
    .build/debug/Metrolist --playtest          # muted end-to-end playback test
    METROLIST_HOME=/tmp/m .build/debug/Metrolist --snapshot out/   # offscreen screenshots
    METROLIST_HOME=/tmp/m .build/debug/Metrolist --bitperfecttest [--live]   # bit-perfect output
    METROLIST_HOME=/tmp/m .build/debug/Metrolist --concerttest [--live]      # concerts (live Ticketmaster: METROLIST_TICKETMASTER_KEY)
    .build/debug/Metrolist --matchwhy <videoId>  # how a music video is matched to its song

`METROLIST_HOME` redirects all of the app's storage, so tests never touch your own data.

AutoMix measurement (run a release build; `Tools/run_audits.sh` runs them all):

    .build/release/Metrolist --mixaudit Tools/groundtruth/groups.csv   # plans by style group
    .build/release/Metrolist --mixaudit --approved                      # the approved reference pairs
    .build/release/Metrolist --mixaudit --pairs-file pairs.tsv          # any pairs (optionally with your own transition points)
    .build/release/Metrolist --analysisaudit Tools/groundtruth/silver   # beat grids against reference labels
    .build/release/Metrolist --beatmodeltest refDir                     # Core ML model against Python
    .build/release/Metrolist --dumppcm dir groups.csv                   # the app's own decoded audio, for Tools/ml

`METROLIST_BEATMODEL=off` turns the beat model off; `METROLIST_MODELS=dir` points at another model.

## How it works

- `InnerTube/` – YouTube Music API (WEB_REMIX client) plus `StreamResolver`, which presents
  VISIONOS / ANDROID_VR client identities to get direct Opus (itag 251) audio URLs.
- `Playback/` – progressive downloader (IPv6/IPv4 aware), WebM demuxer, Opus decoding through
  AudioToolbox, AVAudioEngine output, queue/radio logic, system Now Playing integration.
- `Lyrics/` – BetterLyrics (word-timed TTML), LRCLIB (line-timed), YouTube Music (plain).
- `Library/` – liked songs, playlists, history as JSON in the data folder.
- `Mix/` – AutoMix (above).
- `UI/` – SwiftUI views. `@ViewState` is an alias for `SwiftUI.State` (see `ViewState.swift`).

A technical paper on AutoMix and the queue ordering is in `docs/`.
