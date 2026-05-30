"""Page assembly: panels -> 1536x1536 pages -> output.zip (Pillow).

Layout rules (from the plan / contract):
- Normal scenes fill a 2x2 grid of 768px panels -> 1536x1536 pages.
- A pivotal scene gets a FULL-PAGE 1x1 slot (a single 768px panel scaled to the
  full 1536x1536 page) that *interrupts* the 2x2 fill: any partially-filled
  grid page is flushed first, then the pivotal scene gets its own page.
- Each panel gets a translucent caption box across the bottom ~18%, drawn via
  RGBA Image.alpha_composite (NOT a plain paste), with text word-wrapped using
  font.getbbox()/draw.textlength() (NOT getsize(), which PIL removed; NOT a
  char-count guess). Text is truncated with an ellipsis if it overflows.
"""
from __future__ import annotations

import zipfile
from pathlib import Path
from typing import List, Tuple

from PIL import Image, ImageDraw

from app.models import Scene
from .fonts import load_font

PAGE_SIZE = 1536  # 2 x 768
CAPTION_FRACTION = 0.18  # bottom ~18% of each panel
ELLIPSIS = "…"

Panel = Tuple[Scene, Image.Image]


# --- caption rendering ------------------------------------------------------
def _wrap_lines(draw: ImageDraw.ImageDraw, text: str, font, max_width: int) -> List[str]:
    """Greedy word-wrap using measured pixel widths (draw.textlength)."""
    words = text.split()
    if not words:
        return []
    lines: List[str] = []
    current = words[0]
    for word in words[1:]:
        candidate = f"{current} {word}"
        if draw.textlength(candidate, font=font) <= max_width:
            current = candidate
        else:
            lines.append(current)
            current = word
    lines.append(current)
    return lines


def _truncate_to_lines(
    draw: ImageDraw.ImageDraw, lines: List[str], font, max_width: int, max_lines: int
) -> List[str]:
    """Cap to max_lines; append an ellipsis to the last line if truncated."""
    if len(lines) <= max_lines:
        return lines
    kept = lines[:max_lines]
    last = kept[-1]
    # Trim words/chars off the last line until the ellipsis fits.
    while last and draw.textlength(last + ELLIPSIS, font=font) > max_width:
        last = last[:-1]
    kept[-1] = (last.rstrip() + ELLIPSIS) if last else ELLIPSIS
    return kept


def draw_caption(panel: Image.Image, caption: str) -> Image.Image:
    """Composite a translucent caption box with word-wrapped text onto a panel."""
    if not caption:
        return panel.convert("RGB")

    base = panel.convert("RGBA")
    w, h = base.size
    box_h = max(1, int(h * CAPTION_FRACTION))
    box_top = h - box_h
    pad = max(6, int(w * 0.03))

    # Pick a font size proportional to the panel; measure on a scratch drawer.
    font_size = max(12, int(h * 0.045))
    font = load_font(font_size)

    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    odraw = ImageDraw.Draw(overlay)

    # Translucent black box across the bottom.
    odraw.rectangle([0, box_top, w, h], fill=(0, 0, 0, 160))

    max_text_w = w - 2 * pad
    # Line height from the font's vertical bbox (NOT getsize()).
    ascent_box = font.getbbox("Ag")
    line_h = (ascent_box[3] - ascent_box[1]) + max(2, int(font_size * 0.25))
    max_lines = max(1, (box_h - pad) // line_h)

    lines = _wrap_lines(odraw, caption, font, max_text_w)
    lines = _truncate_to_lines(odraw, lines, font, max_text_w, max_lines)

    # Vertically center the text block within the caption box.
    block_h = line_h * len(lines)
    y = box_top + max(0, (box_h - block_h) // 2)
    for line in lines:
        odraw.text((pad, y), line, font=font, fill=(255, 255, 255, 255))
        y += line_h

    composited = Image.alpha_composite(base, overlay)
    return composited.convert("RGB")


# --- page layout ------------------------------------------------------------
def _blank_page() -> Image.Image:
    return Image.new("RGB", (PAGE_SIZE, PAGE_SIZE), (20, 20, 20))


def _quadrant_origin(slot: int, panel_size: int) -> Tuple[int, int]:
    # slot 0=TL, 1=TR, 2=BL, 3=BR
    col = slot % 2
    row = slot // 2
    return (col * panel_size, row * panel_size)


def build_pages(panels: List[Panel], panel_size: int) -> List[Image.Image]:
    """Lay panels onto pages: 2x2 grid, pivotal scenes get their own full page."""
    pages: List[Image.Image] = []
    current: Image.Image | None = None
    slot = 0

    def flush() -> None:
        nonlocal current, slot
        if current is not None:
            pages.append(current)
            current = None
            slot = 0

    for scene, raw_panel in panels:
        # Normalize panel to the expected size and burn in its caption.
        panel = raw_panel
        if panel.size != (panel_size, panel_size):
            panel = panel.resize((panel_size, panel_size))
        panel = draw_caption(panel, scene.caption)

        if scene.pivotal:
            # Interrupt the current grid page, then a dedicated full-page panel.
            flush()
            full = panel.resize((PAGE_SIZE, PAGE_SIZE))
            page = _blank_page()
            page.paste(full, (0, 0))
            pages.append(page)
            continue

        if current is None:
            current = _blank_page()
            slot = 0
        ox, oy = _quadrant_origin(slot, panel_size)
        current.paste(panel, (ox, oy))
        slot += 1
        if slot == 4:
            flush()

    flush()
    return pages


def build_output_zip(panels: List[Panel], output_path: Path, panel_size: int) -> int:
    """Build pages and write them as PNGs into ``output_path`` (a zip). Returns page count."""
    pages = build_pages(panels, panel_size)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for i, page in enumerate(pages):
            import io

            buf = io.BytesIO()
            page.save(buf, format="PNG")
            zf.writestr(f"page_{i + 1:02d}.png", buf.getvalue())
    return len(pages)
