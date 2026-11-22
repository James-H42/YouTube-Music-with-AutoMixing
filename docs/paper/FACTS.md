# Verified facts for the AutoMix paper (branch claude/merge-2026-11-21, 2026-11-22)

Each line: fact, then its source (file:line, a document, or a measurement run). Only facts listed
here go into the paper, the README's AutoMix sections and the social-media drafts.

Every number below was measured again on the current build on 22 November 2026, or read again
from the primary source that day. The outputs are kept in the git-ignored
`Tools/ml/data/audit-results/2026-11-22/`. Commands run from the repository root with a release
build, `METROLIST_TEST_KEYCHAIN=1`, `METROLIST_MODELS=Models` and a test `METROLIST_HOME`.

## Authorship
- Written by Claude Opus 5.5 (`claude-opus-5-5`) with extended thinking at the xhigh effort level,
  in Claude Code, at the owner's request; proof-read by a second instance of the same model at the
  same setting — session transcript metadata (`"model":"claude-opus-5-5"`, `"effort":"xhigh"` on
  every message, main session and proof-reading subagent)

## Measurements on the current build (2026-11-22)

| Figure | Value | Command | Output |
|---|---|---|---|
| Beat F / downbeat F, no model | 0.796 / 0.431; vocaloid 0.668, tempo right 46 % | `METROLIST_BEATMODEL=off --analysisaudit Tools/groundtruth/silver groups.csv` on a fresh library | `none/analysis.txt` |
| Beat F / downbeat F, shipped | 0.814 / 0.439; vocaloid 0.724, tempo right 56 % | same, model on | `ship/analysis.txt` |
| Beat F / downbeat F, model grid | 0.953 / 0.899 | same, `METROLIST_BEATGRIDS=Tools/ml/data/small0-all` | `grid/analysis.txt` |
| Approved plans | shipped byte-identical to 2026-11-22 00:04 final run and to no-model; model grid changes 9 of 10 | `--mixaudit --approved` | `*/approved.tsv` |
| Fades, 200 style pairs | none 28 %, shipped 26 %, grid 37 % | `--mixaudit groups.csv --pairs 25` | `*/groups.txt` |
| Fades, 242 history pairs | none 19 %, shipped 19 %, grid 27 % | `--mixaudit --pairs-file Tools/ml/data/history-pairs.tsv` | `*/history.txt` |
| Plan types, 200 style pairs, without → with tempo limit | structure 93→95, similarity 14→27, lyrics 2→3, sample 13→12, tempo 49→10, ending 29→53; synced 162→125; stretch > 12 % 84→47; > 20 % 47→10 (7 sample, 3 ramps shown as structure) | `--mixaudit groups.csv --pairs 25 [--tempo-cap 0]` | `ship/groups*.tsv` |
| Common pairs (37), without → with limit | 2 changed: tempo→fade, tempo→blend | `--pairs-file Tools/ml/data/common-pairs.tsv [--tempo-cap 0]` | `ship/common*.tsv` |
| History pairs (242), without → with limit | tempo 41→8, ending 23→45 | `--pairs-file history-pairs.tsv [--tempo-cap 0]` | `ship/history*.tsv` |
| Tempo matches without limit moving tempo > 25 % | 61 of 91 distinct pairs (style, common, history) | from the three `--tempo-cap 0` runs | `ship/*-nocap.tsv` |
| MONTERO (uo1Ti_IWr8M) → Body (JiNxvNtlBPM) | with limit: Fade 7 s; without: Tempo match 163.1 % speed, +7 st, 2 bars, approach 32 s | `--mixaudit --pairs-file` that pair | `montero-*.tsv` |
| Unconfirmed "Sample match" | style pairs 33 % (old rule) → 6 %; history 24 % → 5 % | `--no-gate --tempo-cap 0` against default | `ship/groups-oldrule.txt`, `ship/history-oldrule.txt` |
| Sample gate, held out by song | AUC 0.713 ± 0.009 (core+tape, l2 0.3) vs 0.644 ± 0.008 for the old measure alone; old rule fires on 69.3 % of negatives, catches 89 % | features regenerated with `--mixaudit … --features [--augment]` on the refhome-a library, then `train_gate.py … --task stretched --fpr 0.08`; 1,040 pairs, 204 positive | `gate/train_gate.txt` |
| Shipped gate v1 on today's features | passes 7.2 % of negatives, 42.6 % of positives at 0.617 | scored with `data/gate/gate-stretched-v1.json` | (computed in session) |
| Positives by style | common pairs: 21 hip-hop, 8 electronic, 4 pop, 3 rock, 2 J-pop; curated positives hip-hop, electronic, J-pop | `Tools/groundtruth/common-mixes.tsv`, curated groups | |
| Queue order, held out by sequence | learned 29.9 %, hand-set 27.8 %, chance 20 % first of 5; MRR +0.020, 95 % interval −0.002 … +0.040; 501 transitions in 28 sequences (12 Spotify "Mixed By", 16 parts of 6 albums); retrained weights within 0.026 of shipped v2 | `train_sequencer.py … --homes` (version-7 analyses only) | `seq/sequencer-v7.txt` |
| Vocal guess without lyrics | wrong on 44 % of bars; pooled AUC 0.642; 88 songs with version-7 analyses (of 93 with stems) | `vocal_check.py data/stems HOME` | `vocal_check.txt` |
| Stem parity with PyTorch | drums 113.0, bass 118.7, other 112.0, vocals 126.1 dB SDR (pass 40 dB) on 4tlUwgtgdZA at 60 s | `--stemtest`, `check_stems.py` | `stems/check_stems.txt` |
| Stem timing | model load 1.3 s; one 7.8 s segment 0.68 s, first run included; 20 s at 48 kHz 2.80 s; lag 0, file offset 3.50 ms | `--stemtest` | `stems/stemtest.txt` |
| Vocal residue, six approved-sample songs | one pass leaves vocals −43.9 to −56.9 dB; second pass gains 0.0 to 7.2 dB | `--vocalresidue` on JhulBGMA7G4, 2ulp_AMut14, y32ejtuxSjM, GTmbyuTKT_c, dBLzh47wdrU, V4HdD2Fu_64 | `stems/residue.txt` |
| Beat model parity | six songs, beat and bar F 1.000 at ±25 ms; 3.25–4.74 s model time for 207–320 s songs | `--beatmodeltest Tools/ml/data/small0` | `stems/beatmodeltest.txt` |
| Model sizes | HTDemucs.mlpackage 200 MB, BeatThis.mlpackage 9.4 MB | `du -sh Models/*` | |
| Swift size | 36,829 lines in 120 files | `find Sources -name '*.swift'` | |

