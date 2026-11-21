"""Compares the app's stems (`Metrolist --stemtest FILE START DIR`) with HT-Demucs in PyTorch on
the very same 44.1 kHz input. PASS needs every stem within 40 dB SDR of the reference, which is
far below anything audible; float32 Core ML and float64 DFTs usually agree to 60 dB or more.

Usage: check_stems.py DIR
"""
import sys

import numpy as np
import torch
from demucs.pretrained import get_model

from convert_demucs import host_combine, host_spec

folder = sys.argv[1]
model = get_model("htdemucs").models[0].eval()
read = lambda name: np.fromfile(f"{folder}/{name}.f32", dtype=np.float32)
mix = torch.from_numpy(np.stack([read("input-L"), read("input-R")]))[None]
with torch.no_grad():
    reference = model(mix)[0].numpy()
worst = float("inf")
for index, source in enumerate(model.sources):
    ours = np.stack([read(f"{source}-L"), read(f"{source}-R")])
    target = reference[index]
    sdr = 10 * np.log10((target ** 2).sum() / max(((target - ours) ** 2).sum(), 1e-20))
    worst = min(worst, sdr)
    print(f"  {source:7} SDR against PyTorch {sdr:6.1f} dB  (level {10 * np.log10((target ** 2).mean() + 1e-12):6.1f} dB)")
print("PASS" if worst >= 40 else "FAIL", f"worst {worst:.1f} dB")
