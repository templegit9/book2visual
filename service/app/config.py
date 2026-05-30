"""Runtime configuration for the Book2Visual service.

All knobs are environment-driven so the same code runs in stub mode on a Mac and
in full GPU mode on a ThunderCompute instance.
"""
from __future__ import annotations

import os
from pathlib import Path


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


# --- Mode -------------------------------------------------------------------
# When set, the service performs ZERO GPU work: it emits the full real event
# sequence and produces a real output.zip using PIL-drawn placeholder panels.
STUB_MODE: bool = _env_bool("BOOK2VISUAL_STUB", False)

# --- LLM (text stage) -------------------------------------------------------
LLM_MODEL: str = os.environ.get("BOOK2VISUAL_LLM_MODEL", "Qwen/Qwen2.5-32B-Instruct-AWQ")
VLLM_URL: str = os.environ.get("BOOK2VISUAL_VLLM_URL", "http://127.0.0.1:8001/v1")
VLLM_API_KEY: str = os.environ.get("BOOK2VISUAL_VLLM_API_KEY", "EMPTY")
LLM_MAX_RETRIES: int = int(os.environ.get("BOOK2VISUAL_LLM_MAX_RETRIES", "3"))

# --- Image stage ------------------------------------------------------------
FLUX_BASE_MODEL: str = os.environ.get("BOOK2VISUAL_FLUX_MODEL", "black-forest-labs/FLUX.1-dev")
FLUX_KONTEXT_MODEL: str = os.environ.get(
    "BOOK2VISUAL_KONTEXT_MODEL", "black-forest-labs/FLUX.1-Kontext-dev"
)
ANIME_LORA: str = os.environ.get(
    "BOOK2VISUAL_ANIME_LORA", "alfredplpl/flux.1-dev-modern-anime-lora"
)
PANEL_SIZE: int = int(os.environ.get("BOOK2VISUAL_PANEL_SIZE", "768"))

# --- Paths ------------------------------------------------------------------
SERVICE_ROOT: Path = Path(__file__).resolve().parent.parent
ASSETS_DIR: Path = SERVICE_ROOT / "assets"
FONTS_DIR: Path = ASSETS_DIR / "fonts"
DATA_DIR: Path = Path(os.environ.get("BOOK2VISUAL_DATA_DIR", str(SERVICE_ROOT / "_jobs")))
LOG_DIR: Path = Path(os.environ.get("BOOK2VISUAL_LOG_DIR", str(SERVICE_ROOT / "_logs")))

# --- Server -----------------------------------------------------------------
HOST: str = os.environ.get("BOOK2VISUAL_HOST", "127.0.0.1")
PORT: int = int(os.environ.get("BOOK2VISUAL_PORT", "8000"))
