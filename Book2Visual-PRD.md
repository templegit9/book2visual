# Book2Visual — Product Requirements Document

**Version:** 1.1  
**Date:** 2026-05-29  
**Status:** Ready for implementation  
**Author:** Product discovery session — sole owner/developer

---

## 0. v1.1 Addendum — Research Corrections (authoritative; overrides conflicting text below)

The original v1.0 body (Sections 1–12) was written before integration research. The following
corrections were verified against the live ThunderCompute API spec + `tnr` CLI source and current
HuggingFace model cards (2026-05-29). **Where this addendum conflicts with the body, this wins.**

1. **Thunder control plane is a direct REST API**, not a CLI dependency. Base
   `https://api.thundercompute.com:8443`, header `Authorization: Bearer <token>`. The Swift app
   calls it directly with `URLSession`; it does **not** shell out to `tnr`.
   - Start = `POST /instances/{id}/up`; Stop = `POST /instances/{id}/down`;
     Delete = `POST /instances/{id}/delete`; Create = `POST /instances/create`.
   - **No per-instance status endpoint** — poll `GET /instances/list` (returns `status`, `ip`,
     `port`, `gpuType` per instance). This replaces FR-INST-01's "tnr subprocess" framing and the
     §8 "Thunder REST API / tnr CLI" ambiguity.
2. **SSH user is `ubuntu`** (not `root`). Read `ip` and `port` from the list response — port is
   not always 22. Supply our own `public_key` at create time and keep the matching private key
   (otherwise Thunder returns a generated private key exactly once). Updates FR-SSH-01/05.
3. **Real GPU menu (per-minute billing):** A6000 48GB ($0.27/hr), **A100 80GB ($0.78 — default
   target)**, L40, L40S, H100 80GB ($1.38). **A100 40GB and T4 DO NOT EXIST on Thunder** — the
   Appendix (§12) tiers referencing them are void. The ≤$2/run goal (G3/NFR-COST-01) is comfortable
   on A100 80GB at $0.78/hr.
4. **Use production mode, not prototyping.** Prototyping GPUs are virtual (GPU-over-TCP via an
   `LD_PRELOAD` shim only `tnr connect` installs); raw SSH into a prototyping box may have **no
   working CUDA device**. Production mode gives a real attached GPU that raw SSH can use.
5. **Snapshots are the durable pre-bake / "custom image" mechanism** (`POST /snapshots/create`,
   then launch new instances from that snapshot as `template`). Whether the plain persistent disk
   survives `/down` is **disputed in Thunder's own docs** — do not rely on it; use snapshots. The
   app orchestrates a one-time "Prepare Environment" flow: provision → bootstrap (deps + weights)
   → snapshot. This realizes the §6b/§7 weight-persistence intent. (NB: you cannot build a
   Linux/CUDA env on macOS and upload it — wrong OS/arch; weights download on the instance.)
6. **Character consistency mechanism changes.** FLUX **IP-Adapters explicitly disclaim character
   consistency** on their own model cards, and **PuLID** (InsightFace, real-face-trained) is weak
   on anime. The mechanism is **FLUX.1-Kontext-dev** used **depth-1 fan-out** (one canonical
   reference → each panel conditioned independently, **never chained** — Kontext drifts after ~5–6
   chained edits). Fallback for a recurring cast: **per-character anime LoRA**. v1 implements both
   behind `consistency_mode` and A/Bs them on the demo. This **supersedes FR-IMG-02's IP-Adapter**.
7. **LLM serving:** `Qwen/Qwen2.5-32B-Instruct-AWQ` (A100 80GB) or `Qwen2.5-14B-Instruct-AWQ`
   (tighter), served by a **vLLM sidecar process** with **JSON-schema guided decoding**
   (`response_format` json_schema). FastAPI calls vLLM's OpenAI-compatible endpoint; the engine is
   NOT embedded in the FastAPI worker. Refines FR-TEXT-06 (default model id corrected to the AWQ
   build; backend fixed to vLLM).
8. **Licensing:** FLUX.1-dev and FLUX.1-Kontext-dev are **non-commercial** weights — fine for this
   personal-use product. FLUX.1-schnell (Apache-2.0) is the commercial escape hatch if Book2Visual
   is ever sold.
9. **FLUX has a photoreal bias** — an explicit anime **style LoRA** is required (e.g.
   `alfredplpl/flux.1-dev-modern-anime-lora`, or `Shakker-Labs/FLUX.1-Kontext-dev-LoRA-Flat-Cartoon-Style`),
   not just style words in the prompt (FR-IMG-03). **Top open risk:** whether an anime style LoRA
   composes with `FluxKontextPipeline` while preserving identity — validated by the consistency spike
   before the architecture is committed.

---

## 1. Title and One-Line Summary

**Book2Visual** — A native macOS app that converts a story you own into a condensed, AI-interpreted colored-anime visual adaptation, running entirely on your rented GPU with no cloud API required.

---

## 2. Problem Statement and Background

### The problem

A reader finishes a book they love and wants to re-experience it in a different medium — as a manga or anime-style visual adaptation. Professional adaptations exist for a handful of blockbuster titles, but the overwhelming majority of books are never adapted. Fan adaptations are prohibitively time-intensive: commissioning art is expensive; hand-drawing is a craft skill most readers don't have.

AI image and language models have now crossed a capability threshold where this is technically tractable for a solo developer. Capable open-source LLMs (Qwen2.5 family) can extract narrative scenes and write prose captions faithful to an author's voice. FLUX-family diffusion models can generate consistently styled images at high quality. IP-Adapter techniques can anchor character appearance across multiple generated panels, addressing the historic consistency failure mode of generative manga tools.

The missing piece is a coherent, end-to-end, cost-effective pipeline that stitches these components together and presents the result as something a reader can actually look at and enjoy — without requiring a machine-learning background to operate.

### Why now

