# Merging the AutoMix branch with the UI and system branch

Written 2026-11-21 (evening) for the agent that merges two branches of work. Both are
**uncommitted** in their own git worktrees; nothing from either has been committed or pushed.
This guide covers what this branch (`claude/automix-all-styles`) contains, every file the two
branches both change and how to combine each one, the changes that interact without a textual
conflict, and how to check the result.

Read `docs/PROJECT_GUIDE.md` (this worktree's copy) for the owner's rules. The ones that matter
most here:

- **Never commit or push unless the owner asks in that session.** Merging two worktrees of
  uncommitted work is normally done with commits. Ask the owner before you make any, and
  propose the plan in "How to merge" below.
- **Never test against the owner's data.** Every test run sets `METROLIST_HOME` to a folder in
  `/tmp/claude/`.
- `swift build` and running the binary need the Bash sandbox off.
- **The approved AutoMix pairs must plan exactly as before** (`--mixaudit --approved`); say so
  if one changes.
- Agents can't hear the result. Report measurements, and leave listening to the owner.

## The two branches

| | This branch | The other branch |
|---|---|---|
| Branch | `claude/automix-all-styles` | `claude/session-2026-11-21` |
| Worktree | `.claude/worktrees/automix-all-styles` | `.claude/worktrees/session-2026-11-21` |
| Base | `14aa15f` (= `dev`; the main checkout has no uncommitted source changes) | `14aa15f` |
| Holds | AutoMix for every style (beat model, analysis v7, planner, sample gate, tempo ramps, learned Autoplay order, stems), the measurement tools, and today's fixes to radio, Autoplay, queue order and stems | Bit-perfect output and exclusive output, the grey-band fix, video matching, the storage split, the video bar, artist links, ⓘ help (`InfoTip`), Concerts (Ticketmaster and MusicBrainz) |
| Its notes | `docs/automix-progress.md`, `docs/AUTOMIX_REFERENCE_MIXES.md`, `Tools/ml/README.md`, this guide | `docs/OVERNIGHT_PROGRESS.md` in its worktree |

The other branch may still be changing when you read this. Re-run the comparison below
(`diff -u` of each shared file against `git show 14aa15f:<file>`) rather than trusting the line
numbers here.

### The other branch's own guide

The other branch has its own guide, `docs/MERGE_GUIDE_session-2026-11-21.md` in its worktree.
Read it for that branch's side: its features, its `AppSettings.swift` conflict and its checks.
It was last changed at 16:43 on 2026-11-21, before this branch's evening fixes. Where the two
guides disagree, this one is newer:

- It counts six shared files and expects `PlayerController.swift` to merge cleanly, with "two
  small hunks" from AutoMix. The evening fixes rewrote the radio, Autoplay and sequencing code
  in that file, so expect conflicts there (see below). `README.md` is changed on both sides
  too.
- Its trial `diff3 -m` was run before those fixes. Run it again.
- It says to keep the "owner placement 19 of 21" result. Disregard it: that measure used the
  custom transitions the owner saved by accident (see "Today's fixes", item 5).
- It expects `--featuretest` 32/32. This branch adds 6 stem-timing checks, so expect 38, plus
  any checks the other branch added.

Both branches' `docs/*.md` notes are git-ignored apart from the ones with `.gitignore`
exceptions: that guide and `docs/OVERNIGHT_PROGRESS.md` are not. Copy them into the merged
checkout by hand, as you do the stem model.

## How to merge (proposal for the owner)

1. With the owner's permission, commit each worktree's work on its own branch (one commit each
   is enough). The stem model must stay out of git: `Models/HTDemucs*.mlpackage/` is ignored
   and is about 200 MB. `Models/BeatThis.mlpackage` (10 MB) and its `.json`, `.f32` and licence
   files are meant to be committed. `Tools/ml/data/` and the virtual environments are ignored.
2. Merge `claude/automix-all-styles` into `claude/session-2026-11-21`, or both into `dev`, and
   resolve the files below.
3. Copy `Models/HTDemucs.mlpackage` (git-ignored) from this worktree into the merged checkout's
   `Models/`. Without it the app builds and runs, but stems are off and the "Mix with stems"
   toggle is disabled.
4. Run every check in "After the merge".

If the owner doesn't want commits yet, apply this branch onto the other worktree as a patch:
`git diff 14aa15f` for the tracked files, plus a copy of the untracked files listed below.

## Files both branches change

Seven files. For each: what the other branch did, what this branch did, and how to combine.

### `Sources/Metrolist/Playback/PlayerController.swift` (the biggest one)

**The other branch:**
- `import CoreAudio`.
- Bit-perfect volume routing after `var volume`: the `deviceVolumeTarget` family,
  `updateVolumeRouting()`, `adoptVolume`, `processingStages`, `appGain`, `reapplyOutputMode()`.
- In `init`, the `OutputDevices.shared.onChange` closure calls `updateVolumeRouting()`, and
  `routedBitPerfect` is set.
- `settings.autoMix` became `settings.mixes` (AutoMix on and not paused by bit-perfect output)
  in `autoMixActive`, `mixPair`, `sequencesAutoQueue` and `prepareMix`.
- `settings.normalizeVolume` became `settings.normalizes` in `loadCurrent` and in `tick`'s
  `engine.enqueueNext`.
- At the top of `tick`, the bit-perfect switch re-applies the output mode.

**This branch:**
- `init`: `if settings.autoMix, settings.mixStems { StemSeparator.warmUp() }`. When merging,
  make it `settings.mixes`, so the 200 MB model isn't loaded while bit-perfect output pauses
  AutoMix.
- `candidateKey` adds `|\(settings.mixStems)`.
- New state: `radioSeed` (observed, `private(set)`), `queueGeneration` and
  `extendingGeneration`. These replace `isExtending`, which no longer exists.
- `play(_:…)` resets `radioSeed`, bumps `queueGeneration` and clears `extendBlockedUntil`.
- `playRadio(for:)` sets `radioSeed` and fills the queue at once.
- `enqueue` inserts before the trailing block of Autoplay songs instead of appending.
- `clearUpcoming` ends the radio and bumps the generation.
- `sequenceAutoQueue` is rewritten: it orders Autoplay's songs to follow the song before them
  (a Play Next song when one waits), instead of waiting. Keep this branch's function body, with
  the other branch's `settings.mixes` in the `sequencesAutoQueue` line just above it. Expect a
  conflict here, because the two edits are adjacent.
- `extendQueueIfNeeded` is rewritten: generation tokens, the radio, and no repeats of a video
  already swapped for its audio release.
- `tick` calls `separateStemsAhead()` right after `prepareMix()`. Keep the other branch's
  bit-perfect block at the top of `tick`, and its `settings.normalizes` in `enqueueNext`.
- `previewMix` starts 10 s ahead (not 5) while the transition's stems aren't separated yet.
- New helpers above `albumId(of:source:)`: `stemsAheadFor`, `stemsSeparated(for:)` and
  `separateStemsAhead()`.

### `Sources/Metrolist/App/AppSettings.swift`

- **The other branch:** `bitPerfect`, `exclusiveOutput`, `mixes`, `normalizes` and
  `applyOutput()`.
- **This branch:**
  - `mixStems`, with its registered default `true`.
  - `mixOptions` passes `stems: mixStems && StemSeparator.isInstalled`. Keep this one; the
    other branch's `mixOptions` is the old one without stems.
  - `defaults` is now `AppPaths.settings` (see "Settings kept apart in tests"). The other
    branch's new settings use the same `defaults` property, so they are covered without
    changes.

### `Sources/Metrolist/Playback/AudioEngine.swift`

The two branches change different regions, so this should merge cleanly. Check the merged file
for both sets of changes.

- **The other branch:** bit-perfect `prepare` calls in `configure(format:)` and
  `setOutputDevice`, `currentOutputDevice`, `applyOutputDevice` using `playbackDevice(chosen:)`,
  and a re-apply in `handleConfigurationChange`.
- **This branch:**
  - `OpusReader`'s rounded seek trim.
  - `AudioEngine.playbackSamples` (test helper) and `StemMix`.
  - `setStemMix`, `currentFile` and `applyStems`, called from `pump()` before the reader gain.
  - New `readPosition`, the song time a deck has read up to. It uses `sampleRate` under `lock`,
    which the other branch's `configure` still sets.

### `Sources/Metrolist/Backup/LibraryBackup.swift`

- **The other branch:** adds `"bitPerfect", "exclusiveOutput"` to `settingsKeys`.
- **This branch:**
  - Adds `"mixStems"` to `settingsKeys`.
  - `create` and `restore` default to `defaults: AppPaths.settings`, not `.standard`.
- Keep all three keys, and this branch's defaults.

### `Sources/Metrolist/UI/SettingsView.swift`

- **The other branch:** rewrote the Sound section (bit-perfect, ⓘ explanations through
  `InfoTip`/`.info(Explain.…)`) and added an orange "Paused while bit-perfect output is on"
  note under the AutoMix toggle.
- **This branch:** one new toggle, "Mix with stems (vocals, bass, drums)", right after "Match
  keys by shifting pitch when it helps", with a `.help(...)` text.
- Keep both. If the other branch has moved the AutoMix rows to `.info(Explain.…)` by the time
  you merge, give the stems toggle an `Explain` entry with the same text, for consistency.

### `Sources/Metrolist/main.swift`

Both branches add command-line flags. Keep all of them.

- **This branch adds:**
  - `--mixaudit`, `--analysisaudit`, `--beatmodeltest`, `--dumppcm` and `--stemtest` (earlier
    sessions).
  - `--radiotest` and `--vocalresidue` (today).
  - `--mixtest … --ahead`, an option inside `Probe.mixTest`.
- **The other branch adds:** `--concerttest`, `--bitperfecttest` and others.

### `README.md`

Combine the two sets of additions. This branch adds:
- the beat model and the AutoMix measurement commands;
- a `StemSeparator` bullet;
- the learned Autoplay order and its new Play Next behaviour;
- a "Start Radio" paragraph.

### Also: `docs/PROJECT_GUIDE.md`

The guide is untracked in both worktrees, and the two copies differ. The common ancestor is
the main checkout's copy, dated 2026-11-20. Merge by hand:
- Take the other branch's sections for its features: bit-perfect, Concerts, ⓘ help, video and
  storage.
- Take this branch's AutoMix, stems, test-command and Open-items sections.
- Write one Status section covering both.

## Changes that interact without a textual conflict

1. **Bit-perfect output pauses AutoMix** (`settings.mixes`).
   - `separateStemsAhead()` only runs when `nextMixPlan` exists, which needs `mixPair`, which on
     the merged code checks `settings.mixes`. So no stems are separated with bit-perfect on.
   - Also make the `init` warm-up use `settings.mixes` (above).
   - `reapplyOutputMode()` reloads the deck, which cancels any cued mix and clears its stems.
     That is fine.
2. **Settings kept apart in tests.**
   - On 2026-11-21 the owner's real Autoplay setting was found switched off although they had
     turned it on. Several test suites set `settings.autoplay = false`: `--playnexttest`,
     `--videomixtest`, `--sqtest`, `--videosynctest`, `--snapshot` and the probe. When a test
     runs from the packaged app (`dist/Metrolist.app/Contents/MacOS/Metrolist`), it writes into
     the app's real preference domain, `app.metrolist.mac.automix`.
   - This is the likely cause, not a proven one. The other branch's agent also ran the packaged
     app, and its Concerts keys are in the real domain.
   - Now `AppPaths.settings` is a separate domain (`app.metrolist.mac.automix.tests`) whenever
     `METROLIST_HOME` is set. `AppSettings`, `LibraryBackup` and `StreamResolver`'s
     `accountPlayback` read use it.
   - The other branch does the same for the Keychain (`Keychain.swift`, a test keychain under
     `METROLIST_HOME`).
   - **Still writing to `UserDefaults.standard` directly:**
     - this branch's base code: `LyricsService`, `DCManager`, `SharedQueue`,
       `SharedQueueClient`, `AppModel` (`sessionMigrated`), `InnerTube` (visitor data),
       `Scrobbler`, `BlockedContent` and `OutputDevices` (`outputDeviceUID`);
     - the other branch: `ConcertStore` (`concertLocation`, `concertOrder`,
       `concertsMusicBrainz`).

     Moving the user-facing ones (`OutputDevices`, `ConcertStore`, `BlockedContent`,
     `Scrobbler`, `LyricsService`) to `AppPaths.settings` is recommended, especially
     `OutputDevices`, because the bit-perfect and output tests choose devices. This was left
     undone here to keep merge conflicts small.
3. **Queue UI.** `NowPlayingViews.swift` (not touched by the other branch) shows "Radio:
   similar songs keep coming" while `player.radioSeed != nil`, otherwise the Autoplay line as
   before. If the other branch's AutoMix popover (`AutoMixViews.swift`, which has an Autoplay
   toggle) or player bar says anything about radio or Autoplay, it should treat a running radio
   as independent of the Autoplay setting.
