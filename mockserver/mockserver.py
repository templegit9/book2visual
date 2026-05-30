"""Book2Visual mock server — standalone, contract-faithful, no GPU, no Thunder.

A single-file FastAPI app that implements the SAME contract as service/ with
canned/instant responses: fast SSE (~8 scenes), and a small REAL output.zip
generated with Pillow. The macOS app develops against this with no Thunder
account and no service/ checkout. Event/HTTP shapes are byte-compatible with the
real service.

Run:  uvicorn mockserver:app --host 127.0.0.1 --port 8000
"""
from __future__ import annotations

import asyncio
import io
import threading
import uuid
import zipfile
from datetime import datetime, timezone
from typing import Dict, List, Optional

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse
from PIL import Image, ImageDraw
from pydantic import BaseModel, ConfigDict, Field
from sse_starlette.sse import EventSourceResponse

app = FastAPI(title="Book2Visual Mock Server", version="1.0.0")

PANEL = 768
PAGE = 1536


def _ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- minimal contract models (mirror service/) ------------------------------
class CharacterHint(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str = Field(min_length=1)
    race_hint: Optional[str] = None


class JobRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    text: str = Field(min_length=1)
    characters: List[CharacterHint] = Field(min_length=1)
    vram_mode: str = "concurrent"
    consistency_mode: str = "kontext"


# --- dedicated background event loop ----------------------------------------
# Jobs run here (NOT on a request's transient loop) so they survive the request
# that created them and any stream disconnect/reconnect — same design as the real
# service/, so behavior is identical.
class _BackgroundLoop:
    def __init__(self) -> None:
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._ready = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, name="mock-jobs", daemon=True)
        self._thread.start()
        self._ready.wait()

    def _run(self) -> None:
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)
        self._ready.set()
        self._loop.run_forever()

    def submit(self, coro) -> None:
        assert self._loop is not None
        asyncio.run_coroutine_threadsafe(coro, self._loop)


_bg = _BackgroundLoop()


# --- tiny in-memory job store (single job at a time) ------------------------
class _Job:
    def __init__(self, job_id: str, req: JobRequest) -> None:
        self.job_id = job_id
        self.req = req
        self.status = "running"
        self.events: List[dict] = []  # append-only (atomic in CPython)
        self.finished = threading.Event()
        self.cancel = threading.Event()
        self.output: Optional[str] = None
        self.pages = 0


_jobs: Dict[str, _Job] = {}
_order: List[str] = []
_active: Optional[str] = None


def _event(job_id: str, type_: str, **kw) -> dict:
    ev = {
        "type": type_,
        "job_id": job_id,
        "scene_index": kw.get("scene_index"),
        "total_scenes": kw.get("total_scenes"),
        "message": kw.get("message", ""),
        "ts": _ts(),
        "pages": kw.get("pages"),
        "error_code": kw.get("error_code"),
    }
    return ev


def _placeholder(lines: List[str], color) -> Image.Image:
    img = Image.new("RGB", (PANEL, PANEL), color)
    d = ImageDraw.Draw(img)
    y = 40
    for ln in lines:
        d.text((30, y), ln, fill=(255, 255, 255))
        y += 30
    d.rectangle([0, 0, PANEL - 1, PANEL - 1], outline=(255, 255, 255), width=3)
    return img


def _caption(panel: Image.Image, text: str) -> Image.Image:
    base = panel.convert("RGBA")
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    box_top = int(PANEL * 0.82)
    d.rectangle([0, box_top, PANEL, PANEL], fill=(0, 0, 0, 160))
    d.text((20, box_top + 20), text[:60], fill=(255, 255, 255, 255))
    return Image.alpha_composite(base, overlay).convert("RGB")


_COLORS = [
    (78, 121, 167), (242, 142, 43), (225, 87, 89), (118, 183, 178),
    (89, 161, 79), (237, 201, 72), (176, 122, 161), (255, 157, 167),
    (120, 120, 180),
]


