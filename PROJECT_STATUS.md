# Book2Visual — Project Status & Operations Guide

**Last updated:** 2026-05-30
**Repo:** https://github.com/templegit9/book2visual
**Status:** ✅ Working end-to-end on real GPU. Validated. Thunder spend at $0 (instance + snapshots deleted).

---

## What Book2Visual is

A native **macOS (SwiftUI) app** that turns a short story you own into a condensed,
AI-interpreted **colored-anime visual adaptation**. It runs **open-source models** on a
**user-rented ThunderCompute GPU** — the Mac app is the control plane; all generation happens on
the rented instance (private, no third-party AI APIs).

- **Text stage:** Qwen2.5-32B-Instruct-AWQ (served by vLLM) extracts key scenes + per-character
  descriptions + author-voice captions (guided JSON).
- **Image stage:** FLUX.1-dev generates one canonical reference per character; **FLUX.1-Kontext-dev**
  conditions each panel on that reference (depth-1 fan-out — never chained) for character consistency;
  an anime style LoRA gives the anime look.
- **Assembly:** Pillow tiles panels into 2×2 pages (1536×1536), full-page slots for pivotal scenes,
  burned-in caption boxes → `output.zip` of PNG pages.

---

## ✅ Proven (2026-05-30 live run)

Ran the demo "Lighthouse" story end-to-end on a real **A100 80GB**:
- Qwen-32B extracted **7 scenes, 2 characters** in ~80s.
- FLUX + Kontext + anime LoRA generated reference sheets + 7 panels.
- Output: **4 pages** (2× 2×2 grids + 2 full-page pivotal scenes), characters **recognizably
  consistent** across panels, correct anime style, legible captions.
- **The #1 technical risk — anime LoRA composing with FLUX Kontext while preserving identity — is
  RESOLVED.** `consistency_mode=kontext` is the shippable default.

Generated pages are in `_live_test_output/` (gitignored).

---

## Repository layout

```
contract/    Source-of-truth interface (OpenAPI + JSON schemas + CONTRACT.md)
service/     Python: FastAPI + Qwen(vLLM)/FLUX-Kontext pipeline + Pillow assembly
             - BOOK2VISUAL_STUB=1 runs the whole thing with NO GPU (offline dev/test)
             - scripts/bootstrap_instance.sh  (one-time: deps + weight download)
             - scripts/start_services.sh       (launch vLLM + FastAPI in tmux)
mockserver/  Standalone contract-faithful mock for offline app development
app/         macOS SwiftUI app (Swift Package): Thunder REST client, SSH tunnel,
             Keychain, SSE job client, in-app viewer
docs/        SETUP.md, THUNDER_SPIKE.md, CONSISTENCY_SPIKE.md
Book2Visual-PRD.md   Full PRD (Section 0 = authoritative v1.1 corrections)
```

**Tests (offline, no GPU):** `cd service && .venv/bin/pytest` (21 pass) ·
`cd app && swift build && swift test` (32 pass).

---

## Verified facts that shaped the build (don't regress)

- **ThunderCompute control plane = REST** `https://api.thundercompute.com:8443`, `Authorization: Bearer`.
  SSH user is **`ubuntu`**; read ip+port from `GET /instances/list` (no per-instance status endpoint).
- Use **production mode** A100 80GB (prototyping GPUs are virtual/GPU-over-TCP and need a `tnr connect`
  shim that raw SSH lacks).
- **`tnr` CLI has NO start/stop/up/down** — only create/status/connect/modify/delete/scp/ports/snapshot.
  Halt billing with `tnr delete <id>`.
- **Character consistency = FLUX.1-Kontext-dev** depth-1 fan-out. FLUX IP-Adapters explicitly disclaim
  character consistency; PuLID is weak on anime faces. FLUX has a photoreal bias → an explicit anime
  **style LoRA** is required.
- FLUX.1-dev / Kontext-dev are **non-commercial** weights (fine for personal use; FLUX.1-schnell is the
  Apache-2.0 commercial escape hatch).

---

## Live-run gotchas (all fixed in repo)

1. **`huggingface-cli` removed in huggingface_hub ≥1.0** → use `hf download` (bootstrap fixed).
2. **Two venvs required** — vLLM 0.6.6 needs `transformers==4.47.1` + `numpy<2`; FLUX Kontext needs
   `diffusers≥0.35` + transformers 5.x. They can't share a venv:
   - `service/.venv`      → FLUX/diffusers (FastAPI service)
   - `service/.venv-vllm` → vLLM sidecar (LLM)
   They communicate over HTTP (`BOOK2VISUAL_VLLM_URL=http://127.0.0.1:8001/v1`).
