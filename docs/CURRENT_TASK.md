# Current Task

Version:
V0.4 — Autonomous Task Engine. Base: V0.3.2 (commits e445f3f / d68513d / fc8a998), V0.3.1, V0.3, V0.2.1.

Task:
User-initiated autonomy: Goal → durable Task → validated structured Plan → scheduled agents/tools → deterministic validation → bounded repair/escalation → report; workspace + capabilities + leases; restart recovery. NOT V0.5 (no proactive work). No tag.

State:
**V0.4 — READY FOR MANUAL TEST.** Implemented, automated tested (482 unit tests, smoke 94/0/2, `verify.sh` PASSED incl. V0.4 guards) and REAL TESTED (`--task-live-test` 29/29: OpenCode FREE fixed a failing fixture test end to end; cancel; interrupt/resume; approval). Nothing is MANUALLY VERIFIED.

Last Successful Step:
`scripts/verify.sh` → VERIFY PASSED; `--task-live-test` → 29 passed, 0 failed; captures show Compact still 392×448; performance equals V0.3.2 on the same host (see PROJECT_STATE).

Next Step:
User manual test: README items 67–91 (use a throw-away project). Do NOT start V0.5 and do NOT tag until the user approves.

Blocked By:
Nothing.

Notes:
- Reference: `docs/AUTONOMOUS_TASK_ENGINE.md`, DEC-033…040, `docs/KNOWN_ISSUES.md` (JARVIS-V04-1…7).
- Security carry-over: JARVIS never invokes credential.*/integration.*; only `model.list`. verify.sh guards are extended, never weakened.
- Git: main only, no tags, no AI trailers (user rule).
