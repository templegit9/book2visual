# Book2Visual — Interface Contract

This directory is the **single source of truth** for the boundary between the macOS app (`app/`)
and the remote pipeline service (`service/`). Both sides MUST code against the schemas here.
Change the contract here first, then update both sides.

- `openapi.yaml` — the HTTP surface of the FastAPI service (`service/`).
- `schemas/*.schema.json` — JSON Schemas (draft 2020-12) for the payloads. These are the
  authoritative shapes. Swift `Codable` models and Python `pydantic` models both mirror these.

## Transport overview

1. **Control plane (app ↔ ThunderCompute, NOT this service):** direct HTTPS REST to
   `https://api.thundercompute.com:8443` with `Authorization: Bearer <token>`. Lifecycle only
   (create / list / up / down / delete). Documented in `docs/THUNDER_SPIKE.md`, not here.
2. **Data plane (app ↔ this service):** plain HTTP/1.1 + JSON over a localhost SSH tunnel.
   The service binds `127.0.0.1:<port>` (default 8000) on the instance; the app forwards a local
   port to it (`ssh -L`). The service has **no auth of its own** — the SSH tunnel is the boundary.

## Endpoints (summary; see `openapi.yaml` for the full spec)

| Method | Path | Purpose |
|---|---|---|
| GET  | `/health` | Liveness + whether models are loaded. Used for tunnel validation + heartbeat. |
| POST | `/jobs` | Submit an adaptation job (`JobRequest`). Returns `{ "job_id": "<uuid>" }`. 409 if a job is already running. |
| GET  | `/jobs/{job_id}/stream` | **SSE** stream of `ProgressEvent`s until `job_complete` or `job_error`. |
| POST | `/jobs/{job_id}/cancel` | Request cancellation; job stops after the current scene. |
| GET  | `/jobs/{job_id}/output` | Download the result `output.zip` (binary). Only valid after `job_complete`. |
| GET  | `/jobs` | List recent jobs (status only). For future history UI. |

## Payloads

### `JobRequest` (POST /jobs body) — `schemas/job_request.schema.json`
```json
{
  "text": "<story plain text, 2000-4000 words>",
  "characters": [
    { "name": "Gregor Samsa", "race_hint": "human" }
  ],
  "vram_mode": "concurrent",
  "consistency_mode": "kontext"
}
```
- `vram_mode`: `"concurrent"` (both models resident, ≥80GB) | `"sequenced"` (LLM → free → FLUX).
- `consistency_mode`: `"kontext"` (FLUX.1-Kontext-dev depth-1 fan-out, default) | `"lora"`
  (per-character anime LoRA). These are the two backends A/B'd on the demo.

### `ProgressEvent` (each SSE `data:` line) — `schemas/progress_event.schema.json`
```json
{
  "type": "scene_complete",
  "job_id": "…",
  "scene_index": 3,
  "total_scenes": 8,
  "message": "Scene 3/8 panel rendered.",
  "ts": "2026-05-29T18:00:00Z"
}
```
- `type` ∈ `job_accepted | stage_update | scene_start | scene_complete | job_complete | job_error`.
- `scene_index` / `total_scenes` may be `null` before scene extraction finishes.
- Ordering guarantee: exactly one terminal event (`job_complete` XOR `job_error`) ends the stream.
- **Cancellation** is delivered as a terminal `job_error` with `error_code: "cancelled"` (there is no separate event type); `GET /jobs` then reports the job `status: "cancelled"`.
- **`pages`** (present on `job_complete`) is an **integer page count**, not a list of filenames. Page filenames come from unzipping `GET /output`.
- **`ts` format:** RFC3339 / ISO-8601 **with a timezone offset** — always UTC `Z` (e.g. `2026-05-29T20:14:07Z`). Consumers should tolerate fractional seconds.
- **SSE framing:** each event is `data: <json>\n\n`. If an `event:` line is also sent, it MUST equal the JSON `type`; otherwise omit it. The `POST /jobs` response is `{ "job_id": "<uuid>" }` (key is `job_id`, not `id`).

### `SceneList` (internal text-stage output) — `schemas/scene_list.schema.json`
Produced by the LLM (guided JSON decoding), consumed by the image + assembly stages. Not returned
to the app directly, but defined here so both stages agree on shape.
```json
{
  "characters": [
    { "name": "Gregor Samsa", "appearance_prompt": "…", "ref_sheet_prompt": "…" }
  ],
  "scenes": [
    { "index": 0, "title": "…", "image_prompt": "…",
      "characters_present": ["Gregor Samsa"], "caption": "…", "pivotal": false }
  ]
}
```

## Stub / mock mode (enables offline, code-first development)

- The **service** honors `BOOK2VISUAL_STUB=1`: it skips all GPU work and emits deterministic
  placeholder panels + a canned `SceneList`, while still streaming the full real event sequence
  and producing a real `output.zip`. This lets `service/` run and be tested on macOS with no GPU.
- `mockserver/` is a tiny standalone implementation of this contract for the **app** to develop
  against with no Thunder account and no `service/` checkout.
- Both MUST emit byte-compatible event/HTTP shapes so swapping in the real service is a no-op.