- Qwen2.5-32B (4-bit quantized) runs on a single A100 80GB and produces instruction-following quality sufficient for structured scene extraction.
- FLUX.1-dev produces output quality that justifies calling the result a "visual adaptation" rather than a proof-of-concept.
- ThunderCompute offers A100/H100 GPU instances at hobbyist-accessible per-hour rates, making a 30-60 minute GPU job financially practical for personal use.
- macOS SwiftUI and the broader Apple platform provide a native UX layer that can hide the SSH-tunnel / GPU-lifecycle complexity from the end user entirely.
- None of the above were simultaneously true at hobbyist-project quality two years ago.

### What this is not

Book2Visual is not a commercial product, an e-reader, a publishing tool, or a replacement for licensed adaptations. It is a personal creative tool for a reader who owns a book and wants to see it visualized for their own enjoyment. All processing is local to a user-rented GPU instance. No book text is sent to third-party cloud APIs.

---

## 3. Goals and Non-Goals

### Goals (v1)

- **G1:** Accept a pasted short story (2,000–4,000 words) and produce a complete visual adaptation as a sequence of PNG pages without requiring manual intervention once the job is started.
- **G2:** Maintain plausible character visual consistency across all panels by anchoring on a canonical character reference image generated once per character.
- **G3:** Keep the user's cost per run under $2 USD in GPU rental fees for the v1 short-story demo use case.
- **G4:** Present a polished native macOS experience: the app manages the GPU instance lifecycle so the user never touches a terminal.
- **G5:** Keep all book text and generated content private — processed exclusively on the user's rented instance, never routed through a third-party inference API.

### Non-Goals (v1)

- **NG1:** Full-length novel support (input capped at ~4,000 words for v1).
- **NG2:** PDF, EPUB, or HTML export (ZIP of PNGs is sufficient for v1).
- **NG3:** Scene-by-scene review and regeneration UI before final assembly.
- **NG4:** Shaped speech bubbles or dynamic/non-uniform panel layouts.
- **NG5:** Multi-job queue or concurrent instance support.
- **NG6:** Homebrew or App Store distribution.
- **NG7:** Windows or Linux client.
- **NG8:** Commercial licensing or redistribution of output.

---

## 4. Target User and Primary Use Case

### Target user

**Primary persona: "The Reader Who Wants to See the Story"**

A book lover — not a developer, not an AI researcher — who has finished reading a short story or novel excerpt and wants to experience it as a visual medium. They are comfortable with macOS. They understand at a high level that GPU compute costs money by the hour, and they are willing to pay a few dollars for a personal creative run. They are not comfortable dropping into a terminal to manage SSH connections or download model weights manually.

This is, concretely, a single person: the developer themselves and a small circle of readers with a similar profile. v1 is explicitly a personal tool. There is no DAU target.

**Who it is NOT for:**

- Users expecting professional manga art quality (output is AI-interpreted colored anime stills, not hand-inked manga).
- Users wanting to process and redistribute copyrighted commercial novels at scale.
- Users without access to a ThunderCompute account (v1 assumes an existing account with an API token).

### Primary use case walkthrough

> "I just finished reading 'The Metamorphosis' and I want to see it as a visual story."

1. The user opens Book2Visual on their Mac. They see their provisioned instance status (stopped). They click **Start Instance**. The app calls the ThunderCompute API, provisions or resumes the instance, waits for it to be ready, and establishes an SSH tunnel to the FastAPI service running on it. A status indicator turns green: "Instance ready."

2. The user pastes the story text into the **Story** field (3,200 words). They type character entries: "Gregor Samsa — human" and "Grete Samsa — human." They click **Run Adaptation**.

3. The app posts the job to the FastAPI endpoint over the SSH tunnel. A live log panel streams per-scene progress: "Extracting scenes... found 8 key scenes. Generating character reference for Gregor Samsa... Reference image complete. Generating panel 1/8... Panel 2/8..." and so on.

4. When the job completes (estimated 25–45 minutes for this story on an A100), the app automatically downloads the output ZIP from the instance, extracts the PNG pages, and opens the **Viewer** — a simple full-screen page-flipping view of the generated pages.

5. The user clicks **Export ZIP** to save the PNGs to their Downloads folder. They click **Stop Instance** to shut down the GPU and stop the billing clock.

---

## 5. Success Metrics

These are the concrete, measurable criteria that determine whether v1 is working. They are evaluated by the developer running the pipeline against the demo short story.

| Metric | Target | How measured |
|---|---|---|
| **End-to-end completion rate** | >= 90% of runs complete without manual intervention | Manual test runs (target: 9 of 10 succeed) |
| **End-to-end runtime (A100, 4k words)** | <= 60 minutes wall clock | Timed from "Run" click to viewer open |
| **Cost per run (A100, 4k words)** | <= $2.00 USD in GPU rental | ThunderCompute billing log post-run |
| **Character consistency (subjective)** | Same character looks "recognizably the same person" across >= 70% of panels | Developer visual review of output panels |
| **Caption legibility** | Prose caption text readable at 100% zoom in the viewer | Visual review — no truncation, no illegible font size |
| **Instance lifecycle reliability** | Start + Stop operations succeed without terminal fallback >= 95% of the time | Manual test runs |
| **Pages generated** | >= 4 pages for a 2,000-word input; >= 8 pages for a 4,000-word input | Count output PNGs |
| **SSH tunnel stability** | Tunnel remains live for the full job duration without reconnection | Log observation during a full run |

**North-star outcome:** The developer reads through the output pages and says "I can tell this is the story I put in, and the characters look like themselves." That is the qualitative bar. The metrics above are the scaffolding that gets there.

---

## 6. Functional Requirements

Requirements are tagged Must (M), Should (S), or Could (C) for v1 priority.

---

### 6a. macOS App — UI Screens and Navigation

**FR-APP-01 (M)** The app presents a single primary window with a sidebar or tab strip containing three sections: **Setup**, **Run**, and **Viewer**.

