"""VRAM load strategies: concurrent vs sequenced.

VRAM math (approximate, bf16/AWQ on an 80GB A100):
  - Qwen2.5-32B-Instruct-AWQ (4-bit) weights ~= 18-20GB + KV cache/activations
    -> ~24-28GB resident under vLLM.
  - FLUX.1-dev / FLUX.1-Kontext-dev (transformer + T5-XXL + VAE, bf16)
    -> ~30-33GB resident.
  Concurrent total ~= 54-61GB -> fits 80GB with headroom.

Strategies:
  - "concurrent": LLM (vLLM sidecar) and FLUX both resident; the pipeline
    interleaves per scene (extract once, then render). Lowest latency, needs 80GB.
  - "sequenced": run the ENTIRE text stage first, free the LLM (stop/scale-down
    the vLLM sidecar), THEN load FLUX and render all panels. Needed when the GPU
    can't hold both (e.g. 48GB A6000, or a 14B LLM + CPU offload).

Because vLLM runs as a separate process (sidecar), "freeing the LLM" in the
sequenced strategy is an operational action on that sidecar, not an in-process
unload. This module documents the contract and provides the FLUX-side
load/unload hooks used by image_stage.
"""
from __future__ import annotations

from typing import Literal

VramMode = Literal["concurrent", "sequenced"]


class LoadStrategy:
    def __init__(self, mode: VramMode) -> None:
        self.mode = mode

    @property
    def free_llm_before_images(self) -> bool:
        """In sequenced mode the LLM should be freed before FLUX is loaded."""
        return self.mode == "sequenced"

    @property
    def keep_flux_resident(self) -> bool:
        """In concurrent mode FLUX stays resident across the whole job."""
        return self.mode == "concurrent"
