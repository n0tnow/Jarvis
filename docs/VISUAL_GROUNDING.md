# Visual Grounding (V0.13)

Perception only. A visual provider answers "where is X in this picture / what does this picture show"; it **never** decides, approves or acts. Code: `Sources/Jarvis/Vision/`.

## 1. Rules

* The output is untrusted data: `VisualRegion` boxes are normalised and validated; text is sanitised and bounded; instruction-like text printed in a picture is **recorded as an injection note and ignored**.
* Safety is the **worst** of (model label, text printed on screen, the label the plan asked for), classified by the V0.11 `ConsequenceClassifier`. A purchase / account / credential / install / permission button stays blocked whatever the model says.
* A proposal reaches the executor only through the V0.11 `VisionProposing` seam (`GroundedVisionProposer`). The executor still checks freshness, occlusion, user interference and policy; coordinates are window-relative and a coordinate click remains the last rung of the ladder.
* Providers are **on-device**. Privacy classes (on-device / subscription / free cloud × desktop / project / synthetic) exist, but **no cloud provider is registered**: screen content never leaves the machine. No API key, no paid API.
* Pictures are memory-only. What is stored: picture hash, provider, query, outcome, short detail (`visual_observations`, schema v12).

## 2. Providers

| Provider | Role | Notes |
|---|---|---|
| Apple Vision OCR | text only | on-device, instant; cannot find icons |
| Qwen3-VL-2B-Instruct (4-bit MLX) | locate / describe | local helper, cold ≈ 3.7 s, warm ≈ 2.0 s (locate incl. the count check; a describe question ≈ 1 s), ≈ 2.0 GB resident |
| Qwen3-VL-4B-Instruct (4-bit MLX) | locate / describe, better boxes | cold ≈ 5.3 s, warm ≈ 3.4 s (locate incl. the count check; a describe question ≈ 1.1 s), ≈ 2.9 GB resident |

Helper (`scripts/vision-ai/jarvis_vision_worker.py`, mlx-vlm 0.7.6; re-run `scripts/setup_vision_ai.sh` after pulling to refresh the copy it installs): offline (`HF_HUB_OFFLINE`), pinned model revisions, started on demand, unloaded after 45 s idle and under memory pressure, killed if hung, killed at quit. Installed **only** by `scripts/setup_vision_ai.sh`; nothing is downloaded by the app; no model file is committed. Apache-2.0.
Settings → Visual: Off / On-device (automatic) and the model choice (applies after relaunch).

## 3. Benchmark (REAL measured, 16 synthetic cases, `--visual-benchmark`)

Apple OCR 7 / 16 (some "passes" are artefacts of "no text recognised") · Qwen3-VL-2B 15 / 16 · Qwen3-VL-4B 15 / 16 (better IoU: 0.63–0.93 vs 0.30–0.88) · chain (OCR first, then 4B) 15 / 16. Re-measured after the helper gained its **count check** (a single box is verified with a second question — two or more matches ⇒ AMBIGUOUS; found by the real icon-only test where two identical stars were first clicked once): same 15 / 16, locate latency ≈ +1.2 s. Unload takes ≈ 0.1 s.
The one failure (`lighting-dark`: the model says "yes" for a dim frame) is why **lighting is judged from the editor's luminance numbers, not from a model**. The purchase button is flagged as a purchase, the injection case is not followed, the ambiguous case abstains.
A Claude Code image probe was accepted over stream-json (subscription), but it would send screen content to the cloud, so it is **not integrated**. Codex CLI is not installed here; OpenCode's free models are excluded by the sensitive-screen-content rule.

## 4. Use

* Unity: capture + objective analysis first; the VLM may add a one-line, labelled-INFERRED description.
* Other apps: only when the ladder reaches the vision rung (no Accessibility label); a model box is never executed directly.
* "Not found" and "ambiguous" are normal answers (abstain), not errors to be guessed around.

## 5. Not done / limits

No visual stack for video, DRM or secure content (blank by design). Live Screen-Recording-dependent tests need the user's permission and are manual. Prime Video is a **human** manual test only; there is no Prime-Video-specific scraper, and no purchase / rental / subscription action exists.

## 6. REAL evidence (this Mac, M5 / 16 GB, three displays incl. Retina)

* Icon-only control (circled plus, no text / no Accessibility element): found, ONE click inside it, verified from the UI (`--computer-live-test`).
* Two identical star icons: AMBIGUOUS, neither clicked. "Buy now": blocked as a purchase before any click.
* Stale screenshot after the window moved: refused; re-observed; the click still lands inside the control. Retina + non-Retina displays: the same press lands inside the control. User typing: JARVIS steps back.
* Safari (an application with no adapter): the model's box for the address field overlapped Accessibility's own frame by 55 % (cold start included, ≈ 8.6 s); the picture was memory-only.
