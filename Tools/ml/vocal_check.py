"""How well the planner's guess of where someone is singing matches the vocal stem.

Without timed lyrics, `MixPlanner.Bars` guesses singing from how much of a bar's energy sits in
the middle band (20th to 80th percentile of the song, silent bars excluded). This compares that
guess, bar by bar, with the vocal segments found in the HT-Demucs vocal stem
(`stems_probe.py`, Mosaikbox's rule). Reports AUC per song and pooled, and how often the
guess would call a bar sung or unsung wrongly at a 0.5 threshold, the planner's clash cut.

Usage: vocal_check.py STEMS_DIR HOME ...
"""
import json
import os
import sys

import numpy as np

stems_dir, homes = sys.argv[1], sys.argv[2:]


def analysis(video):
    for home in homes:
        path = os.path.join(home, "Analysis", f"{video}.json")
        if os.path.exists(path):
            return json.load(open(path))
    return None


def auc(scores, labels):
    scores, labels = np.asarray(scores), np.asarray(labels)
    if labels.all() or not labels.any():
        return float("nan")
    order = np.argsort(scores, kind="mergesort")
    ranks = np.empty(len(scores))
    ranks[order] = np.arange(1, len(scores) + 1)
    pos = labels.sum()
    return (ranks[labels].sum() - pos * (pos + 1) / 2) / (pos * (len(labels) - pos))


all_scores, all_labels, per_song = [], [], []
for name in sorted(os.listdir(stems_dir)):
    video = name[:-5]
    stems = json.load(open(os.path.join(stems_dir, name)))
    track = analysis(video)
    if not track or len(track["beats"]) != stems["beats"]:
        continue
    beats = track["beats"]
    low, mid, high = (np.array(track[k]) for k in ("beatLow", "beatMid", "beatHigh"))
    if len(low) != len(beats):
        continue
    phase = track.get("downbeatPhase", 0)
    bar_starts = track.get("barStarts") or list(range(phase, len(beats), 4))
    segments = stems["vocalSegments"]
    shares, levels, labels = [], [], []
    for position, start in enumerate(bar_starts):
        end = bar_starts[position + 1] if position + 1 < len(bar_starts) else start + 4
        if end > len(beats) or end - start <= 0 or end - start > 8:
            continue
        total = low[start:end] + mid[start:end] + high[start:end]
        shares.append(float(np.mean(mid[start:end] / np.maximum(total, 1e-6))))
        levels.append(float(np.mean(total / 3)))
        t0 = beats[start]
        t1 = beats[end] if end < len(beats) else t0 + (end - start) * 60 / track["bpm"]
        covered = sum(max(0.0, min(t1, b) - max(t0, a)) for a, b in segments)
        labels.append(covered / max(1e-6, t1 - t0) >= 0.5)
    if len(shares) < 16:
        continue
    ordered = sorted(shares)
    lo = ordered[len(ordered) // 5]
    hi = max(lo + 1e-3, ordered[min(len(ordered) - 1, len(ordered) * 4 // 5)])
    guess = [0.0 if level < 0.3 else min(1.0, max(0.0, (share - lo) / (hi - lo))) for share, level in zip(shares, levels)]
    labels = np.array(labels)
    song_auc = auc(guess, labels)
    called = np.array(guess) >= 0.5
    per_song.append((video, song_auc, float((called != labels).mean()), float(labels.mean())))
    all_scores += guess
    all_labels += list(labels)

valid = [s for s in per_song if not np.isnan(s[1])]
print(f"{len(per_song)} songs, {len(all_labels)} bars, {np.mean(all_labels):.0%} of bars sung (vocal stem)")
print(f"mid-band guess against the vocal stem: pooled AUC {auc(all_scores, np.array(all_labels)):.3f}, "
      f"median song AUC {np.median([s[1] for s in valid]):.3f}")
called = np.array(all_scores) >= 0.5
labels = np.array(all_labels)
print(f"at the planner's 0.5 cut: {(called != labels).mean():.0%} of bars wrong; "
      f"misses {((~called) & labels).sum() / max(1, labels.sum()):.0%} of sung bars, "
      f"calls {(called & ~labels).sum() / max(1, (~labels).sum()):.0%} of unsung bars sung")
