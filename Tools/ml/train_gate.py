"""Trains AutoMix's sample gate from `Metrolist --mixaudit --features` output.

The gate answers one question for a pair of songs: is the best match the similarity search found
at *another speed* real shared material (a sample, a remix, a replayed record), or chance? Without
a database link the planner used to accept such a match whenever it stood 4.5 standard deviations
above the same-speed alignments; that fired on about a third of unrelated pairs.

Labels come from the reference sets (docs/AUTOMIX_REFERENCE_MIXES.md):
  positive  common:sample / common:interpolation / common:mashup, sample, dj-sample,
            interpolation, dj-version, and the approved pairs that are known samples
  negative  random style-group pairs, the owner's play history, DJ-adjacent pairs (Spotify
            "Mixed By", mix albums, dj-recurring, soulmix), common:blend, other approved pairs

Model: L2-regularised logistic regression on standardised features. With a few dozen positives
anything bigger overfits. Folds are grouped by song (pairs sharing a song stay together) and
repeated with several seeds.

Usage: train_gate.py OUT.json FEATURES.tsv ... [--task stretched|same] [--fpr 0.05]
"""
import argparse
import collections
import csv
import json
import math
import random

import numpy as np

POSITIVE = {"common:sample", "common:interpolation", "common:mashup", "sample", "dj-sample", "interpolation", "dj-version"}
APPROVED_SAMPLES = {("y32ejtuxSjM", "GTmbyuTKT_c"), ("dBLzh47wdrU", "V4HdD2Fu_64"), ("JhulBGMA7G4", "2ulp_AMut14")}

STRETCHED = {
    "core": ["variantStandout", "pitchMargin", "coverage", "tone"],
    "core+tape": ["variantStandout", "pitchMargin", "coverage", "tone", "tapeDeviation", "semitoneFit"],
    "all": ["value", "standout", "variantStandout", "pitchMargin", "coverage", "tapeDeviation", "semitoneFit",
            "logStretch", "entryLog", "tone", "keysAgree", "record"],
    "old": ["standout"],
}
SAME = {
    "core": ["sameStandout", "sameCoverage", "sameTone"],
    "all": ["sameValue", "sameStandout", "sameCoverage", "sameTone", "sameEntryLog"],
    "old": ["sameStandout"],
}


def kind_of(group):
    group = group.split("~", 1)[0]  # "~rate:semitones" marks an augmented copy
    if group.startswith("common:"):
        return group
    return group.split(":", 1)[0]


def load(paths):
    pairs = {}
    for path in paths:
        with open(path, encoding="utf-8") as f:
            for row in csv.DictReader(f, delimiter="\t"):
                augmentation = row["group"].split("~", 1)[1] if "~" in row["group"] else ""
                key = (row["a"], row["b"], augmentation)
                kind = kind_of(row["group"])
                positive = kind in POSITIVE or (kind == "approved" and key in APPROVED_SAMPLES)
                record = {k: (float(v) if k not in ("group", "a", "b", "reason") else v) for k, v in row.items()}
                record["entryLog"] = math.log1p(record["entry"])
                record["sameEntryLog"] = math.log1p(record["sameEntry"])
                record["kind"] = kind
                record["label"] = 1 if positive else 0
                if key in pairs and pairs[key]["label"] >= record["label"]:
                    continue
                pairs[key] = record
    return list(pairs.values())