**FR-APP-02 (M)** The **Setup** screen contains:
- ThunderCompute instance status indicator (Stopped / Starting / Running / Error) with last-refreshed timestamp.
- **Start Instance** and **Stop Instance** buttons, disabled when the action is not applicable to the current state.
- A **Settings** sheet (accessible via gear icon) containing: Thunder API token field (write-only display, stored in Keychain), SSH key path field (file picker, path stored in preferences, key passphrase stored in Keychain), SSH user and host fields (auto-populated from Thunder API after provisioning, editable), FastAPI port field (default: 8000).
- A **Validate Connection** button that tests the SSH tunnel and FastAPI health endpoint, showing pass/fail inline.

**FR-APP-03 (M)** The **Run** screen contains:
- A multi-line text area labeled "Paste story text here" with a live character/word count.
- A character table with Add/Remove rows, each row having: Character Name (text field), Race/Appearance Hint (text field, optional). Placeholder text: "e.g. 'East Asian' — only needed if the book does not describe this character's appearance."
- A **VRAM Mode** segmented control: Concurrent (default — loads LLM and image model simultaneously) vs. Sequenced (loads one at a time — use on smaller GPUs / T4 fallback). Tooltip explains the tradeoff.
- A **Run Adaptation** button, enabled only when: instance status is Running, text area is non-empty, at least one character row exists.
- A log panel below the controls that streams per-scene progress messages in real time during a job.
- A **Cancel Job** button (enabled during an active job) that sends a cancellation signal to the FastAPI endpoint.

**FR-APP-04 (M)** The **Viewer** screen:
- Displays generated PNG pages in sequence, one page per view, with Previous/Next navigation (keyboard arrows supported).
- Shows page number / total page count.
- An **Export ZIP** button that copies the downloaded output ZIP to a user-chosen location via NSSavePanel.
- Opens automatically when a job completes and output is downloaded.

**FR-APP-05 (S)** The app menu bar shows a persistent instance status indicator (dot icon: grey/yellow/green/red) so the user is aware of running instance cost even when the window is not focused.

**FR-APP-06 (S)** The app shows a native macOS notification when a job completes or fails.

**FR-APP-07 (C)** The Run screen retains the last-used story text and character list across app launches (stored in UserDefaults or a local file, not in iCloud).

---

### 6b. Instance Lifecycle Management

**FR-INST-01 (M)** The app integrates with the ThunderCompute API (via the `tnr` CLI invoked as a subprocess, or direct HTTPS calls to the Thunder REST API if documented) to perform: list instances, start instance, stop instance, query instance status.

**FR-INST-02 (M)** The app reads the Thunder API token from macOS Keychain. It never writes the token to disk outside of Keychain. The token is requested once via the Settings sheet and stored with `kSecAttrService = "book2visual.thunder"`.

**FR-INST-03 (M)** After a **Start Instance** command, the app polls instance status every 10 seconds and updates the status indicator until the instance reaches Running state or an error is reported. Polling timeout: 5 minutes (after which an error state is shown).

**FR-INST-04 (M)** **Stop Instance** sends a stop command to the Thunder API and polls until the instance reaches Stopped state. If a job is currently running, the app presents a confirmation dialog: "A job is in progress. Stopping the instance will cancel it and output will be lost. Stop anyway?"

**FR-INST-05 (S)** The app remembers the instance ID associated with the current session (stored in UserDefaults) and resumes monitoring it on next launch if the instance is still running. This prevents the user from losing track of a running instance.

**FR-INST-06 (S)** The Settings sheet includes a section for selecting which existing Thunder instance to manage (dropdown populated via API list call), to support users with more than one instance.

**FR-INST-07 (M)** The FastAPI server on the instance is assumed to be running before the SSH tunnel is established. Initial environment setup (installing FastAPI service, downloading model weights) is a documented one-time manual step performed by the developer via SSH before first use. The app does not automate first-time environment setup.

*Rationale: The one-time setup cost (model weight download, pip installs) is amortized to near-zero by using a persistent volume or pre-baked instance snapshot. Automating this in the Mac app adds significant complexity for a step the developer only performs once. Document it thoroughly instead.*

---

### 6c. SSH Tunnel and Connectivity

**FR-SSH-01 (M)** The app establishes a local SSH port-forward tunnel (`ssh -L <local_port>:localhost:<remote_port> <user>@<host>`) using the SSH key at the configured path. The key passphrase is read from Keychain at tunnel-open time.

**FR-SSH-02 (M)** The SSH tunnel is opened after the instance reaches Running state and before any API calls are attempted. It is closed when the instance is stopped or the app quits.

**FR-SSH-03 (M)** The SSH tunnel is managed as a background process. If the tunnel process exits unexpectedly during a job, the app detects this (process monitor or heartbeat failure) and shows an error state with a **Reconnect** button that re-establishes the tunnel.

**FR-SSH-04 (S)** The app sends a keep-alive heartbeat ping to the FastAPI `/health` endpoint every 30 seconds during an active job to detect tunnel loss early.

**FR-SSH-05 (M)** The SSH key is read from the path the user specifies in Settings. The app never writes a private key to disk. The key must already exist at the specified path (generated and deployed to the instance by the developer as part of one-time setup).

---

### 6d. Job Progress Streaming

**FR-PROG-01 (M)** During an active job, the FastAPI service streams per-scene progress events to the Mac app. The transport is Server-Sent Events (SSE) over the SSH tunnel HTTP connection. Each event includes: event type (scene_start, scene_complete, stage_update, job_complete, job_error), scene index, total scene count, and a human-readable message.

**FR-PROG-02 (M)** The log panel in the Run screen appends each received event as a timestamped line. The panel auto-scrolls to the bottom on new events.

**FR-PROG-03 (M)** A progress bar above the log panel shows overall completion as (scenes_complete / total_scenes).