Not reproducible on the current code and therefore not quoted: the 21 November "pulse, octave and
bar phase" beat-model role (0.932), and a first stem run of "about 20 s" (today's first run took
0.68 s with warm caches).

## Track analysis (`Sources/Metrolist/Mix/TrackAnalysis.swift`)
- Analysis format version 7: beats and bar lines from the beat model when installed — TrackAnalysis.swift:6
- Decoded to mono at roughly 12 kHz (integer decimation factor so rate ≈ 11–12 kHz; needs > 10 s) — :232–280
- Loudness: RMS in half-second steps; main level = median of middle section; intro end / outro start where smoothed energy crosses 0.5 × reference — :24, :350–356
- Onset strength: spectral flux of log-compressed magnitudes, FFT 1024, hop 256, Hann window; separate low-band flux (< 200 Hz) — :358–406, :789–840
- Band levels: 3 wide bands (edges 250 Hz, 2 kHz) for waveform/levels; 7 octave-wide tone bands (100, 200, 400, 800, 1600, 3200 Hz edges), log energy, standardised per track — :33, :370–391
- Tempo: autocorrelation of onset envelope (unbiased), lags 55–210 BPM; score(lag) = [r(lag) + 0.7 r(2·lag) + 0.7 r(4·lag)] × exp(−½ (log2(bpm/110)/0.9)²) — :409–439
- Beat tracking: dynamic programming after Ellis 2007, tightness 100, penalty (log interval/period)² — :448–484
- Tempo refined by least-squares line through beat times (middle 3/4 of beats) — :541–543
- Beat confidence = clamp((periodicity − 0.3)/0.3): beat-driven music > 0.6, free-time < ~0.35 — :545–547
- Bar lines: of each four beats, the one with most low-frequency attack (summed low flux) — :549–555
- Beat model use: corrects the built-in grid ONLY when the built-in beat is 3/2 or 2/3 of the model's (|ratio−1.5| ≤ 0.06 or |ratio−2/3| ≤ 0.03) and agreement < 0.8; re-tracks at the model's period and keeps it only if ≥ 0.8 agreement with model beats. Half/double time left alone (planner folds them). Larger role measured: made mixes worse (twice as many fades on history pairs, approved plans changed) — :492–520
- Key: chromagram (≈ C2–C7, each frame normalised to unit sum, FFT hop 1024) against Krumhansl–Kessler profiles; Camelot code — :563, :732–770, :54
- Per-beat harmony: 12-bin chroma per beat, unit length — :31
- Sections: bar-by-bar self-similarity matrix scanned with a checkerboard kernel (Foote novelty); peaks above threshold, ≥ 4 bars apart — :649–700
- Waveform: three-band envelope 0–255 — :41

