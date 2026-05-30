# Runbook: pre-bake a Book2Visual snapshot (ThunderCompute)

Goal: provision a production **A100 80GB** instance, install deps + download all
weights once, verify the service, then snapshot so future runs launch instantly.

> Control plane is the Thunder REST API (`https://api.thundercompute.com:8443`,
> `Authorization: Bearer <token>`). The `tnr` CLI works too; both are shown.

## 1. Provision (production mode, A100 80GB)

REST:
```bash
curl -sX POST https://api.thundercompute.com:8443/instances/create \
  -H "Authorization: Bearer $THUNDER_TOKEN" -H "Content-Type: application/json" \
  -d '{"gpuType":"a100-80gb","mode":"production","public_key":"'"$(cat ~/.ssh/b2v.pub)"'"}'
# Poll until status=RUNNING and read ip/port:
curl -sX GET https://api.thundercompute.com:8443/instances/list \
  -H "Authorization: Bearer $THUNDER_TOKEN" | jq '.[] | {id,status,ip,port,gpuType}'
```
`tnr` equivalent: `tnr create --gpu a100-80gb --mode production` then `tnr status`.

Note: SSH user is **ubuntu**; the `port` from the list response is not always 22.

## 2. Bootstrap (on the instance)

```bash
ssh -i ~/.ssh/b2v -p <port> ubuntu@<ip>
git clone <repo> ~/Book2Visual && cd ~/Book2Visual/service
export HF_TOKEN=<your hf token>     # required for gated FLUX weights
mkdir -p _logs
bash scripts/bootstrap_instance.sh   # installs deps, downloads weights, starts vLLM + service
```
Expect `{"status":"ok","models_loaded":true,"stub":false}` from `/health`.

## 3. Verify a real run (smoke)

```bash
curl -s 127.0.0.1:8000/health
JOB=$(curl -sX POST 127.0.0.1:8000/jobs -H 'Content-Type: application/json' \
  -d '{"text":"<~2000-4000 word story>","characters":[{"name":"Gregor"}]}' | jq -r .job_id)
curl -N 127.0.0.1:8000/jobs/$JOB/stream     # watch ProgressEvents to job_complete
curl -s 127.0.0.1:8000/jobs/$JOB/output -o out.zip && unzip -l out.zip
```

## 4. Snapshot

REST:
```bash
curl -sX POST https://api.thundercompute.com:8443/snapshots/create \
  -H "Authorization: Bearer $THUNDER_TOKEN" -H "Content-Type: application/json" \
  -d '{"instanceId":"<id>","name":"book2visual-a100-prebaked"}'
```
`tnr` equivalent: `tnr snapshot create <id> --name book2visual-a100-prebaked`.

Launch future instances FROM the snapshot (`template`/`snapshotId` field) so deps
+ weights are already present. Do **not** rely on the plain persistent disk
surviving `/down` — Thunder's own docs dispute it; the snapshot is the durable
mechanism. Confirm restore timing during the live spike.

## 5. Tear down (stop billing)

`POST /instances/{id}/down` (or `tnr stop <id>`). Per-minute billing stops on
down. Delete with `POST /instances/{id}/delete` when finished.