def song_groups(rows):
    parent = {}

    def find(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for r in rows:
        parent[find(r["a"])] = find(r["b"])
    return [find(r["a"]) for r in rows]


def fit(x, y, l2, weights=None):
    """Logistic regression by Newton's method; returns (w, b) on standardised x."""
    n, d = x.shape
    weights = np.ones(n) if weights is None else weights
    w = np.zeros(d)
    b = math.log((y @ weights + 1) / ((1 - y) @ weights + 1))
    for _ in range(50):
        z = x @ w + b
        p = 1 / (1 + np.exp(-z))
        g_w = x.T @ (weights * (p - y)) + l2 * w
        g_b = np.sum(weights * (p - y))
        s = weights * p * (1 - p)
        h = np.zeros((d + 1, d + 1))
        h[:d, :d] = x.T @ (x * s[:, None]) + l2 * np.eye(d)
        h[:d, d] = h[d, :d] = x.T @ s
        h[d, d] = s.sum() + 1e-9
        step = np.linalg.solve(h, np.concatenate([g_w, [g_b]]))
        w -= step[:d]
        b -= step[d]
        if np.abs(step).max() < 1e-8:
            break
    return w, b


def auc(scores, y):
    order = np.argsort(scores)
    ranks = np.empty(len(scores))
    ranks[order] = np.arange(1, len(scores) + 1)
    pos = y == 1
    if pos.sum() == 0 or (~pos).sum() == 0:
        return float("nan")
    return (ranks[pos].sum() - pos.sum() * (pos.sum() + 1) / 2) / (pos.sum() * (~pos).sum())


def threshold_for(scores, y, fpr):
    negatives = np.sort(scores[y == 0])
    if len(negatives) == 0:
        return float(scores.min())
    index = min(len(negatives) - 1, int(math.ceil((1 - fpr) * len(negatives))))
    return float(negatives[index])


def cross_validate(rows, features, l2, folds=5, repeats=8):
    x = np.array([[r[f] for f in features] for r in rows])
    y = np.array([r["label"] for r in rows], dtype=float)
    groups = song_groups(rows)
    unique = sorted(set(groups))
    out_of_fold = np.zeros((repeats, len(rows)))
    for repeat in range(repeats):
        rng = random.Random(repeat)
        shuffled = unique[:]
        rng.shuffle(shuffled)
        fold_of = {g: i % folds for i, g in enumerate(shuffled)}
        fold = np.array([fold_of[g] for g in groups])
        for k in range(folds):
            train, test = fold != k, fold == k
            if y[train].sum() == 0:
                continue
            mean, scale = x[train].mean(0), x[train].std(0) + 1e-9
            # Balance the classes so a handful of positives isn't drowned out.
            weight = np.where(y[train] == 1, (1 - y[train]).sum() / max(1, y[train].sum()), 1.0)
            w, b = fit((x[train] - mean) / scale, y[train], l2, weight)
            out_of_fold[repeat, test] = (x[test] - mean) / scale @ w + b
    return out_of_fold, y


def report(name, scores, y, fpr):
    aucs = [auc(s, y) for s in scores]
    tprs, fprs = [], []
    for s in scores:
        t = threshold_for(s, y, fpr)
        tprs.append(((s > t) & (y == 1)).sum() / max(1, (y == 1).sum()))
        fprs.append(((s > t) & (y == 0)).sum() / max(1, (y == 0).sum()))
    print(f"  {name:12} AUC {np.mean(aucs):.3f} ± {np.std(aucs):.3f}   at ≤{fpr:.0%} false: caught {np.mean(tprs):.0%} of positives (false {np.mean(fprs):.1%})")
    return np.mean(aucs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("features", nargs="+")
    parser.add_argument("--task", default="stretched", choices=["stretched", "same"])
    parser.add_argument("--fpr", type=float, default=0.05)
    parser.add_argument("--l2", type=float, default=1.0)
    parser.add_argument("--set", default=None, help="feature set to ship (default: best by cross-validation)")
    args = parser.parse_args()

    rows = load(args.features)
    if args.task == "stretched":
        rows = [r for r in rows if r["stretched"] == 1]
        sets = STRETCHED
    else:
        # Same-speed question: only pairs at roughly the same tempo can share material at one speed.
        rows = [r for r in rows if abs(r["ratio"] - 1) <= 0.12 and r["sameValue"] != 0]
        sets = SAME
    y_all = np.array([r["label"] for r in rows])
    print(f"{args.task}: {len(rows)} pairs, {int(y_all.sum())} positive, {int((1 - y_all).sum())} negative")
    by_kind = collections.Counter((r["kind"], r["label"]) for r in rows)
    print("  by kind:", ", ".join(f"{k}{'+' if l else ''} {n}" for (k, l), n in sorted(by_kind.items())))

    # The old rule, as the planner applied it without a link (value must also be admissible).
    if args.task == "stretched":
        old = np.array([(r["standout"] >= 4.5 and r["value"] >= 0.42) or r["record"] == 1 for r in rows], dtype=float)
        fired = np.array([r["reason"] == "sample" for r in rows])
    else:
        old = np.array([r["sameStandout"] >= 4 for r in rows], dtype=float)
        fired = np.array([r["reason"] in ("similarity", "knownSample") for r in rows])
    for name, decision in (("old rule", old), ("old plans", fired.astype(float))):
        tpr = ((decision == 1) & (y_all == 1)).sum() / max(1, (y_all == 1).sum())
        fpr = ((decision == 1) & (y_all == 0)).sum() / max(1, (y_all == 0).sum())
        print(f"  {name:12} caught {tpr:.0%} of positives, fired on {fpr:.1%} of negatives")

    results = {}
    for name, features in sets.items():
        for l2 in (0.3, 1.0, 3.0, 10.0):
            scores, y = cross_validate(rows, features, l2)
            results[(name, l2)] = report(f"{name} l2={l2:g}", scores, y, args.fpr)
    chosen = args.set or max((k for k in results if k[0] != "old"), key=lambda k: results[k])[0]
    l2 = max((k for k in results if k[0] == chosen), key=lambda k: results[k])[1]
    features = sets[chosen]

    # Final fit on everything; threshold from the pooled out-of-fold scores of the same setup.
    scores, y = cross_validate(rows, features, l2)
    pooled_threshold = float(np.median([threshold_for(s, y, args.fpr) for s in scores]))
    x = np.array([[r[f] for f in features] for r in rows])
    mean, scale = x.mean(0), x.std(0) + 1e-9
    weight = np.where(y == 1, (1 - y).sum() / max(1, y.sum()), 1.0)
    w, b = fit((x - mean) / scale, y, l2, weight)
    final = (x - mean) / scale @ w + b
    print(f"\nchosen: {chosen}, l2={l2:g}; threshold (logit) {pooled_threshold:.3f}")
    for f, value in zip(features, w):
        print(f"  {f:16} weight {value:+.3f}")
    caught = ((final > pooled_threshold) & (y == 1)).sum()
    false = ((final > pooled_threshold) & (y == 0)).sum()
    print(f"  in-sample: caught {caught} of {int(y.sum())} positives, fired on {false} of {int((1 - y).sum())} negatives")
    print("  positives missed:", ", ".join(f"{r['kind']} {r['a']}→{r['b']} ({s:.2f})" for r, s in zip(rows, final) if r["label"] == 1 and s <= pooled_threshold))
    print("  negatives passed:", ", ".join(f"{r['kind']} {r['a']}→{r['b']} ({s:.2f})" for r, s in zip(rows, final) if r["label"] == 0 and s > pooled_threshold))
    json.dump({"task": args.task, "features": features, "mean": mean.tolist(), "scale": scale.tolist(),
               "weights": w.tolist(), "bias": float(b), "threshold": pooled_threshold, "l2": l2,
               "positives": int(y.sum()), "negatives": int((1 - y).sum()), "fpr": args.fpr},
              open(args.out, "w"), indent=1)


if __name__ == "__main__":
    main()