## Beat model (`Mix/BeatModel.swift`, `Tools/ml/README.md`)
- Beat This! small checkpoint `small0`, 2.1 M parameters, ~10 MB, Core ML, fp32 (fp16 matched but 5× slower) — Tools/ml/README.md:7, :58
- Input: log-mel spectrogram of 22.05 kHz mono, 128 mel bands (Slaney), FFT 1024 (513 bins), 50 frames/s (20 ms), log(1+1000x); 30 s chunks overlapping by the border — BeatModel.swift:6–21, :105–107, :164
- Peaks: local maxima within ±70 ms above even odds; bar lines snapped to nearest beat — BeatModel.swift:203–231
- Conversion: torch.export; SumHead autocast guard patched; constant folding must skip large tensors (else ~1 GB rotary tables) — Tools/ml/README.md:52–58
- Parity: see the measurement table (2026-11-22)
- Role comparison: see the measurement table (none, shipped, model grid; the fourth 21-Nov role is not in the code)
- Vocaloid tempo correct 46 % → 56 % — measurement table
- Style groups: 198 songs, 7 groups; common-mixes set 37 sample pairs and blends — PROJECT_GUIDE Status

## Reference data and learned parts (`docs/AUTOMIX_REFERENCE_MIXES.md`)
- Spotify "Mixed By": 21 playlists, 564 tracks (order only); DJ-mixed albums: 9 (Ministry of Sound, Kanye West & A-Trak Soul Mix Show) — :19–20
- Kim et al. 2020, read in the paper's text on 2026-11-22: 1,557 mixes from 1001Tracklists, 13,728 tracks, 20,765 transitions; "mostly focuses on House and Trance"; tempo adjusted <5 % in 86.1 %, <10 % in 94.5 %, <20 % in 98.6 %; "Only 2.5% among the total 24,202 tracks are transposed", 94.3 % of those by one semitone; transition-length histogram "has peaks at every phrase" (32 beats); cue-out distribution "has more distinctive peaks around every 32 beat"; subsequence DTW "does not work well for some genres such as Techno"; metadata "obtained with permission from 1001Tracklists", interested people should contact them
- Mosaikbox, read in the paper's text on 2026-11-22: vocal segments split on silences of one second or longer below −40 dBFS, segments under 400 ms dropped; clash if vocals intersect > 2 s, then the playing song's vocals are attenuated; 30 participants (22 male, 8 female), mainly academics aged 23–30, 8 with DJ experience; ratings 1 (awful) to 5 (excellent): AMU 2.490, MBbase 3.076, MBstem 3.457, MBfull 3.033; Wilcoxon signed-rank with Holm–Bonferroni, MBstem vs MBbase p < 0.0001; dataset drum and bass only (participants familiar with it; ±8 % tempo tolerance); cites "the subjective nature of mixes" and "the lack of ground truth corpora" for song similarity; ethics: possible artist/label bias from timbre, participant demographic bias; rule-based design avoids training on copyrighted music
- HT-Demucs 42 M parameters — docs/AUTOMIX_REFERENCE_MIXES.md:267 (not re-checked; not used in the paper)
- Sample gate: logistic regression, six features, strongest pitchMargin; shipped v1 trained 2026-11-21 on 204 positive vs 826 negative pairs; re-measured figures in the table
- Record-replay guess (tempo ratio a whole number of semitones) not gated — :289–291
- Tempo ramps: steady songs 12–20 % apart, approach 16–45 s, beat-matched blend near end — :292–295
- Sequencer: conditional logit over pools of five, held out by sequence; figures in the table
- Stems: figures in the table
- Stem parity is deterministic: 2026-11-21 and 2026-11-22 runs gave the same SDRs

