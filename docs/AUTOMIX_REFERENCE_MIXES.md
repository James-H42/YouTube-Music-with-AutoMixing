# AutoMix reference mixes: what real mixes do, and how to test against them

Written on 2026-11-21 for agents working on AutoMix. It collects public evidence of how people
and streaming services join songs, lists songs and pairs with a known reason to fit together,
and gives the steps for using them in YouTube Music through the app's test commands. The
owner judges AutoMix by ear against Spotify's Mix and Apple Music's AutoMix; this guide is the
measurable side of that. Agents cannot hear the result, so every claim made from these sets is
a measurement, and the owner's listening decides what sounds right.

Read `docs/PROJECT_GUIDE.md` first for the owner's rules: no commits, test homes only, and
approved pairs that must not change without saying so.

## Where everything is

| What | File | Committed? |
|---|---|---|
| Curated pairs (samples, DJ repeats, remix moves, the Soul Mix Show), query form | `Tools/groundtruth/reference-mixes.tsv` | yes |
| The 2026-11-21 set of famous sample pairs and blends (built the night before) | `Tools/groundtruth/common-mixes.tsv` | yes |
| Spotify "Mixed By" playlists, in their order (21 playlists, 564 tracks) | `Tools/groundtruth/spotify-mixed-by.tsv` | yes |
| DJ-mixed albums from Discogs: Ministry of Sound and Kanye West & A-Trak (9 albums) | `Tools/groundtruth/mix-albums.tsv` | yes |
| Collector and analyser (Spotify embed, Discogs, MixesDB, VocaDB, pairs, resolve) | `Tools/ml/reference_mixes.py` | yes |
| Raw downloads: MixesDB set lists, Discogs JSON, VocaDB check, generated pairs, query lists, `--analyze` logs | `Tools/ml/data/reference/` | no (git-ignored) |

Raw set lists stay out of the repository on purpose. They are community edits from MixesDB and
can be fetched again with the tool. Discogs data is CC0, and the Spotify file holds titles
only.

## What the evidence says about good transitions

### Streaming services

**Spotify Mix** (Premium only, since August 2025; on desktop since May 2026). Spotify's
support page and newsroom describe the following:
- **Presets:** "Auto", "Fade" and "Rise". Presets "combine volume, effects, and EQ settings".
  Spotify does not say how Auto chooses a transition.
- **Controls:** volume curves for each track; EQ for highs, mids and lows; and low-pass and
  high-pass filters that "gradually fade in or out specific frequencies". Spotify suggests
  using "the waveform and beat data to find the best spot in each track".
- **Information shown:** the BPM and key of every track.
- **Advice:** "choose songs with similar tempos and Camelot keys". "Dance genres like house and
  techno tend to blend more smoothly". Order songs to build up or wind down energy.
- **Free accounts:** a mixed playlist plays as an ordinary playlist. Over Spotify Connect,
  transitions are also dropped.

Spotify's public pages name no other presets. Labels such as "Sound match", "Blend", "Lyric
match" and "Known sample" are this app's own (`MixPlanner.describe`).

**Spotify's "Mixed By" hub** (`open.spotify.com/genre/0JQ5DAqbMKFPSyykKYdCTj`) holds playlists
that artists mixed themselves with the feature. Their order is public through the embed page;
the transitions themselves are not. The 21 found:
- From the September 2025 post: Martin Garrix, PinkPantheress, SOFI TUKKER, Chris Lake, Steve
  Aoki, WizTheMc, Romy, Don Diablo, Pete Tong, Fcukers, DJ Seinfeld and Swedish House Mafia.
- From the December 2025 post: Anyma & Solomun, Rawayana, Amaarae, Cash Cobain, Jessie Ware,
  SG Lewis, Rochelle Jordan, Jim-E Stack and Tiësto. Tiësto's embed shows only the first 100
  tracks.
- Later additions named in the press (John Summit, Becky G, Normani, GroovyRoom and others)
  had no findable links.

The styles cover tech house, EDM, trance, deep house, UK garage, hip-hop, R&B, Latin, disco
and indie. Jim-E Stack's indie list (Sinéad O'Connor into Talking Heads, Kate Bush, Radiohead)
is the useful counter-example: a real artist sequenced it, but most of it can't be
beat-matched. A good AutoMix should fade or cut there, not stretch.

