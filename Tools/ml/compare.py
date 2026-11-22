"""Compares two label folders (for example the small model against the full one) per style group.

Usage: .venv/bin/python compare.py REFERENCE_DIR OTHER_DIR GROUPS_CSV
"""
import collections
import json
import pathlib
import sys

import mir_eval
import numpy as np

reference, other, groups_file = (pathlib.Path(p) for p in sys.argv[1:4])
groups = {}
for line in groups_file.read_text(encoding="utf-8").splitlines():
    if line.strip() and not line.startswith("#"):
        fields = line.split(",")
        groups[fields[0]] = fields[1]
scores = collections.defaultdict(list)
for path in sorted(reference.glob("*.json")):
    twin = other / path.name
    if not twin.exists():
        continue
    a, b = json.loads(path.read_text()), json.loads(twin.read_text())
    beat = mir_eval.beat.f_measure(np.array(a["beats"]), np.array(b["beats"]))
    down = mir_eval.beat.f_measure(np.array(a["downbeats"]), np.array(b["downbeats"]))
    group = groups.get(path.stem, "ungrouped")
    scores[group].append((beat, down))
    scores["ALL"].append((beat, down))
for group in sorted(scores):
    values = np.array(scores[group])
    print(f"{group:12} {len(values):4d} songs  beat F {values[:, 0].mean():.3f}  downbeat F {values[:, 1].mean():.3f}"
          f"  (downbeat F < 0.8: {int((values[:, 1] < 0.8).sum())})")
