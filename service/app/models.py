"""Pydantic models mirroring contract/schemas/*.schema.json exactly.

Every object that the contract marks ``additionalProperties: false`` uses
``model_config = ConfigDict(extra="forbid")`` so unexpected fields are rejected
(HTTP 422) — matching the JSON Schema semantics one-to-one.
"""
from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
from typing import List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field


def utcnow_iso() -> str:
    """RFC3339 / ISO-8601 UTC timestamp with a trailing ``Z`` (contract format)."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- JobRequest -------------------------------------------------------------
class CharacterHint(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1)
    race_hint: Optional[str] = Field(
        default=None,
        description="Optional appearance/race hint used only when the text does not describe the character.",
    )


VramMode = Literal["concurrent", "sequenced"]
ConsistencyMode = Literal["kontext", "lora"]


class JobRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    text: str = Field(min_length=1, description="Story plain text. v1 target 2000-4000 words.")
    characters: List[CharacterHint] = Field(min_length=1)
    vram_mode: VramMode = "concurrent"
    consistency_mode: ConsistencyMode = "kontext"


# --- ProgressEvent ----------------------------------------------------------
class EventType(str, Enum):
    job_accepted = "job_accepted"
    stage_update = "stage_update"
    scene_start = "scene_start"
    scene_complete = "scene_complete"
    job_complete = "job_complete"
    job_error = "job_error"


TERMINAL_EVENTS = {EventType.job_complete, EventType.job_error}


class ProgressEvent(BaseModel):
    model_config = ConfigDict(extra="forbid", use_enum_values=True)

    type: EventType
    job_id: str
    scene_index: Optional[int] = Field(default=None, ge=0)
    total_scenes: Optional[int] = Field(default=None, ge=0)
    message: str
    ts: str = Field(default_factory=utcnow_iso)
    pages: Optional[int] = Field(default=None, description="Present on job_complete.")
    error_code: Optional[str] = Field(default=None, description="Present on job_error.")


# --- SceneList (internal text-stage output) ---------------------------------
class SceneCharacter(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    appearance_prompt: str
    ref_sheet_prompt: str


class Scene(BaseModel):
    model_config = ConfigDict(extra="forbid")

    index: int = Field(ge=0)
    title: Optional[str] = None
    image_prompt: str
    characters_present: List[str] = Field(default_factory=list)
    caption: str = Field(max_length=200)
    pivotal: bool = False


class SceneList(BaseModel):
    model_config = ConfigDict(extra="forbid")

    characters: List[SceneCharacter] = Field(default_factory=list)
    scenes: List[Scene] = Field(min_length=1)


# --- HTTP response bodies ---------------------------------------------------
class JobStatus(str, Enum):
    running = "running"
    complete = "complete"
    error = "error"
    cancelled = "cancelled"


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"
    models_loaded: bool
    stub: bool


class CreateJobResponse(BaseModel):
    job_id: str


class JobSummary(BaseModel):
    job_id: str
    status: JobStatus


class CancelResponse(BaseModel):
    status: Literal["cancelling"] = "cancelling"
