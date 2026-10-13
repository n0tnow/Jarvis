# Current Task

Version:
V0.13.1 — Project Operator Closure & Stability — **READY FOR MANUAL TEST** (not complete, not tagged; V0.13 itself also awaits the manual test). Base: V0.13 (de48238), V0.12 … V0.1. NOT V0.14.

Task:
Make JARVIS an operator that can resume a real project, work inside its development environment, inspect the result, correct itself and leave a validated continuation state — WITHOUT a second orchestrator (V0.12 stays the only one) and WITHOUT self-improvement (V0.14) or the final personality / whiteboard (V0.15).

V0.13.1 State:
* JARVIS-V13-7 (flaky Computer live check): MITIGATED — root-cause class fixed (an AX "unsupported" return code is not the outcome; read-only cross-check, never repeated; DEC-206). Trigger of the original intermittent AX answer NOT identified. Evidence on the final code: 10/10 full `--computer-live-test` (95/0/2), 40/40 focused, 10/10 restart cycles; before: 5 failures in 9 V0.13 runs. Two test-side flaws found and fixed at the cause (restart-cycle check, cold-VLM stale screenshot → pre-warm).
* Input System typed Unity operations (7 ops): IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (Unity 6000.5.1f1, Input System 1.19.0, `--operator-live-test` 131/0/0).
* Animation + audio experiments (same engine; success, deterministic failure, cancel): IMPLEMENTED · AUTOMATED TESTED · REAL TESTED.
* Scene Profile on the Full HUD Project card (live vs stale): IMPLEMENTED · captured · MANUAL TEST REQUIRED. Compact stays 392×448.
* Guard matrix `docs/GUARD_MATRIX.md` (35 rows; 5 gaps closed). Stability soak 10/10 cycles (RSS 80→86 MB, no orphans).
* `scripts/verify.sh`: VERIFY PASSED (1470 tests / 216 suites; smoke 147/0/2; idle 0.01 CPU-s / 8 s at 73 MB).
* MANUAL TEST REQUIRED: README 987–999 (V0.13.1) and 824–986 (V0.13).

V0.13 State:
* Project Continuity (`docs/PROJECT_OPERATOR.md`): IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (`--continuity-live-test` 21/0/0 + two-launch hard kill).
* Unity development operator (`docs/UNITY_DEVELOPMENT_OPERATOR.md`): IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (`--operator-live-test` 97/0/0, real Unity 6000.5.1f1; model-planned graph 7/0; soak 5/0).
* General visual grounding (`docs/VISUAL_GROUNDING.md`): IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (benchmark 15/16 ×3; computer live test 95/0/2 incl. icon-only / ambiguous / purchase / Safari).
* Experiments and asset suitability (`docs/EXPERIMENTATION.md`): IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (disposable-project experiments, a real Poly Haven asset REFUTED honestly, cancel, hard-kill recovery, soak).
* UI: Project continuity card, Experiments card, Settings → Project operator, Compact operator line (392×448): IMPLEMENTED · captured (`tasks_operator.png`) · MANUAL TEST REQUIRED.
* `scripts/verify.sh`: VERIFY PASSED (1446 tests / 210 suites, smoke 147/0/2, idle 0.01 CPU-s / 8 s, 28 new guards).
* MANUAL TEST REQUIRED: README 824–986.

Next Step:
Wait for the user's manual V0.13 / V0.13.1 test. Do not start V0.14 / V0.15 / V1.0 without approval. No tag.

Blocked By:
Nothing.

Notes:
* Git: main only, no tags, no AI co-author trailers (the user's brief overrides the harness attribution reminder).
* Automated tests never touch the user's real Hamam / Unity game; Unity live tests use a disposable fixture copy.
* Nothing in continuity, experiments or visual grounding runs while idle: no timer, poll or watcher; the vision helper is on demand and unloads after 45 s.
* Known issues: `docs/KNOWN_ISSUES.md` JARVIS-V13-1…17 (V13-7 mitigated, trigger unknown).