**FR-PROG-04 (S)** Stage-level granularity is streamed within each scene: "Scene 3/8: Extracting description... done. Generating panel image... done. Writing caption... done."

---

### 6e. Output Retrieval

**FR-OUT-01 (M)** On job_complete event, the app automatically initiates an SCP or SFTP download of the output ZIP from the instance to a local app-managed directory (`~/Library/Application Support/Book2Visual/outputs/<job-id>/`).

**FR-OUT-02 (M)** The app shows a download progress indicator during the transfer.

**FR-OUT-03 (M)** After download completes, the app extracts the ZIP, enumerates the PNG pages in filename sort order, and loads them into the Viewer.

**FR-OUT-04 (M)** The Export ZIP button copies the original downloaded ZIP file to the user's chosen destination via NSSavePanel. The default suggested filename is `book2visual-<story-title-slug>-<date>.zip`.

---

### 6f. Remote Pipeline Service (FastAPI)

The FastAPI service runs as a persistent process on the Thunder instance, launched at instance startup (e.g., via a systemd unit or a tmux session started by an rc script). The Mac app does not start or stop the FastAPI process — it relies on it being present once the instance is Running.

**FR-API-01 (M)** `GET /health` — returns `{"status": "ok", "models_loaded": <bool>}`. Used for tunnel validation and heartbeat.

**FR-API-02 (M)** `POST /jobs` — accepts job payload (see FR-PIPE-01 for schema), returns `{"job_id": "<uuid>"}`. Begins processing asynchronously.

**FR-API-03 (M)** `GET /jobs/{job_id}/stream` — SSE endpoint that streams progress events for the given job. Returns events until job_complete or job_error.

**FR-API-04 (M)** `POST /jobs/{job_id}/cancel` — signals the running job to stop after the current scene completes. Returns `{"status": "cancelling"}`.

**FR-API-05 (M)** `GET /jobs/{job_id}/output` — returns the output ZIP as a binary file download, available only after job_complete.

**FR-API-06 (S)** `GET /jobs` — lists recent jobs with their status, for potential future history UI.

**FR-API-07 (M)** The service enforces a single-job-at-a-time constraint: if a job is already running, `POST /jobs` returns HTTP 409 with `{"error": "job_already_running"}`.

**FR-API-08 (M)** The FastAPI service writes structured JSON logs to a file on the instance for debugging. Log rotation is configured (max 3 files, 10 MB each).

---

### 6g. Text Stage (LLM Pipeline)

**FR-TEXT-01 (M)** The job payload schema accepted by `POST /jobs`:
```json
{
  "text": "<story plain text>",
  "characters": [
    {"name": "Gregor Samsa", "race_hint": "human"}
  ],
  "vram_mode": "concurrent" | "sequenced"
}
```

**FR-TEXT-02 (M)** Scene extraction: the LLM reads the full story text and produces a structured list of key scenes. Each scene contains: scene index, a brief title, the source text passage it is drawn from, a list of characters present, and whether the scene is flagged as "pivotal" (candidate for full-page treatment). Target: 1 scene per ~400-500 words of input (8–10 scenes for a 4,000-word story).

**FR-TEXT-03 (M)** Character description extraction: for each named character in the input list, the LLM extracts all appearance descriptors mentioned in the source text. If none are found, the user-supplied race_hint is used as the primary descriptor. The output is a canonical character description string used to generate the reference image and to condition all subsequent panel prompts.

**FR-TEXT-04 (M)** Caption generation: for each scene, the LLM writes a 1-3 sentence caption in the style of the author's prose (not a plot summary). The caption is the text burned into the panel's caption box.

**FR-TEXT-05 (M)** All LLM calls are structured-output / JSON-mode calls to ensure parseable responses. The pipeline uses retry logic (up to 3 attempts) with a fallback prompt if the LLM returns malformed JSON.

**FR-TEXT-06 (M)** The LLM model is configurable via an environment variable on the instance (`BOOK2VISUAL_LLM_MODEL`). Default: `Qwen/Qwen2.5-32B-Instruct-GPTQ-Int4`. The serving backend is vLLM or llama.cpp server (see Appendix for per-GPU recommendations).

**FR-TEXT-07 (S)** The LLM is prompted to produce an interpretive, condensed adaptation — not a literal transcription. The system prompt instructs it to select the most visually dramatic and narratively significant moments, aiming for emotional impact over completeness.

---

### 6h. Image Stage (Diffusion Pipeline)

**FR-IMG-01 (M)** A canonical character reference image is generated for each character before any scene panels are produced. The reference image prompt is constructed from the character description string and a fixed style prefix: "manga character reference sheet, single character, colored anime style, white background, [character description]." The reference image is saved as `ref_<character_name>.png` in the job working directory.

**FR-IMG-02 (M)** All scene panel images are generated using FLUX + IP-Adapter, with the character's reference image passed as the IP-Adapter conditioning image. Each panel prompt is constructed as: `"[style prefix] [scene description] [character descriptions of present characters]"`.

**FR-IMG-03 (M)** The style prefix applied to all image prompts is: `"colored anime still, manga panel, vibrant colors, detailed linework"`. This is hardcoded for v1.

**FR-IMG-04 (M)** Image resolution is 768x768 pixels per panel for v1. This is chosen to fit 4 panels (2x2 grid) onto a final page at reasonable quality without excessive VRAM pressure.

**FR-IMG-05 (M)** The FLUX model is configurable via environment variable (`BOOK2VISUAL_FLUX_MODEL`). Default: `black-forest-labs/FLUX.1-dev`. Fallback: `black-forest-labs/FLUX.1-schnell` (for smaller GPU tiers). See Appendix.

**FR-IMG-06 (M)** In **Concurrent** VRAM mode, both the LLM and the FLUX model are held in VRAM simultaneously. The text stage and image stage for each scene are interleaved: extract scene N text, generate scene N image, move to scene N+1. This minimizes total wall-clock time but requires a GPU with sufficient VRAM (A100 80GB recommended).