3. **OOM fix** — the Kontext backend loaded TWO full FLUX transformers via `.to("cuda")` (~62GB) on top
   of vLLM → OOM on 80GB. Now `enable_model_cpu_offload()` by default (`BOOK2VISUAL_FLUX_RESIDENT=1`
   forces full-GPU on a dedicated, no-sidecar card). Run vLLM at `--gpu-memory-utilization 0.35
   --max-model-len 8192`. Trade-off: CPU offload makes panels ~1 min each (~13 min for a 7-scene job).
4. **No systemd on the instance** (container-based) → use `scripts/start_services.sh` (tmux), not unit
   files. The vLLM serve command must be ONE line (flag wrapping breaks it).
5. **App live path** — `AppEnvironment.live()` originally never opened an SSH tunnel. Fixed: a shared
   `SSHTunnel` opens on Start Instance, closes on Stop.

---

## How to resume (rebuild from scratch — snapshots were deleted)

> All code is on GitHub; rebuild costs a one-time ~30–60 min weight download + GPU time.

```bash
# 1. Provision a production A100 80GB
tnr create --gpu a100 --num-gpus 1 --mode production --vcpus 18 --primary-disk 200
tnr status                      # wait for RUNNING; note it gets a NEW id + ip/port
tnr connect <id>                # opens the instance shell (ubuntu@…)

# 2. On the instance: get code + one-time bootstrap
git clone https://github.com/templegit9/book2visual.git
cd ~/book2visual/service
export HF_TOKEN=<a fresh HF token, with FLUX.1-dev + FLUX.1-Kontext-dev licenses ACCEPTED>
bash scripts/bootstrap_instance.sh     # installs deps (two venvs) + downloads weights

# 3. Launch services (idempotent; tmux)
HF_TOKEN=$HF_TOKEN bash scripts/start_services.sh
curl -s 127.0.0.1:8001/v1/models       # vLLM ready?
curl -s 127.0.0.1:8000/health          # {"status":"ok","models_loaded":...,"stub":false}

# 4a. Submit a job over the instance shell (smoke test)
curl -s -X POST 127.0.0.1:8000/jobs -H 'Content-Type: application/json' \
  -d '{"text":"<2-4k word story>","characters":[{"name":"X","race_hint":"..."}],
       "vram_mode":"concurrent","consistency_mode":"kontext"}'
# then GET /jobs/<id>/stream and /jobs/<id>/output

# 4b. OR drive it from the Mac app (see below)

# 5. Stop billing when done
tnr delete <id>                 # (optionally `tnr snapshot create ...` first to bank setup)
```

### Using the Mac app live
```bash
cd app && swift run             # (or generate a .app: xcodegen generate && open in Xcode)
```
In the app: **Settings** → paste Thunder API token (→ Keychain) → pick SSH key path
(the tnr key at `~/.thunder/keys/<uuid>`) → set instance id → **Start Instance** (opens the SSH
tunnel) → run `start_services.sh` on the instance if not auto-running → **Run** your story → **Viewer**.

**Offline (no GPU/account):** `BOOK2VISUAL_MOCK=1 swift run` (or point at `mockserver/`).

---

## Costs

- Compute: A100 80GB ≈ **$0.78/hr** (Thunder, per-minute). A full short-story run ≈ <$2.
- Snapshots: ~**$0.05/GB/mo** while stored. (We deleted ours → $0.)
- **Current Thunder spend: $0** (instance deleted; snapshots deleted).
- A future snapshot can be cheaper with a smaller `--primary-disk` (real content ~127GB, not 250GB).

---

## Action items / loose ends

- [ ] **Revoke the two HF tokens** pasted during setup (`hf_MCPP…`, `hf_ARDv…`) at
      https://huggingface.co/settings/tokens — treat as exposed. Use a fresh token when rebuilding.
- [ ] Confirm both Thunder snapshots are deleted (`tnr snapshot list` → empty) so spend is truly $0.
- [ ] (Optional) LoRA-mode A/B vs Kontext to double-confirm the default.
- [ ] (Optional) Full Mac-app GUI run against a live instance (the path is wired but not yet GUI-tested
      end-to-end on real hardware).
- [ ] (Optional, v2+) systemd-less autostart polish, EPUB/PDF export, scene-review UI, Homebrew dist.
```
