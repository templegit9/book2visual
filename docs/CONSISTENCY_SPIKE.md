# Spike 2 — Character-consistency A/B (the decisive quality experiment)

**Goal:** decide the panel-generation mechanism before committing. This is the single biggest
technical risk: holding ONE character visually stable across ~12 anime-style panels. Run on the
provisioned A100 80GB after weights are downloaded. ~30–45 min of GPU time.

## The two contenders (set via JobRequest `consistency_mode`)

- **`kontext` (primary hypothesis):** FLUX.1-Kontext-dev, **depth-1 fan-out** — generate ONE
  canonical reference image per character, then condition every panel **independently** on that
  single reference (NEVER chain panel→panel; Kontext drifts after ~5–6 chained edits). Plus an
  anime style LoRA for the aesthetic.
- **`lora` (fallback):** train/apply a **per-character anime LoRA** on FLUX.1-dev (identity + style
  baked into one adapter), plain `FluxPipeline`.

## The known unknown this spike must answer
**Does an anime style LoRA compose with `FluxKontextPipeline` while preserving identity?**
diffusers does not document LoRA-on-Kontext; a strong style LoRA may fight Kontext's identity
preservation. If they conflict, `lora` becomes primary.

## Procedure
1. Pick a demo character with a clear text description + a 12-scene story (use the demo short story).
2. **Run A (kontext):** submit the job with `consistency_mode=kontext`. Inspect:
   - Does the canonical reference render in the right anime style (not photoreal)?
   - Across 12 panels, is the character "recognizably the same person"? Count drift panels.
   - Multi-character panels (2–3 chars): do identities stay separate?
3. **Run B (lora):** same story, `consistency_mode=lora`. Same inspection.
4. Compare against PRD §5 metric: **same character recognizable across ≥70% of panels.**

## Decision matrix
| Outcome | Decision |
|---|---|
| kontext ≥70% AND style LoRA composes cleanly | **Ship kontext** as default; keep lora as fallback. |
| kontext identity good but style drifts photoreal | Tune LoRA weight / try a Kontext-specific cartoon LoRA (`Shakker-Labs/FLUX.1-Kontext-dev-LoRA-Flat-Cartoon-Style`); if unfixable → lora. |
| kontext <70% | **Ship lora** (per-character anime LoRA on FLUX.1-dev). Update PRD + default `consistency_mode`. |

## Record
Save the two 12-panel outputs side by side, the drift counts, and chosen `consistency_mode`.
Update `Book2Visual-PRD.md` §0 + the project memory with the winner. This closes the top risk.

## Style-prompt notes (FLUX photoreal bias)
FLUX defaults toward realism — rely on an explicit anime LoRA, not just the style prefix
(`"colored anime still, manga panel, vibrant colors, detailed linework"`). Candidate LoRAs:
`alfredplpl/flux.1-dev-modern-anime-lora`, `alvdansen/softserve_anime`,
`Shakker-Labs/FLUX.1-Kontext-dev-LoRA-Flat-Cartoon-Style`.