**FR-IMG-07 (M)** In **Sequenced** VRAM mode, the LLM completes all text-stage work for all scenes first, is unloaded from VRAM, then the FLUX model is loaded and all image generation is performed in a second pass. This allows the pipeline to run on smaller GPUs (e.g., T4 16GB) at the cost of additional wall-clock time.

**FR-IMG-08 (S)** FLUX inference step count is configurable via environment variable (`BOOK2VISUAL_FLUX_STEPS`). Default: 28 steps for FLUX.1-dev; 4 steps for FLUX.1-schnell.

---

### 6i. Assembly Stage

**FR-ASSM-01 (M)** Panel assembly is performed by a Pillow script on the instance. The output is a sequence of full-page PNG files.

**FR-ASSM-02 (M)** Standard page format: a 2x2 grid of four 768x768 panels, assembled into a 1536x1536 pixel page. Scenes fill panels in narrative order; the last panel on a page may be blank (filled with a solid background color) if the scene count is not a multiple of 4.

**FR-ASSM-03 (M)** Pivotal scenes (flagged by the LLM during scene extraction) are placed on their own full-page 1x1 slot (1536x1536, single panel upscaled or center-cropped from the 768x768 source). A pivotal scene interrupts the sequential page fill and starts a new page.

**FR-ASSM-04 (M)** Each panel has a rectangular caption box rendered at the bottom of the panel (occupying approximately the bottom 18% of panel height). The caption box has a semi-transparent dark background. The author's prose caption text is rendered in white using a bundled TTF font (the font file is included in the FastAPI service repository). Minimum font size: 14pt equivalent at 768px height. Text wraps within the box; if the caption is too long, it is truncated with an ellipsis.

**FR-ASSM-05 (S)** Page number is rendered in the bottom-right margin of each assembled page.

**FR-ASSM-06 (M)** All assembled pages are packaged into a single ZIP file (`output.zip`) in the job working directory on the instance.

---

## 7. Non-Functional Requirements

### Performance

**NFR-PERF-01** End-to-end job runtime for a 4,000-word story on an A100 80GB in Concurrent VRAM mode: target <= 60 minutes.

**NFR-PERF-02** SSH tunnel establishment after instance start: target <= 30 seconds from instance Ready state.

**NFR-PERF-03** Output ZIP download to Mac: no specific target, but download progress must be visible to the user (not a silent hang).

**NFR-PERF-04** App launch time: target <= 3 seconds to first interactive frame on M1 Mac.

### Cost

**NFR-COST-01** GPU rental cost per run (4,000-word story, A100 80GB): target <= $2.00 USD. This constrains job runtime (A100 80GB runs at approximately $2–4/hr on ThunderCompute; a 60-minute job approaches this ceiling — optimize prompt brevity and inference config accordingly).

**NFR-COST-02** The app must not leave an instance running unintentionally. The menu bar status indicator and the FR-INST-05 session-resume memory are the primary safeguards for v1.

### Privacy and Security

**NFR-SEC-01** Book text is never transmitted to any third-party API or service. All LLM and image model inference runs on the user's own rented instance.

**NFR-SEC-02** The Thunder API token is stored exclusively in macOS Keychain. It is never logged, written to a preferences file, or transmitted over any channel other than HTTPS to the ThunderCompute API.

**NFR-SEC-03** The SSH private key is read from disk only to open the tunnel; its contents are never written elsewhere by the app. The passphrase is stored in Keychain.

**NFR-SEC-04** All communication between the Mac app and the FastAPI service travels over the SSH tunnel (localhost-to-localhost after the tunnel is established). The FastAPI service listens on localhost only (127.0.0.1), not on a public network interface.

**NFR-SEC-05** The FastAPI service does not implement authentication (it is protected by the SSH tunnel). If this assumption changes (e.g., tunnel is not used), an API key layer must be added before any exposure to a network interface.

### Reliability

**NFR-REL-01** If the SSH tunnel drops during a job, the app detects this within 60 seconds (via heartbeat failure) and presents a clear error with a Reconnect option. The job may continue on the instance; the user can reconnect and resume monitoring.

**NFR-REL-02** If a FLUX or LLM inference call fails for a single scene (OOM, timeout, malformed output), the pipeline logs the error and continues to the next scene (best-effort), inserting a placeholder panel image (solid color with error text). It does not abort the entire job.

**NFR-REL-03** For v1, full-job restart is the recovery path for fatal failures (e.g., instance crash, OOM on all retries). Partial resume (checkpoint/restart) is a v2 feature.

### Accessibility

**NFR-A11Y-01** The Mac app meets minimum macOS accessibility standards: all interactive controls have accessibility labels, keyboard navigation works for primary flows (Start/Stop Instance, Run, navigate Viewer).

### Compatibility

**NFR-COMPAT-01** macOS 14 Sonoma or later. No support for earlier macOS versions is required.

**NFR-COMPAT-02** The FastAPI service targets Python 3.11+ and the current release of the relevant model libraries (transformers, diffusers, vllm/llama-cpp-python) at the time of first deployment. Library versions are pinned in `requirements.txt`.

---

## 8. System Architecture Overview

### Components

