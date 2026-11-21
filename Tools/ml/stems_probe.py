"""Separates cached songs into stems with HT-Demucs and stores what AutoMix would use from them.

For each video id: decode the cached file with ffmpeg (44.1 kHz stereo), separate it into
vocals, drums, bass and other (htdemucs, MIT licence, Rouard, Massa and Défossez, ICASSP 2023),
and write OUT/<id>.json with the RMS level of each stem on every beat of the app's own beat
grid (Analysis/<id>.json), plus vocal segments found the way Mosaikbox does (Sowula and Knees,
ISMIR 2024): split on silences of 1 s or more below -40 dBFS, drop segments under 400 ms.
No audio is kept.

Usage: stems_probe.py OUT_DIR --homes HOME ... --ids ID ... | --pairs PAIRS.tsv ...
Runs on the GPU (MPS) outside the agent sandbox.
"""
import argparse
import json
import os
import subprocess
import sys
import time

import numpy as np
import torch
from demucs.apply import apply_model
from demucs.pretrained import get_model

RATE = 44_100


def decode(path):
    run = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", "2", "-ar", str(RATE), "-"],
                         capture_output=True, check=True)
    return np.frombuffer(run.stdout, dtype=np.float32).reshape(-1, 2).T.copy()


def vocal_segments(vocals, hop=RATE // 100):
    """Mosaikbox's rule: silences of at least 1 s below -40 dBFS split the vocal stem."""
    mono = vocals.mean(0)
    frames = len(mono) // hop
    level = np.sqrt((mono[: frames * hop].reshape(frames, hop) ** 2).mean(1) + 1e-12)
    loud = 20 * np.log10(level) > -40
    segments, start, quiet_run = [], None, 0
    for index, on in enumerate(loud):
        if on:
            if start is None:
                start = index
            quiet_run = 0
        elif start is not None:
            quiet_run += 1
            if quiet_run >= 100:  # 1 s of silence ends the segment
                end = index - quiet_run + 1
                if (end - start) * hop / RATE >= 0.4:
                    segments.append([round(start * hop / RATE, 2), round(end * hop / RATE, 2)])
                start, quiet_run = None, 0
    if start is not None and (frames - start) * hop / RATE >= 0.4:
        segments.append([round(start * hop / RATE, 2), round(frames * hop / RATE, 2)])
    return segments


def per_beat(stem, beats):
    mono = stem.mean(0)
    edges = [int(t * RATE) for t in beats] + [len(mono)]
    return [round(float(np.sqrt((mono[a:b] ** 2).mean() + 1e-12)), 6) if b > a else 0.0 for a, b in zip(edges, edges[1:])]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--homes", nargs="+", required=True)
    parser.add_argument("--ids", nargs="*", default=[])
    parser.add_argument("--pairs", nargs="*", default=[])
    parser.add_argument("--model", default="htdemucs")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    ids = list(args.ids)
    for path in args.pairs:
        for line in open(path, encoding="utf-8"):
            if line.startswith("#") or not line.strip():
                continue
            fields = line.rstrip("\n").split("\t")
            ids += fields[1:3]
    ids = list(dict.fromkeys(ids))

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model = get_model(args.model)
    model.eval()
    print(f"{len(ids)} songs, model {args.model} ({model.sources}), device {device}", flush=True)
    for video in ids:
        destination = os.path.join(args.out, f"{video}.json")
        if os.path.exists(destination):
            continue
        media = analysis = None
        for home in args.homes:
            records = json.load(open(os.path.join(home, "media.json")))
            record = records.get(video)
            if record and os.path.exists(os.path.join(home, "Media", record["fileName"])):
                media = os.path.join(home, "Media", record["fileName"])
            candidate = os.path.join(home, "Analysis", f"{video}.json")
            if os.path.exists(candidate):
                analysis = json.load(open(candidate))
            if media and analysis:
                break
        if not media or not analysis:
            print(f"{video}: missing {'audio' if not media else 'analysis'}", flush=True)
            continue
        started = time.time()
        wav = torch.from_numpy(decode(media))
        reference = wav.mean(0)
        mean, std = reference.mean(), reference.std() + 1e-8
        with torch.no_grad():
            stems = apply_model(model, ((wav - mean) / std)[None], device=device, split=True, overlap=0.25, progress=False)[0]
        stems = (stems * std + mean).cpu().numpy()
        beats = analysis["beats"]
        result = {"model": args.model, "sources": model.sources, "beats": len(beats), "duration": wav.shape[1] / RATE}
        for name, stem in zip(model.sources, stems):
            result[name] = per_beat(stem, beats)
        result["vocalSegments"] = vocal_segments(stems[model.sources.index("vocals")])
        json.dump(result, open(destination, "w"))
        print(f"{video}: {wav.shape[1] / RATE:.0f} s in {time.time() - started:.1f} s, {len(result['vocalSegments'])} vocal segments", flush=True)


if __name__ == "__main__":
    sys.exit(main())
