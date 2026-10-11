# Current Task

Version:
V0.3.1 — Intelligence infrastructure (IN PROGRESS). Base: V0.3 READY FOR MANUAL TEST (not yet user-verified), V0.2.1.

Task:
Durable persistence + audit trail + OpenCode free-model pool + local Qwen + provider supervisor + automatic model routing + background sub-agent foundation. NOT V0.4 (no autonomous task engine). No tag.

State (milestones):
A recovery ✅ · B research (docs/OPENCODE_RESEARCH.md, Qwen runtime) ✅ · C SQLite persistence ✅ (commit f2665a5) · D router + local policy + free registry ✅ (23f6c72) · E local Qwen runtime ✅ · F supervisor/resources/OpenCode service/benchmarks/agents/audit/coordinator ✅ (unit + integration tested, 302 tests) · G Settings/System UI ⏳ · H live REAL tests (`--intelligence-live-test`) ⏳ · I verify.sh + perf + docs ⏳

Last Successful Step:
302 unit tests green (fake CLIs, fake local worker, temp SQLite). REAL manual probes done: OpenCode free model answers through `opencode run`, restrictive config canary-tested, local Qwen answers `JARVIS_LOCAL_OK` via mlx-vlm in an isolated venv.

Current Step:
Commit E/F, then UI (Settings provider modes + OpenCode free models + local runtime + active agents), then the real live test through the app stack.

Next Step:
`--intelligence-live-test` (SQLite reopen, local Qwen, OpenCode free model, routing local/free/premium, lifecycle, cleanup), `--benchmark-models`, verify.sh policy updates, performance table, docs (README/PROJECT_STATE/ARCHITECTURE/KNOWN_ISSUES/ROADMAP/DEV_LOG), push. STOP at V0.3.1 status. Do NOT start V0.4.

Blocked By:
Nothing.

Notes:
- Coding WORK ("write/fix/refactor …") is `workerRequired` in conversation (V0.3 rule, preserved): it never reaches a provider. Coding QUESTIONS and background agents (AgentRunManager) are what exercise the free-model pool in V0.3.1.
- Git: main only, no tags, no AI trailers.