```
+---------------------------+         +-----------------------------------+
|      macOS App (Swift)    |         |    ThunderCompute Cloud           |
|                           |         |                                   |
|  +---------------------+  |  HTTPS  |  Thunder REST API / tnr CLI       |
|  | Instance Manager    |<----------->  (instance lifecycle)             |
|  +---------------------+  |         +-----------------------------------+
|                           |
|  +---------------------+  |         +-----------------------------------+
|  | SSH Tunnel Manager  |<--SSH--->  |    GPU Instance (A100/H100)       |
|  +---------------------+  |  tunnel |                                   |
|           |               |         |  +-----------------------------+  |
|  +--------v------------+  |  HTTP   |  | FastAPI Service (port 8000) |  |
|  | API Client          |<----------->  | (listens on 127.0.0.1 only) |  |
|  | (localhost tunnel)  |  |         |  +-----------------------------+  |
|  +---------------------+  |         |         |             |           |
|           |               |         |  +------v----+  +----v--------+  |
|  +--------v------------+  |         |  | Text Stage|  | Image Stage |  |
|  | Progress Stream     |  |   SSE   |  | (Qwen LLM)|  | (FLUX +     |  |
|  | (SSE listener)      |<---------  |  | via vLLM  |  |  IP-Adapter)|  |
|  +---------------------+  |         |  +-----------+  +-------------+  |
|                           |         |         |             |           |
|  +---------------------+  |  SCP/   |  +------v-----------v--------+  |
|  | Output Downloader   |<--SFTP--   |  | Assembly Stage (Pillow)   |  |
|  +---------------------+  |         |  | output.zip                |  |
|           |               |         |  +---------------------------+  |
|  +--------v------------+  |         |                                   |
|  | In-App Viewer       |  |         |  Persistent Volume:               |
|  | (PNG page browser)  |  |         |  - Model weights (LLM + FLUX)     |
|  +---------------------+  |         |  - IP-Adapter weights             |
|                           |         |  - FastAPI service code           |
|  Keychain:                |         +-----------------------------------+
|  - Thunder API token      |
|  - SSH key passphrase     |
+---------------------------+
```

### Data and control flow

**Instance lifecycle (control plane):**
```
Mac App --> Thunder REST API (HTTPS) --> Instance START/STOP/STATUS
```

**Job execution (data plane):**
```
Mac App --> SSH Tunnel --> FastAPI POST /jobs --> Pipeline (LLM + FLUX + Pillow)
Mac App <-- SSE stream <-- FastAPI GET /jobs/{id}/stream <-- Pipeline events
Mac App <-- SCP/SFTP <-- output.zip (after job_complete event)
```

**Secrets flow:**
```
macOS Keychain --> Mac App (in-memory only, never written to disk)
  |- Thunder API token --> Thunder HTTPS calls
  |- SSH key passphrase --> SSH process stdin/expect
```

### Model weight persistence strategy

Model weights (Qwen2.5-32B-GPTQ-Int4, FLUX.1-dev, IP-Adapter) are downloaded once during the one-time manual setup and stored on a ThunderCompute persistent volume attached to the instance. The instance OS disk is ephemeral on some GPU cloud providers; the persistent volume ensures weights survive stop/start cycles. Total weight storage: approximately 45–60 GB (see Appendix for breakdown by tier).

This is a one-time cost of 30–60 minutes of download time and the persistent volume storage fee (typically $0.10–0.20/GB/month on Thunder). It is explicitly not automated by the Mac app for v1.

---

## 9. v1 Scope: In vs. Out

### In Scope for v1

| Feature | Notes |
|---|---|
| Instance start / stop via Thunder API | Core cost-control feature, promoted into v1 |
| Instance status monitoring (polling) | Menu bar indicator + Setup screen |
| SSH tunnel management | Open/close/reconnect |
| macOS Keychain secret storage | Thunder API token + SSH passphrase |
| Plain text story input (paste) | 2,000–4,000 words |
| Character name + race/appearance hint fields | Simple text table, no autocomplete |
| VRAM mode selector (Concurrent / Sequenced) | Segmented control with tooltip |
| LLM scene extraction (Qwen2.5) | Structured output, JSON mode |
| LLM character description extraction | Using source text + race hint |
| LLM caption generation (author-voice prose) | Per-scene, 1–3 sentences |
| Canonical character reference image generation | FLUX, once per character, before panels |
| IP-Adapter character consistency anchoring | Applied to all scene panel generations |
| FLUX panel image generation | FLUX.1-dev (default) or FLUX.1-schnell |
| 2x2 composite page assembly (Pillow) | 1536x1536 output pages |
| Full-page slots for pivotal scenes | LLM-flagged pivotal scenes |
| Rectangular prose caption boxes | Bottom 18% of panel, semi-transparent |
| SSE progress streaming to Mac app | Per-scene granularity |
| Auto-download output ZIP on completion | SCP/SFTP to local App Support folder |
| In-app PNG page viewer | Simple prev/next navigation |
| ZIP export via NSSavePanel | Copies downloaded ZIP to user location |
| Job cancellation | Signal to FastAPI; stops after current scene |
| Single-job-at-a-time enforcement | HTTP 409 on concurrent submit |
| Structured JSON logging on instance | For debugging |
| FastAPI service (persistent, assumed running) | Started during one-time setup |

### Out of Scope for v1

| Feature | Deferred to |
|---|---|
| EPUB / PDF / HTML export | v2 |
| Scene-by-scene review and regeneration UI | v2 |
| Shaped speech bubbles | v2 |
| Dynamic / non-uniform panel layouts | v2 |
| Full-book (novel-length) input support | v2 |
| Partial job resume after interruption | v2 |
| Multi-instance support / job queue | v3 |
| Homebrew distribution / installer | v3 |
| App Store distribution | Future |
| EPUB parsing (reading from ebook files) | Future |
| Multiple art style options | Future |
| Sharing / export to social formats | Future |
| Automated first-time environment setup | Future (manual setup doc for v1) |
| LoRA fine-tuning for style consistency | Future |

---

## 10. Risks, Assumptions, and Mitigations

### Risk 1: Character consistency quality is insufficient

**Description:** IP-Adapter conditioning from a FLUX-generated reference image may not produce consistent character appearance across 8–10 panels. The characters may look like "the same type of person" but not "the same person."

**Likelihood:** Medium-High. IP-Adapter consistency with FLUX is an active research area; results vary by character description complexity.