**Apple Music AutoMix** (iOS 26). Apple's newsroom says it "uses AI to analyse audio features"
and builds transitions "with time stretching and beat matching". Apple's support page says it
picks a transition to suit the music, and may only "remove silence at the beginning and end of
a track, or perform a simple crossfade". It works on playlists and stations, not albums.
Reviews report:
- It "has the habit of cutting songs short" (TechRadar, via Yahoo).
- "The adaptation to tempo or melody is not always successful" (heise).
- MacRumors says the transition is placed "based on an analysis of the key and tempo".

### Real DJs: measured on 1,557 mixes

T. Kim, M. Choi, E. Sacks, Y.-H. Yang and J. Nam, "A Computational Analysis of Real-World DJ
Mixes using Mix-To-Track Subsequence Alignment" (ISMIR 2020, pp. 764–770;
doi:10.5281/zenodo.4245544). The data is 1,557 mixes from 1001Tracklists: 13,728
tracks and 20,765 transitions, mostly house and trance. The tracks were aligned to the mixes
with beat-synchronous chroma and MFCC subsequence DTW. Findings:
- **Tempo changes are small.** "86.1% of the tempo are adjusted less than 5%, 94.5% are less
  than 10%, and 98.6% are less than 20%." DJs pick songs that are already close in tempo,
  rather than stretching unrelated songs together.
- **Pitch changes are rare.** "Only 2.5% among the total 24,202 tracks are transposed and,
  among those transposed tracks, 94.3% of them are only one semitone." Master tempo
  (time-stretch without a pitch change) is the norm.
- **Cue points follow phrases.** The distribution of cue-out points "has more distinctive peaks
  around every 32 beat", which is a phrase in dance music. Cue-in points sit mostly near the
  start of the incoming track.
- **DJs agree with each other.** For the same track, "23.6% of the total cue point pairs have
  zero deviation. 40.4% of them were within one measure (4 beats), 73.6% were within 8 measures
  and 86.2% were within 16 measures."

What this means for AutoMix:
- A beat-matched blend that needs more than about 10% stretch is something DJs almost never
  do. A large speed change is justified when the songs share material: a sample, a remix, or
  the same record at another speed. The approved P.Y.T. → Good Life plan (67 %) and HBFS →
  Stronger plan (84 %) are exactly that case.
- Bars are not enough. Exits and entries should fall on 8-bar (32-beat) phrase lines.
- Pitch shifting should stay at one semitone or less, and be used rarely.

The dataset itself (`pip install djmix`; `dj.mixes[i].download()`) links mixes and tracks to
YouTube ids. Its analysis code is at `github.com/mir-aidj/djmix-analysis`. A follow-up paper
(Kim, Yang and Nam, DAFx 2022) estimates DJ fader and EQ curves.

### Harmonic mixing, mashups and DJ habits

- **Camelot wheel** (Mixed In Key):
  - Safe moves are the same key, one step round the wheel (±1), or the relative major or minor
    (A ↔ B at the same number).
  - "Energy boost" moves are +2, or the advanced −5 (the same as +7). Use them sparingly, or
    they feel forced.
  - `MixPlanner.harmonicallyCompatible` already treats same, ±1 and relative as compatible.
- **Mashups** (Mixed In Key, lalal.ai, Sweetwater guides):
  - The songs should share a key or a related key.
  - "Tempo matters, but phrasing matters more".
  - For very different tempos, run one song at half speed, for example 90 BPM hip-hop over
    175 BPM drum and bass.
  - Listeners preferred the vocal in its original key.
- **Hip-hop DJs play the sample, then the song that samples it.** DJ Jazzy Jeff's 23 sets on
  MixesDB repeat these pairs:

  | Source → song that samples it | Sets |
  |---|---|
  | Gap Mangione "Diana in the Autumn Wind" → Slum Village "Fall in Love" | 6 |
  | The J.B.'s "The Grunt" → Public Enemy "Night of the Living Baseheads" | 5 |
  | Ronnie Foster "Mystic Brew" → A Tribe Called Quest "Electric Relaxation" | 5 |
  | Ahmad Jamal "Ghetto Child" → Common "They Say" | 5 |
  | Honey Cone "Innocent 'Til Proven Guilty" → Common "Testify" | 4 |
  | Screamin' Jay Hawkins → The Notorious B.I.G. "Kick in the Door" | 4 |
  | Grace Jones "My Jamaican Guy" → LL Cool J "Doin' It" | 4 |

  This is the owner's own test method (P.Y.T. → Good Life), used by a working DJ.
