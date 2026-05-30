"""Stub end-to-end: POST /jobs -> stream to completion -> GET /output -> valid zip.

Also validates the canned SceneList against the contract scene_list schema and
checks the >=8-scenes-incl-pivotal requirement.
"""
from __future__ import annotations

import io
import json
import zipfile

from PIL import Image

from .schema_check import validate


def test_stub_scene_list_conforms(scene_list_schema, sample_request):
    from app.models import JobRequest
    from stub.fake_pipeline import stub_scene_list

    sl = stub_scene_list(JobRequest.model_validate(sample_request))
    data = json.loads(sl.model_dump_json())
    validate(data, scene_list_schema)
    assert len(sl.scenes) >= 8
    assert any(s.pivotal for s in sl.scenes)
    assert len(sl.characters) == len(sample_request["characters"])


def test_e2e_post_stream_output(client, sample_request):
    jid = client.post("/jobs", json=sample_request).json()["job_id"]

    # Stream to terminal.
    pages_reported = None
    with client.stream("GET", f"/jobs/{jid}/stream") as resp:
        assert resp.status_code == 200
        for line in resp.iter_lines():
            if line and line.startswith("data:"):
                ev = json.loads(line[5:].strip())
                if ev["type"] == "job_complete":
                    pages_reported = ev["pages"]
                    break
                if ev["type"] == "job_error":
                    raise AssertionError(f"job errored: {ev}")
    assert pages_reported and pages_reported >= 1

    # Output now available.
    out = client.get(f"/jobs/{jid}/output")
    assert out.status_code == 200
    assert out.headers["content-type"] == "application/zip"

    with zipfile.ZipFile(io.BytesIO(out.content)) as zf:
        names = zf.namelist()
        assert len(names) == pages_reported
        assert all(n.endswith(".png") for n in names)
        for n in names:
            img = Image.open(io.BytesIO(zf.read(n)))
            assert img.size == (1536, 1536)

    # Job now listed as complete.
    jobs = client.get("/jobs").json()
    assert any(j["job_id"] == jid and j["status"] == "complete" for j in jobs)


def test_cancel_path(client, sample_request):
    """A cancel request should yield a job_error(cancelled) terminal eventually,
    OR complete if it finished first (stub is fast). Either is contract-valid."""
    jid = client.post("/jobs", json=sample_request).json()["job_id"]
    client.post(f"/jobs/{jid}/cancel")
    terminal = None
    with client.stream("GET", f"/jobs/{jid}/stream") as resp:
        for line in resp.iter_lines():
            if line and line.startswith("data:"):
                ev = json.loads(line[5:].strip())
                if ev["type"] in ("job_complete", "job_error"):
                    terminal = ev
                    break
    assert terminal is not None
    assert terminal["type"] in ("job_complete", "job_error")
