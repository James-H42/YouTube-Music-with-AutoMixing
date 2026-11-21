"""Recomputes the summary fields (bpm, meter, odd bars, tempo changes) of existing label files
from their beats and downbeats, without running the model again.

Usage: .venv/bin/python relabel.py LABEL_DIR
"""
import json
import pathlib
import sys

import numpy as np

from silver import summarise

for path in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    label = json.loads(path.read_text())
    label.update(summarise(np.asarray(label["beats"]), np.asarray(label["downbeats"])))
    path.write_text(json.dumps(label))
print("done")
