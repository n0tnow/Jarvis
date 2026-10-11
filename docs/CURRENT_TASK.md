# Current Task

Version:
V0.3.1 (intelligence infrastructure) — READY FOR MANUAL TEST. Base: V0.3 (also awaiting manual test), V0.2.1.

Task:
Hand V0.3.1 to the user. Nothing else is in progress. V0.4 (persistent task engine / autonomous workers) is NOT started and needs explicit approval. No tag.

State (milestones):
A recovery ✅ · B research (OPENCODE_RESEARCH, Qwen runtime) ✅ · C SQLite persistence ✅ · D router + local policy + free registry ✅ · E local Qwen runtime ✅ · F supervisor/resources/OpenCode service/benchmarks/agents/audit/coordinator ✅ · G UI ✅ · H REAL live tests ✅ (28/28 on OpenCode 1.19.0) · I verify.sh + perf + docs ✅

Last Successful Step:
`scripts/verify.sh` PASSED (327 unit tests, smoke 85/0/2); `--intelligence-live-test --benchmark-models` PASSED 28/28.

Current Step:
Commit/push done (see git log). Waiting for manual test.

Next Step:
User manual test (README 33–39). Then, only with approval: tag decision and V0.4.

Blocked By:
Nothing. Notes: OpenCode moved to a redesigned CLI (1.19.0) — supported (both generations probed from `--help`). Re-run `--intelligence-live-test` after OpenCode upgrades. The user was told to rotate their OpenCode Go key (accidentally printed by an exploratory `credential.list` call; JARVIS never calls it).

Notes:
- Cost/privacy rules DEC-022…028 bind: no paid API, free only by verified price, local = lightweight only, no silent fallback, sensitive never to free cloud.
- Git: main only, no tags, no AI trailers.