## Planner (`Mix/MixPlanner.swift`)
- candidates(): needs A > 45 s, B > 30 s; families: structural (section-aligned blends), lyrical (shared words), similar (sound/sample/tempo matches), ramps, ending fade; fade score 0.5 if nothing else, else min(0.45, best − 0.05); free tempo (beat confidence < 0.5) → fade ≥ 0.62; keep ≤ 6 plans, ≤ 3 structure, ≤ 2 of other kinds; near-duplicates (< 4 s apart) dropped; withStems + describe applied — :347–377
- MixLength: short/medium/long target overlap 6/10/18 s; fade 4/7/11 s; bar counts from {1,2,4,8,16,32} with seconds in [0.45, 1.8] × target — MixLength in MixPlanner.swift
- maxStretch 0.12 for beat-matched mixes; fold(): incoming beat counted ×1, ×2 or ×½ to bring periods closest — :173, fold
- structural(): both beat confidence ≥ 0.5; folded tempo within 12 %; exit after max(25 % of A, min(intro end + 20 s, 50 %)); entry within min(45 % of B, 100 s); four-beat-regular bars only — :477–528
- Structure score (per exit bar a, entry bar b, length L bars, s = 4L·beat seconds, T = target):
  1 − E_lostA + 0.14·[leaves on boundary or within 4 beats of outro] − 0.10·|log2(s/T)| + 0.1·min(1,clarityA) − 0.1
  − 1.4·E_skippedB + 0.08·[starts on boundary/first audible bar] + 0.12·[lands on boundary/intro end] + 0.1·min(1,clarityB) − 0.1
  + 0.30(H − 0.55) − 0.05|shift| − 0.40·C·(0.5 + 0.5 s/T) − 0.25·max(0, 0.5 − H)·s/T − 0.15·min(1,|ℓA − ℓB|) − 1.5·max(0, |ρ−1| − 0.05)
  H = mean bar chroma agreement after best shift; C = mean product of vocal activity; ℓ = mean level; ρ = folded tempo ratio — :507–548
- Key shift: harmony for shifts −2…+2; a shift taken only if (H_shift − 0.05|shift|) > H_0 + 0.06 — :445–475
- Top 60 verified: beats steady around both ends, beat clarity ≥ 0.45; exits ≥ 20 s apart; ≤ 3 structure plans; shape Blend; rough (H < 0.5 or C > 0.45) → outgoing mids step back — :554–588
- synced(): local beat periods around the join; sync only if both beat confidence ≥ 0.4 and |ρ−1| ≤ 0.16; volume crossfade lanes — :602–616
- tempoCurve: overlap ≥ 12 s glides 15 %→85 %; shorter overlaps hold the old tempo, ease after — tempoCurve
- approachLength(rate, pitch) = clamp(8|pitch| + 45|log2 rate|, 12, 32) s ("about eight seconds a semitone") — :232–235
- similar(): beat-chroma centred (track mean removed), time grid step 0.4 s, window 20 steps (8 s); A searched from 25 % of its length; B up to min(55 % of B, 120 s); variants: same speed with shifts {0,±1,±2} (key match on), other speeds for multiples {1,2,½} with stretch in [0.62, 1.6] and |stretch−1| > 0.12, shifts {0,±1,±2, tape−1, tape, tape+1} (|shift| ≤ 8), tape = round(12·log2 stretch); "record" clue when tempo ratio within 0.06 st of a whole semitone — :880–953
- Match must stand out: same speed ≥ 4σ; other speed: known link 4.5σ, gate open 4σ, else 4.5σ; admissible value ≥ 0.45 (steady) / 0.58, other speed ≥ 0.42 — :1127–1155
- Sample gate inputs (SampleEvidence): standout, variant standout, pitch margin, coverage, tape deviation, semitone fit, log stretch, entry, tone agreement, keys agree … gate = logistic on 6 standardised features (mean/scale/weights/bias in SampleGate), threshold 0.617 — :136–166, :1050–1080
- Tempo match: gate closed → reason .tempo, score −0.35; since 2026-11-21 dropped if |rate−1| > 0.20 or |shift| > 2 (tempoMatchMaxStretch, tempoMatchMaxShift) — :1246–1257
- Record-replay plan (not gated): arrives on a late section change of A, enters B at its first audible beat, Blend shape — :1254–1290
- Ramps: no known link, both steady, no sample/tempo result, closest reading 12–20 % apart → playing song eases to the next tempo before a beat-matched overlap near the end; score 0.85 − 2(gap − 0.12) − 0.7 lostA − 0.5 skipB — :1295–1318
- withStems(): only synced plans ≥ 8 beats, no loop, not fade/manual. Vocals: if both sing > 2 s (vocal ≥ 0.5 per bar) and not a lyric match, outgoing vocals out over first quarter (refined by engine). Bass: swap at 0.5–0.53 (EQ low band left open). Drums (structure/tempo plans): incoming 0 → 1 over 0.25–0.5; outgoing 1 → 0.4 at 0.5 → 0.1 at 1 — :390–425

