"""SSE ordering: events validate against the schema; exactly one terminal event;
scene_complete count == total_scenes; ordering invariants hold."""
from __future__ import annotations

import json

from .schema_check import validate


def _collect_events(client, job_id: str):
    events = []
    with client.stream("GET", f"/jobs/{job_id}/stream") as resp:
        assert resp.status_code == 200
        for line in resp.iter_lines():
            if not line:
                continue
            if line.startswith("data:"):
                payload = line[len("data:"):].strip()
                events.append(json.loads(payload))
                if events[-1]["type"] in ("job_complete", "job_error"):
                    break
    return events


def test_full_event_sequence(client, sample_request, progress_event_schema):
    jid = client.post("/jobs", json=sample_request).json()["job_id"]
    events = _collect_events(client, jid)

    # Every event conforms to the ProgressEvent schema.
    for ev in events:
        validate(ev, progress_event_schema)

    types = [e["type"] for e in events]

    # First event is job_accepted.
    assert types[0] == "job_accepted"

    # Exactly one terminal event, and it is last.
    terminals = [t for t in types if t in ("job_complete", "job_error")]
    assert len(terminals) == 1
    assert types[-1] in ("job_complete", "job_error")
    assert types[-1] == "job_complete"  # stub always succeeds

    # total_scenes appears and scene_complete count matches it.
    total = next(e["total_scenes"] for e in events if e.get("total_scenes"))
    completes = [e for e in events if e["type"] == "scene_complete"]
    starts = [e for e in events if e["type"] == "scene_start"]
    assert len(completes) == total
    assert len(starts) == total

    # Every scene_start precedes its matching scene_complete.
    seen_complete = set()
    for ev in events:
        if ev["type"] == "scene_start":
            assert ev["scene_index"] not in seen_complete
        if ev["type"] == "scene_complete":
            seen_complete.add(ev["scene_index"])
    assert seen_complete == set(range(total))

    # job_complete carries pages.
    last = events[-1]
    assert isinstance(last["pages"], int) and last["pages"] >= 1


def test_all_events_share_job_id(client, sample_request):
    jid = client.post("/jobs", json=sample_request).json()["job_id"]
    events = _collect_events(client, jid)
    assert all(e["job_id"] == jid for e in events)