4. **Audio versions.** `extendQueueIfNeeded` skips radio songs whose video or audio counterpart
   is already queued, using the player's in-memory `counterparts`. The other branch changed
   `AudioVersionCache.swift` and `YTMusic.swift` (video matching). Check that `counterparts`
   still gets filled when a video is swapped (`audioVersion(of:)`), so no duplicates come back.
5. **`processingStages`** (the other branch, for the signal-path display) lists "AutoMix". With
   stems on you may want "AutoMix (stems)". This is optional.

## Everything this branch changes

Tracked files changed (against `14aa15f`): `.gitignore`, `README.md`, `Scripts/make-dist.sh`
(bundles `Models/`), `App/AppPaths.swift`, `App/AppSettings.swift`, `App/FeatureTests.swift`,
`App/Probe.swift`, `Backup/LibraryBackup.swift`, `InnerTube/StreamResolver.swift`,
`Mix/MixEngine.swift`, `Mix/MixPlan.swift`, `Mix/MixPlanner.swift`, `Mix/MixSequencer.swift`,
`Mix/TrackAnalysis.swift`, `Playback/AudioEngine.swift`, `Playback/PlayerController.swift`,
`UI/Player/NowPlayingViews.swift`, `UI/SettingsView.swift`, `main.swift`.