## Engine (`Mix/MixEngine.swift`, `Playback/AudioEngine.swift`)
- Two decks (AudioEngine each: AVAudioUnitTimePitch rate 0.5–2, AVAudioUnitEQ 4 bands, AVAudioUnitDelay echo); mixer; master EQ and limiter after — AudioEngine.swift:190–194, :410–416
- Player cues the next track about 30 s (+ approach) before the mix point; approach follows position, so pause/seek safe — PlayerController tick; README
- Start: preroll = output latency + stretcher latency; incoming deck play(atHostTime: now + remaining − preroll) — MixEngine.swift:486–525
- Phase lock: e = beats_B − beats_A (beats since entry/exit); if |e| < 0.45: d ← d + 0.08(e − d); incoming rate × (1 + clamp(−0.6 d, ±0.025)), after 3 % of the overlap — :544–555
- Hand-over at progress ≥ 0.5: player switches to the incoming song — :565–575
- Settle after: back to own tempo/key over max(8, 150|rate−1|, 6|pitch|) s, ≤ 24 s — :593–598
- Abandon if > 1.5 s past the mix point (or too little left); if the next track isn't ready, waits; if outgoing can't stretch, falls back to a cross-fade — :476–507
- Stems ahead: separated as soon as the plan is known, cached; vocalHandOver: if both vocals overlap > 1 s, outgoing vocals fade over half a beat on the last beat before incoming vocals start; late stems start from the deck's read position, faded in over a beat (decks read ~3 s ahead); a side without stems swaps bass on the EQ — :228–293
- Deck subtracts (1 − gain)·stem from what it reads (StemMix) — AudioEngine.swift StemMix

## Stems (`Mix/StemSeparator.swift`)
- HT-Demucs network in Core ML; around it, as demucs 4.0.1: reflect padding, normalised 4096-point STFT, hop 1024, periodic Hann, inverse, overlapping 7.8 s segments cross-faded with triangular weights; ~0.6 s compute per 7.8 s once compiled; first run ~20 s (warm-up at launch); fp16 wrong (SDR ~0 dB) so fp32 — StemSeparator.swift:6–18, :55–56; Tools/ml/README.md:91–97
- Vocal segments from the vocal stem: silences ≥ 1 s below −40 dBFS split, parts ≥ 0.4 s kept (Mosaikbox) — :96–99
- Only stretches around a transition separated; cache of recent stretches — :10–14, :141

## Measurement tools
- `--mixaudit`: plans pairs from cached analyses (no network), fixed seed so runs compare the same pairs; reports per group: sync %, fade %, unconfirmed sample %, entry > 30 s, stretch > 12 %, kick alignment (low-band onsets < 150 Hz at ~47 fps of each song, correlated through the plan at lags ±2 beats; planned lag best = "kick ok"), exit in line, median entry/left — App/MixAudit.swift:4–35, :332–354
- Approved pairs: owner-approved reference pairs; plans must stay byte-identical — PROJECT_GUIDE rules
- Sample-gate features via `--mixaudit --features --augment` (replays faster/slower) — Tools/ml/README.md:78–85

## Corrections from the proof-read (2026-11-22)
- After the cap, the 10 style-group plans stretching > 20 % are 7 sample matches and 3 tempo ramps (Blend, rates 1.219–1.232), not all samples. Ramps can reach a rate of 1.25.
- "101 of 148" double-counted groups.tsv and groups-stems.tsv; re-measured on 2026-11-22: 61 of 91 distinct Tempo matches moved tempo > 25 %.
- Beat-matching is allowed from beat confidence 0.4 (`synced`); blends need 0.5.
- The planner also fetches lyrics over the network.

