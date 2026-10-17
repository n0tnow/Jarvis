# Current Task

Version:
V0.15 — Daily JARVIS Experience, Final Voice Integration, Conversational Context, Product Packaging & First-Run Setup — **READY FOR MANUAL TEST** (not complete, not tagged). Base: V0.14 (20579ab). The LAST feature milestone; NOT V1.0.

Task:
Turn the existing architecture into an installable, everyday macOS assistant: `JARVIS.app` launchable without Terminal, concise evidence-safe conversation, bounded follow-up references, readiness + typed first-run setup, Launch at Login / notifications / single instance — with NO new orchestrator and NO new authority.

V0.15 State:
* Presentation, working context, readiness, setup, packaging, lifecycle: IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (`docs/DAILY_JARVIS.md`, `CONVERSATIONAL_CONTEXT.md`, `APP_PACKAGING.md`, `FIRST_RUN_SETUP.md`).
* `/Applications/JARVIS.app` installed (0.15.0, ad-hoc signed, hardened runtime, microphone-only entitlement). `scripts/verify-installed.sh --crash` passed; installed `--packaging-live-test` 17/0/0.
* `scripts/verify.sh`: 1660 tests / 247 suites; smoke 165/0/2; idle 0.02 CPU-s / 8 s at 75 MB. `--daily-jarvis-live-test` 47/0/0, `--setup-live-test` 15/0/0, V0.7 `--voice-live-test` 36/0/0.
* MANUAL TEST REQUIRED: README 1153–1234 (installed launch, menu bar, first run, permissions, human voice, brevity, follow-ups, notifications, Launch at Login, crash/relaunch, a real day of use).

V1.0 stabilisation fix 1 (DEC-246): capability introspection, response-depth target and Push-to-Talk visibility fixed after the first real use — AUTOMATED VERIFIED / HUMAN PTT TEST REQUIRED (README 1235–1242).

V1.0 stabilisation fix 2 (DEC-247…253): real capability grounding, hands-free lifecycle, production UI truth, conversation/state truth — AUTOMATED VERIFIED / HUMAN WAKE + UI TEST REQUIRED (README 1243–1258). Audit table: `docs/PRODUCTION_TRUTH.md`.

Next Step:
Wait for Bilal's human acceptance tests of fix 2 (README 1243–1258: wake word in the room, voice states, installed UI). No Fix 3, no V1.1, no feature work without approval. No tag.

Blocked By:
Nothing.

Notes:
* Git: main only, no tags, no AI co-author trailers (the user's brief overrides the harness attribution reminder).
* Automated tests never touch the real Hamam project; no provider quota was spent; no credential store was read; the final custom voice is intentionally not chosen.
* Known issues: `docs/KNOWN_ISSUES.md` JARVIS-V15-1…10.

Previous task (V0.14) summary: READY FOR MANUAL TEST (README 1000–1152).
