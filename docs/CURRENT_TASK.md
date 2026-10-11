# Current Task

Version:
V0.5 — Proactive Reasoning, Opportunity Engine & Approval Policy — **READY FOR MANUAL TEST** (not COMPLETE; not tagged). Base: V0.4 (7f6b3d5), V0.3.2, V0.3.1, V0.3, V0.2.1.

Task (done):
A DECISION layer above the V0.4 task engine (see `docs/PROACTIVE_REASONING.md`, DEC-041…046). Approved or automatic actions are NORMAL V0.4 tasks; the opportunity/policy/approval code never edits files.

State:
Implemented · automated tested (`scripts/verify.sh` PASSED, 536 tests, smoke 99/0/2) · REAL TESTED (`--proactive-live-test` 26/26, OpenCode FREE) · manual test required (README 92–125).

Next Step:
Wait for the user's manual test of V0.5. Then, only with explicit approval, V0.6 (Unity Project Agent). Do not start it unprompted; no tag until the user approves.

Blocked By:
Nothing.

Notes:
- Default autonomy mode is Ask Before Acting; Low-Risk Autonomous is opt-in (Settings → Autonomy).
- Known limits: `docs/KNOWN_ISSUES.md` JARVIS-V05-1…5.
- Git: main only, no tags, no AI trailers (user rule).
