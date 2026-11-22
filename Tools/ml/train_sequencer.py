"""Learns how DJs pick the next song, for AutoMix's Autoplay ordering (`MixSequencer`).

Training data: DJ-made sequences (Spotify "Mixed By" playlists and DJ-mixed albums, see
docs/AUTOMIX_REFERENCE_MIXES.md), with each song analysed by the app. For every song in a
sequence, the song the DJ actually played next competes against four other songs from the same
sequence, much as the app's Autoplay pool holds five similar songs. A conditional logit model
(softmax over the pool) learns weights for tempo gap, key relation, shared artist and loudness
step. Evaluation leaves whole sequences out and reports how often the DJ's choice ranks first
of five (chance 20 %), against the hand-set `MixSequencer.fit` it would replace.

Usage: train_sequencer.py OUT.json --spotify spotify-mixed-by.tsv --albums mix-albums.tsv
         --logs queries-a.txt resolve-a.txt ... --homes /tmp/claude/refhome-a ...
"""
import argparse
import collections
import json
import math
import os
import random
import re

import numpy as np

from reference_mixes import resolved_ids

KEY_CLASSES = ["compatible", "diagonal", "shift1", "shift2", "clash"]
# Few, smooth features: a few hundred transitions can't support one weight per tempo band.
FEATURES = (["tempoGap", "tempo>12%", "tempoFree", "halfDouble"] + [f"key:{k}" for k in KEY_CLASSES]
            + ["keyUnknown", "sameArtist", "loudnessStep"])


def camelot(key, minor):
    return (((key + 3) % 12 if minor else key) * 7 % 12 + 7) % 12 + 1


def compatible(a, b, shift=0):
    key_b = (b["key"] + shift) % 12
    na, nb = camelot(a["key"], a["isMinor"]), camelot(key_b, b["isMinor"])
    distance = min((na - nb) % 12, (nb - na) % 12)
    return distance <= 1 if a["isMinor"] == b["isMinor"] else distance == 0


def key_class(a, b):
    if a["keyConfidence"] < 0.35 or b["keyConfidence"] < 0.35:
        return None
    na, nb = camelot(a["key"], a["isMinor"]), camelot(b["key"], b["isMinor"])
    steps = min((na - nb) % 12, (nb - na) % 12)
    if compatible(a, b):
        return "compatible"
    if steps == 1 and a["isMinor"] != b["isMinor"]:
        return "diagonal"
    if any(compatible(a, b, s) for s in (1, -1)):
        return "shift1"
    if any(compatible(a, b, s) for s in (2, -2)):
        return "shift2"
    return "clash"


def tempo_gap(a, b):
    if a["beatConfidence"] < 0.5 or b["beatConfidence"] < 0.5 or a["bpm"] <= 0 or b["bpm"] <= 0:
        return None, False
    gaps = {m: abs(a["bpm"] / (b["bpm"] * m) - 1) for m in (1.0, 2.0, 0.5)}
    m = min(gaps, key=gaps.get)
    return gaps[m], m != 1.0


def loudness(track):
    energy = [e for e in track["energy"] if e > 0]
    return 20 * math.log10(max(1e-6, sum(energy) / max(1, len(energy))))


def features(a, b, same_artist):
    x = dict.fromkeys(FEATURES, 0.0)
    gap, folded = tempo_gap(a, b)
    if gap is None:
        x["tempoFree"] = 1
    else:
        # Gap in units of the planner's largest stretch (12 %), capped where it stops mattering.
        x["tempoGap"] = min(gap, 0.24) / 0.12
        x["tempo>12%"] = 1.0 if gap > 0.12 else 0.0
        x["halfDouble"] = 1.0 if folded else 0.0
    k = key_class(a, b)
    if k is None:
        x["keyUnknown"] = 1
    else:
        x[f"key:{k}"] = 1
    x["sameArtist"] = 1.0 if same_artist else 0.0
    x["loudnessStep"] = min(12.0, abs(loudness(a) - loudness(b))) / 6
    return np.array([x[f] for f in FEATURES])


def hand_fit(a, b, same_artist):
    """MixSequencer.fit as shipped on 2026-11-21 (weights 0.5 tempo, 0.3 key, 0.2 artist)."""
    tempo = 0.2
    gap, _ = tempo_gap(a, b)
    if gap is not None:
        tempo = 1 - 0.6 * gap / 0.12 if gap <= 0.12 else 0
    key = 0.5
    k = key_class(a, b)
    if k is not None:
        key = {"compatible": 1, "diagonal": 0.75, "shift1": 0.7, "shift2": 0.5, "clash": 0.15}[k]
    return 0.5 * tempo + 0.3 * key + (0.2 if same_artist else 0)


