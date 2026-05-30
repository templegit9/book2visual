# Book2Visual mock server

Standalone, contract-faithful mock of the pipeline service. No GPU, no Thunder,
no `service/` checkout required. The macOS app develops against this. Event and
HTTP shapes are byte-compatible with the real `service/`.

## Run

```bash
pip install fastapi "uvicorn[standard]" pydantic pillow sse-starlette
uvicorn mockserver:app --host 127.0.0.1 --port 8000
```

(from inside `mockserver/`)

## What it does

- `GET /health` → `{"status":"ok","models_loaded":true,"stub":true}`
- `POST /jobs` → `{"job_id": "..."}`, or `409 {"error":"job_already_running"}`
- `GET /jobs/{id}/stream` → fast SSE ProgressEvents (~9 scenes incl. one pivotal),
  ending in exactly one `job_complete`.
- `POST /jobs/{id}/cancel` → `{"status":"cancelling"}` (stops after current scene)
- `GET /jobs/{id}/output` → a real small `output.zip` of PNG pages (409 until complete)
- `GET /jobs` → recent job statuses
