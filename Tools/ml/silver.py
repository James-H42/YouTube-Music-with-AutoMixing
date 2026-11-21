"""Writes development reference labels ("silver" labels) with the pretrained Beat This! model.

Usage:
    .venv/bin/python silver.py WAV_DIR OUT_DIR [--checkpoint final0] [--device mps]

WAV_DIR holds 22.05 kHz mono files written by the app (`Metrolist --dumppcm WAV_DIR`), so the
labels line up with the app's own decoding. Each label file is OUT_DIR/<videoId>.json in the
format `Metrolist --analysisaudit` reads. These labels come from a model, not from a person:
use them to develop and compare, and confirm the ones that matter by ear.
"""

import argparse
import json
import pathlib
import statistics

import numpy as np
import soundfile as sf
import torch
from beat_this.inference import Audio2Beats

BEAT_THIS_COMMIT = "b95c8ab"


def summarise(beats: np.ndarray, downbeats: np.ndarray) -> dict:
    intervals = np.diff(beats)
    # Tempo from the mean of the beat intervals near the median one: the median alone is rounded
    # to the 20 ms frame (several BPM out at speed), and a line fit through beat numbers is
    # thrown off by any gap where the model found no beats.
    if len(intervals):
        median = float(np.median(intervals))
        typical = intervals[np.abs(intervals / median - 1) <= 0.1]
        bpm = 60.0 / float(np.mean(typical if len(typical) else intervals))
    else:
        bpm = 0.0
    # Beats per bar: how many beats fall between consecutive downbeats.
    counts = []
    for start, end in zip(downbeats[:-1], downbeats[1:]):
        counts.append(int(np.sum((beats >= start - 0.02) & (beats < end - 0.02))))
    meter = statistics.mode(counts) if counts else None
    # Bars whose length differs from the common one (pickups, 2-beat bars, meter changes).
    odd_bars = [round(float(downbeats[i]), 3) for i, c in enumerate(counts) if meter and c != meter]
    # Tempo changes: 16-beat windows whose median beat length moves more than 4 %.
    changes = []
    window = 16
    previous = None
    for start in range(0, max(0, len(intervals) - window), window // 2):
        local = 60.0 / float(np.median(intervals[start:start + window]))
        if previous and abs(local / previous - 1) > 0.04:
            changes.append({"time": round(float(beats[start]), 3), "bpm": round(local, 2)})
        previous = local
    return {"bpm": round(bpm, 3), "meter": meter, "oddBars": odd_bars, "tempoChanges": changes}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("wav_dir")
    parser.add_argument("out_dir")
    parser.add_argument("--checkpoint", default="final0")
    parser.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()

    out = pathlib.Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    tracker = Audio2Beats(checkpoint_path=args.checkpoint, device=args.device, dbn=False)
    for wav in sorted(pathlib.Path(args.wav_dir).glob("*.wav")):
        target = out / f"{wav.stem}.json"
        if target.exists() and not args.overwrite:
            continue
        signal, rate = sf.read(wav, dtype="float32")
        beats, downbeats = tracker(signal, rate)
        beats = np.asarray(beats, dtype=float)
        downbeats = np.asarray(downbeats, dtype=float)
        if len(beats) < 16:
            print(f"{wav.stem}: only {len(beats)} beats, skipped")
            continue
        label = {
            "source": f"beat_this:{args.checkpoint}@{BEAT_THIS_COMMIT}",
            "beats": [round(float(b), 4) for b in beats],
            "downbeats": [round(float(d), 4) for d in downbeats],
            **summarise(beats, downbeats),
        }
        target.write_text(json.dumps(label))
        print(f"{wav.stem}: {label['bpm']:.1f} BPM, meter {label['meter']}, "
              f"{len(label['oddBars'])} odd bars, {len(label['tempoChanges'])} tempo changes")


if __name__ == "__main__":
    main()
