"""Deterministic, no-GPU stub pipeline.

Produces a canned SceneList (>=8 scenes including one pivotal) and PIL-drawn
placeholder panels (solid color + scene title + caption text) so the assembly
stage yields a real, multi-page output.zip. This is what makes the service
runnable and testable on a GPU-less Mac.
"""
from __future__ import annotations

import asyncio
import hashlib
from typing import Dict, List, Tuple

from PIL import Image, ImageDraw

from app import config
from app.models import JobRequest, Scene, SceneCharacter, SceneList
from pipeline.fonts import load_font

# A fixed palette so panels are visually distinct and deterministic.
_PALETTE = [
    (78, 121, 167),
    (242, 142, 43),
    (225, 87, 89),
    (118, 183, 178),
    (89, 161, 79),
    (237, 201, 72),
    (176, 122, 161),
    (255, 157, 167),
    (156, 117, 95),
    (186, 176, 172),
    (100, 100, 160),
    (160, 100, 100),
]


def stub_scene_list(req: JobRequest) -> SceneList:
    """Build a deterministic SceneList seeded by the request's characters."""
    names = [c.name for c in req.characters] or ["Protagonist"]
    primary = names[0]
    secondary = names[1] if len(names) > 1 else names[0]

    characters = [
        SceneCharacter(
            name=c.name,
            appearance_prompt=(
                f"{c.name}, {c.race_hint or 'character'}, consistent anime design, "
                "distinct silhouette and color palette"
            ),
            ref_sheet_prompt=(
                f"character reference sheet of {c.name}, full body, neutral pose, "
                f"{c.race_hint or 'anime character'}, colored anime style, clean background"
            ),
        )
        for c in req.characters
    ]

    # 9 scenes, scene 4 is pivotal -> gets a full page.
    raw = [
        ("The Waking", f"{primary} wakes to an unfamiliar dawn.", [primary], False),
        ("The Threshold", f"{primary} steps past the door into the unknown.", [primary], False),
        ("The Meeting", f"{primary} encounters {secondary}.", names, False),
        ("The Pact", f"{primary} and {secondary} strike a fragile bargain.", names, False),
        ("The Turning", f"Everything changes for {primary} in a single breath.", names, True),
        ("The Pursuit", f"{primary} is chased through narrow streets.", [primary], False),
        ("The Reckoning", f"{secondary} reveals a hidden truth.", names, False),
        ("The Descent", f"{primary} falls toward an inevitable end.", [primary], False),
        ("The Dawn", f"{primary} stands at last in quiet light.", [primary], False),
    ]
    scenes: List[Scene] = []
    for i, (title, prompt, present, pivotal) in enumerate(raw):
        caption = prompt
        if len(caption) > 200:
            caption = caption[:197] + "..."
        scenes.append(
            Scene(
                index=i,
                title=title,
                image_prompt=(
                    f"colored anime still, {prompt} {', '.join(present)}"
                ),
                characters_present=present,
                caption=caption,
                pivotal=pivotal,
            )
        )
    return SceneList(characters=characters, scenes=scenes)


def _color_for(key: str) -> Tuple[int, int, int]:
    h = int(hashlib.sha256(key.encode("utf-8")).hexdigest(), 16)
    return _PALETTE[h % len(_PALETTE)]


def _draw_placeholder(text_lines: List[str], color, size: int) -> Image.Image:
    img = Image.new("RGB", (size, size), color)
    draw = ImageDraw.Draw(img)
    font = load_font(int(size * 0.05))
    y = int(size * 0.08)
    for line in text_lines:
        draw.text((int(size * 0.06), y), line, fill=(255, 255, 255), font=font)
        y += int(size * 0.08)
    # Border so panel edges are visible in the grid.
    draw.rectangle([0, 0, size - 1, size - 1], outline=(255, 255, 255), width=3)
    return img


class StubImageRunner:
    """Mirrors the real ImageRunner interface but draws placeholders on CPU."""

    async def build_references(self, scene_list: SceneList) -> Dict[str, Image.Image]:
        refs: Dict[str, Image.Image] = {}
        for ch in scene_list.characters:
            # Tiny simulated latency so SSE event ordering is observable.
            await asyncio.sleep(0)
            refs[ch.name] = _draw_placeholder(
                ["REF SHEET", ch.name], _color_for("ref:" + ch.name), config.PANEL_SIZE
            )
        return refs

    async def render_panel(
        self, scene: Scene, references: Dict[str, Image.Image]
    ) -> Image.Image:
        await asyncio.sleep(0)
        lines = [
            f"SCENE {scene.index + 1}",
            scene.title or "",
            "PIVOTAL" if scene.pivotal else "",
        ]
        lines = [l for l in lines if l]
        return _draw_placeholder(
            lines, _color_for(f"scene:{scene.index}"), config.PANEL_SIZE
        )
