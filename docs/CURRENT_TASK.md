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

V1.0 stabilisation fix 3 (DEC-254…259): macOS productization — one installed app, permission truth, storage isolation (fixture incident), Settings destination with Wake Word, window policy and header-only drag, Full HUD design system — AUTOMATED VERIFIED / HUMAN UI + WAKE TEST REQUIRED (README 1259–1267).

V1.0 stabilisation fix 4 (DEC-260…266): action execution with receipts, structured system status, self-echo safety (envelope-confirmed barge-in, provenance phantom guard), contextual vocabulary, media goal — AUTOMATED VERIFIED / HUMAN ACTION + VOICE TEST REQUIRED (README 1268–1277).

V1.0 decision milestone, Phase A (DEC-267…274): typed Decision layer in front of the existing pipeline (deterministic grammar first), verified self-navigation (state + render acknowledgement + settled re-read), grounded voice-status / visibility / project-open answers, bounded spoken restatements, an upstream pathological-transcript guard, an OPTIONAL remote classifier (Jev) as a disabled-by-default adapter with mocks only, a 353-case decision corpus + runner, and a local-model benchmark harness — IMPLEMENTED · pure logic AUTOMATED TESTED on Linux · macOS glue UNCOMPILED (JARVIS-V1D-1) · MANUAL TEST REQUIRED (README 1278–1294). Phase B handoff: `docs/V1_DECISION_INTELLIGENCE_PHASE_B.md`.

V1.0 decision milestone Phase B (DEC-275…279): Cloud Phase A integrated and verified on macOS; Jev transport + Keychain credential; Unity project open; held-out and Jev benchmarks; local model benchmark; installed build — AUTOMATED TESTED / REAL TESTED (parts) / MANUAL TEST REQUIRED (README 1295–1305, see docs/V1_DECISION_INTELLIGENCE_PHASE_B.md "Phase B results").

V1.0 intelligence & reliability pass (Cloud, DEC-280…286): semantic lexicon + typed referents + confidence/Jev routing + presentation contract/claim firewall + project discovery + pure reliability policies + seeded soak — AUTOMATED TESTED (Linux harness) / macOS glue UNCOMPILED (JARVIS-V1RP-1) / MANUAL TEST REQUIRED (README 1306–1314). Branch `claude/laughing-albattani-uzdlr6`, not merged. See `docs/V1_RELIABILITY_PASS.md`.

V1.0 background reliability pass (Cloud, DEC-287…293): policy layer for long unattended tasks (derived status, readiness, retry/budget, replay, approval expiry, drift, event log, usage, context selection, worker admission, digest, quality gate) — AUTOMATED TESTED (Linux harness) / macOS UNCOMPILED (JARVIS-V1BG-2) / mostly NOT WIRED (JARVIS-V1BG-1) / MANUAL TEST REQUIRED (README 1315–1321). Details: `docs/V1_BACKGROUND_RELIABILITY.md`.

V1.0 Jev gating (Cloud, DEC-301…308): Jev as an optional advisory classifier behind one local gate (safety classes, per-intent floors, corroboration, local risk / target resolution, model calibration, malformed-answer rejection, minimal context, fallbacks) — AUTOMATED TESTED (Linux harness, simulated classifiers) / macOS UNCOMPILED (JARVIS-V1JV-1) / NO LIVE JEV NUMBERS (JARVIS-V1JV-2) / MANUAL TEST REQUIRED (README 1327–1330). Details: `docs/JEV_DECISION_POLICY.md`.

V1.0 autonomous engineering pipeline (Cloud, DEC-294…300): typed scoped assignments, observed-state verification (claims never evidence), change attribution that spares the user's dirty tree, tampering / quality / dependency / doc-truth checks, bounded semantic repair loop, ownership / staleness / cancellation, capability-based worker selection, review independence, rollback plan, grounded reports — AUTOMATED TESTED (Linux harness, real Git + Python fixtures) / macOS UNCOMPILED (JARVIS-V1EP-2) / NOT WIRED into the TaskEngine (JARVIS-V1EP-1) / MANUAL TEST REQUIRED (README 1322–1326). Details: `docs/AUTONOMOUS_ENGINEERING_PIPELINE.md`.

Next Step:
FIRST (local Mac): check out `claude/laughing-albattani-uzdlr6`, run `scripts/test.sh` then `scripts/verify.sh` (the engineering pass added eight test files and `scripts/guards_engineering.sh` too — JARVIS-V1EP-2) (the background pass added five test files and `scripts/guards_background.sh`; fix any macOS compile adjustment without weakening an assertion or a guard — JARVIS-V1BG-2); then the earlier list:
(previous) FIRST (local Mac): check out `claude/laughing-albattani-uzdlr6`, run `scripts/verify.sh`, fix any compile error in the macOS glue (JARVIS-V1RP-1 lists the files) — do not weaken a guard; then README 1306–1314; then decide whether to merge to `main` (fast-forward is possible: the branch is `origin/main` + commits). The Phase B items still open stay open: re-grant permissions, point JARVIS at the real Hamam folder (JARVIS-V1PB-1; `Jarvis --discover-projects` helps), README 1295–1305 and 1268–1277. Wiring the reliability policies into the TaskEngine is a separate, explicitly approved step (JARVIS-V1RP-2). No V1.1, no Hamam development, no tag.

Phase B next step (still valid):
Wait for Bilal: re-grant the permissions for the new build, point JARVIS at the real Hamam folder (JARVIS-V1PB-1), then README 1295–1305 and the still-open fix 4 checks (1268–1277). Only after "Jarvis, Hamam projesini aç." opens the real project and the voice tests pass may controlled Hamam work be discussed. No V1.1, no Hamam development, no Higgsfield without approval. No tag. No tag.

Blocked By:
Nothing.

Notes:
* Git: main only, no tags, no AI co-author trailers (the user's brief overrides the harness attribution reminder).
* Automated tests never touch the real Hamam project; no provider quota was spent; no credential store was read; the final custom voice is intentionally not chosen.
* Known issues: `docs/KNOWN_ISSUES.md` JARVIS-V15-1…10.

Previous task (V0.14) summary: READY FOR MANUAL TEST (README 1000–1152).