def names(artists):
    return {n.strip().lower() for n in re.split(r",|&| and | x |\bfeat\.?|\bft\.?", artists) if len(n.strip()) >= 2}


def load_sequences(args):
    found = {}
    for q, log in zip(args.logs[::2], args.logs[1::2]):
        found.update({k: v[0] for k, v in resolved_ids(q, log).items()})
    analyses = {}

    def analysis(video):
        if video in analyses:
            return analyses[video]
        for home in args.homes:
            path = os.path.join(home, "Analysis", f"{video}.json")
            if os.path.exists(path):
                d = json.load(open(path))
                analyses[video] = {k: d.get(k) for k in ("bpm", "beatConfidence", "key", "isMinor", "keyConfidence", "energy", "duration")}
                return analyses[video]
        analyses[video] = None
        return None

    sequences = collections.OrderedDict()
    for line in open(args.spotify, encoding="utf-8"):
        if line.startswith("#"):
            continue
        curator, _, _, artists, title, _ = line.rstrip("\n").split("\t")
        query = f"{artists.split(',')[0].strip()} {title}"
        sequences.setdefault(("spotify", curator), []).append((query, artists))
    for line in open(args.albums, encoding="utf-8"):
        if line.startswith("#"):
            continue
        _, album, _, _, position, artists, title, _ = line.rstrip("\n").split("\t")
        disc = re.split(r"[-.]", position)[0] if re.search(r"[-.]", position) else ""
        if album == "The Annual 2006" and not disc.startswith("CD"):
            continue  # the DVD is unmixed
        sequences.setdefault(("album", f"{album} {disc}".strip()), []).append((f"{artists} {title}", artists))
    result = {}
    for key, items in sequences.items():
        songs = []
        for query, artists in items:
            video = found.get(query)
            track = analysis(video) if video else None
            songs.append((video, track, names(artists)) if track else None)
        result[key] = songs
    return result


def pools(sequences, rng, size=5):
    """(sequence, candidates, index of the true next) for every adjacent pair with both analysed."""
    out = []
    for key, songs in sequences.items():
        present = [i for i, s in enumerate(songs) if s]
        for i in range(len(songs) - 1):
            if not songs[i] or not songs[i + 1] or songs[i][0] == songs[i + 1][0]:
                continue
            others = [j for j in present if j not in (i - 1, i, i + 1) and songs[j][0] not in (songs[i][0], songs[i + 1][0])]
            if len(others) < size - 1:
                continue
            chosen = rng.sample(others, size - 1)
            out.append((key, i, [i + 1] + chosen))
    return out


def design(sequences, pool_list):
    xs, keys = [], []
    for key, i, candidates in pool_list:
        a = sequences[key][i]
        rows = [features(a[1], sequences[key][j][1], bool(a[2] & sequences[key][j][2])) for j in candidates]
        xs.append(np.array(rows))
        keys.append(key)
    return xs, keys


def train(xs, l2=1.0, steps=3000, rate=0.05):
    d = xs[0].shape[1]
    w = np.zeros(d)
    m = np.zeros(d)
    v = np.zeros(d)
    for t in range(1, steps + 1):
        grad = l2 * w
        for x in xs:
            z = x @ w
            p = np.exp(z - z.max())
            p /= p.sum()
            grad -= x[0] - p @ x  # the true next song is row 0
        grad /= len(xs)
        m = 0.9 * m + 0.1 * grad
        v = 0.999 * v + 0.001 * grad * grad
        w -= rate * (m / (1 - 0.9 ** t)) / (np.sqrt(v / (1 - 0.999 ** t)) + 1e-8)
    return w