- **Electronic DJs play an original into its remix** (or the reverse):
  - Porter Robinson's "Sad Machine" into the Anamanaguchi remix.
  - Kyary Pamyu Pamyu's "Yume no Hajima Ring Ring" into the Yandere remix (two sets).
  - Swedish House Mafia's "One" into the Congorock remix (5 sets).
  - Avicii's run of four "Show Me Love" remixes.
- **Acapellas over instrumentals and bootleg mashups** are common: Justice vs Simian "We Are
  Your Friends (Acapella)", and Avicii's 152 distinct bootlegs. AutoMix can't separate stems,
  so this stays out of scope. It does explain why DJ tracklists contain "vs" entries.

### J-pop, anime and vocaloid

- Porter Robinson's 2014 Essential Mix mixes J-pop with Western electronic music:
  - Hikaru Utada "Simple And Clean".
  - Kyary Pamyu Pamyu, original then Yandere remix.
  - Tomggg "Popteen" (Maltine Records).
  - Ray "lull〜そして僕らは〜", original then the Maon remix.
  - Fu_Mou feat. 星子 "Green Night Parade".
- **Sample and quote links checked against two or more write-ups:**
  - Kenshi Yonezu "KICK BACK" quotes Morning Musume "Sōda! We're Alive", with Tsunku's
    permission.
  - Jennifer Lopez "I'm Real" uses Yellow Magic Orchestra "Firecracker", itself a cover of
    Martin Denny.
  - Trey Songz "Can't Be Friends" samples Ryuichi Sakamoto "Bibo no Aozora".
  - Hatsune Miku "Ievan Polkka" is Otomania's 2007 rearrangement of Loituma's version.
  - The Weeknd "Out of Time" samples Tomoko Aran "Midnight Pretenders" (already in
    common-mixes).
  - Rainych covered Miki Matsubara "Mayonaka no Door".
