# Current Task

Version:
V0.13 — Autonomous Project Operator & General Visual Grounding — **READY FOR MANUAL TEST** (not complete, not tagged). Base: V0.12 (957f95e), V0.11 … V0.1.

Task:
Make JARVIS an operator that can resume a real project, work inside its development environment, inspect the result, correct itself and leave a validated continuation state — WITHOUT a second orchestrator (V0.12 stays the only one) and WITHOUT self-improvement (V0.14) or the final personality / whiteboard (V0.15).

State:
* Project Continuity (`docs/PROJECT_OPERATOR.md`): IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (`--continuity-live-test` 21/0/0 + two-launch hard kill).
* Unity development operator (`docs/UNITY_DEVELOPMENT_OPERATOR.md`): IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (`--operator-live-test` 97/0/0, real Unity 6000.5.1f1; model-planned graph 7/0; soak 5/0).
* General visual grounding (`docs/VISUAL_GROUNDING.md`): IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (benchmark 15/16 ×3; computer live test 95/0/2 incl. icon-only / ambiguous / purchase / Safari).
* Experiments and asset suitability (`docs/EXPERIMENTATION.md`): IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (disposable-project experiments, a real Poly Haven asset REFUTED honestly, cancel, hard-kill recovery, soak).
* UI: Project continuity card, Experiments card, Settings → Project operator, Compact operator line (392×448): IMPLEMENTED · captured (`tasks_operator.png`) · MANUAL TEST REQUIRED.
* `scripts/verify.sh`: VERIFY PASSED (1446 tests / 210 suites, smoke 147/0/2, idle 0.01 CPU-s / 8 s, 28 new guards).
* MANUAL TEST REQUIRED: README 824–986.

Next Step:
Wait for the user's manual V0.13 test. Do not start V0.14 / V0.15 / V1.0 without approval. No tag.

Blocked By:
Nothing.

Notes:
* Git: main only, no tags, no AI co-author trailers (the user's brief overrides the harness attribution reminder).
* Automated tests never touch the user's real Hamam / Unity game; Unity live tests use a disposable fixture copy.
* Nothing in continuity, experiments or visual grounding runs while idle: no timer, poll or watcher; the vision helper is on demand and unloads after 45 s.
* Known issues: `docs/KNOWN_ISSUES.md` JARVIS-V13-1…14 (one intermittent V0.11 live check, JARVIS-V13-7).