**Mitigation:**
- Tune IP-Adapter scale weight (start at 0.6–0.8, experiment per story).
- Include the full canonical character description in every panel prompt, not just the IP-Adapter image.
- For v1, set the user expectation explicitly: "AI interpretation — characters will be recognizable but not photorealistic clones." This is a feature frame, not a bug frame.
- v2 mitigation: explore LoRA fine-tuning on the reference image.

### Risk 2: Model VRAM fit on chosen GPU tier

**Description:** Qwen2.5-32B (4-bit) requires ~22 GB VRAM. FLUX.1-dev requires ~24 GB VRAM. In Concurrent mode, simultaneous loading requires ~46 GB — comfortably fits on A100 80GB but not on smaller tiers.

**Likelihood:** Low on A100/H100; High if a smaller GPU is attempted in Concurrent mode.

**Mitigation:**
- The VRAM mode selector (Concurrent / Sequenced) directly addresses this.
- In Sequenced mode, peak VRAM is max(22 GB, 24 GB) = 24 GB, fitting on an A100 40GB.
- The Appendix GPU/model recommendation table explicitly maps tier to supported configuration.
- Add a runtime VRAM check in the FastAPI service at job start; return an error with recommended mode if VRAM is insufficient.

### Risk 3: Instance cost runaway (forgotten running instance)

**Description:** The user starts an instance, leaves the app, and the instance runs for hours or days, accumulating unexpected charges.

**Likelihood:** Medium. Forgetting cloud resources is a common user failure mode.

**Mitigation:**
- Persistent menu bar status indicator (green dot = money burning).
- FR-INST-05: app resumes monitoring on relaunch and shows the running instance prominently.
- **Recommended additional safeguard:** configure a maximum auto-stop timer on the ThunderCompute instance (if the platform supports it) as a backstop. Document this in the setup guide.
- v2: in-app idle timer with "auto-stop after N minutes of inactivity" setting.

### Risk 4: ThunderCompute API integration unknowns

**Description:** The `tnr` CLI and/or Thunder REST API may not expose all lifecycle operations needed (start, stop, status, instance selection) in a stable, documented form.

**Likelihood:** Medium. CLI tools for GPU cloud providers are often works-in-progress.

**Mitigation:**
- Spike the Thunder API/CLI integration as the first engineering task before building any UI.
- Design the InstanceManager as a protocol/interface so the underlying implementation (CLI subprocess vs. REST) can be swapped without touching the rest of the app.
- Fallback: if the API is insufficient, provide a "Manual mode" where the user is prompted to start the instance in a browser and confirm when it's ready; the app skips lifecycle management and goes straight to SSH tunnel.

### Risk 5: Model weight download time and persistence

**Description:** FLUX.1-dev + Qwen2.5-32B-GPTQ-Int4 + IP-Adapter total approximately 50–60 GB. On a fresh instance without a persistent volume, this download takes 30–90 minutes and must be repeated every time.

**Likelihood:** Certain on first setup; ongoing if persistent volume is not configured.

