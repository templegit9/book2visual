"""FastAPI surface for the Book2Visual pipeline service.

Implements every endpoint in contract/openapi.yaml:
    GET  /health
    POST /jobs                       (409 if one already running)
    GET  /jobs/{id}/stream           (SSE ProgressEvents)
    POST /jobs/{id}/cancel
    GET  /jobs/{id}/output           (409 until complete)
    GET  /jobs
"""
from __future__ import annotations

import asyncio
from typing import List

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse
from sse_starlette.sse import EventSourceResponse

from . import config
from .jobs import manager
from .logging_setup import get_logger
from .models import (
    CancelResponse,
    CreateJobResponse,
    HealthResponse,
    JobRequest,
    JobStatus,
    JobSummary,
    ProgressEvent,
)

logger = get_logger()

app = FastAPI(
    title="Book2Visual Pipeline Service",
    version="1.0.0",
    description="Turns a short story into a colored-anime visual adaptation.",
)


@app.get("/health", response_model=HealthResponse)
async def get_health() -> HealthResponse:
    # In stub mode there are no real models, but the service is fully functional.
    models_loaded = True if config.STUB_MODE else manager.models_loaded
    return HealthResponse(models_loaded=models_loaded, stub=config.STUB_MODE)


@app.post("/jobs")
async def create_job(request: JobRequest):
    job = await manager.create(request)
    if job is None:
        return JSONResponse(
            status_code=409, content={"error": "job_already_running"}
        )
    logger.info("Created job %s", job.job_id, extra={"job_id": job.job_id})
    return CreateJobResponse(job_id=job.job_id)


@app.get("/jobs", response_model=List[JobSummary])
async def list_jobs() -> List[JobSummary]:
    return [JobSummary(job_id=j.job_id, status=j.status) for j in manager.list_jobs()]


@app.get("/jobs/{job_id}/stream")
async def stream_job(job_id: str, request: Request):
    job = manager.get(job_id)
    if job is None:
        return JSONResponse(status_code=404, content={"error": "unknown_job"})

    async def event_generator():
        # The job's `history` is the canonical, append-only, ordered list of all
        # emitted events (the job runs on the manager's background loop thread).
        # We stream from a cursor into it, polling until the terminal event has
        # been appended. This is robust to a subscriber that connects late
        # (events already in history) or even after completion.
        cursor = 0
        while True:
            # Drain any new history entries.
            while cursor < len(job.history):
                yield _sse(job.history[cursor])
                cursor += 1

            if job.finished.is_set() and cursor >= len(job.history):
                # All events (including the terminal one) have been replayed.
                break
            if await request.is_disconnected():
                break

            # Poll for more events without blocking this request's event loop.
            await asyncio.sleep(0.05)

    return EventSourceResponse(event_generator())


@app.post("/jobs/{job_id}/cancel")
async def cancel_job(job_id: str):
    job = manager.get(job_id)
    if job is None:
        return JSONResponse(status_code=404, content={"error": "unknown_job"})
    manager.request_cancel(job)
    logger.info("Cancellation requested for %s", job_id, extra={"job_id": job_id})
    return CancelResponse()


@app.get("/jobs/{job_id}/output")
async def get_job_output(job_id: str):
    job = manager.get(job_id)
    if job is None:
        return JSONResponse(status_code=404, content={"error": "unknown_job"})
    if job.status != JobStatus.complete or job.output_path is None:
        return JSONResponse(
            status_code=409, content={"error": "job_not_complete"}
        )
    return FileResponse(
        path=str(job.output_path),
        media_type="application/zip",
        filename="output.zip",
    )


def _sse(event: ProgressEvent) -> dict:
    """Serialize a ProgressEvent to an SSE record (data: <json>)."""
    return {"data": event.model_dump_json(exclude_none=False)}
