# macOS YouTube Music with AutoMix

A native macOS client for YouTube Music, written in SwiftUI with Liquid Glass, with
**AutoMix**: optional DJ-style transitions between songs. It is a complete app on its own and
needs no other software. It follows the design of the Android client
[Metrolist](https://github.com/MetrolistGroup/Metrolist) (GPL-3.0), and is licensed GPL-3.0
in the same way.

Features: search and browse, your library and playlists, synced lyrics, queue and Autoplay,
downloads, a mini player and menu-bar player, system Now Playing, and AutoMix with a
transition editor. Data is kept in `~/Library/Application Support/Metrolist`.

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
  the cookies are used only for requests to YouTube. Never commit either, and never share your data folder
  (`~/Library/Application Support/Metrolist`), which also holds your library,
  listening history and cached audio.
- **Online lookups.** If "Look up known samples online" is on, the title and artist of the
  playing and next songs are sent to musicbrainz.org (and to Genius if you add a token).
  Nothing else about you is sent. Switch it off in Settings → AutoMix.
- **No warranty.** The software is provided "as is", without warranty of any kind, as the
  GNU General Public License v3.0 (see `LICENSE`) sets out. Transitions are produced by
  automatic analysis and may not sound as intended.
- **Third-party code and credit.** The design, and the way it talks to YouTube Music, follow
  the Metrolist Android app (GPL-3.0), whose authors deserve the credit for it.
  `InnerTube/EJSSolver.swift` bundles yt-dlp's EJS solver (Unlicense, with meriyah under ISC
  and astring under MIT). Their licences and credits apply to those parts.
- **Releases.** Builds are ad-hoc signed and not notarised, so macOS
  will ask you to allow the app under System Settings → Privacy & Security. Distribute the
  source with any build you share, as the GPL requires.

## AutoMix

Off by default. Click the AutoMix button in the player bar, the full-screen player or the mini
player to switch it (⌥⌘M); hold it, or press ⌥⌘E, for the transition editor. It is hidden while an
album plays in order, unless "Mix within albums" is on in Settings.

- `Mix/TrackAnalysis.swift` – on-device analysis of each cached track: tempo (autocorrelation
  checked at the half bar and bar), beat grid, bar phase, key, per-beat harmony (chroma), tone
  colour and band levels, section boundaries (Foote novelty) and a three-band waveform.
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
  towards Autoplay's own order. The next song is left alone once its
  transition is near. Songs queued by hand, albums and playlists are never moved. Switch:
  Settings → "Order Autoplay songs for smoother mixes".
- `Mix/MixPlan.swift` – a transition as data: mix points, length in bars, the approach, tempo
  curve, an optional loop, and breakpoint curves for volume, bass, mids, highs, filter and echo
  on each deck. Presets: Fade, Blend (a cross-fade that hands the bass over), Rise, Cut and Echo
  Out (both switch on a bar line, placed on the phrase AutoMix chose), Loop.
- `Mix/MixEngine.swift` – two decks. Before the overlap the playing deck follows the approach
  (by position, so pausing and seeking are safe); the incoming track starts on an exact host
  time; a phase lock keeps the beats together; tempo and pitch ease back afterwards.
- `UI/Player/MixEditorView.swift` – the editor: drag a waveform to move its mix point, drag
  curve points, pick a preset or another of AutoMix's proposals. Picking a proposal or preset
  only tries it out for this play of the pair (Keep saves it); hand edits are kept per pair of
  songs in `mixes.json`.

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

## Checks

Diagnostic switches on the binary (see also the AutoMix and playback sections):

    .build/debug/Metrolist --probe "query"     # live test of browse/search/stream/lyrics parsing
    .build/debug/Metrolist --playtest          # muted end-to-end playback test
    METROLIST_HOME=/tmp/m .build/debug/Metrolist --snapshot out/   # offscreen screenshots

`METROLIST_HOME` redirects all of the app's storage, so tests never touch your own data.

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
