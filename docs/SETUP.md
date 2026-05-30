# Book2Visual — Live Setup Runbook (Milestone 3)

The master end-to-end runbook for bringing Book2Visual up on real ThunderCompute hardware.
Do this once; afterward the app launches from the snapshot in ~1 minute with zero setup time.

> **Cost:** an A100 80GB on Thunder is ~$0.78/hr (per-minute billing). A full demo run is
> typically <$2. The one-time bootstrap (weight download) adds ~30–60 min of instance time
> (~$0.50–1.00) plus snapshot storage (~$0.05/GB/month).

## Prerequisites (you run these — they need your account / a browser)

```bash
# 1. Install the Thunder CLI (only needed for login + as a fallback; the app uses REST directly)
! pip install tnr

# 2. Interactive browser login — creates ~/.thunder credentials and is the easiest way to mint a token
! tnr login
#    Then create an API token at https://console.thundercompute.com/settings/tokens
#    Keep it handy — you'll paste it into the app's Settings (stored in macOS Keychain) OR export it:
! export TNR_API_TOKEN=<your-token>
```

## Step 1 — Provision a PRODUCTION A100 80GB

Production mode (not prototyping) gives a real attached GPU that raw SSH can use.

```bash
# Generate a dedicated keypair for Book2Visual (the app does this automatically; manual fallback:)
! ssh-keygen -t ed25519 -f ~/.ssh/book2visual_ed25519 -N ""

# Create the instance (REST; or `tnr create --gpu a100 --num-gpus 1 --mode production --primary-disk 250`)
#   - gpu_type: a100xl (80GB) ; mode: production ; disk: >=250GB (weights ~52GB)
#   - pass our public key so we keep the private key
```
See `docs/THUNDER_SPIKE.md` for the exact REST calls and the persistent-disk verification.

## Step 2 — Bootstrap the instance (one-time)

```bash
# Copy the service to the instance (user is `ubuntu`, read ip+port from the instance list)
! scp -i ~/.ssh/book2visual_ed25519 -P <port> -r service ubuntu@<ip>:~/book2visual
! ssh -i ~/.ssh/book2visual_ed25519 -p <port> ubuntu@<ip> \
    'export HF_TOKEN=<your-hf-token>; bash ~/book2visual/scripts/bootstrap_instance.sh'
```
`bootstrap_instance.sh` does the whole one-time setup: installs deps, pre-downloads all weights
(Qwen2.5-32B-AWQ + FLUX.1-dev + FLUX.1-Kontext-dev + an anime LoRA), and starts the vLLM sidecar
+ FastAPI service on `127.0.0.1:8000`. `HF_TOKEN` is required (gated FLUX weights).

## Step 3 — Snapshot (so you never re-setup)

```bash
# Confirm the service is healthy (bootstrap already started it):
! ssh -i ~/.ssh/book2visual_ed25519 -p <port> ubuntu@<ip> 'curl -s 127.0.0.1:8000/health'
#   expect {"status":"ok","models_loaded":true,"stub":false}
# Then snapshot — full runbook in service/scripts/make_snapshot.md
```
Future instances are created FROM this snapshot → weights already present, instant start.

## Step 4 — Run the app

1. Build/run the macOS app (`cd app && swift run`, or generate the .app via `xcodegen generate`).
2. Settings → paste your Thunder API token (→ Keychain), pick the SSH key, set the snapshot.
3. Setup → **Start Instance** (launches from snapshot), wait for green.
4. Run → paste your demo short story (2–4k words), add characters + race hints, choose
   `consistency_mode` (kontext vs lora for the A/B), **Run Adaptation**.
5. Watch live per-scene progress; pages auto-download and open in the Viewer; **Stop Instance**
   when done to stop billing.

## Offline alternative (no Thunder needed)
Point the app at the local mock: `cd mockserver && python mockserver.py` (see its README), then
set the app's port to the mock — exercises the whole UX with no GPU/account.