New files: `App/AnalysisAudit.swift`, `App/MixAudit.swift`, `App/RadioTest.swift`,
`App/StemTest.swift`, `Mix/AudioDecode.swift`, `Mix/BeatModel.swift`,
`Mix/StemSeparator.swift`, `Models/` (the stem model is git-ignored), `Tools/` (groundtruth,
ml tools; data and virtual environments are git-ignored), `docs/AUTOMIX_REFERENCE_MIXES.md`,
`docs/PROJECT_GUIDE.md`, and this guide. The new docs have `.gitignore` exceptions.

### Today's fixes (2026-11-21 evening), from the owner's listening test

The owner tested a 16-song sequence (Virtual Insanity → … → Day 'N' Nite) and reported four
things.

1. **Start Radio queued only the song itself.**
   - Cause: `playRadio(for:)` was just `play([song])`. The radio came from Autoplay's
     `extendQueueIfNeeded`, which is guarded by `settings.autoplay`, and the owner's stored
     setting was off.
   - Two more faults: a request still running for the previous queue blocked the new one and
     then added the old seed's songs to the new queue, and a seed video swapped for its audio
     release came back as a duplicate (the log had "Hey Jude (Live) moved up to follow Hey Jude
     (Live)").
   - Fixed: a radio now fills the queue at once and keeps going regardless of Autoplay,
     requests carry a queue generation, and counterparts are de-duplicated.
2. **Autoplay didn't add songs although it was on.**
   - The owner's stored `autoplay` was `0`. It was set back to `1`, and test runs no longer
     write there (above).
3. **Autoplay order and Play Next.**
   - Play Next still wins: those songs stay at the front. Previously AutoMix didn't order
     Autoplay's songs at all while a Play Next song waited. Now it orders them to follow that
     song (the log line reads "autoplay order: X moved up to follow \<Play Next song\>").
   - Add to Queue now goes after the listener's own songs but before Autoplay's or a radio's.
     Before, it went after everything Autoplay had already added.
4. **Vocal bleed in stem transitions.** Three timing causes, measured in the owner's
   `mix.log`.
   - **Stems arrived late.** The owner previewed most transitions with the preview button,
     which jumps to 5 s before the mix point, and separating takes 3.3 to 5.3 s. One
     transition logged "too late … plays whole songs". In that case the bass swap was missing
     too, because a stem plan switches the EQ bass swap off.
   - **Decks read 3 s ahead.** Stems change only audio read after they are set. When they
     arrived less than 3 s before the overlap, the first part played with the outgoing vocals,
     then dropped in a jump.
   - **Both vocals together for a quarter of the overlap.** The outgoing vocals faded over the
     first quarter even when the incoming vocals started at once.
   - Fixes:
     - Stems are separated as soon as the transition is known, and cached
       (`StemSeparator.separate`, four stretches; `MixEngine.separateStemsAhead`).
     - Stems that arrive late start from where the deck has read, faded in over a beat
       (`MixEngine.stemGains`).
     - A side without stems makes its bass swap on the EQ (`MixEngine.withoutStems`).
     - The outgoing vocals leave over half a beat, on the beat before the incoming vocals start,
       once both sing for more than 1 s (`MixEngine.vocalHandOver`; it was Mosaikbox's 2 s over
       the first quarter).
     - A mix point moved later re-separates the new stretch.
     - The preview starts 10 s ahead while stems aren't ready.
   - Separation depth itself was measured with `--vocalresidue` on six of the owner's songs.
     Separating the processed audio again finds −37 to −57 dB of vocal left, and a second
     subtraction pass gains 0 to 10 dB at those levels, so it wasn't added. The model can't
     see vocals it has itself put in "other". If the owner still hears bleed with the timing
     fixed, the next step is a stronger vocal model (HT-Demucs fine-tuned, `htdemucs_ft`
     vocals).
5. **Custom transitions made by accident.** The owner said the transitions saved as their own
   during the training process were misclicks: reset and ignore them.
   - The owner's `mixes.json` (22 transitions) is now `{}`. The backup is
     `mixes.backup-2026-11-21-misclicks.json` beside it.
   - `Tools/ml/data/owner-mixes.tsv` is renamed `owner-mixes.IGNORE-misclicks.tsv`.
   - `Tools/run_audits.sh` no longer measures it, and the docs no longer call it gold.
   - No learned part (sample gate, sequencer) was trained on it. Only the "owner placement"
     measure and two comments used it: the "Tempo match" rationale, and the rule that ramps
     yield to a tempo match. The planner's behaviour was left unchanged (the approved plans
     are identical), but the reason for keeping "Tempo match" is gone, so that decision is
     back with the owner.

