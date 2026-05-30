#!/usr/bin/env bash
# bootstrap_instance.sh — one-time setup of a ThunderCompute GPU instance.
#
# Run this ON the instance (Ubuntu + CUDA, production-mode A100 80GB) as the
# `ubuntu` user. It installs deps, pre-downloads all model weights, then starts
# the vLLM sidecar and the FastAPI service bound to 127.0.0.1:8000.
#
# After it verifies healthy, snapshot the instance (see make_snapshot.md) so
# future runs launch from the pre-baked image with zero setup time.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/Book2Visual/service}"
LLM_MODEL="${BOOK2VISUAL_LLM_MODEL:-Qwen/Qwen2.5-32B-Instruct-AWQ}"
FLUX_MODEL="${BOOK2VISUAL_FLUX_MODEL:-black-forest-labs/FLUX.1-dev}"
KONTEXT_MODEL="${BOOK2VISUAL_KONTEXT_MODEL:-black-forest-labs/FLUX.1-Kontext-dev}"
ANIME_LORA="${BOOK2VISUAL_ANIME_LORA:-alfredplpl/flux.1-dev-modern-anime-lora}"
VLLM_PORT="${VLLM_PORT:-8001}"
SERVICE_PORT="${BOOK2VISUAL_PORT:-8000}"

echo "==> System packages"
sudo apt-get update -y
sudo apt-get install -y python3.11 python3.11-venv python3-pip git git-lfs
git lfs install || true

echo "==> Python venv + deps"
cd "$REPO_DIR"
python3.11 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip
# Torch first from the CUDA index, then the rest.
pip install torch==2.5.1 --index-url https://download.pytorch.org/whl/cu124
pip install -r requirements.txt

echo "==> Pre-download model weights"
# HF_TOKEN must be exported for the gated FLUX weights.
# huggingface_hub >=1.0 dropped `huggingface-cli`; the command is now `hf download`.
# Install the CLI explicitly (not all base images ship it) and authenticate non-interactively.
pip install -U "huggingface_hub[cli]"
if [ -n "${HF_TOKEN:-}" ]; then hf auth login --token "$HF_TOKEN" || true; fi
hf download "$LLM_MODEL"
hf download "$FLUX_MODEL"
hf download "$KONTEXT_MODEL"
hf download "$ANIME_LORA"

echo "==> Start vLLM sidecar (OpenAI-compatible, guided decoding)"
nohup python -m vllm.entrypoints.openai.api_server \
  --model "$LLM_MODEL" \
  --host 127.0.0.1 --port "$VLLM_PORT" \
  --max-model-len 16384 \
  --gpu-memory-utilization 0.45 \
  > "$REPO_DIR/_logs/vllm.out" 2>&1 &

echo "==> Wait for vLLM to be ready"
for _ in $(seq 1 120); do
  if curl -sf "http://127.0.0.1:${VLLM_PORT}/v1/models" >/dev/null; then
    echo "vLLM ready."; break
  fi
  sleep 5
done

echo "==> Start FastAPI service (real GPU mode; STUB unset)"
unset BOOK2VISUAL_STUB
export BOOK2VISUAL_VLLM_URL="http://127.0.0.1:${VLLM_PORT}/v1"
nohup uvicorn app.main:app --host 127.0.0.1 --port "$SERVICE_PORT" \
  > "$REPO_DIR/_logs/service.out" 2>&1 &

echo "==> Verify"
for _ in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:${SERVICE_PORT}/health" >/dev/null; then
    curl -s "http://127.0.0.1:${SERVICE_PORT}/health"; echo
    echo "Service healthy. Ready to snapshot."
    exit 0
  fi
  sleep 5
done
echo "Service did not become healthy in time; check _logs/." >&2
exit 1
