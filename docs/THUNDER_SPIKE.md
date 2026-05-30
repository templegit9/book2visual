# Spike 1 — ThunderCompute lifecycle validation

**Goal:** confirm the integration assumptions before trusting them in the app. ~30 min, <$1.
All facts below were verified against the live API spec + `tnr` CLI source, but two items are
marked **[CONFIRM]** because Thunder's own docs were self-contradictory — verify empirically.

Base URL `https://api.thundercompute.com:8443`, header `Authorization: Bearer $TNR_API_TOKEN`.

## 1. Create a production A100 80GB with our own key
```bash
PUB=$(cat ~/.ssh/book2visual_ed25519.pub)
curl -s -X POST https://api.thundercompute.com:8443/instances/create \
  -H "Authorization: Bearer $TNR_API_TOKEN" -H "Content-Type: application/json" \
  -d "{\"cpu_cores\":18,\"gpu_type\":\"a100xl\",\"num_gpus\":1,\"disk_size_gb\":250,\"mode\":\"production\",\"template\":\"base\",\"public_key\":\"$PUB\"}"
# -> {"identifier":<id>,"uuid":"...","key":null}   (key null because we supplied public_key — good)
```

## 2. Poll status (NO per-instance endpoint — use the list)
```bash
curl -s https://api.thundercompute.com:8443/instances/list -H "Authorization: Bearer $TNR_API_TOKEN"
# wait until the instance shows status=="RUNNING" AND a non-null ip; note ip + port.
```

## 3. Raw SSH as `ubuntu` (NOT root), reading port from the list
```bash
ssh -i ~/.ssh/book2visual_ed25519 -p <port> -o StrictHostKeyChecking=accept-new ubuntu@<ip> \
  'nvidia-smi -L'   # MUST list a real A100. If GPU is missing -> you got a prototyping box, not production.
```
**[CONFIRM]** that a raw SSH session (no `tnr connect`) has a working CUDA device. Production mode
should give a real attached GPU; if `nvidia-smi` fails, the GPU-over-TCP shim assumption applies and
you must either use `tnr connect` once or stay strictly in production mode.

## 4. Stop / start and the persistent-disk question  **[CONFIRM — the decisive test]**
```bash
ssh ... ubuntu@<ip> 'echo hello > ~/persist_probe.txt && ls -la ~/persist_probe.txt'
curl -s -X POST https://api.thundercompute.com:8443/instances/<id>/down -H "Authorization: Bearer $TNR_API_TOKEN"
# wait for STOPPED, then:
curl -s -X POST https://api.thundercompute.com:8443/instances/<id>/up   -H "Authorization: Bearer $TNR_API_TOKEN"
# wait for RUNNING + new ip, then:
ssh ... ubuntu@<ip> 'cat ~/persist_probe.txt'   # if "hello" survives -> persistent disk works across stop/start
```
- **If the probe survives:** you can cache weights on the home disk and rely on stop/start. Simpler.
- **If it does NOT survive:** weights must live in a **snapshot**; create new instances from the
  snapshot each session (the design already assumes this as the safe default).

## 5. Snapshot create/restore timing
```bash
curl -s -X POST https://api.thundercompute.com:8443/snapshots/create \
  -H "Authorization: Bearer $TNR_API_TOKEN" -H "Content-Type: application/json" \
  -d "{\"instanceId\":<id>,\"name\":\"book2visual-base\"}"
curl -s https://api.thundercompute.com:8443/snapshots/list -H "Authorization: Bearer $TNR_API_TOKEN"
# Record how long create takes and how long create-from-snapshot takes (feeds the app's "Prepare Environment" UX).
```

## 6. Tear down (stop billing)
```bash
curl -s -X POST https://api.thundercompute.com:8443/instances/<id>/down -H "Authorization: Bearer $TNR_API_TOKEN"
# or /delete to remove entirely (keeps the snapshot).
```

## Report back
The two **[CONFIRM]** answers (raw-SSH GPU works? persistent disk survives stop/start?) determine
whether the app's `ThunderRESTInstanceManager` + snapshot flow is final or needs a tweak. Paste the
`nvidia-smi -L` output, the persist-probe result, and the snapshot timings.
