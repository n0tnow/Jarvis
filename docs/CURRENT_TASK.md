# Current Task

Version:
V0.14 — Adaptive Learning, Controlled Self-Improvement & MCP/Skill Registry — **READY FOR MANUAL TEST** (not complete, not tagged). Base: V0.13.1 (a17b5ff). NOT V0.15.

Task:
Add a bounded adaptive layer around the existing systems: evidence-backed learning (rules, workflows/Skills, capability gaps), controlled self-improvement through the single V0.12 orchestrator, and an MCP/Skill registry with a sandboxed benchmark — without making any learned item, model, MCP or skill an authority.

V0.14 State:
* Learning, rules, Skills, gaps, self-improvement, MCP registry, Learning + Capabilities screens, conversation intents: IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (`docs/ADAPTIVE_LEARNING.md`, `SELF_IMPROVEMENT.md`, `MCP_REGISTRY.md`, `SKILLS.md`).
* `scripts/verify.sh`: VERIFY PASSED (1565 tests / 230 suites; smoke 155/0/2; idle 0.01 CPU-s / 8 s at 75 MB). `--adaptive-live-test` 84/0/0; `--mcp-live-test` 84/0/0; `--mcp-section ui` 19/0/0.
* Real candidate benchmark (`--mcp-section candidate`): 14/0/0 on the final code (cochlea-mcp built in the sandbox and benchmarked). It needs the unauthenticated GitHub API (60 requests/h): one earlier rerun was rate-limited and honestly reported licence/activity as unknown.
* MANUAL TEST REQUIRED: README 1000–1152. Not manually verified: everything.

Next Step:
Wait for the user's manual V0.14 test. Do not start V0.15 / V1.0 without approval. No tag.

Blocked By:
Nothing.

Notes:
* Git: main only, no tags, no AI co-author trailers (the user's brief overrides the harness attribution reminder).
* Automated tests never touch the user's real Hamam / Unity game; live tests use disposable fixtures; `--adaptive-live-test` / `--mcp-live-test` start from an empty isolated data directory.
* Nothing in learning, discovery, benchmark or MCP runs while idle (guarded).
* Known issues: `docs/KNOWN_ISSUES.md` JARVIS-V14-1…8.

Previous task (V0.13.1) summary: READY FOR MANUAL TEST (README 987–999 and 824–986).