**Mitigation:**
- The persistent volume approach (one-time setup, volume reattached on start/stop) eliminates recurring downloads. Document this as a required step in the setup guide.
- If ThunderCompute supports instance snapshots/images, document creating a pre-baked image as an alternative to a persistent volume.
- The Mac app setup guide (linked from the Settings screen's help button) should walk through this step with estimated times and costs.

### Risk 6: FLUX manga/anime style fidelity

**Description:** FLUX.1-dev is a photorealistic base model. Generating "colored anime stills" requires careful prompt engineering or style LoRA. Without this, output may look like photorealistic illustrations rather than anime.

**Likelihood:** Medium. Raw FLUX.1-dev with anime-style prompts produces variable results.

**Mitigation:**
- Use a community anime-style LoRA (e.g., an anime/illustration fine-tune of FLUX.1-dev) if licensing permits.
- Tune the style prefix prompt extensively during development. Terms like "anime key visual," "cel shading," "2D illustration" in addition to "colored anime still" improve results.
- Set user expectation: "colored anime-style illustration" rather than "traditional manga." This is actually more achievable with FLUX than true black-and-white inked manga.

### Risk 7: Prose caption legibility in 2x2 tiles

**Description:** At 768x768 pixels per panel, a caption box occupying 18% of height = approximately 138 pixels. At standard screen resolution, this may be tight for 1–3 sentences of prose.

**Likelihood:** Medium. Prose captions vary in length; long sentences will be cramped.

**Mitigation:**
- Cap captions at 200 characters in the LLM prompt. Instruct the LLM to write short, punchy captions.
- Use a clear, high-contrast font. Bundle a legible TTF (e.g., a clean sans-serif like Inter or Nunito — check licensing for bundling rights).
- Test with the longest expected caption at 768px before finalizing.
- v2: dynamic caption box height or external caption rendering below the panel.

### Risk 8: SSH tunnel reliability under long jobs

**Description:** Jobs may run for 30–60 minutes. TCP connections over SSH can be silently dropped by network middleboxes, NAT tables timing out, or macOS sleep.

**Likelihood:** Medium. macOS network changes (wifi handoff, sleep/wake) are common.

**Mitigation:**
- SSH keep-alive: configure `ServerAliveInterval=30` and `ServerAliveCountMax=3` in the SSH subprocess arguments.
- The job continues on the instance regardless of tunnel state. Tunnel reconnect only affects monitoring, not the pipeline itself.
- FR-SSH-03 + FR-SSH-04: detect tunnel loss within 60 seconds, surface reconnect UI immediately.
- Ensure the FastAPI service survives tunnel disconnects gracefully (it has no persistent connection to the client; SSE is stateless from the server side).

### Key Assumptions

| Assumption | Risk if wrong |
|---|---|
| ThunderCompute instance has a persistent volume with pre-downloaded model weights | Every run takes 30–90 minutes of weight download before first inference |
| FastAPI service auto-starts on instance boot | First use after instance start fails until manually SSH'd in |
| IP-Adapter is compatible with the chosen FLUX checkpoint | Image stage fails to load; fallback to no-IP-Adapter (consistency loss) |
| tnr CLI or Thunder API supports programmatic start/stop | App falls back to manual mode (less polished) |
| SSH key is already authorized on the instance | All SSH tunnel operations fail |

---

## 11. Phased Roadmap

### v1 — "Demo Validation" (current target)

**Goal:** Prove the end-to-end pipeline works and produces an enjoyable output for a 2,000–4,000 word short story. Personal use only.

**Scope:** Everything in the "In Scope for v1" table above.

**Success:** Developer runs a favorite short story through the app, reads the output pages, and says "this is recognizably the story and I want to do this again."

**Key milestones:**
1. Thunder API spike + SSH tunnel PoC (validate integration assumptions)
2. FastAPI service skeleton + SSE streaming to Mac app
3. Text stage (LLM scene extraction) end-to-end
4. Image stage (FLUX + IP-Adapter) end-to-end
5. Assembly + download + viewer end-to-end
6. Instance lifecycle management in Mac app
7. Keychain secrets + Settings UI
8. End-to-end test with full short story

---

### v2 — "Usable Product" (next phase)

**Goal:** Make it pleasant enough to share with a small circle of readers. Add the missing quality-of-life and output quality features.

**New capabilities:**
- Scene-by-scene review widget: view generated panels per scene before final assembly; regenerate individual panels.
- PDF export: assemble pages into a PDF for reading on iPad/Kindle.
- Partial job resume: checkpoint after each scene; restart from last successful scene on failure.
- Full-page import for longer stories: chunking strategy to handle up to ~20,000 words (short novella).
- Idle auto-stop: configurable timer to stop the instance after N minutes of inactivity.
- Improved character consistency: experiment with LoRA fine-tuning on the reference image, or DreamBooth-style per-job fine-tune.
- Richer race/appearance UI: a structured appearance form (skin tone, hair color/style, facial features) replacing the free-text race hint.

---

### v3 — "Shared Tool" (longer term)

**Goal:** Something a non-developer friend could install and use.

**New capabilities:**
- Homebrew distribution (or a notarized DMG download).
- Multi-instance support / job queue for running jobs in parallel.
- EPUB file input: parse EPUB, extract chapters, let the user select which chapter to adapt.
- Full-novel support with chapter-level batching.
- Dynamic panel layouts: vary grid from 1x1 to 2x2 to 3x3 based on scene density.

---

### Future / Exploratory

- App Store distribution (requires significant privacy/entitlements review given SSH and Keychain usage).
- Art style selector (multiple style LoRAs: watercolor, vintage comic, Studio Ghibli-esque, etc.).
- Shaped speech bubbles with dialogue extracted from the text.
- Export to social-shareable formats (animated panel sequence, short video).
- Collaborative session: share the output with a friend in-app.

---

## 12. Appendix: GPU / Model Recommendation Table

This table maps ThunderCompute GPU tier to recommended model configuration and expected runtime.

| Thunder GPU | VRAM | LLM Model | FLUX Model | VRAM Mode | Est. Runtime (4k words) | Est. Cost / Run |
|---|---|---|---|---|---|---|
| **A100 80GB** (recommended) | 80 GB | Qwen2.5-32B-Instruct-GPTQ-Int4 (~22 GB) | FLUX.1-dev (~24 GB) | Concurrent | 30–45 min | $1.00–$2.50 |
| **H100 80GB** | 80 GB | Qwen2.5-32B-Instruct-GPTQ-Int4 (~22 GB) | FLUX.1-dev (~24 GB) | Concurrent | 20–35 min | $1.50–$3.50 (higher $/hr) |
| **A100 40GB** | 40 GB | Qwen2.5-14B-Instruct-GPTQ-Int4 (~10 GB) | FLUX.1-dev (~24 GB) | Sequenced | 50–75 min | $1.00–$2.00 |
| **A10G 24GB** | 24 GB | Qwen2.5-7B-Instruct (~7 GB) | FLUX.1-schnell (~12 GB) | Sequenced | 60–90 min | < $1.00 |
| **T4 16GB** (free tier) | 16 GB | Qwen2.5-7B-Instruct (~7 GB) | FLUX.1-schnell (~12 GB) | Sequenced | 90–150 min | ~$0 (free tier) |

**Notes:**

- VRAM figures are approximate and vary with quantization and attention kernel selection. Monitor actual VRAM usage with `nvidia-smi` during development and tune accordingly.
- FLUX.1-schnell uses 4-step inference (vs. 28 for FLUX.1-dev) and is significantly faster but produces lower quality output. Acceptable for T4/A10G tiers where quality is already constrained.
- Qwen2.5-32B 4-bit on A100 80GB is the target configuration. Do not attempt Concurrent mode with 32B on a 40GB GPU — it will OOM.
- The IP-Adapter weights (~3 GB) are loaded alongside FLUX in all configurations. Include this in VRAM budgeting.
- Model weight storage breakdown for the persistent volume:
  - Qwen2.5-32B-GPTQ-Int4: ~20 GB
  - FLUX.1-dev: ~24 GB
  - FLUX.1-schnell: ~12 GB (optional, only if multi-tier support desired)
  - IP-Adapter for FLUX: ~3 GB
  - FastAPI service + dependencies: ~5 GB
  - **Total (with both FLUX models):** ~64 GB
  - **Total (FLUX.1-dev only):** ~52 GB

**Recommendation:** Provision the instance with an A100 80GB for development and first demo runs. Use a persistent volume of at least 70 GB. Once the pipeline is validated, optimize for the A100 40GB + Sequenced mode if cost reduction is needed.

---

*This PRD reflects all decisions made through the product discovery session completed on 2026-05-29. All requirements are traceable to explicit user decisions. Items marked [ASSUMPTION] have been surfaced as risks in Section 10.*