- **VocaDB** (`vocadb.net/api`) is the best structured source for vocaloid.
  - `songs/byPv?pvService=Youtube&pvId=ID` finds a song from its YouTube id.
  - `songs/{id}/details` gives `minMilliBpm` and `maxMilliBpm`, the community-entered tempo.
  - Checked on the style groups (`reference_mixes.py vocadb`): 48 of 103 vocaloid and J-pop
    songs were found by id, and 20 had a tempo. 19 of those agree with the silver labels within 3 %. One (KIKUO "Dance of the
    Frogs", VocaDB 200 against 149) is a 4:3 disagreement that needs a listen.
  - VocaDB also links originals to their remixes, covers and mashups (`originalVersionId`,
    `songType`).

  So VocaDB is a trustworthy independent tempo check where it has data, which is about half
  the songs it knows.

### Albums mixed by DJs (Discogs, `mix-albums.tsv`)

**Welcome To Kanye's Soul Mix Show** (Kanye West & DJ A-Trak, 2006): 23 records Kanye sampled.
The Discogs notes say "All songs are played at around the same speed as used for sampling". So
each record is the source side of a sample pair, already at the speed of the song that uses
it. Confirmed links among them:
- Bobby Bland → JAY-Z "Heart of the City (Ain't No Love)".
- Luther Vandross "A House Is Not a Home" → Twista "Slow Jamz".
- Chaka Khan → "Through the Wire".
- Gil Scott-Heron → "My Way Home".
- Curtis Mayfield → "Touch the Sky".
- Ahmad Jamal → "They Say".
- Honey Cone → "Testify".

The others need `--mixplan --samples` or a MusicBrainz lookup before they are treated as
links.

**Ministry of Sound** mixed albums:
- *Rapper's Delight* (2015, 60 hip-hop classics).
- *Chilled Hip Hop* (2016).
- *Throwback Slowjamz* (2016, three mixes of R&B ballads).
- *80s Soul Jams* (2018).
- *R & B Mixtape* (2014).
- *Masterpiece* by Jazzie B (Soul II Soul, 2008: rare groove, then house).
- *Masterpiece* by Gilles Peterson (2011, two mixed discs and one unmixed).
- *The Annual 2006* (two mixed CDs; the DVD is unmixed and is left out of the pairs).

These cover slow tempos (R&B ballads at 60 to 90 BPM), hip-hop at 85 to 100 BPM and soul.
Those are the styles where AutoMix's four-on-the-floor habits are most likely to be wrong.
Several albums also contain both halves of known sample pairs. Mtume "Juicy Fruit" and The
Notorious B.I.G. are on *80s Soul Jams* and *Rapper's Delight*. "Just the Two of Us" is on
*Throwback Slowjamz*.

### DJ set histories (MixesDB)

MixesDB's MediaWiki API (`www.mixesdb.com/w/api.php`) gives every set page of an artist's
category, with "# Artist - Title [Label]" tracklists. `reference_mixes.py sets` counts
transitions a DJ repeated in different sets (rebroadcasts that share over 60 % of their tracks
count once), original-to-remix moves and mashups. The categories fetched on 2026-11-21:

| DJ | Sets with tracklists | Repeated transitions | Notes |
|---|---|---|---|
| Porter Robinson | 17 | 43 | J-pop and anime in 2014; mashups of his own |
| Madeon | 10 | 25 | The Knocks "Dancing With The DJ" → M83 "Midnight City" in 3 sets |
| DJ Jazzy Jeff | 23 | 127 | source → sampler pairs (table above) |
| DJ Premier | 39 | 28 | rock specials: ZZ Top → Rage Against the Machine, Yes → Simple Minds |
| A-Trak | 50 | 19 | hip-hop runs: OutKast "ATLiens" → Nas "Made You Look" |
| Avicii | 114 | 85 | original ↔ remix chains, 152 bootlegs |
| Calvin Harris | 30 | 69 | "Sweet Nothing" → Pyero "Bura" in 6 sets |
| Disclosure | 49 | 25 | a five-track run repeated in 5 sets |
| Swedish House Mafia | 30 | 51 | "One" → Congorock remix → "One (Your Name)" |
| Fred again.. | 26 | 23 | runs of his own and Sammy Virji's songs |
| Daft Punk | 33 | 3 | few repeats; 1990s house sets |
| Kaytranada | 16 | 0 | never repeats a transition |

Steve Aoki (274 pages), Martin Garrix (170), Diplo (152) and Ministry of Sound (619) were still
downloading when this was written. Run `sets` on them when they finish.

### Stems: Kano's STEM Player, DJ apps and Mosaikbox

**Kano's STEM Player** (2021, made with Ye for *Donda*):
- It splits a track with AI into four stems (vocals, drums, bass, other).
- It has a touch slider for each stem, plus loop, speed and effect controls.
- Users upload songs through Kano's web app.
- Kano has not published the separation model, and the player doesn't transition between songs.

**DJ apps** (Serato Stems, djay Neural Mix, rekordbox, VirtualDJ) separate in real time and use
stems in three moves:
- a bass swap (never two basslines at once);
- a drum swap;
- one song's vocals over the other's instrumental, or the outgoing vocals ducked as new ones
  arrive.

The known weakness is artifacts on dense bass.

**Mosaikbox** (Sowula and Knees, ISMIR 2024, pp. 850–857, doi:10.5281/zenodo.14877463, code at
github.com/robaerd/mosaikbox) is
the one evaluated automatic mixer with stems.
- **Separation:** HT-Demucs into four stems.
- **Vocal rule:** vocal segments come from the vocal stem, split on silences of at least 1 s
  below −40 dBFS, keeping segments of 0.4 s or longer. If both songs' vocals overlap for more
  than 2 s, the playing song's vocals fade out over the first 4 of 16 bars.
- **Drum rule:** if rhythmic similarity is below 0.95, the new drums rise over bars 4 to 8, and
  the old ones drop to 0.4 by bar 8 and 0.1 by bar 16.
- **EQ:** a bass swap at the transition point, with the treble brought in gradually.
- **Results** (30 listeners, mean transition rating out of 5):

  | System | Rating |
  |---|---|
  | AutoMashUpper baseline | 2.49 |
  | Mosaikbox without stem rules | 3.08 |
  | Mosaikbox with stem rules | 3.46 |

  The stem rules were the significant step (Wilcoxon, Holm-corrected p < 0.0001).

**HT-Demucs** (Rouard, Massa and Défossez, ICASSP 2023, doi:10.1109/ICASSP49357.2023.10096956;
MIT licence, 42 M parameters) is the
usual open model. Core ML and MLX ports exist.

## What AutoMix learned from these sets (2026-11-21)

All of it is measured; none of it has been heard. The owner's listening decides.

1. **Sample gate** (`SampleGate`, `Tools/ml/train_gate.py`).
   - It decides whether a match at another speed is real shared material.
   - Model: logistic regression on six features. The strongest is `pitchMargin`: a real sample
     matches at one pitch clearly better than at the others.
   - Training data: 204 positive pairs (the sample, interpolation and remix sets, plus faster and
     slower replays of same-speed pairs) against 826 DJ-adjacent, random and play-history pairs.
   - Re-measured on 2026-11-22 with the current build's features (1,040 pairs, 204 real): held
     out by song, AUC 0.713 against 0.644 for the old 4.5σ rule's measure. The old rule fired on
     69 % of the negatives; the shipped gate passes 7.2 % of them and 42.6 % of the real matches.
   - Unrelated songs rarely get "Sample match" now: 33 % → 6 % of random style pairs, and 24 % → 5 %
     of the owner's play history (2026-11-22, current build with the tempo limit).
   - The same tempo-eased move stays available, under its own name, "Tempo match". It ranks
     below what the same tempo offers. It was first kept because four of the owner's saved
     transitions used it, but on 2026-11-21 the owner said those saved transitions were
     accidental clicks, so that reason no longer holds. Whether it stays is the owner's call
     (`docs/PROJECT_GUIDE.md`, Open items).
   - The tempo-only "record replayed at another speed" guess is not gated: tempos a whole number
     of semitones apart are their own evidence. It is how the approved P.Y.T. → Good Life plan
     arises when no database link is cached, and the play-next and video-mix suites need it.
2. **Tempo ramps.** Steady songs 12 to 20 % apart, with nothing lining up at the other tempo,
   get a slow approach (16 to 45 s) to the next tempo and a beat-matched blend near the end,
   instead of a fade. DJs move tempo more than 20 % in only 1.4 % of transitions, so beyond that
   it stays a fade.
3. **Autoplay ordering** (`MixSequencer`, `Tools/ml/train_sequencer.py`).
   - Model: a conditional logit over pools of five, trained on 501 transitions in 28 DJ-made
     sequences (12 Spotify "Mixed By" playlists and 16 parts of 6 mix albums) and held out by
     sequence.
   - Re-measured on 2026-11-22: the DJ's next song ranks first 29.9 % of the time, against 27.8 %
     for the old hand-set weights and 20 % by chance. Mean reciprocal rank rose by 0.020, but the
     95 % interval (−0.002 … 0.040) includes zero, so the gain is not yet clear. (On 2026-11-21
     it read 30.1 % against 27.3 %, interval 0.001 … 0.046; the libraries' analyses have changed
     since.)
   - DJs weigh tempo most and key much less than the old weights did.
4. **Stems in transitions** (`StemSeparator`, `MixPlan.outgoingStems` / `incomingStems`, the
   "Mix with stems" setting).
   - HT-Demucs runs through Core ML on the two stretches of an overlap only. The output matches
     PyTorch at 112.0 to 126.1 dB SDR (2026-11-22; pass mark 40 dB).
   - On 2026-11-22 the model loaded in 1.3 s, a 7.8 s segment took 0.68 s including the first
     run, and a 20 s stretch took 2.8 s at 48 kHz, done when the transition is decided.
   - The engine removes `1 − gain` of each stem from the samples it plays. They are aligned with
     playback to the sample: Opus files are 3.5 ms out between decoding and playback, and that
     is corrected.
   - Rules: Mosaikbox's vocal rule, decided on the separated vocal stems when the transition is
     prepared. A bass swap at the midpoint. A drum hand-over in blends and tempo matches.
   - Without lyrics, the planner's own vocal guess got 44 % of bars wrong against the vocal stem
     (88 songs with current analyses, pooled AUC 0.642, 2026-11-22). That is why the vocal
     decision waits for the stems.

## Data sets for training and labels

| Set | What it gives | Access | Licence |
|---|---|---|---|
| Harmonix Set (Nieto et al., ISMIR 2019) | Beats, downbeats and sections for 912 Western pop songs, with YouTube URLs and DTW alignment scores (`dataset/youtube_urls.csv`, `youtube_alignment_scores.csv`) | `github.com/urinieto/harmonixset` | MIT |
| Beat This! annotations | Beats for 16 sets, including RWC Popular (Japanese pop, audio not on YouTube) and a corrected Harmonix | `github.com/CPJKU/beat_this_annotations` | MIT |
| DJ mix dataset (Kim et al. 2020) | 1,557 mixes with track boundaries; YouTube ids; cue points by alignment | `pip install djmix` | metadata used with 1001Tracklists' permission |
| UnmixDB | Synthetic mixes of open-licence dance tracks with exact cue truth | Zenodo 1422385 | open |
| VocaDB | Community BPM, YouTube ids, original ↔ remix/cover/mashup links for vocal-synth music | `vocadb.net/api` | see VocaDB's terms (not checked) |

Two sources refuse automated requests and are not used: 1001Tracklists (HTTP 403) and
WhoSampled (Cloudflare check). Don't work around that.

## How to test with these songs through YouTube Music

All steps run from the repository root with the Bash sandbox off, because the app's
networking ignores the sandbox proxy. Use a release build (`swift build -c release`) and a
test home, never the owner's data.

1. **Make a test home.** Clone the last one so analyses already done are kept:
   `cp -Rc /tmp/claude/styleshome-narrow /tmp/claude/refhome`.
2. **Write the query list.** Take the unique "query A" and "query B" values of the pair files
   you want, one per line. The pair files are `reference-mixes.tsv`, `common-mixes.tsv`, or
   output of `reference_mixes.py pairs Tools/groundtruth/spotify-mixed-by.tsv - spotify-mix`
   and `... mix-albums.tsv - album-mix`.
3. **Download and analyse.**
   `tr '\n' '\0' < queries.txt | METROLIST_HOME=/tmp/claude/refhome xargs -0 .build/release/Metrolist --analyze > resolve.txt 2>&1`.
   - `--analyze` searches YouTube Music with the songs filter, so it gets the audio release
     rather than a music video. It caches the file and prints "Title — Artist [videoId]".
   - About 2 to 3 songs a minute per home. Separate homes can run side by side; merge their
     `Analysis/` folders afterwards.
   - Swift buffers its output to a file, so the log fills in chunks. Count
     `Analysis/*.json` to watch progress.
4. **Map queries to ids.**
   `python3 Tools/ml/reference_mixes.py resolve pairs.tsv --pairs P1.tsv P2.tsv --logs queries.txt resolve.txt`.
   This writes `kind:group  idA  idB` lines. Check a sample of the titles in `resolve.txt`:
   the first search hit is sometimes a live version or a different edit (DJs often played
   extended mixes).
5. **Plan and measure.**
   `METROLIST_HOME=… .build/release/Metrolist --mixaudit --pairs-file pairs.tsv --out results.tsv`.
   It prints, per group:
   - the share of synced plans, fades and unlinked "Sample match" plans;
   - entries after 30 s, and stretches over 12 %;
   - the kick-alignment check and exits inside a sung line;
   - the median entry point and the median time left of the first song.
6. **Always also run** `--mixaudit --approved` (the approved plans must not change without
   saying so). `Tools/run_audits.sh` runs the standard set. Don't measure against
   `owner-mixes.tsv` (now `Tools/ml/data/owner-mixes.IGNORE-misclicks.tsv`): on 2026-11-21 the
   owner said those saved transitions came from accidental clicks.

### What a good result looks like, per set

| Set | Expected behaviour | Watch for |
|---|---|---|
| `sample`, `dj-sample`, common-mixes samples | the shared material is found: "Known sample" or "Sample match", entry near the sampled part, speed and pitch consistent with the sample | a plain blend at the song ends, which misses the point |
| `interpolation`, `dj-version` (original → remix or cover) | a similarity or sample plan, mostly at a small stretch; same key | treating a remix like an unrelated song |
| `dj-recurring`, Spotify house/EDM lists, *The Annual* | beat-matched (synced) in most pairs, stretch under 6 to 8 %, exit on a phrase line | fades between songs DJs mixed; stretches over 10 % |
| Hip-hop and R&B albums, Cash Cobain, Amaarae | short synced blends or clean cuts on a bar; slow songs folded correctly (half or double time) | four-bar blends of two vocals; 70 BPM read as 140 |
| `soulmix` | free-tempo soul; mostly fades or short blends | beat-matching rubato records |
| Jim-E Stack, rock specials | fades or short blends; no invented "Sample match" | unlinked sample matches with big speed changes |

Report the results by set and by style group. A change that helps one set must be checked
against all of them, and against the approved pairs.

## Using the sets for training

- **Positives for "the two songs share material"**: `sample`, `dj-sample`, `interpolation`, the
  `dj-version` pairs, and the common-mixes samples.
- **Negatives**: Spotify, album and DJ-recurring neighbours, which are compatible but don't
  share material; and random pairs across style groups (`--mixaudit` "mixed").
- **DJ practice priors**: the tempo ratio, key distance and energy step of consecutive tracks in
  DJ-made sequences, against random pairs from the same sequences. These show what DJs accept
  when they choose to blend.
- **Owner gold**: the approved plans only. These are few, so use them for checking, not
  fitting. The 21 saved transitions once used as gold (`owner-mixes.tsv`) came from accidental
  clicks (owner, 2026-11-21): they were cleared from the app and must not be used for checking
  or fitting. No learned part was trained on them; only the "owner placement" measure used them.
- **Hold-out rules**:
  - Split by song, never by pair, so a song never sits on both sides.
  - Keep one style group out at a time.
  - Report each set separately.
  - Small models with few features (logistic or shallow trees) suit about 100 positives.
    Anything larger will overfit.

## Sources

- Spotify support, Mixed playlists: https://support.spotify.com/ae-en/article/mixed-playlists/
- Spotify newsroom: https://newsroom.spotify.com/2025-08-19/mix-your-favorite-playlists-seamlessly-by-adding-your-own-transitions/ , https://newsroom.spotify.com/2025-09-22/mixed-playlists-debut-martin-garrix-pinkpantheress-sofi-tukker/ , https://newsroom.spotify.com/2025-12-17/new-years-eve-party-playlists/
- Apple newsroom (June 2025): https://www.apple.com/my/newsroom/2025/06/apple-services-deliver-powerful-features-and-intelligent-updates-to-users-this-fall ; Apple support: https://support.apple.com/guide/iphone/aside/iphcba31c44b/ios ; heise: https://heise.de/-11139247 ; MacRumors: https://www.macrumors.com/2025/06/12/ios-26-automix-apple-music/
- Kim et al., ISMIR 2020: https://doi.org/10.5281/zenodo.4245544 ; https://arxiv.org/abs/2008.10267 ; https://mir-aidj.github.io/djmix-analysis ; https://github.com/mir-aidj/djmix-dataset
- Mixed In Key, Camelot and energy boost: https://mixedinkey.com/workflows/how-to-use-the-camelot-wheel/ , https://mixedinkey.com/Book/Use-Advanced-Harmonic-Mixing-Techniques/
- Mashup theory: https://www.lalal.ai/blog/a-guide-to-mashups/ , https://magneticmag.com/2024/07/how-to-make-a-good-mashup/
- Harmonix Set: https://github.com/urinieto/harmonixset ; Beat This! annotations: https://github.com/CPJKU/beat_this_annotations
- Discogs: Welcome To Kanye's Soul Mix Show, release 5794717; Ministry of Sound masters 1222780, 1687668, 1011822, 1454564, 781266, 941758, 2791694 and 197939 (https://api.discogs.com)
- MixesDB API: https://www.mixesdb.com/w/api.php
- VocaDB API: https://vocadb.net/api
- Kick Back: https://en.wikipedia.org/wiki/Kick_Back_(song) , https://dic.pixiv.net/a/KICKBACK ; I'm Real: https://en.wikipedia.org/wiki/I%27m_Real ; Can't Be Friends: https://en.wikipedia.org/wiki/Can%27t_Be_Friends ; Ievan Polkka: https://en.wikipedia.org/wiki/Ievan_polkka ; Heart of the City: https://en.wikipedia.org/wiki/Heart_of_the_City_(Ain%27t_No_Love) ; Slow Jamz: https://en.wikipedia.org/wiki/Slow_Jamz ; Out of Time / city pop: https://tvtropes.org/pmwiki/pmwiki.php/Main/CityPop ; Mayonaka no Door: https://www.tokyoweekender.com/entertainment/music/city-pop-songs-covered-by-overseas-artists/
