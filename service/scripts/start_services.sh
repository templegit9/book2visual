#!/usr/bin/env bash
# start_services.sh — launch the vLLM sidecar + FastAPI pipeline service.
#
# The ThunderCompute instance is container-based (no systemd), so services are
# started by this idempotent script instead of unit files. Run it after the
# instance comes up (the Mac app can invoke it over SSH right after Start
# Instance, or run it once manually). Both run in tmux so they survive SSH drops.
#
#   HF_TOKEN=hf_xxx bash scripts/start_services.sh
#
# Idempotent: if a session is already serving, it is left alone.
set -uo pipefail

SVC="${REPO_DIR:-$HOME/book2visual/service}"
cd "$SVC"
mkdir -p _logs

need() { command -v tmux >/dev/null || { echo "tmux missing: sudo apt-get install -y tmux"; exit 1; }; }
need

# --- vLLM sidecar (isolated venv: vllm 0.6.6 + transformers 4.47.1) -----------
if curl -sf -m3 http://127.0.0.1:8001/v1/models >/dev/null 2>&1; then
  echo "vLLM already serving."
else
  tmux kill-session -t vllm 2>/dev/null || true
  tmux new-session -d -s vllm \
    "cd '$SVC' && source .venv-vllm/bin/activate && \
     export HF_TOKEN='${HF_TOKEN:-}' && \
     vllm serve Qwen/Qwen2.5-32B-Instruct-AWQ --host 127.0.0.1 --port 8001 \
       --max-model-len 8192 --gpu-memory-utilization 0.35 2>&1 | tee _logs/vllm.out"
  echo "vLLM launching (tmux: vllm). ~3-4 min to load the 32B."
fi

# --- FastAPI pipeline service (main venv: diffusers/FLUX) ---------------------
if curl -sf -m3 http://127.0.0.1:8000/health >/dev/null 2>&1; then
  echo "FastAPI service already up."
else
  tmux kill-session -t svc 2>/dev/null || true
  tmux new-session -d -s svc \
    "cd '$SVC' && source .venv/bin/activate && \
     export HF_TOKEN='${HF_TOKEN:-}' BOOK2VISUAL_VLLM_URL=http://127.0.0.1:8001/v1 \
            PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True && \
     unset BOOK2VISUAL_STUB && \
     uvicorn app.main:app --host 127.0.0.1 --port 8000 2>&1 | tee _logs/service.out"
  echo "FastAPI service launching (tmux: svc)."
fi

echo "Done. Check:  curl -s 127.0.0.1:8001/v1/models   and   curl -s 127.0.0.1:8000/health"
