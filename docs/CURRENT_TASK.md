# Current Task

Version:
V0.12 — Advanced Multi-Agent Orchestration & Intelligent Routing — **READY FOR MANUAL TEST** (committed on `main`). Base: V0.11 (304e981), V0.10, V0.9, V0.8, V0.7, V0.6, V0.5, V0.4, V0.3.2, V0.3.1, V0.3, V0.2.1.

Task:
Make the capabilities of V0.1–V0.11 work together as one system with JARVIS as the ORCHESTRATOR: specialist ROLES (Analysis, Coding, Research, Unity, Computer, QA, Review) over a validated, bounded task graph; deterministic planning first (a model only for open-ended compound goals); least-capability role contracts re-checked at node start; typed, sanitized, trust-labelled artifacts and fenced handoffs; per-role routing reasons, benchmarks and risk-based review independence; bounded retry/escalation/revision; approval gates; PARTIAL/BLOCKED outcomes; status questions from the graph; cancel cascade; revalidating resume. NOT V1.0. No tag, no COMPLETE.

State:
IMPLEMENTED · AUTOMATED TESTED (1326 unit tests / 188 suites, 68 of them orchestration; `scripts/verify.sh` PASSED; smoke 139/0/2; 20 new guards; idle 0.01 CPU-s per 8 s at 73 MB) · REAL TESTED (`--orchestration-live-test --orchestration-soak 2`, release build: 61 passed / 0 failed / 0 skipped — real OpenCode FREE / Claude Code / Codex role benchmarks and tasks on disposable fixtures, a real research child, a real Finder Computer node, review independence, STOP with real agents, hard-kill + explicit resume, soak 371 tasks) · **MANUAL TEST REQUIRED** (README 704–823). Docs: `docs/MULTI_AGENT_ORCHESTRATION.md`, DEC-157…190, KNOWN_ISSUES JARVIS-V12-1…13. Not validated: any human use, a real Unity editor / Xcode inside a graph, multi-hour runs, model-planned graphs with a real planner model on hard goals, battery.

Next Step:
Wait for the user's manual test. Do NOT start V1.0 without explicit approval. Use a throw-away project copy (never the real game).

Blocked By:
Nothing.

Notes:
- Git: main only, no tags, no AI co-author trailers (the user's brief overrides the harness attribution reminder).
- Nothing in the orchestration layer runs while idle: no timer, poll, helper, provider process or network; the V0.10 embedding helper unloads itself 120 s after a task.
- `TaskEngine.orchestrationEnabled` is true in the app and false in the V0.4–V0.11 suites.

### Real findings (found by the live runs / new scenarios; all fixed)
* A node whose last two dependencies finished at nearly the same time could be STARTED TWICE (pre-existing V0.4 scheduler race, only visible with parallel readers) → started nodes are excluded from the ready list; regression-tested.
* The memory authority gate did not refuse agent-targeted grants (“always allow ComputerAgent to install software”) → patterns extended (agents, “without asking”, “full access”, Turkish); structurally memory could never act, but it could be stored and shown as context.
* The free OpenCode model followed the planted instructions of the security role cases in one run (0/2; 2/2 in another) → role evidence is now a routing filter for security-relevant coding/review (a free model needs COMPLETE passing evidence; explicit choices are respected).
* A compound goal containing “research” was taken by the research intake and lost its code scan → compound-goal detection (two distinct jobs, verbs only) now precedes the research intake for project goals.
* A research child is created after its parent → the live test (and any “latest task” logic) must pick root tasks; the finished-task hook ignores children.
* The research clause of a compound goal needs its own subject (“…check the latest official Unity BoxCollider documentation”): the V0.9 relevance filter otherwise finds nothing (the optional branch then fails and the task ends PARTIAL, honestly).
* Structural guards caught: deny-list words in the new orchestration files (narrow exemptions), `source: .voice` and `String(contentsOf` in the live test, a secret-shaped literal in the benchmark trap (assembled at run time), `\bMemoryItem` vs `maxMemoryItems`.

### Results
Unit 1326 (188 suites; 68 orchestration) · `scripts/verify.sh` PASSED · smoke 139/0/2 · idle 0.01 CPU-s/8 s, 73 MB · `--orchestration-live-test` (release) 61/0/0 — numbers in `docs/MULTI_AGENT_ORCHESTRATION.md` §14.

### Decisions
DEC-157 … DEC-190.

### Remaining Work
User manual test (README 704–823). V1.0 only with approval. No tag.
