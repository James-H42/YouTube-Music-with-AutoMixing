"""Converts HT-Demucs (htdemucs, MIT licence, Meta) to Core ML for AutoMix's stem transitions.

Core ML gets the network only. The host (Swift, `Mix/StemSeparator.swift`) does what the model's
`_spec` and `_ispec` do: reflect padding, a 4096-point normalised STFT with hop 1024, and the
inverse. HT-Demucs predicts complex spectrograms directly (complex as channels), so no Wiener
filtering is involved. Inputs and outputs, for one 7.8 s segment (343,980 samples, 44.1 kHz):

  mix   [1, 2, 343980]          stereo waveform
  mag   [1, 4, 2048, 336]       its spectrogram, real and imaginary parts as channels
  ->
  spec  [1, 4, 4, 2048, 336]    per source (drums, bass, other, vocals): complex spectrogram
  wave  [1, 4, 2, 343980]       per source: the time branch's waveform
  stem = istft(spec) + wave

Usage: convert_demucs.py OUT_DIR [--fp16] [--check AUDIO_FILE]
"""
import argparse
import math
import os
import subprocess
import time

import numpy as np
import torch
import torch.nn.functional as F
from demucs.hdemucs import pad1d
from demucs.pretrained import get_model
from demucs.spec import ispectro, spectro
from einops import rearrange


class Core(torch.nn.Module):
    """HTDemucs.forward between `_magnitude` and `_mask` (demucs 4.0.1, htdemucs.py lines 542-656)."""

    def __init__(self, model):
        super().__init__()
        self.m = model

    def forward(self, mix, mag):
        m = self.m
        x = mag
        B, C, Fq, T = x.shape
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)
        xt = mix
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - meant) / (1e-5 + stdt)
        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * emb
            saved.append(x)
        if m.crosstransformer:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = rearrange(x, "b c f t-> b c (f t)")
                x = m.channel_upsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                x = rearrange(x, "b c f t-> b c (f t)")
                x = m.channel_downsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = m.channel_downsampler_t(xt)
        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)
        S = len(m.sources)
        x = x.view(B, S, -1, Fq, T)
        x = x * std[:, None] + mean[:, None]
        xt = xt.view(B, S, -1, mix.shape[-1])
        xt = xt * stdt[:, None] + meant[:, None]
        return x, xt


def host_spec(model, mix):
    """HTDemucs._spec followed by _magnitude (cac)."""
    hl = model.hop_length
    le = int(math.ceil(mix.shape[-1] / hl))
    pad = hl // 2 * 3
    padded = pad1d(mix, (pad, pad + le * hl - mix.shape[-1]), mode="reflect")
    z = spectro(padded, model.nfft, hl)[..., :-1, :][..., 2: 2 + le]
    B, C, Fr, T = z.shape
    mag = torch.view_as_real(z).permute(0, 1, 4, 2, 3).reshape(B, C * 2, Fr, T)
    return mag


def host_combine(model, spec, wave, length):
    """HTDemucs._mask (cac) and _ispec, then the two branches summed."""
    B, S, C, Fr, T = spec.shape
    z = torch.view_as_complex(spec.view(B, S, -1, 2, Fr, T).permute(0, 1, 2, 4, 5, 3).contiguous())
    hl = model.hop_length
    z = F.pad(z, (0, 0, 0, 1))
    z = F.pad(z, (2, 2))
    pad = hl // 2 * 3
    le = hl * int(math.ceil(length / hl)) + 2 * pad
    x = ispectro(z, hl, length=le)[..., pad: pad + length]
    return x + wave


def segment_from(path, seconds_in=60.0):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", str(seconds_in), "-t", "7.8", "-i", path, "-f", "f32le", "-ac", "2", "-ar", "44100", "-"],
                         capture_output=True, check=True).stdout
    audio = torch.from_numpy(np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).T.copy())
    return F.pad(audio, (0, 343980 - audio.shape[-1]))[None]


def sdr(reference, estimate):
    noise = ((reference - estimate) ** 2).sum()
    return float(10 * torch.log10((reference ** 2).sum() / (noise + 1e-12)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--fp16", action="store_true")
    parser.add_argument("--check", default=None, help="audio file for a parity check")
    args = parser.parse_args()

    model = get_model("htdemucs").models[0].eval()
    length = int(model.segment * model.samplerate)
    mix = segment_from(args.check) if args.check else torch.randn(1, 2, length) * 0.1
    mix = mix * 1.0
    with torch.no_grad():
        reference = model(mix)
        mag = host_spec(model, mix)
        core = Core(model).eval()
        spec, wave = core(mix, mag)
        rebuilt = host_combine(model, spec, wave, length)
    print("split-off core vs full model: max |diff|", float((reference - rebuilt).abs().max()),
          "SDR", round(sdr(reference, rebuilt), 1), "dB", flush=True)

    import coremltools as ct
    started = time.time()
    traced = torch.jit.trace(core, (mix, mag), check_trace=False)
    precision = ct.precision.FLOAT16 if args.fp16 else ct.precision.FLOAT32
    mlmodel = ct.convert(traced, convert_to="mlprogram",
                         inputs=[ct.TensorType(name="mix", shape=mix.shape), ct.TensorType(name="mag", shape=mag.shape)],
                         outputs=[ct.TensorType(name="spec"), ct.TensorType(name="wave")],
                         compute_precision=precision, minimum_deployment_target=ct.target.macOS15)
    mlmodel.author = "Rouard, Massa and Défossez (Meta), converted for Metrolist AutoMix"
    mlmodel.license = "MIT (facebookresearch/demucs)"
    mlmodel.short_description = "HT-Demucs 4-stem separation (drums, bass, other, vocals), network only; host does STFT and iSTFT."
    name = "HTDemucs16.mlpackage" if args.fp16 else "HTDemucs.mlpackage"
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, name)
    mlmodel.save(path)
    print(f"converted in {time.time() - started:.0f} s -> {path}", flush=True)

    loaded = ct.models.MLModel(path, compute_units=ct.ComputeUnit.ALL)
    started = time.time()
    output = loaded.predict({"mix": mix.numpy(), "mag": mag.numpy()})
    print(f"Core ML predict: {time.time() - started:.2f} s", flush=True)
    started = time.time()
    output = loaded.predict({"mix": mix.numpy(), "mag": mag.numpy()})
    print(f"Core ML predict (warm): {time.time() - started:.2f} s", flush=True)
    stems = host_combine(model, torch.from_numpy(output["spec"]), torch.from_numpy(output["wave"]), length)
    for index, source in enumerate(model.sources):
        print(f"  {source:7} Core ML vs PyTorch SDR {sdr(reference[0, index], stems[0, index]):.1f} dB")


if __name__ == "__main__":
    main()
