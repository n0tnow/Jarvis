# Current Task

Version:
V0.3.2 — Agent Observatory & Live Consoles (IN PROGRESS). Base: V0.3.1 (verified from the repo: 327 tests green, clean, synced), V0.3, V0.2.1.

Task:
Make JARVIS observable: live provider/agent overview, sanitized live console, truthful progress, history, timeline, Stop, restart reconciliation. NOT V0.4 (no task engine, no unrestricted shell, no recursive agents). No tag.

State:
A recovery ✅ · B security boundary (`Observability/OutputSanitizer.swift`: central sanitizer + StreamSanitizer, fail closed, Redactor delegates to it) ✅ · C data plane ✅ (`ObservabilityTypes`, `ExecutionHub` bounded consoles + batched persistence, `SafeProvider` wraps EVERY engine at `IntelligenceCoordinator.makeResolved`, migration v2 `agent_events`/`agent_run_steps`/run label+progress+activity, `AuditRecorder.reconcileStaleRuns`, `ProviderStateResolver`, `AgentObservatory` read model, `ObservatoryDemo` dev-only) ✅ · D tests for the data plane ✅ (371 unit tests) · E UI (Agents section, console, history, compact summary) ⏳ · F real tests / perf / verify.sh / docs ⏳

Last Successful Step:
371 unit tests green. A real sanitizer bug was found by the new tests (JSON-field regex back-reference) and fixed.

Next Step:
`HUDSection.agents` + views (provider cards, run cards, detail with NSTextView console for native ⌘C, history, timeline), Compact summary row (392×448 unchanged), router aliases, `--demo-agents` launch options; then real runs (Qwen/OpenCode/Stop/restart), perf, verify.sh, docs (docs/AGENT_OBSERVABILITY.md, DEC-029…), commits. STOP at V0.3.2 status; do NOT start V0.4.

Blocked By:
Nothing.

Notes:
- Security incident carry-over: a V0.3.1 `credential.list` probe printed an OpenCode Go key into a tool output (user told to rotate). JARVIS only ever calls `opencode api model.list`; verify.sh forbids credential/integration operation names; never add an API console.
- Git: main only, no tags, no AI trailers.
