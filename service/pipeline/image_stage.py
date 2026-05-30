"""Image stage: canonical reference per character, then depth-1 panel fan-out.

Selects the consistency backend from JobRequest.consistency_mode:
  - "kontext" -> KontextBackend (FLUX.1-Kontext-dev, identity from one reference)
  - "lora"    -> LoraBackend (per-character anime LoRA on FluxPipeline)

Reference images are generated ONCE per character; every scene panel is
conditioned on the ORIGINAL reference(s) for the characters present — never on a
previously generated panel (depth-1 fan-out). diffusers/torch are imported
lazily inside the backend modules, so importing this module is cheap and the
heavy deps are only touched when STUB_MODE is off.

This module's ImageRunner mirrors the StubImageRunner interface
(``build_references`` / ``render_panel``) used by the orchestrator.
"""
from __future__ import annotations

import asyncio
from typing import Dict, List

from app.models import JobRequest, Scene, SceneList
from .vram import LoadStrategy

STYLE_PREFIX = "colored anime still, manga panel, vibrant colors, detailed linework"


class ImageRunner:
    def __init__(self, req: JobRequest) -> None:
        self.req = req
        self.strategy = LoadStrategy(req.vram_mode)
        self.backend = self._make_backend(req.consistency_mode)
        self._loaded = False

    @staticmethod
    def _make_backend(consistency_mode: str):
        if consistency_mode == "lora":
            from .consistency.lora import LoraBackend

            return LoraBackend()
        from .consistency.kontext import KontextBackend

        return KontextBackend()

    def _ensure_loaded(self) -> None:
        if not self._loaded:
            self.backend.load()
            self._loaded = True

    async def build_references(self, scene_list: SceneList) -> Dict[str, object]:
        """Generate one canonical reference image per character (off the event loop)."""

        def _work() -> Dict[str, object]:
            self._ensure_loaded()
            refs: Dict[str, object] = {}
            for ch in scene_list.characters:
                refs[ch.name] = self.backend.build_reference(ch.ref_sheet_prompt)
            return refs

        return await asyncio.to_thread(_work)

    async def render_panel(self, scene: Scene, references: Dict[str, object]):
        """Render one panel conditioned on the present characters' references."""

        def _work():
            self._ensure_loaded()
            present_refs = [
                references[name]
                for name in scene.characters_present
                if name in references
            ]
            # Kontext conditions on the reference image(s); LoRA selects adapters.
            from .consistency.kontext import KontextBackend

            if isinstance(self.backend, KontextBackend):
                return self.backend.render_panel(scene.image_prompt, present_refs)
            return self.backend.render_panel(
                scene.image_prompt, scene.characters_present
            )

        return await asyncio.to_thread(_work)

    def close(self) -> None:
        if self._loaded:
            self.backend.unload()
            self._loaded = False
