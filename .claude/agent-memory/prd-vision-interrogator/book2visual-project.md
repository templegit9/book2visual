---
name: book2visual-project
description: Core project context for Book2Visual — architecture decisions, scope, pipeline, and v1 constraints established in the discovery session
metadata:
  type: project
---

Book2Visual is a native macOS (SwiftUI, macOS 14+) app that converts a book/story the user owns into a condensed, AI-interpreted colored-anime/manga visual adaptation, running open-source models on a user-rented ThunderCompute GPU instance.

**PRD status:** Full PRD generated 2026-05-29. Saved as `Book2Visual-PRD.md` in the project root.

## Architecture decisions (locked for v1)

- **Mac app:** SwiftUI, macOS 14+. Manages ThunderCompute instance lifecycle (provision/start/stop via tnr CLI or Thunder API token). SSH tunnel to FastAPI on instance.
- **Remote service:** Long-lived FastAPI server on the GPU instance. Mac app calls it over SSH tunnel. Real per-scene log streaming (SSE or WebSocket).
- **Secrets:** macOS Keychain for SSH key passphrase + Thunder API token. SSH key read from existing path on disk — never written.
- **Progress:** Live per-scene progress streamed to in-app view. Auto-download PNG pages to Mac on completion.
- **Output viewer:** In-app PNG viewer. v1 export = ZIP of PNGs (no PDF/EPUB).
- **Resume on interruption:** Full restart acceptable for v1 (no partial resume).

## Pipeline

1. **Text stage:** Qwen2.5-32B (4-bit quant) preferred; degrades to 14B/7B on smaller GPUs. Tasks: extract key scenes, per-character descriptions, write prose captions, generate canonical character reference (description + reference image as consistency anchor).
2. **Image stage:** FLUX.1-dev preferred on big GPUs; FLUX.1-schnell on smaller. IP-Adapter fed canonical character reference image for consistency across panels.
3. **Assembly:** Pillow. Fixed 2x2 composite pages. Author prose burned as rectangular caption boxes. Important scenes = full-page 1x1 slots.

## v1 scope

**IN:** Instance lifecycle management (provision/start/stop), plain-text input (paste, 2k–4k words), character name + race text fields, full pipeline, ZIP export, in-app viewer, SSH tunnel, Keychain secrets, VRAM-mode config flag.

**OUT:** EPUB input parsing, PDF/HTML export, scene-review widget, fancy race-selector UI, shaped speech bubbles, dynamic panel layouts, multi-instance/job queue, full-book scaling, Homebrew distribution.

## Key risks

- Character consistency quality on AI-interpreted appearances
- Model VRAM fit on chosen Thunder GPU tier
- Instance cost runaway (forgotten running instances)
- Thunder API integration unknowns (tnr CLI vs REST API)
- Model weight download time / persistence (recommend pre-baked persistent volume)
- FLUX manga/anime style fidelity (it's colored stills, not inked manga)
- Prose caption legibility in 2x2 tiles
- SSH tunnel reliability under long jobs

See also: [[user-profile]]
