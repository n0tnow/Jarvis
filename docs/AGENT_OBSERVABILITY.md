# Agent Observability (V0.3.2 — DEC-029…DEC-032)

JARVIS can show what its agents/providers are doing **while they do it**, without a second provider process and without ever
showing, storing or logging a secret. This file is the reference; the decisions are in `DECISIONS.md`.

## Data flow (one stream, many observers)

```
Provider process (Claude / Codex / OpenCode) · local Qwen worker
        │ raw text — UNTRUSTED
        ▼
SafeProvider (decorator, wraps EVERY engine in IntelligenceCoordinator.makeResolved)
  └─ StreamSanitizer (OutputSanitizer, fail closed, split-secret safe)   ← THE one security boundary
        │ sanitized events — the only thing downstream ever sees
        ├──► agent runtime / ConversationService (answer text, same stream iteration)
        └──► ExecutionHub  ── bounded ConsoleBuffer (≤600 events / ≤80 000 chars per run)
                           ── coalesced UI revision (≈120 ms)
                           ── batched SQLite persistence (≈500 ms, agent_events)
                           ── sanitized output artifact when the run ends
                    │
                    ▼
            AgentObservatory (read model: provider cards, run views, history, timeline, stats)
                    │
                    ▼
         SwiftUI (Full HUD → Agents · Compact summary strip)
```

* **Same execution.** The console shows the very stream the agent runtime consumes. There is no "attach", no tail of a second
  process, no re-run. A unit test counts launches.
* **Sanitize before observation.** `Observability/OutputSanitizer.swift` is the only place raw text is turned into safe text. It runs
  *before* SwiftUI observable state, console buffers, activity events, SQLite and artifact files. `AgentConsoleEvent` sanitizes inside
  its initializer, so an event cannot exist unsanitized. Render-time-only redaction is not used anywhere.
* **Fail closed.** If the sanitizer throws/times out, the text is replaced by a withheld marker; there is no raw fallback. Tests inject
  a failing `SanitizerEngine`.
* **Split secrets.** `StreamSanitizer` holds back a bounded tail so a key split across chunks/lines is still masked, and flushes at
  stream end.
* **Credentials/integrations are never touched.** The only OpenCode API operation is the fixed `model.list`. There is no generic API console.
  `verify.sh` forbids `credential.*` / `integration.*` operation names, pty/shell use, and any write path that bypasses the hub.
* User-typed prompts are the user's own input, not provider output; the audit trail stores a prompt hash/length and a redacted excerpt
  (none for sensitive tasks), as in V0.3.1.

## Progress is never invented

`ProgressCalculator` → `ProgressSource`:

| Source | When | Display |
|---|---|---|
| `structuredSteps` | the runner declared N steps and reports each as it completes | `k / N steps` + bar |
| `weightedSteps` | declared steps with declared weights | percentage of declared weight |
| `unknown` | everything else (every real CLI/local run today) | indeterminate bar, elapsed time, "no measurable steps" — **never a percentage** |

`progressSource` is persisted with the run, so history shows the same truth after a restart. Token counts/elapsed time are shown as such,
never converted to progress.

## Provider states (truthful)

`ProviderStateResolver` is a pure function of (engine, availability, local-model state, active runs): NOT INSTALLED · SIGN-IN REQUIRED ·
READY · STARTING · RUNNING · RATE LIMITED · UNAVAILABLE · FAILED; Local Qwen adds UNLOADED · LOADED · IDLE.

* **READY ≠ RUNNING.** RUNNING means an execution in the hub is active for that engine — nothing else produces it.
* **Downloaded ≠ loaded.** Qwen is UNLOADED until the worker is started; while the model is loading a waiting run shows STARTING
  ("Loading model into memory"), then RUNNING, then LOADED · IDLE.
* A run is `starting` until the provider process/job is launched, then `running` ("Waiting for output" → "Generating").

## Run lifecycle

`RunPhase`: queued · starting · running · verifying · waiting · completed · failed · cancelled · interrupted · escalated.
Statuses persisted in `agent_runs` (`AgentRunStatus` incl. `interrupted`).

* **Stop** goes only through the existing cancellation path (`ExecutionHub.requestStop` → stop routing → `ConversationService.cancelCurrentResponse`
  / `AgentRunManager.cancel` / benchmark cancel / local cancel). The provider layer kills the real process tree; the run ends CANCELLED.
  Tested for real with OpenCode (tree gone in ≈0.1 s, no cooldown) and Qwen (worker stays usable).
