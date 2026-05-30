"""Job orchestrator: drives text -> image -> assembly and emits ProgressEvents.

Selects the stub path (no GPU) vs the real GPU path based on ``config.STUB_MODE``.
The real path imports torch/diffusers/vLLM-backed modules **lazily** (only when
stub mode is off) so the service is fully runnable/testable without those deps.

Event sequence (contract):
    job_accepted
    stage_update (text stage)
    [per scene] scene_start -> scene_complete
    stage_update (assembly)
    job_complete (carries `pages`)   XOR   job_error
"""
from __future__ import annotations

import asyncio
from typing import Awaitable, Callable

from . import config
from .jobs import Job
from .logging_setup import get_logger
from .models import EventType, JobStatus, ProgressEvent, SceneList

logger = get_logger()

Emit = Callable[[ProgressEvent], Awaitable[None]]


async def run_job(job: Job, emit: Emit) -> None:
    """Run a full adaptation job, emitting ProgressEvents via ``emit``."""
    jid = job.job_id
    req = job.request

    await emit(
        ProgressEvent(
            type=EventType.job_accepted,
            job_id=jid,
            message="Job accepted.",
        )
    )

    # --- Text stage ---------------------------------------------------------
    await emit(
        ProgressEvent(
            type=EventType.stage_update,
            job_id=jid,
            message="Extracting scenes from the story (text stage)...",
        )
    )

    scene_list: SceneList = await _run_text_stage(req)
    total = len(scene_list.scenes)
    job.total_scenes = total

    await emit(
        ProgressEvent(
            type=EventType.stage_update,
            job_id=jid,
            total_scenes=total,
            message=f"Scene extraction complete: {total} scenes, "
            f"{len(scene_list.characters)} characters.",
        )
    )

    # --- Image stage (per-scene panels) -------------------------------------
    # Real path generates one canonical reference image per character first,
    # then fans out depth-1 to each panel. The stub path draws placeholders.
    backend_label = req.consistency_mode
    panels = []
    image_runner = await _make_image_runner(req)

    # Build per-character reference images once (depth-1 fan-out source).
    await emit(
        ProgressEvent(
            type=EventType.stage_update,
            job_id=jid,
            total_scenes=total,
            message=f"Building character reference sheets ({backend_label} backend)...",
        )
    )
    references = await image_runner.build_references(scene_list)

    for scene in scene_list.scenes:
        if job.cancel_requested:
            # Cooperative cancellation: stop AFTER the current scene boundary.
            await emit(
                ProgressEvent(
                    type=EventType.job_error,
                    job_id=jid,
                    scene_index=scene.index,
                    total_scenes=total,
                    message=f"Cancelled before scene {scene.index + 1}/{total}.",
                    error_code="cancelled",
                )
            )
            job.status = JobStatus.cancelled
            return

        await emit(
            ProgressEvent(
                type=EventType.scene_start,
                job_id=jid,
                scene_index=scene.index,
                total_scenes=total,
                message=f"Scene {scene.index + 1}/{total}: rendering panel...",
            )
        )

        panel = await image_runner.render_panel(scene, references)
        panels.append((scene, panel))

        await emit(
            ProgressEvent(
                type=EventType.scene_complete,
                job_id=jid,
                scene_index=scene.index,
                total_scenes=total,
                message=f"Scene {scene.index + 1}/{total} panel rendered.",
            )
        )

    # --- Assembly stage -----------------------------------------------------
    await emit(
        ProgressEvent(
            type=EventType.stage_update,
            job_id=jid,
            total_scenes=total,
            message="Assembling pages and packaging output.zip...",
        )
    )

    # Assembly is pure-Pillow and identical for stub and real paths.
    from pipeline import assembly

    config.DATA_DIR.mkdir(parents=True, exist_ok=True)
    job_dir = config.DATA_DIR / jid
    job_dir.mkdir(parents=True, exist_ok=True)
    output_zip = job_dir / "output.zip"

    pages = await asyncio.to_thread(
        assembly.build_output_zip, panels, output_zip, config.PANEL_SIZE
    )
    job.output_path = output_zip
    job.pages = pages
    job.status = JobStatus.complete

    await emit(
        ProgressEvent(
            type=EventType.job_complete,
            job_id=jid,
            total_scenes=total,
            pages=pages,
            message=f"Done. {pages} page(s) ready for download.",
        )
    )


# --- stage selection --------------------------------------------------------
async def _run_text_stage(req) -> SceneList:
    if config.STUB_MODE:
        from stub.fake_pipeline import stub_scene_list

        return stub_scene_list(req)
    # Real path — imported lazily so vLLM client deps aren't needed in stub mode.
    from pipeline import text_stage

    return await asyncio.to_thread(text_stage.extract_scenes, req)


async def _make_image_runner(req):
    if config.STUB_MODE:
        from stub.fake_pipeline import StubImageRunner

        return StubImageRunner()
    # Real path — imports diffusers/torch lazily inside image_stage/consistency.
    from pipeline import image_stage

    return image_stage.ImageRunner(req)
