# Book2Visual — Pipeline Service (`service/`)

Remote FastAPI service that turns a short story into a colored-anime visual
adaptation. Runs on a ThunderCompute GPU instance in production; runs and is
fully testable on a GPU-less Mac via **stub mode**. Conforms exactly to
`../contract/` (openapi.yaml + schemas).

## Layout

```
service/
├── app/                     FastAPI surface + job lifecycle
│   ├── main.py              endpoints: /health, /jobs, /jobs/{id}/stream (SSE),
│   │                        /jobs/{id}/cancel, /jobs/{id}/output, GET /jobs
│   ├── models.py            pydantic models mirroring contract schemas
│   │                        (extra="forbid" == additionalProperties:false)
│   ├── jobs.py              single-job lock, async run, SSE fan-out,
│   │                        guaranteed single terminal event
│   ├── orchestrator.py      drives text -> image -> assembly; stub vs real switch
│   ├── logging_setup.py     rotating JSON logs (10MB x 3 files)
│   └── config.py            env-driven config
├── pipeline/
│   ├── text_stage.py        vLLM OpenAI client + JSON-schema guided decoding
│   ├── image_stage.py       per-character reference, depth-1 panel fan-out
│   ├── consistency/
│   │   ├── kontext.py       FLUX.1-Kontext-dev (primary)
│   │   └── lora.py          per-character anime LoRA on FluxPipeline (fallback)
│   ├── vram.py              concurrent vs sequenced load strategies (VRAM math)
│   ├── assembly.py          Pillow 2x2 pages (1536²), pivotal full-page slots,
│   │                        translucent caption boxes -> output.zip
│   └── fonts.py             bundled-TTF caption font loader
├── stub/fake_pipeline.py    deterministic no-GPU SceneList + placeholder panels
├── scripts/                 bootstrap_instance.sh, make_snapshot.md
├── assets/fonts/            DejaVuSans.ttf (bundled) + NOTICE.md
├── tests/                   pytest: contract, SSE ordering, assembly, stub e2e
├── requirements.txt         light runtime deps + (commented) instance-only GPU deps
└── README.md
```

## Stub mode (no GPU)

Set `BOOK2VISUAL_STUB=1`. The service does **zero** GPU work: it emits the full
real event sequence and produces a real `output.zip` from PIL-drawn placeholder
panels and a canned SceneList. The GPU code paths (torch / diffusers / vLLM) are
import-guarded — imported lazily only when stub mode is OFF — so `pip install` of
torch/diffusers/vllm is **not** required to run or test here.

## Environment variables

| Var | Default | Meaning |
|---|---|---|
| `BOOK2VISUAL_STUB` | unset (0) | `1` = no-GPU stub mode |
| `BOOK2VISUAL_LLM_MODEL` | `Qwen/Qwen2.5-32B-Instruct-AWQ` | vLLM model id |
| `BOOK2VISUAL_VLLM_URL` | `http://127.0.0.1:8001/v1` | vLLM OpenAI endpoint |
| `BOOK2VISUAL_FLUX_MODEL` | `black-forest-labs/FLUX.1-dev` | base FLUX |
| `BOOK2VISUAL_KONTEXT_MODEL` | `black-forest-labs/FLUX.1-Kontext-dev` | Kontext |
| `BOOK2VISUAL_ANIME_LORA` | `alfredplpl/flux.1-dev-modern-anime-lora` | anime style LoRA |
| `BOOK2VISUAL_PANEL_SIZE` | `768` | panel px (pages are 2× = 1536) |
| `BOOK2VISUAL_DATA_DIR` | `service/_jobs` | per-job output dir |
| `BOOK2VISUAL_LOG_DIR` | `service/_logs` | rotating JSON logs |
| `BOOK2VISUAL_HOST` / `_PORT` | `127.0.0.1` / `8000` | bind address |

## Setup (Mac, light deps only)

```bash
cd service
python3.11 -m venv .venv
source .venv/bin/activate
pip install fastapi "uvicorn[standard]" pydantic pillow httpx sse-starlette pytest pytest-asyncio
```

(Do **not** install the GPU deps from requirements.txt on a Mac.)

## Run the tests

```bash
cd service && source .venv/bin/activate
pytest            # BOOK2VISUAL_STUB is forced on inside tests/conftest.py
```

## Run the service (stub mode)

```bash
cd service && source .venv/bin/activate
BOOK2VISUAL_STUB=1 uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Smoke test:

```bash
curl -s 127.0.0.1:8000/health
JOB=$(curl -sX POST 127.0.0.1:8000/jobs -H 'Content-Type: application/json' \
  -d '{"text":"a story ...","characters":[{"name":"Gregor"}]}' | python -c 'import sys,json;print(json.load(sys.stdin)["job_id"])')
curl -N 127.0.0.1:8000/jobs/$JOB/stream          # SSE to job_complete
curl -s 127.0.0.1:8000/jobs/$JOB/output -o out.zip && unzip -l out.zip
```

## Real GPU mode (on the instance)

Unset `BOOK2VISUAL_STUB`, run `scripts/bootstrap_instance.sh` (installs the GPU
deps, downloads weights, starts the vLLM sidecar + the service), then snapshot
per `scripts/make_snapshot.md`. The service calls vLLM over its OpenAI-compatible
endpoint with JSON-schema guided decoding and generates panels with FLUX +
Kontext (or per-character LoRA), depth-1 fan-out from one reference per character.

## Contract conformance notes

- `POST /jobs` returns `409 {"error":"job_already_running"}` when a job is active.
- SSE: `job_accepted` → `stage_update`/`scene_start`/`scene_complete` per scene →
  exactly one terminal `job_complete` (carries `pages`) XOR `job_error`.
- `GET /jobs/{id}/output` returns `409` until the job is complete.
- All request models use `extra="forbid"` so unknown fields → `422`.
```
