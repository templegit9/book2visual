"""Job lifecycle management: single-job lock, async execution, SSE fan-out.

Jobs run on a DEDICATED background event-loop thread owned by the JobManager —
NOT on the event loop of whichever HTTP request created them. This is what makes
the design robust: a job survives the lifetime of the request that POSTed it
(e.g. under Starlette's TestClient, each request runs on its own transient loop
that is torn down at the end of the request; a task spawned there would be
cancelled). With a persistent background loop the job runs to completion
regardless of request lifecycles.

Cross-thread coordination uses thread-safe primitives:
- ``job.history`` is an append-only list (list.append is atomic in CPython); the
  SSE endpoint reads it by index from any loop/thread.
- ``job.finished`` is a ``threading.Event`` set when the terminal event has been
  appended.
Exactly one terminal event (job_complete XOR job_error) is guaranteed to be the
last entry in ``history`` — see :meth:`JobManager._run`.
"""
from __future__ import annotations

import asyncio
import threading
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

from .logging_setup import get_logger
from .models import (
    EventType,
    JobRequest,
    JobStatus,
    ProgressEvent,
    TERMINAL_EVENTS,
)

logger = get_logger()


@dataclass
class Job:
    job_id: str
    request: JobRequest
    status: JobStatus = JobStatus.running
    # Cooperative cancellation flag (thread-safe).
    cancel_event: threading.Event = field(default_factory=threading.Event)
    output_path: Optional[Path] = None
    pages: Optional[int] = None
    total_scenes: Optional[int] = None
    # Append-only, ordered list of every emitted event (atomic append in CPython).
    history: List[ProgressEvent] = field(default_factory=list)
    # Set once the terminal event has been appended to history.
    finished: threading.Event = field(default_factory=threading.Event)

    @property
    def cancel_requested(self) -> bool:
        return self.cancel_event.is_set()


class _BackgroundLoop:
    """A single asyncio event loop running on its own daemon thread."""

    def __init__(self) -> None:
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._thread: Optional[threading.Thread] = None
        self._ready = threading.Event()

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, name="b2v-jobs", daemon=True)
        self._thread.start()
        self._ready.wait()

    def _run(self) -> None:
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)
        self._ready.set()
        self._loop.run_forever()

    def submit(self, coro) -> "asyncio.Future":
        assert self._loop is not None
        return asyncio.run_coroutine_threadsafe(coro, self._loop)


class JobManager:
    """Owns at most one active job at a time plus a history of recent jobs."""

    def __init__(self) -> None:
        self._jobs: Dict[str, Job] = {}
        self._order: List[str] = []
        self._active_id: Optional[str] = None
        self._lock = threading.Lock()
        self._bg = _BackgroundLoop()
        self.models_loaded: bool = False

    # --- queries ------------------------------------------------------------
    def get(self, job_id: str) -> Optional[Job]:
        return self._jobs.get(job_id)

    def list_jobs(self) -> List[Job]:
        return [self._jobs[jid] for jid in self._order]

    def has_active(self) -> bool:
        if self._active_id is None:
            return False
        job = self._jobs.get(self._active_id)
        return job is not None and job.status == JobStatus.running

    # --- creation -----------------------------------------------------------
    async def create(self, request: JobRequest) -> Optional[Job]:
        """Create + start a job, or return ``None`` if one is already running."""
        with self._lock:
            if self.has_active():
                return None
            job_id = str(uuid.uuid4())
            job = Job(job_id=job_id, request=request)
            self._jobs[job_id] = job
            self._order.append(job_id)
            self._active_id = job_id

        # Start the orchestrator on the dedicated background loop.
        self._bg.start()
        from .orchestrator import run_job

        self._bg.submit(self._run(job, run_job))
        return job

    async def _run(self, job: Job, run_job) -> None:
        """Execute the orchestrator, guaranteeing exactly one terminal event."""
        terminal_emitted = False

        async def emit(event: ProgressEvent) -> None:
            nonlocal terminal_emitted
            job.history.append(event)
            if EventType(event.type) in TERMINAL_EVENTS:
                terminal_emitted = True
            logger.info(
                event.message,
                extra={"job_id": job.job_id, "event_type": event.type},
            )

        try:
            await run_job(job, emit)
        except asyncio.CancelledError:
            if not terminal_emitted:
                await emit(
                    ProgressEvent(
                        type=EventType.job_error,
                        job_id=job.job_id,
                        message="Job task cancelled.",
                        error_code="cancelled",
                        total_scenes=job.total_scenes,
                    )
                )
                job.status = JobStatus.cancelled
            raise
        except Exception as exc:  # noqa: BLE001 — convert any failure to job_error
            logger.exception("Job %s crashed", job.job_id)
            if not terminal_emitted:
                await emit(
                    ProgressEvent(
                        type=EventType.job_error,
                        job_id=job.job_id,
                        message=f"Pipeline failed: {exc}",
                        error_code="internal_error",
                        total_scenes=job.total_scenes,
                    )
                )
            job.status = JobStatus.error
        finally:
            # Belt-and-braces: never leave a stream without a terminal event.
            if not terminal_emitted:
                await emit(
                    ProgressEvent(
                        type=EventType.job_error,
                        job_id=job.job_id,
                        message="Job ended without a terminal event.",
                        error_code="internal_error",
                        total_scenes=job.total_scenes,
                    )
                )
                job.status = JobStatus.error
            job.finished.set()
            with self._lock:
                if self._active_id == job.job_id:
                    self._active_id = None

    # --- cancellation -------------------------------------------------------
    def request_cancel(self, job: Job) -> None:
        job.cancel_event.set()


# Module-level singleton used by the FastAPI app.
manager = JobManager()