def hits(scores_per_pool):
    first = [1.0 if np.argmax(s) == 0 and s[0] > max(s[1:]) else (1.0 / (1 + sum(s[1:] == s[0])) if s[0] >= max(s[1:]) else 0.0) for s in scores_per_pool]
    ranks = [1 + sum(other > s[0] for other in s[1:]) + 0.5 * sum(other == s[0] for other in s[1:]) for s in scores_per_pool]
    return float(np.mean(first)), float(np.mean([1 / r for r in ranks]))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--spotify", required=True)
    parser.add_argument("--albums", required=True)
    parser.add_argument("--logs", nargs="+", required=True)
    parser.add_argument("--homes", nargs="+", required=True)
    parser.add_argument("--l2", type=float, default=0.5)
    parser.add_argument("--repeats", type=int, default=5)
    args = parser.parse_args()

    sequences = load_sequences(args)
    analysed = sum(1 for s in sequences.values() for x in s if x)
    total = sum(len(s) for s in sequences.values())
    print(f"{len(sequences)} sequences, {analysed} of {total} songs analysed")

    # What DJ neighbours look like next to other songs from the same sequence.
    rng = random.Random(1)
    pool_list = pools(sequences, rng)
    xs, keys = design(sequences, pool_list)
    print(f"{len(xs)} DJ transitions with a pool of 5")
    true_rows = np.array([x[0] for x in xs])
    other_rows = np.array([row for x in xs for row in x[1:]])
    print("feature            DJ next   other   (share of pairs)")
    for index, name in enumerate(FEATURES):
        if name == "loudnessStep":
            print(f"  {name:16} {true_rows[:, index].mean() * 6:5.1f} dB {other_rows[:, index].mean() * 6:5.1f} dB")
        elif name == "tempoGap":
            print(f"  {name:16} {true_rows[:, index].mean() * 12:5.1f} %  {other_rows[:, index].mean() * 12:5.1f} %  (mean, capped at 24 %)")
        else:
            print(f"  {name:16} {true_rows[:, index].mean():6.1%}  {other_rows[:, index].mean():6.1%}")

    # Leave one sequence out, several random pools each.
    results = collections.defaultdict(list)
    per_style = collections.defaultdict(lambda: collections.defaultdict(list))
    for repeat in range(args.repeats):
        rng = random.Random(100 + repeat)
        pool_list = pools(sequences, rng)
        xs, keys = design(sequences, pool_list)
        for held in sequences:
            train_x = [x for x, k in zip(xs, keys) if k != held]
            test = [(x, i) for i, (x, k) in enumerate(zip(xs, keys)) if k == held]
            if not test or not train_x:
                continue
            w = train(train_x, args.l2, steps=600)
            for x, i in test:
                key, a_index, candidates = pool_list[i]
                a = sequences[key][a_index]
                learned = x @ w
                hand = np.array([hand_fit(a[1], sequences[key][j][1], bool(a[2] & sequences[key][j][2])) for j in candidates])
                results["learned"].append(learned)
                results["hand"].append(hand)
                per_style[held[1]]["learned"].append(learned)
                per_style[held[1]]["hand"].append(hand)
    print(f"\nheld-out sequences ({args.repeats} sets of random pools): DJ's choice ranked first of 5 / mean reciprocal rank")
    print(f"  chance            20.0% / 0.457")
    for name in ("hand", "learned"):
        top, mrr = hits(results[name])
        print(f"  {name:16} {top:6.1%} / {mrr:.3f}")
    # Paired bootstrap over sequences (resampling whole sequences, since pools within one
    # sequence are not independent): is the learned model's reciprocal rank really higher?
    def reciprocal(scores):
        return 1 / (1 + sum(other > scores[0] for other in scores[1:]) + 0.5 * sum(other == scores[0] for other in scores[1:]))
    per_sequence = [(np.mean([reciprocal(s) for s in r["learned"]]) - np.mean([reciprocal(s) for s in r["hand"]]), len(r["hand"]))
                    for r in per_style.values()]
    rng = np.random.default_rng(0)
    gains = []
    for _ in range(2000):
        sample = [per_sequence[i] for i in rng.integers(0, len(per_sequence), len(per_sequence))]
        gains.append(sum(g * n for g, n in sample) / sum(n for _, n in sample))
    low, high = np.percentile(gains, [2.5, 97.5])
    print(f"  learned - hand, mean reciprocal rank: {np.mean(gains):+.3f} (95 % interval {low:+.3f} … {high:+.3f}, bootstrap over sequences)")
    print("  per sequence (hand → learned, first of 5):")
    for seq, r in per_style.items():
        print(f"    {seq[:34]:34} {hits(r['hand'])[0]:5.0%} → {hits(r['learned'])[0]:5.0%}  ({len(r['hand'])} pools)")

    rng = random.Random(7)
    xs, _ = design(sequences, pools(sequences, rng))
    w = train(xs, args.l2)
    print("\nweights (log-odds against the other songs in a pool):")
    for name, value in zip(FEATURES, w):
        print(f"  {name:16} {value:+.3f}")
    json.dump({"features": FEATURES, "weights": w.tolist(), "l2": args.l2, "transitions": len(xs)},
              open(args.out, "w"), indent=1)


if __name__ == "__main__":
    main()
