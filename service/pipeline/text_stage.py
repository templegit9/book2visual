"""Text stage: story -> validated SceneList via a vLLM OpenAI-compatible endpoint.

Uses JSON-schema *guided decoding* (``response_format={"type":"json_schema",...}``)
with the SceneList schema so the model can only emit conformant JSON. Validated
with the pydantic SceneList model; up to ``LLM_MAX_RETRIES`` attempts on
malformed/invalid output.

This module is only imported when STUB_MODE is OFF (see orchestrator). It uses
``httpx`` (a light dep) to talk to the vLLM sidecar; it does NOT import
torch/vllm in-process — vLLM runs as a separate server.
"""
from __future__ import annotations

import json
from typing import Any, Dict

from app import config
from app.models import JobRequest, SceneList

# --- Prompt templates (module constants, per the plan) ----------------------
SYSTEM_PROMPT = """\
You are an expert visual-adaptation director. You turn a short prose story into a
condensed, interpretive colored-anime visual adaptation — NOT a literal panel of
every sentence.

Rules:
- Pick the 8-15 MOST visually dramatic scenes (roughly one scene per 400-500
  words of source text). Favor turning points, confrontations, reveals, and
  striking imagery over connective tissue.
- For EACH named character, extract a concise canonical `appearance_prompt`
  (stable physical descriptors that should look the same in every panel) AND a
  `ref_sheet_prompt` (a prompt for a single full-body character reference image).
- For each scene write an `image_prompt` describing the moment cinematically,
  list `characters_present`, and write an author-voice `caption` of AT MOST 200
  characters that reads like narration from the story's own voice.
- Mark a scene `pivotal: true` ONLY for the single most important turning point
  (or at most two), which will be given a full page.
- Output MUST conform exactly to the provided JSON schema. Use 0-based `index`.
"""

USER_PROMPT_TEMPLATE = """\
Adapt the following story into a SceneList.

Characters the reader has named (use these names verbatim; apply each race_hint
ONLY where the text itself does not describe the character):
{character_block}

STORY:
{story}
"""


def _character_block(req: JobRequest) -> str:
    lines = []
    for c in req.characters:
        hint = f" (hint: {c.race_hint})" if c.race_hint else ""
        lines.append(f"- {c.name}{hint}")
    return "\n".join(lines)


def _scene_list_json_schema() -> Dict[str, Any]:
    """The SceneList JSON schema for vLLM guided decoding (derived from pydantic)."""
    schema = SceneList.model_json_schema()
    return {
        "type": "json_schema",
        "json_schema": {"name": "SceneList", "schema": schema, "strict": True},
    }


def extract_scenes(req: JobRequest) -> SceneList:
    """Call the vLLM endpoint with guided JSON decoding and validate the result.

    Raises RuntimeError if no valid SceneList is produced within the retry budget.
    """
    import httpx  # light dep; safe to import in real path

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {
            "role": "user",
            "content": USER_PROMPT_TEMPLATE.format(
                character_block=_character_block(req), story=req.text
            ),
        },
    ]
    payload = {
        "model": config.LLM_MODEL,
        "messages": messages,
        "temperature": 0.7,
        "max_tokens": 4096,
        "response_format": _scene_list_json_schema(),
    }
    headers = {"Authorization": f"Bearer {config.VLLM_API_KEY}"}

    last_err: Exception | None = None
    with httpx.Client(base_url=config.VLLM_URL, timeout=600.0) as client:
        for attempt in range(1, config.LLM_MAX_RETRIES + 1):
            try:
                resp = client.post(
                    "/chat/completions", json=payload, headers=headers
                )
                resp.raise_for_status()
                content = resp.json()["choices"][0]["message"]["content"]
                data = json.loads(content)
                scene_list = SceneList.model_validate(data)
                # Re-index defensively so downstream layout is 0-based contiguous.
                for i, scene in enumerate(scene_list.scenes):
                    scene.index = i
                return scene_list
            except Exception as exc:  # noqa: BLE001 — retry on any parse/validate error
                last_err = exc
                continue

    raise RuntimeError(
        f"Text stage failed to produce a valid SceneList after "
        f"{config.LLM_MAX_RETRIES} attempts: {last_err}"
    )