async def _run(job: _Job) -> None:
    async def emit(ev: dict) -> None:
        job.events.append(ev)

    try:
        await emit(_event(job.job_id, "job_accepted", message="Job accepted."))
        await emit(_event(job.job_id, "stage_update", message="Extracting scenes..."))
        total = 9  # includes one pivotal (index 4)
        await emit(
            _event(job.job_id, "stage_update", total_scenes=total,
                   message=f"{total} scenes extracted.")
        )
        panels = []
        for i in range(total):
            if job.cancel.is_set():
                await emit(_event(job.job_id, "job_error", scene_index=i,
                                  total_scenes=total, error_code="cancelled",
                                  message=f"Cancelled before scene {i + 1}/{total}."))
                job.status = "cancelled"
                return
            await emit(_event(job.job_id, "scene_start", scene_index=i,
                              total_scenes=total,
                              message=f"Scene {i + 1}/{total}: rendering panel..."))
            pivotal = i == 4
            lines = [f"SCENE {i + 1}", "PIVOTAL" if pivotal else "mock panel"]
            panel = _caption(_placeholder(lines, _COLORS[i % len(_COLORS)]),
                             f"Scene {i + 1} caption.")
            panels.append((pivotal, panel))
            await emit(_event(job.job_id, "scene_complete", scene_index=i,
                              total_scenes=total,
                              message=f"Scene {i + 1}/{total} panel rendered."))
            await asyncio.sleep(0.05)  # fast but observable SSE pacing

        await emit(_event(job.job_id, "stage_update", total_scenes=total,
                          message="Assembling pages..."))
        pages = _assemble(panels)
        out = f"/tmp/b2v_mock_{job.job_id}.zip"
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
            for idx, pg in enumerate(pages):
                buf = io.BytesIO()
                pg.save(buf, format="PNG")
                zf.writestr(f"page_{idx + 1:02d}.png", buf.getvalue())
        job.output = out
        job.pages = len(pages)
        job.status = "complete"
        await emit(_event(job.job_id, "job_complete", total_scenes=total,
                          pages=len(pages),
                          message=f"Done. {len(pages)} page(s) ready."))
    except Exception as exc:  # noqa: BLE001
        await emit(_event(job.job_id, "job_error", error_code="internal_error",
                          message=str(exc)))
        job.status = "error"
    finally:
        job.finished.set()
        global _active
        if _active == job.job_id:
            _active = None


def _assemble(panels) -> List[Image.Image]:
    pages: List[Image.Image] = []
    current = None
    slot = 0

    def flush():
        nonlocal current, slot
        if current is not None:
            pages.append(current)
            current = None
            slot = 0

    for pivotal, panel in panels:
        if pivotal:
            flush()
            page = Image.new("RGB", (PAGE, PAGE), (20, 20, 20))
            page.paste(panel.resize((PAGE, PAGE)), (0, 0))
            pages.append(page)
            continue
        if current is None:
            current = Image.new("RGB", (PAGE, PAGE), (20, 20, 20))
            slot = 0
        col, row = slot % 2, slot // 2
        current.paste(panel, (col * PANEL, row * PANEL))
        slot += 1
        if slot == 4:
            flush()
    flush()
    return pages


# --- endpoints --------------------------------------------------------------
@app.get("/health")
async def health():
    return {"status": "ok", "models_loaded": True, "stub": True}


@app.post("/jobs")
async def create_job(req: JobRequest):
    global _active
    if _active is not None and _jobs[_active].status == "running":
        return JSONResponse(status_code=409, content={"error": "job_already_running"})
    job_id = str(uuid.uuid4())
    job = _Job(job_id, req)
    _jobs[job_id] = job
    _order.append(job_id)
    _active = job_id
    _bg.start()
    _bg.submit(_run(job))
    return {"job_id": job_id}


@app.get("/jobs")
async def list_jobs():
    return [{"job_id": j, "status": _jobs[j].status} for j in _order]


@app.get("/jobs/{job_id}/stream")
async def stream(job_id: str, request: Request):
    job = _jobs.get(job_id)
    if job is None:
        return JSONResponse(status_code=404, content={"error": "unknown_job"})

    async def gen():
        cursor = 0
        while True:
            while cursor < len(job.events):
                yield {"data": _json(job.events[cursor])}
                cursor += 1
            if job.finished.is_set() and cursor >= len(job.events):
                break
            if await request.is_disconnected():
                break
            await asyncio.sleep(0.05)

    return EventSourceResponse(gen())


@app.post("/jobs/{job_id}/cancel")
async def cancel(job_id: str):
    job = _jobs.get(job_id)
    if job is None:
        return JSONResponse(status_code=404, content={"error": "unknown_job"})
    job.cancel.set()
    return {"status": "cancelling"}


@app.get("/jobs/{job_id}/output")
async def output(job_id: str):
    job = _jobs.get(job_id)
    if job is None:
        return JSONResponse(status_code=404, content={"error": "unknown_job"})
    if job.status != "complete" or job.output is None:
        return JSONResponse(status_code=409, content={"error": "job_not_complete"})
    return FileResponse(job.output, media_type="application/zip", filename="output.zip")


def _json(ev: dict) -> str:
    import json

    return json.dumps(ev)
