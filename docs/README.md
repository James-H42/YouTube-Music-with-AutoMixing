# Documentation

This folder holds the project's papers, its AutoMix research notes and the pictures the main
README uses.

## Papers

- [`paper/automix-paper.pdf`](paper/automix-paper.pdf) describes AutoMix version 2.0: its design,
  how its parts work together, how it was tested, what was measured and what it can't yet do.
  The LaTeX source is `paper/automix-paper.tex`. `paper/FACTS.md` lists the source in the code or
  the measurement run behind each fact the paper states.
- [`Metrolist AutoMix and Queueing - Technical Paper.pdf`](Metrolist%20AutoMix%20and%20Queueing%20-%20Technical%20Paper.pdf)
  describes version 1.0, as of 14 November 2026. It stays as a record of the first design.

## AutoMix research and development

- [`AUTOMIX_REFERENCE_MIXES.md`](AUTOMIX_REFERENCE_MIXES.md) covers the reference data: what
  Spotify, Apple Music and real DJs do, the curated sample pairs, Spotify's "Mixed By" playlists and
  DJ-mixed albums, and the learned parts trained on them.
- [`AUTOMIX_BRANCH_MERGE_GUIDE.md`](AUTOMIX_BRANCH_MERGE_GUIDE.md) records what the AutoMix
  redevelopment of 21 November 2026 changed and why.
- [`../Tools/ml/README.md`](../Tools/ml/README.md) explains the Python tools for the beat model,
  the stem model, the sample gate and the queue order.

## Working on the code

- [`PROJECT_GUIDE.md`](PROJECT_GUIDE.md) is the handover guide for developers and coding agents.
  It covers the architecture, the owner's rules, the build and test commands, the current status
  and the open items.

## Pictures

`images/` holds the screenshots and the animation in the main README. All of them were taken from
the running app with a test library.
