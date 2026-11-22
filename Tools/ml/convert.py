"""Converts a Beat This! checkpoint to a Core ML model the app can run, and exports the exact
front-end constants (window and mel filterbank) the app must use to build its input.

Usage:
    .venv/bin/python convert.py [--checkpoint small0] [--out ../../Models]

Writes:
    OUT/BeatThis.mlpackage      input "spect" [1, 1500, 128] (log-mel), outputs "beat" and
                                "downbeat" logits [1, 1500]
    OUT/BeatThis-window.f32     1024 float32 (periodic Hann)
    OUT/BeatThis-mel.f32        513 x 128 float32 (row-major, frequency bins x mel bands)
    OUT/BeatThis.json           front-end parameters and provenance
"""

import argparse
import json
import pathlib

import coremltools as ct
import numpy as np
import torch
import torchaudio
from beat_this.inference import load_model
from beat_this.model.beat_tracker import SumHead

CHUNK = 1500
MELS = 128
BEAT_THIS_COMMIT = "b95c8ab"


def _sum_head_forward(self, x):
    # Same maths as beat_this.model.beat_tracker.SumHead.forward, without the autocast guard
    # (which torch.export can't trace; conversion runs in float32 anyway).
    beat_downbeat = self.beat_downbeat_lin(x)
    beat, downbeat = beat_downbeat[..., 0], beat_downbeat[..., 1]
    return {"beat": beat + downbeat, "downbeat": downbeat}


SumHead.forward = _sum_head_forward


class Wrapper(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, spect):
        out = self.model(spect)
        return out["beat"], out["downbeat"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", default="small0")
    parser.add_argument("--out", default="../../Models")
    parser.add_argument("--precision", default="float32", choices=["float32", "float16"])
    args = parser.parse_args()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    model = load_model(args.checkpoint, device="cpu").eval()
    wrapper = Wrapper(model).eval()
    example = torch.randn(1, CHUNK, MELS)
    with torch.no_grad():
        reference = wrapper(example)
        # torch.export fixes every shape at the static chunk size, so the rotary-position code's
        # shape arithmetic becomes constants (tracing leaves int casts Core ML can't convert).
        exported = torch.export.export(wrapper, (example,)).run_decompositions()
        # Core ML has no "alias" op; an alias is the identity, so splice it out of the graph.
        graph = exported.graph_module.graph
        for node in list(graph.nodes):
            if node.op == "call_function" and "alias" in str(node.target):
                node.replace_all_uses_with(node.args[0])
                graph.erase_node(node)
        exported.graph_module.recompile()
    # Constant folding would expand the rotary-position tables to full activation shapes in
    # every layer and store them as weights (about 1 GB). Keep them as small computed ops.
    # Small constants (such as batch-norm parameters cast to fp16) must still be folded.
    pipeline = ct.PassPipeline.DEFAULT
    pipeline.set_options("common::const_elimination", {"skip_const_by_size": "100000"})
    mlmodel = ct.convert(
        exported,
        outputs=[ct.TensorType(name="beat"), ct.TensorType(name="downbeat")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16 if args.precision == "float16" else ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
        pass_pipeline=pipeline,
    )
    mlmodel.short_description = f"Beat This! ({args.checkpoint}, CPJKU, MIT licence) beat and downbeat logits at 50 fps"
    mlmodel.save(str(out / "BeatThis.mlpackage"))

    prediction = mlmodel.predict({"spect": example.numpy()})
    for name, ref in zip(("beat", "downbeat"), reference):
        diff = np.abs(prediction[name].reshape(-1) - ref.numpy().reshape(-1)).max()
        print(f"{name}: max |coreml - torch| = {diff:.5f}")

    # Front-end constants, taken from the same torchaudio objects Beat This! uses.
    mel = torchaudio.transforms.MelSpectrogram(
        sample_rate=22050, n_fft=1024, hop_length=441, f_min=30, f_max=11000, n_mels=MELS,
        mel_scale="slaney", normalized="frame_length", power=1,
    )
    window = mel.spectrogram.window.numpy().astype(np.float32)
    filterbank = mel.mel_scale.fb.numpy().astype(np.float32)  # (513, 128)
    window.tofile(out / "BeatThis-window.f32")
    filterbank.tofile(out / "BeatThis-mel.f32")
    (out / "BeatThis.json").write_text(json.dumps({
        "checkpoint": args.checkpoint, "beatThisCommit": BEAT_THIS_COMMIT, "precision": args.precision,
        "sampleRate": 22050, "nFFT": 1024, "hop": 441, "fps": 50, "mels": MELS, "chunk": CHUNK, "border": 6,
        "center": "reflect", "normalized": "frame_length", "power": 1, "logMultiplier": 1000,
        "window": "BeatThis-window.f32", "filterbank": "BeatThis-mel.f32 (513 x 128, row-major)",
    }, indent=2))
    print("saved", out / "BeatThis.mlpackage", "window", window.shape, "filterbank", filterbank.shape)


if __name__ == "__main__":
    main()