## Figures (data verified)
- HBFS (JhulBGMA7G4) → Stronger (2ulp_AMut14), approved: knownSample, sync, 16 beats, out 124.37 s, left of A 102 s, in 16.28 s, rate 0.842, approach 32 s, kick ok — /tmp/claude/approved-check/after-plain.tsv; mix.log: 9.2 s overlap; stems: vocals step aside at 3 % of the overlap (both sing 7.8 s) — showcase run
- Approach: a = (pos − (out − approach))/approach; e = 6a⁵ − 15a⁴ + 10a³; rate = target^e; pitch = outgoingPitch·e — MixPlan.approachState
- Settle after: smoothstep 3a² − 2a³ — MixEngine.swift:423–429
- Fade/auto shape: volume linear 1→0 / 0→1; Blend: bass swap curves, out mids/highs dip — MixPlan.applyShape
- 200 style-group pairs: see the measurement table (2026-11-22 values equal the 2026-11-21 ones)
- Approved pairs (10): byte-identical — measurement table

## Tests run on this branch (2026-11-22, current code)
- debug build: --featuretest 47/47 (incl. 6 stem-timing checks); --playnexttest 17 pass + 3 known label failures; --videomixtest 5 pass + 1 known; window test MIX (HBFS → Stronger): next cover joined, hand-over centred, PASS ×2; window test CONCERTS: page buttons hidden at 1.5 s and 5.5 s, back after closing. Release build: --radiotest 14/14 (live); --mixtest 4tlUwgtgdZA -3PKrJgxHK8 --stems --lead 5 --ahead: separated ahead in 5.0 s, "stems ready in 0.0 s (separated ahead)"; --lead 3 without --ahead: EQ bass swap, stems ready in 3.9 s, read 6.3 s into the overlap (late path); --mixaudit --approved with and without --stems byte-identical to 2026-11-21 22:18. Outputs: Tools/ml/data/audit-results/2026-11-22/final-checks. The debug build separates too slowly (37 s) for the late-stems path; use release for stem timing.
- Vocal residue: see the measurement table (−43.9 to −56.9 dB; second pass 0 to 7.2 dB)

## References (verified via doi.org / Zenodo API)
- Foscarin, Schlüter, Widmer, "Beat This! Accurate Beat Tracking Without DBN Postprocessing", ISMIR 2024, doi 10.5281/zenodo.14877491
- Rouard, Massa, Défossez, "Hybrid Transformers for Music Source Separation", ICASSP 2023, pp. 1–5, doi 10.1109/ICASSP49357.2023.10096956
- Sowula, Knees, "Mosaikbox: …", ISMIR 2024, pp. 850–857, doi 10.5281/zenodo.14877463
- Kim, Choi, Sacks, Yang, Nam, "A Computational Analysis of Real-World DJ Mixes using Mix-To-Track Subsequence Alignment", ISMIR 2020, pp. 764–770, doi 10.5281/zenodo.4245544
- Foote, "Automatic audio segmentation using a measure of audio novelty", ICME 2000, pp. 452–455, doi 10.1109/ICME.2000.869637
- Ellis, "Beat Tracking by Dynamic Programming", J. New Music Res. 36(1):51–60, 2007, doi 10.1080/09298210701653344
- Krumhansl, Kessler, "Tracing the dynamic changes in perceived tonal organization in a spatial representation of musical keys", Psychol. Rev. 89(4):334–368, 1982, doi 10.1037/0033-295X.89.4.334
- Vande Veire, De Bie, "From raw audio to a seamless mix: creating an automated DJ system for Drum and Bass", EURASIP J. Audio Speech Music Process. 2018, doi 10.1186/s13636-018-0134-8
- Davies, Hamel, Yoshii, Goto, "AutoMashUpper: Automatic Creation of Multi-Song Music Mashups", IEEE/ACM TASLP 22(12):1726–1737, 2014, doi 10.1109/TASLP.2014.2347135

## Commercial systems (read on 2026-11-22)
- Spotify Newsroom, "Mix Your Favorite Playlists Seamlessly by Adding Your Own Transitions", 19 Aug 2025, updated 19 May 2026 ("Mixing is now rolling out to eligible Premium users on desktop"): "Auto" for "an instant blend", presets such as "Fade" or "Rise", "volume, EQ and effect curves"; no description of how transitions are chosen
- Apple Newsroom (my), "Apple services deliver powerful features and intelligent updates to users this fall", updated 11 June 2025: "Using AI to analyse audio features, it crafts unique transitions between songs with time stretching and beat matching"
