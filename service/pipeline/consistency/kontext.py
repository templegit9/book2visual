"""Primary consistency backend: FLUX.1-Kontext-dev depth-1 fan-out.

Generates ONE canonical reference image per character (from `ref_sheet_prompt`),
then conditions each scene panel on that single reference via FluxKontextPipeline.
Crucially this is DEPTH-1: every panel is generated from the original reference,
never chained panel->panel (Kontext drifts after ~5-6 chained edits).

diffusers/torch are imported LAZILY inside methods so this module never triggers
those heavy deps when the service runs in stub mode.
"""
from __future__ import annotations

from typing import Dict, List

from app import config

# Style prefix shared by both backends. An anime style LoRA is also loaded on
# top of FLUX (FLUX has a photoreal bias; style words alone are insufficient).
STYLE_PREFIX = "colored anime still, manga panel, vibrant colors, detailed linework"


class KontextBackend:
    def __init__(self, anime_lora: str | None = None) -> None:
        self.anime_lora = anime_lora or config.ANIME_LORA
        self._base_pipe = None  # FluxPipeline for reference generation
        self._kontext_pipe = None  # FluxKontextPipeline for conditioned panels

    def load(self) -> None:
        """Load FLUX base + Kontext pipelines and apply the anime style LoRA.

        Both pipelines use ``enable_model_cpu_offload`` rather than ``.to("cuda")``:
        this backend holds TWO ~24GB FLUX transformers (base for references,
        Kontext for panels), and a vLLM sidecar already reserves a chunk of the
        same GPU. Pinning both fully resident OOMs an 80GB card. CPU offload keeps
        the weights in host RAM and pages only the active module onto the GPU, so
        peak VRAM is ~one transformer at a time. Slower per image, but it fits
        alongside vLLM. (Set BOOK2VISUAL_FLUX_RESIDENT=1 to force full-GPU load on
        a dedicated, no-sidecar card.)
        """
        import torch  # noqa: F401  (lazy)
        from diffusers import FluxKontextPipeline, FluxPipeline

        dtype = torch.bfloat16
        resident = config.FLUX_RESIDENT

        self._base_pipe = FluxPipeline.from_pretrained(
            config.FLUX_BASE_MODEL, torch_dtype=dtype
        )
        self._base_pipe.load_lora_weights(self.anime_lora)

        self._kontext_pipe = FluxKontextPipeline.from_pretrained(
            config.FLUX_KONTEXT_MODEL, torch_dtype=dtype
        )
        # Compose the anime style LoRA with Kontext (the #1 open risk validated
        # by the consistency spike). If it degrades identity, switch to `lora`.
        self._kontext_pipe.load_lora_weights(self.anime_lora)

        if resident:
            self._base_pipe.to("cuda")
            self._kontext_pipe.to("cuda")
        else:
            self._base_pipe.enable_model_cpu_offload()
            self._kontext_pipe.enable_model_cpu_offload()

    def unload(self) -> None:
        import gc

        self._base_pipe = None
        self._kontext_pipe = None
        gc.collect()
        try:
            import torch

            torch.cuda.empty_cache()
        except Exception:
            pass

    def build_reference(self, ref_sheet_prompt: str):
        """Generate one canonical reference image (PIL.Image) for a character."""
        prompt = f"{STYLE_PREFIX}, {ref_sheet_prompt}"
        out = self._base_pipe(
            prompt=prompt,
            width=config.PANEL_SIZE,
            height=config.PANEL_SIZE,
            num_inference_steps=28,
            guidance_scale=3.5,
        )
        return out.images[0]

    def render_panel(self, image_prompt: str, references: List):
        """Render a scene panel conditioned on the (first) character reference.

        Depth-1: the conditioning image is always an ORIGINAL reference sheet,
        never a previously generated panel.
        """
        prompt = f"{STYLE_PREFIX}, {image_prompt}"
        # Kontext conditions on a single image; use the primary present character.
        condition_image = references[0] if references else None
        out = self._kontext_pipe(
            prompt=prompt,
            image=condition_image,
            width=config.PANEL_SIZE,
            height=config.PANEL_SIZE,
            num_inference_steps=28,
            guidance_scale=3.5,
        )
        return out.images[0]
