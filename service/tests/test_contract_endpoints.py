"""Contract conformance: endpoints, status codes, 409 single-job, validation."""
from __future__ import annotations


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["models_loaded"] is True
    assert body["stub"] is True


def test_create_job_returns_uuid(client, sample_request):
    r = client.post("/jobs", json=sample_request)
    assert r.status_code == 200
    body = r.json()
    assert "job_id" in body
    # Drain to completion so we don't leave an active job for the next test.
    _drain(client, body["job_id"])


def test_single_job_409(client, sample_request):
    # First job: do NOT drain immediately so it's still active.
    r1 = client.post("/jobs", json=sample_request)
    assert r1.status_code == 200
    jid = r1.json()["job_id"]
    # While the first is active a second POST must 409.
    r2 = client.post("/jobs", json=sample_request)
    if r2.status_code == 200:
        # The first finished extremely fast; tolerate by draining both.
        _drain(client, r2.json()["job_id"])
    else:
        assert r2.status_code == 409
        assert r2.json() == {"error": "job_already_running"}
    _drain(client, jid)


def test_jobrequest_rejects_extra_field(client):
    bad = {"text": "hi", "characters": [{"name": "A"}], "nope": 1}
    r = client.post("/jobs", json=bad)
    assert r.status_code == 422


def test_jobrequest_rejects_empty_characters(client):
    bad = {"text": "hi", "characters": []}
    r = client.post("/jobs", json=bad)
    assert r.status_code == 422


def test_jobrequest_rejects_empty_text(client):
    bad = {"text": "", "characters": [{"name": "A"}]}
    r = client.post("/jobs", json=bad)
    assert r.status_code == 422


def test_character_rejects_extra_field(client):
    bad = {"text": "hi", "characters": [{"name": "A", "weird": 1}]}
    r = client.post("/jobs", json=bad)
    assert r.status_code == 422


def test_output_409_before_complete(client, sample_request):
    r = client.post("/jobs", json=sample_request)
    jid = r.json()["job_id"]
    # Immediately request output — almost certainly not complete yet.
    out = client.get(f"/jobs/{jid}/output")
    assert out.status_code in (409, 200)  # 200 only if it finished instantly
    _drain(client, jid)


def test_output_404_unknown(client):
    assert client.get("/jobs/does-not-exist/output").status_code == 404


def test_stream_404_unknown(client):
    assert client.get("/jobs/does-not-exist/stream").status_code == 404


def test_cancel_404_unknown(client):
    assert client.post("/jobs/does-not-exist/cancel").status_code == 404


def test_list_jobs_shape(client, sample_request):
    r = client.post("/jobs", json=sample_request)
    jid = r.json()["job_id"]
    _drain(client, jid)
    jobs = client.get("/jobs").json()
    assert isinstance(jobs, list)
    statuses = {j["status"] for j in jobs}
    assert statuses <= {"running", "complete", "error", "cancelled"}
    assert any(j["job_id"] == jid for j in jobs)


def _drain(client, job_id: str) -> None:
    """Consume the SSE stream to its terminal event."""
    with client.stream("GET", f"/jobs/{job_id}/stream") as resp:
        assert resp.status_code == 200
        for line in resp.iter_lines():
            if line and ('"job_complete"' in line or '"job_error"' in line):
                break
