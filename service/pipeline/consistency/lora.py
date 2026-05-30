"""Fallback consistency backend: per-character anime LoRA on FluxPipeline.

Instead of conditioning on a reference image (Kontext), this backend trains/loads
a per-character LoRA and applies the relevant character LoRA(s) when rendering a
panel. The anime style LoRA is composed on top for the colored-anime look.

In this code-first build the per-character LoRA *training* is out of scope (a
spike artifact); this module wires the inference path and the backend interface
so the orchestrator can A/B it against Kontext. diffusers/torch are imported
LAZILY so stub mode never needs them.
"""
from __future__ import annotations

from typing import Dict, List

from app import config

STYLE_PREFIX = "colored anime still, manga panel, vibrant colors, detailed linework"


class LoraBackend:
    def __init__(self, anime_lora: str | None = None) -> None:
        self.anime_lora = anime_lora or config.ANIME_LORA
        self._pipe = None
        # Map of character name -> resolved per-character LoRA weight path/id.
        self._character_loras: Dict[str, str] = {}

    def load(self) -> None:
        import torch
        from diffusers import FluxPipeline

        self._pipe = FluxPipeline.from_pretrained(
            config.FLUX_BASE_MODEL, torch_dtype=torch.bfloat16
        ).to("cuda")
        # Always-on anime style LoRA (adapter name "style").
        self._pipe.load_lora_weights(self.anime_lora, adapter_name="style")

    def unload(self) -> None:
        import gc

        self._pipe = None
        self._character_loras.clear()
        gc.collect()
        try:
            import torch

            torch.cuda.empty_cache()
        except Exception:
            pass

    def register_character_lora(self, name: str, lora_id: str) -> None:
        """Register a trained per-character LoRA (produced by the spike pipeline)."""
        self._character_loras[name] = lora_id
        self._pipe.load_lora_weights(lora_id, adapter_name=f"char_{name}")

    def build_reference(self, ref_sheet_prompt: str):
        """Reference sheet (used for parity with Kontext; the LoRA carries identity)."""
        prompt = f"{STYLE_PREFIX}, {ref_sheet_prompt}"
        self._pipe.set_adapters(["style"], adapter_weights=[1.0])
        return self._pipe(
            prompt=prompt,
            width=config.PANEL_SIZE,
            height=config.PANEL_SIZE,
            num_inference_steps=28,
            guidance_scale=3.5,
        ).images[0]

    def render_panel(self, image_prompt: str, character_names: List[str]):
        prompt = f"{STYLE_PREFIX}, {image_prompt}"
        adapters = ["style"]
        weights = [1.0]
        for name in character_names:
            if name in self._character_loras:
                adapters.append(f"char_{name}")
                weights.append(0.9)
        self._pipe.set_adapters(adapters, adapter_weights=weights)
        return self._pipe(
            prompt=prompt,
            width=config.PANEL_SIZE,
            height=config.PANEL_SIZE,
            num_inference_steps=28,
            guidance_scale=3.5,
        ).images[0]