* **No Pause.** None of the integrations can pause a provider process, so no Pause control exists for agents (the V0.1 demo task's Pause is unrelated).
* **Restart reconciliation.** At launch `AuditRecorder.reconcileStaleRuns` marks any row still RUNNING/QUEUED/STARTING as
  `interrupted` with a persisted reason ("JARVIS was closed while this run was active") and a console/timeline event. Verified against
  a real SQLite file written by the app.

## Console capability matrix

| Engine | Output | Live streaming | Same-session input | Console |
|---|---|---|---|---|
| Claude Code | stream-json deltas | token-level | **no** (prompt delivered once on stdin) | read-only |
| Codex | JSON events | message-level | **no** | read-only |
| OpenCode (classic/v2) | JSON events / text | message-level | **no** | read-only |
| Local Qwen | JSON lines from worker | token-level | **no** | read-only |

Input is offered only where an integration truly supports same-session input. None does today, so the console has no input field. It is a
selectable `NSTextView` (native ⌘C through the responder chain; V0.2.1 clipboard behaviour untouched). JARVIS never reads the pasteboard.

**Agent Console ≠ Developer Terminal.** The Agent Console is read-only sanitized output of JARVIS-managed runs. A Developer Terminal
(interactive shell/pty) is a *future* feature that needs its own explicit approval, permissions review and decision record. No pty, shell
string or `sh -c` exists (verify.sh).

## Bounds

| Item | Limit |
|---|---|
| Events in memory per run | 600 |
| Console characters per run | 80 000 |
| Event summary / detail | 400 / 4 000 chars |
| Output log per run (artifact) | 1 000 000 chars |
| UI revision coalescing | ≈120 ms |
| SQLite batching | ≈500 ms |
| History | paginated, filterable (engine, status, text, date) |

Console truncation is announced in the console ("older output trimmed"), never silent. Persistence is batched; events older than 30 days are pruned at launch
(`pruneEvents`; run rows are kept).

## UI

* **Full HUD → AGENTS** (also `show agents`, `ajanları aç`): provider cards, active runs (STOP), recent, **Live / History / Timeline**,
  run detail (Overview · Console · Timeline: steps, files/artifacts, usage, retries/escalation, failure reason).
* **Compact HUD:** a fixed 44 pt summary strip (only while something is running; zero height otherwise); size stays 392×448; Compact XOR Full
  unchanged.
* Accessibility: VoiceOver labels on cards/runs/buttons, state conveyed by text + icon (not colour alone), no animation under Reduce Motion,
  console has an accessibility label stating it is read-only sanitized output.

## Developer simulation

`--demo-agents` / `--demo-stress` (and the "SIMULATE" menu in the Agents section, developer controls only) create synthetic runs through
`ObservatoryDemo`. They are `isSimulated`, labelled **SIMULATED** everywhere, never written to SQLite/artifacts and never counted in
history/statistics. The synthetic secret fixture used by tests/demos is obviously fake.

## Verification map

| Claim | Evidence | Label |
|---|---|---|
| Sanitizer (patterns, split secrets, fail closed, JSON fields) | `SanitizerTests` | AUTOMATED / MOCK TESTED |
| Progress, provider state, phases, ordering, bounded buffers, no second process, malformed events, cancellation event, stale reconcile, history through the real repository | `ObservatoryTests`, `ObservatoryConsoleTests`, `ObservatoryUITests` | AUTOMATED / MOCK TESTED |
| Real Qwen + OpenCode observed (console, timeline, history, state sequence, STOP, synthetic secret through the real model, real-file reconciliation) | `--intelligence-live-test` 35/35 | **REAL TESTED** |
| Windows, Compact 392×448 across states, agents summary | smoke 89/0/2, captures | AUTOMATED / visual |
| Policy guards | `scripts/verify.sh` | AUTOMATED |
| VoiceOver reading order, real clicks/typing, long sessions, Retina | README 40–66 | **MANUAL TEST REQUIRED** |

## V0.4 additions
* Task runs are ordinary runs: `agent_runs.task_id`, `AgentRunView.taskID`, owner `.task` (Stop on such a run stops the task through the existing cancellation path). The Agents list shows `TASK · <title>` above each run.
* Deterministic build/test/file runs are `ProviderID.tool` runs (`BuildTool`/`TestTool`/`FileTool`, provider label "JARVIS Tools"): they have a console (merged stdout/stderr through `SafeToolOutput` — the second sanitization entry point next to `SafeProvider`), audit rows, tool records and exit codes, but never a provider card.
* Task progress is derived from validated steps only and persisted with `progressSource`; the Tasks screen and the Compact card show a percentage only when it exists.

## V0.5 additions
Opportunity/proposal events appear in the activity feed (and the Agents timeline via task ids): "Opportunity detected / recorded / deduplicated / suppressed", "Proposal created", "Approval required", "Proposal approved / denied / dismissed", "Auto task created", "Autonomy budget exhausted", "Proactive assessment used <provider · model> because …". Proactive tasks are ordinary runs, grouped under their task, tagged `JARVIS AUTO TASK` / `APPROVED PROPOSAL` in Tasks.

## V0.6 additions
Each Unity step is one **tool run** (`agentType: UnityTool`, engine `tool`) with sanitized console events per typed operation ("Applied: add BoxCollider to TestCube (12 ms)", "Refused: …", "Rejected: …", "Console baseline captured (N existing errors are not attributed to this task)", "Leaving a Play Mode left over by an interrupted run"). Provider runs of the same task (planner, analysis, coding, `UnityAgent`, review) keep their real engine/model. There are no fake provider cards for tools and no separate Unity log viewer; Unity facts are summarized in the task detail and the report (`## Unity`, with "Visual validation: NOT PERFORMED"). The launched editor's own stdout is sanitized into a bounded in-memory tail and never stored.

## Voice events (V0.7)
Voice reuses the existing activity feed (`JarvisStore.log` → sanitized, capped `activity_events`): "Voice: listening", "Voice: transcript submitted (N characters, tr)", "Voice: first audio N ms after release", "Speech helper loaded/unloaded/stopped", "Voice problem: <category>". Never audio, never transcript text, never partial transcripts, never per-frame events. Detailed per-turn latencies (`VoiceTurnMetrics`: STT startup, first partial, finalisation, routing→first text, text→TTS, TTS→first audio, release→first audio, stop latency) live in memory and in Settings → Voice → diagnostics (developer controls). The speech helper is a managed process (`ProcessRegistry`) but is not an "agent run": it appears in the Agents provider summary only through the System panel Voice row, and its stdout/stderr never reach any console (text results pass `TranscriptText.clean` → `OutputSanitizer`).


## Natural voice events (V0.8)
Same feed, content-free and capped: "Wake mode on/off/unavailable: <reason>", "Voice: Wake word heard", "Voice: turn ended (N ms after the last speech)", "Voice: Barge-in", "Voice: Returned to wake mode", "Wake helper stopped unexpectedly / did not answer — restarting it", "Neural voice helper started (N s) / stopped". Never audio, never a wake probability trace, never VAD frames, never partial transcripts, never the rolling buffer. Latencies of the last natural turn (endpoint, final, first audio, barge-in) are held in memory (`NaturalTurnMetrics`) and shown in the Full HUD voice strip / Settings → Voice diagnostics (developer controls). The helpers' own text is never read (only numbers, flags and audio).

## V0.9 — research in the Observatory

Research and acquisition are ordinary tasks: the Tasks list, activity ("Searching · query 3", "Reading · 5 sources", "Comparing · 4 candidates"), step list, approvals and Stop work unchanged. Each model call is an `agent_run` (`ResearchAgent`) with the sanitized prompt/answer under the usual limits; tool-like work (fetch, download, inspect) is reported as step evidence, not as raw bodies. Page text, URLs with tokens and response headers are sanitized at the existing choke points (`OutputSanitizer`, `HeaderRedactor`, `CanonicalURL.forStorage`); raw pages are never stored or shown in consoles.

## V0.10 — memory in the Observatory

Memory is not a hidden process: bounded, content-free events (proposed · accepted · merged · superseded · disputed · rejected · corrected · forgotten · stale · retrieved · context · revalidated · embedded) go to `memory_events` and short "Project memory · …" lines to the activity feed; a task that receives context logs "Context · N memories for CodingAgent". `memory_context_uses` answers "which memories did this agent run see?" (run id, task id, memory ids, truth keys, sizes). The Memory screen's Diagnostics shows counts by type/status, index health, embedding model/revision, helper state and RSS, last ingestion, last retrieval latency and the last agent context.