## After the merge: checks

Build `swift build` and `swift build -c release` with the sandbox off. If a change seems
missing, touch the file and build again: a build sometimes reports success without recompiling.
For a binary built outside the repository, set `METROLIST_MODELS=<repo>/Models`.

| Check | Command (each with `METROLIST_HOME=<test home>`) | Expected (this branch, 2026-11-21) |
|---|---|---|
| Offline features | `--featuretest` in a fresh folder | 38 PASS, including 6 stem-timing checks |
| Radio and queue (live, release, ~5 min) | `--radiotest` in a fresh folder (`--no-order` skips the slow last part) | 12 PASS |
| Play Next, video mixing | `--playnexttest`, `--videomixtest` in a clone of `/tmp/claude/mixhome` (`cp -Rc`) | Only the 4 known label failures ("Known sample" where the test expects "Sample match"). The build before today fails the same 4 on the same home |
| Approved pairs | `--mixaudit --approved [--stems] --out f.tsv` in a clone of `/tmp/claude/styleshome` | Byte-identical to `/tmp/claude/approved-check/after-plain.tsv` and `after---stems.tsv` (10 pairs) |
| Stems in time | `--mixtest 4tlUwgtgdZA -3PKrJgxHK8 --stems --lead 5 --ahead` in a clone of `/tmp/claude/refhome-a` | `mix.log`: "stems ready in 0.0 s (separated ahead)", no "not in place" line |
| Stems late | the same with `--lead 3` and no `--ahead` | "stems not in place … the bass swap is made with the EQ", then "… read 5.1 s into the overlap … (late: …)" |
| Stem separator | `--stemtest FILE START DIR` | PASS; stems line up with playback at lag 0 |
| The other branch | its own tests (`--bitperfecttest`, `--concerttest`, `--soundtest`, `--outputtest`, `METROLIST_WINDOWTEST=1`, see its notes) | as in its notes |
| Together | bit-perfect on, AutoMix on: play two songs | gapless, no "cued" or "stems" lines in `mix.log`; Settings shows AutoMix paused |
| Settings untouched | before and after the test runs: `defaults read app.metrolist.mac.automix autoplay` | unchanged (`1`) |

Then rebuild `dist/Metrolist.app` with `Scripts/make-dist.sh`. It bundles both models (about
216 MB) and keeps the previous app as `dist/.Metrolist-previous-<time>.app`.

## Changes made to the owner's data this session

All in `~/Library/Application Support/Metrolist/` and the app's preferences, at the owner's
request ("reset and ignore these", "I had it turned on"):

- `mixes.json` → `{}`, with a backup in `mixes.backup-2026-11-21-misclicks.json` (22
  transitions, 25.8 kB).
- `defaults write app.metrolist.mac.automix autoplay -bool true` (it was `0`).

## Still waiting on the owner

- Listening to stem transitions again with these fixes, especially the pairs they heard bleed
  on, and with the preview button.
- Whether "Tempo match" stays, now that the transitions it was based on turned out to be
  accidental.
- Earlier items from `docs/PROJECT_GUIDE.md`: "Mix with stems" on and off, the 12–20 % ramps.
