# AutoMix beat model tools

AutoMix finds beats and bar lines with **Beat This!** (F. Foscarin, J. Schlüter, G. Widmer,
"Beat This! Accurate beat tracking without DBN postprocessing", ISMIR 2024,
doi:10.5281/zenodo.14877491; code and weights
MIT, © 2024 Institute of Computational Perception, JKU Linz; https://github.com/CPJKU/beat_this,
commit `b95c8ab`). The app runs the small checkpoint (`small0`, 2.1 M parameters, about 10 MB)
through Core ML from `Models/BeatThis.mlpackage`. Without the model it uses its built-in tracker.

What the model decides today (`TrackAnalyzer.analyze`): only the beat length, where the built-in
tracker counted a pulse two-thirds or three-halves as long as the model's. The tracker then
follows the onsets again at the model's beat length. Measured again on 2026-11-22 with the
current build, every song analysed from scratch for each role (outputs in
`data/audit-results/2026-11-22/{none,ship,grid}`):

| Model's role | Beat F (downbeat F) vs reference | Mixes (200 style pairs, 242 history pairs, 10 approved) |
|---|---|---|
| none (built-in tracker) | 0.796 (0.431) | style fades 28 %, history fades 19 % |
| corrects 2:3 pulse errors only (shipped) | 0.814 (0.439); vocaloid 0.668 → 0.724, tempo right 46 → 56 % | approved identical to none; style fades 26 %, history fades 19 % |
| replaces the grid (beats and bar lines, `METROLIST_BEATGRIDS=data/small0-all`) | 0.953 (0.899) | 9 of 10 approved plans changed; style fades 37 %, history fades 27 % |

A fourth role, correcting pulse, octave and bar phase, scored 0.932 on 2026-11-21 and doubled the
history fades; its code is no longer in the branch, so it was not measured again.

The planner was tuned on the built-in grids (unbroken, four-beat bars), so more accurate grids
alone did not give better mixes; the next step is adapting the planner's steadiness and bar
checks to bar-by-bar grids, then measuring again.

Everything here runs from this folder. Audio never goes into the repository; `data/` and the
virtual environments are git-ignored.

## Environments

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt          # labelling, evaluation (torch 2.15, MPS)
python3 -m venv .venv-convert && .venv-convert/bin/pip install -r requirements-convert.txt   # conversion (torch 2.7 for coremltools 9.0)
```

Setup needs network access to pypi.org, files.pythonhosted.org, download.pytorch.org and
github.com, and the checkpoints download from cloud.cp.jku.at on first use.

## Steps

1. **Audio from the app's own decoder.** In the repository root:
   `METROLIST_HOME=… .build/release/Metrolist --dumppcm Tools/ml/data/wav Tools/groundtruth/groups.csv`
   writes 22.05 kHz mono WAV files exactly as the app decodes them.
2. **Reference labels.** `.venv/bin/python silver.py data/wav ../groundtruth/silver --checkpoint final0`
   writes beats and bar lines from the large model. These are a development reference ("silver"),
   not ground truth; labels checked by ear should say `"source": "owner…"`.
   `relabel.py DIR` recomputes the tempo and metre fields after a change to `summarise`.
3. **Compare models.** `.venv/bin/python compare.py ../groundtruth/silver data/small0-all ../groundtruth/groups.csv`
   prints agreement per style group.
4. **Convert.** `.venv-convert/bin/python convert.py --checkpoint small0 --out ../../Models`
   writes the Core ML package and the front-end constants (window, mel filterbank). Notes:
   - `torch.export` (not tracing), with Beat This!'s `SumHead` autocast guard patched out and
     `alias` nodes removed, is what converts cleanly.
   - Constant folding must skip large tensors (`skip_const_by_size`), or the rotary-position
     tables are expanded into about 1 GB of weights.
   - fp32 is used: fp16 converts and matches, but ran 5× slower on the tested Mac.
5. **Check the app matches Python.** `.venv/bin/python silver.py data/wav-parity data/small0 --checkpoint small0`,
   then in the root `METROLIST_HOME=… .build/release/Metrolist --beatmodeltest Tools/ml/data/small0`
   (PASS needs beat and bar-line F ≥ 0.99 at ±25 ms; on 2026-11-22 it was 1.000 on six songs,
   3.3 to 4.7 s per song of 3.5 to 5.3 minutes).
6. **Measure AutoMix.** `Tools/run_audits.sh BINARY METROLIST_HOME OUT_DIR` runs the analysis
   audit and every mix audit (approved pairs, style groups, common
   mixes, history pairs). Compare a run with the model against one with `METROLIST_BEATMODEL=off`.

## Reference mixes, learned parts and stems (2026-11-21)

See `docs/AUTOMIX_REFERENCE_MIXES.md` for the data and the results.

**Reference collection: `reference_mixes.py`.** Subcommands: `spotify`, `discogs`,
`discogs-tsv`, `mixesdb`, `mixesdb-count`, `sets`, `vocadb`, `pairs` and `resolve`.
- All requests go through curl. Python's own HTTP client got cut-off replies through the agent
  sandbox.
- Resolve with `--overrides ../groundtruth/reference-overrides.tsv`. A word check also drops
  search hits that don't match the query.

**Sample gate: `train_gate.py`.**
1. Write features with
   `Metrolist --mixaudit --pairs-file P --features F.tsv --augment 1.25:0,1.25:4,0.8:0,0.8:-4`.
   The augmentation replays the next song faster or slower, which turns a same-speed sample
   into one at another speed; it is applied to negatives as well.
2. Train with `.venv/bin/python train_gate.py OUT.json F1.tsv F2.tsv … --task stretched --fpr 0.08`.
   Folds are grouped by song. The shipped v1 is `data/gate/gate-stretched-v1.json`, copied into
   `SampleGate` in MixPlanner.swift.

**Autoplay ordering: `train_sequencer.py`.** A conditional logit over pools of five, on the
Spotify and album sequences, held out by sequence, with a paired bootstrap over sequences. The
shipped weights (v2) are in `MixSequencer.Learned`.

**Stems** (`.venv-stems`: torch 2.7, demucs 4.0.1, coremltools 9; install it outside the
sandbox):
- `convert_demucs.py ../../Models [--check AUDIO]` writes `HTDemucs.mlpackage`. That is the
  network only; Swift does the STFT and its inverse. Use fp32: `--fp16` converts but gives wrong
  stems (SDR around 0 dB against PyTorch).
- `check_stems.py DIR` compares `Metrolist --stemtest` output with PyTorch (PASS at 40 dB;
  measured 112.0–126.1 dB on 2026-11-22).
- `stems_probe.py OUT --homes … --pairs …` stores per-beat stem levels and vocal segments.
  `vocal_check.py` compares the planner's vocal guess with them.

## Rules for changing the model

- Report results per style group (`Tools/groundtruth/groups.csv`); no group may get worse.
  The app never reads the group labels.
- Fine-tuning (not done yet) must mix data from every group and keep the model close to the
  stock one on Western music (distillation), and ship only if every group's held-out score
  is at least the stock model's.
