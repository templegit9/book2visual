"""Font loading for caption rendering.

Prefers the bundled, permissively-licensed TTF in ``service/assets/fonts/`` so
output is reproducible across machines. Falls back to PIL's built-in bitmap font
only if the bundled file is somehow missing (keeps the service from crashing).
"""
from __future__ import annotations

from functools import lru_cache

from PIL import ImageFont

from app import config

_BUNDLED = config.FONTS_DIR / "DejaVuSans.ttf"


@lru_cache(maxsize=16)
def load_font(size: int) -> ImageFont.FreeTypeFont:
    """Load the bundled caption font at ``size`` px (cached per size)."""
    if _BUNDLED.exists():
        return ImageFont.truetype(str(_BUNDLED), size=size)
    # Last resort: PIL default bitmap font (fixed size; not ideal but safe).
    return ImageFont.load_default()
