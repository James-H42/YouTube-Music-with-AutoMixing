"""Lists the largest constants in the exported Beat This! graph (to keep the Core ML model small)."""
import torch
from beat_this.inference import load_model

import convert  # applies the SumHead patch

model = convert.Wrapper(load_model("small0", device="cpu").eval()).eval()
params = sum(p.numel() for p in model.parameters())
print("parameters:", params)
exported = torch.export.export(model, (torch.randn(1, convert.CHUNK, convert.MELS),))
sizes = []
for name, value in list(exported.constants.items()) + list(exported.state_dict.items()):
    if isinstance(value, torch.Tensor):
        sizes.append((value.numel(), name, tuple(value.shape)))
for numel, name, shape in sorted(sizes, reverse=True)[:12]:
    print(f"{numel * 4 / 1e6:9.1f} MB  {name}  {shape}")
