"""Assembly golden-ish tests: page count, dims, pivotal -> own page, zip of PNGs."""
from __future__ import annotations

import io
import zipfile
from pathlib import Path

from PIL import Image

from app.models import Scene
from pipeline import assembly


def _panel(size: int = 768, color=(50, 80, 120)) -> Image.Image:
    return Image.new("RGB", (size, size), color)


def _scene(i: int, pivotal: bool = False) -> Scene:
    return Scene(
        index=i,
        title=f"Scene {i}",
        image_prompt="x",
        characters_present=["A"],
        caption=f"A fairly long caption for scene {i} that should wrap across lines.",
        pivotal=pivotal,
    )


def test_grid_packs_four_per_page():
    panels = [(_scene(i), _panel()) for i in range(4)]
    pages = assembly.build_pages(panels, 768)
    assert len(pages) == 1
    assert pages[0].size == (1536, 1536)


def test_pivotal_gets_own_page_and_interrupts_grid():
    # 2 normal, 1 pivotal, 2 normal -> page1(partial flushed), pivotal page, page3
    scenes = [
        (_scene(0), _panel()),
        (_scene(1), _panel()),
        (_scene(2, pivotal=True), _panel()),
        (_scene(3), _panel()),
        (_scene(4), _panel()),
    ]
    pages = assembly.build_pages(scenes, 768)
    # page with scenes 0,1 (flushed by the pivotal) + pivotal page + page with 3,4
    assert len(pages) == 3
    for p in pages:
        assert p.size == (1536, 1536)


def test_build_output_zip(tmp_path: Path):
    panels = [(_scene(i, pivotal=(i == 4)), _panel()) for i in range(9)]
    out = tmp_path / "output.zip"
    pages = assembly.build_output_zip(panels, out, 768)
    assert out.exists()
    assert pages >= 1

    with zipfile.ZipFile(out) as zf:
        names = zf.namelist()
        assert len(names) == pages
        assert all(n.endswith(".png") for n in names)
        # Confirm each entry is a real 1536x1536 PNG.
        for n in names:
            img = Image.open(io.BytesIO(zf.read(n)))
            assert img.format == "PNG"
            assert img.size == (1536, 1536)


def test_caption_truncates_long_text():
    # A very long caption must not raise and must produce an RGB image.
    panel = _panel()
    out = assembly.draw_caption(panel, "word " * 300)
    assert out.mode == "RGB"
    assert out.size == (768, 768)
