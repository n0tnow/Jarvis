# Persistence (V0.3.1, DEC-023)

Status: IMPLEMENTED · AUTOMATED TESTED (14 unit tests) · REAL TESTED through the app's own persistence layer (see PROJECT_STATE).

## Why
JARVIS needs durable operational memory (tasks, agent runs, which model did what and why, benchmark history, provider health) that survives restarts and lets later milestones retrieve a *small* relevant slice instead of replaying history into prompts. SQLite is a system library on macOS: no server, no new dependency.

## Layout (never inside the git repository)
```
~/Library/Application Support/JARVIS/        (APFS is case-insensitive: same folder as "Jarvis")
    jarvis.sqlite  (+ -wal/-shm)             metadata, relations, audit trail      — mode 0600
    artifacts/{reports,screenshots,provider-output,benchmark,checkpoints,logs}/<yyyymmdd>/<uuid>.<ext>   — 0600 files, 0700 dirs
    runtime/mlx-venv                          local-model runtime (scripts/setup_local_ai.sh)
    provider-workspace/                       empty private cwd for providers (V0.3)
```
`.gitignore` blocks `*.sqlite*`, `*.db`, `*.safetensors`, `*.gguf`; `scripts/verify.sh` fails if any such file is tracked and a test proves the standard path is outside the repo.

## Engine (`Persistence/`)
- `SQLiteDatabase.swift` — system `SQLite3`. ONE serialised writer connection (every `write {}` is a single `BEGIN IMMEDIATE … COMMIT` transaction, rolled back on error) + two read-only connections (WAL lets reads proceed during a write). Foreign keys ON, 5 s busy timeout. A file that cannot be opened as a database is **moved aside** (`jarvis.sqlite.corrupt-<unixtime>`, never deleted) and replaced, so JARVIS keeps starting.
- `Migrations.swift` — `PRAGMA user_version` + `schema_migrations` history; each migration is one transaction; a database **newer** than the build is refused (no silent downgrade). Never edit a shipped migration; append.
- `JarvisRepository.swift` — typed access. `ArtifactStore.swift` — hybrid file + reference storage (path relative to `artifacts/`, size, SHA-256, task/run links; `verify` detects tampering). `Redactor.swift` — secret masking, prompt hashing, bounded excerpts.

## Schema v1
`projects`, `tasks`, `task_steps` · `agent_runs` (the audit trail) · `model_registry`, `model_benchmarks`, `provider_health` · `tool_executions`, `file_changes` · `approvals`, `proposals` · `activity_events` · `artifacts`.
Tables for V0.4+ (`tasks`, `task_steps`, `approvals`, `proposals`) are plain storage: **nothing in V0.3.1 runs autonomous work**.

## Audit trail (`agent_runs`)
Per run: task, parent run, agent type, engine, model, cost class, **selection reason (machine-readable JSON)**, privacy, start/end, status, tools used, files read/changed, validation status, result summary, retry count, escalated from/to, error category, prompt SHA-256 + length, token counts when the provider reports them. "Who changed `NetworkPlayer.cs`?" = `fileChanges(path:)` → `agentRun(id)`.

## Minimisation / secrets
- Never stored: credentials, API keys (none exist), whole prompts, whole answers. Stored: SHA-256, length, and — unless the task is `sensitive` — a ≤120-char **redacted** excerpt. `Redactor` masks provider-style keys, bearer tokens, GitHub/Slack/AWS tokens, JWTs, private-key blocks, `password=`/`token:` assignments and long opaque blobs.
- Activity messages are redacted on write; the table is capped (2000 rows). Large content goes to files, referenced by id.

## Retrieval policy
Providers never receive "the database". Context comes from targeted queries (active task, last N relevant runs, recent failures for the chosen model, benchmark summary) — implemented in `ContextRetrieval` (V0.3.1) and bounded by character budgets. Provider token counts are recorded only when the provider reports them (OpenCode `step_finish.tokens`, Claude `usage`); nothing is estimated and presented as fact.

## Known limits
No encryption at rest (file mode 0600 inside the user's account); no automatic artifact pruning yet; runs left `running` by a crash are listed by `interruptedRuns()` and are NOT auto-resumed (V0.4).

## Schema v3 — autonomous task engine (V0.4)
Additive migration (nothing renamed): `tasks` gains goal, kind, risk, workspace_root, started_at, current_step, activity, progress_fraction/source, constraints, failure_category/reason, cancel_requested, recovery, plan_version, capabilities, git_baseline, report/checkpoint artifact ids, accumulated_seconds, preference, destructive_requested; `task_steps` gains step_key, type, description, depends_on, expected, validation, risk, weight, attempts, agent_run_id, result_summary, failure_*, validation_evidence; new `step_attempts` (primary/repair/escalation/recheck with engine, model, outcome, evidence) and `file_leases` (path, task, step, owner, state active/released/stale); `approvals` gains step_id, action, reason, risk; `file_changes` gains step_key, before_hash, after_hash, preexisting. Repository: `Persistence/TaskRepository.swift` (every text field redacted/sanitized and bounded on write). Launch reconciliation (`reconcileTasksAfterRestart`): `planning/ready/running` tasks → `interrupted` (+ their running/verifying steps), active leases → `stale`. Checkpoints and reports are artifacts (`checkpoints/`, `reports/`), referenced from the task row. Task fixtures, checkpoints and reports are never tracked by git (`verify.sh`).

## Schema v4 — proactive reasoning (V0.5)
Additive transactional migration. `opportunities` (project, origin, origin task/step/run, bounded title/summary, category, evidence JSON ≤12 items, affected scope, structured assessment JSON, risk/design/reversibility/destructiveness/effects/capabilities/confidence/relation/evidence strength, policy decision + reasons, status, timestamps, expiry, **dedup_key**, related opportunity, occurrences, **cooldown_until**, autonomy depth, proposed action JSON, **action_hash**, task id, **unique source_event**); `proposals` extended (opportunity, project, reason, evidence, proposed action, scope, risk, design impact, reversibility, expected benefit, validation plan, action hash, resulting task, expiry, critical flag); `approvals` + `proposal_id`, `scope_hash`; `tasks` + `origin`, `origin_task_id`, `origin_opportunity_id`, `autonomy_depth`, `scope`. Repository: `Persistence/OpportunityRepository.swift`. There is no table or column for model reasoning; all text is sanitized and bounded on write. Launch reconciliation: `OpportunityEngine.reconcileOnLaunch` expires old pending proposals and completes half-finished decisions (deterministic ids ⇒ exactly once).

## Schema v5 — Unity project agent (V0.6)
Additive transactional migration: `task_steps.unity_params` (JSON of the bounded, typed `UnityStepParams` — scene, targets, test mode/filters, observe seconds, expectations, explicit actions). Nothing else is persisted for Unity: editor/connection state is transient; console text is sanitized into step evidence/reports; the Unity checkpoint section (Console baseline fingerprints, editor version, connection/play/compile facts, validated-step evidence, approved dirty scenes) lives in the task checkpoint artifact; there is no table or column for raw Unity output. The bridge's own spool files live in the project's `Library/JarvisBridge` (Unity-owned, git-ignored, regenerated).

## Schema v6 — voice input channel (V0.7)
Additive transactional migration: `tasks.input_channel TEXT NOT NULL DEFAULT 'typed'` ('typed' | 'voice'). Informational only: it changes no policy, capability, risk or approval (`origin` stays `userTask`). **Nothing else about voice is persisted**: there is no audio, waveform, recording, partial-transcript or transcript-history column or table (guarded by `verify.sh`); voice diagnostics are in-memory (`VoiceTurnMetrics`) plus bounded, content-free activity lines (lengths, language, latency). Voice preferences are UserDefaults like every other setting. The speech helper's model lives outside the data directory (`~/AI/models/whisper-small-mlx`, git-ignored by location) and its runtime under `runtime/voice-venv`.


## Natural voice (V0.8) — no new persisted data
V0.8 adds NO table, column or file for audio: the wake ring, VAD state, utterance audio, the synthesised speech and the helper buffers live in memory only (`verify.sh` and the live test scan the data and runtime directories for audio files; `NaturalVoiceSafetyTests` pins the absence of writing code). Persisted preferences (UserDefaults): `prefs.voice.wake.enabled` (default OFF), `…wake.acknowledgement`, `…bargeIn`, `…preset`, `…neuralModelPath`, `…neuralIdleUnloadSeconds`. Turn-manager state is never persisted: every launch starts DORMANT and wake mode returns only if the user left it on and the microphone is allowed. The runtime lives outside the repository: `~/Library/Application Support/JARVIS/runtime/{natural-venv, wake/ (3 pinned feature models + jarvis_head.npz), jarvis_*.py}` and `~/AI/models/supertonic-3`.

## Schema v7 (V0.9)

New tables: `research_sessions` (goal, type, status, constraints JSON, freshness, deep, budget meter JSON, report/markdown artifact ids), `research_queries`, `research_sources` (url, final_url, domain, title, type, official, retrieved_at, content_hash, method, auth_required, http_status, trust, excerpt ≤ 400 chars, note, injection flags), `research_claims` (statement, kind, epistemic, status, freshness, evidence refs), `research_candidates` (name, url, rank, verdict, data JSON), `acquisitions` (state, class, name, source/download URL, host, sha256, size, detected type, quarantine path, trust, inspection JSON, importedTo/importTaskID). **No page body, HTML or binary is ever stored in SQLite**; the report (JSON + Markdown) is an artifact; downloaded files live under `Application Support/JARVIS/acquisitions/<id>/`. Restart: in-flight research/downloads become `interrupted` (`reconcileResearchAfterRestart`); resume is explicit. Migration v6→v7 is additive.

## Schema v8 (V0.10)

New tables: `memory_projects` (key, name, root, path aliases, identity kind), `memory_items` (project key, type, subject, key/value, summary ≤ 400, details ≤ 1,500, status, strength, importance, scope, area, tags, origin, created/updated/valid-from/last-verified/expires, superseded-by, pinned, user-corrected, current-sensitive, language, extraction version, canonical hash, forgotten-at), `memory_sources` (kind, ref, label, locator, observed-at — the provenance), `memory_relations`, `memory_embeddings` (**derived**: model id, revision, dimension, text hash, float32 vector, checksum), `memory_events` (bounded to ≈ 3,000, content-free), `memory_meta` (index versions, last rebuild), `memory_context_uses` (per agent run: memory ids, truth keys, item/char counts). No conversation archive, transcript, page body or audio. Forgetting clears the rationale text and deletes the vector; superseded/archived rows are kept as history. Migration v7→v8 is additive.

## Schema v9 — General Computer Use (V0.11)
`task_steps.computer_params` (the typed actions of a computer step, JSON) · `computer_sessions` (id = task id; goal, status running/waitingForApproval/completed/failed/cancelled/interrupted, target apps, capability rung, vision flag, resume count, memory ids) · `computer_actions` (seq, time, kind, mechanism rung, app, window, target label, risk, status, resolution, verification summary, bounded detail, approval id, **text class + length only**, duration, attempts, provider; bounded to the last 400 per session) · `computer_observations` (kind ax/screenshot, counts, sizes, a few-byte image hash, provider, `persisted` always 0; bounded to 200 per session). There is no column for typed text, clipboard contents, an Accessibility tree or pixels. Restart: running/approval-waiting sessions become `interrupted` (`reconcileComputerAfterRestart`); old sessions fall away (`pruneComputerSessions`). Everything is sanitized (`OutputSanitizer`) before it is stored.

## Schema v10 — Multi-agent orchestration (V0.12)
`task_steps` gains `optional`, `revision`, `delegate_params` (JSON: goal/reason/gate action) and `delegated_task_id`; `tasks.parent_task_id` (a column reserved since v1) now links a delegated child to its parent; `model_benchmarks.context_chars` (prompt size of role-benchmark cases). New tables: `task_graphs` (task id, template, planner `deterministic|model`, rationale, node count, revisions, planner prompt chars/ms), `graph_revisions` (task, n, reason, added node keys), `agent_artifacts` (task, node, role, kind, trust, provider/model, run, attempt, inputs, status valid/stale/rejected, validation line, **sanitized content ≤ 6,000 chars**, hash, injection flags) and `routing_decisions` (task, node, role, run, engine/model, mode, human sentence, machine reason, independence, escalation reason, failure class, outcome, context/handoff/artifact/file/memory counts, queue/run ms, tokens, cost class). Edges are `task_steps.depends_on` (no duplicate truth). Nothing stores hidden reasoning, a provider conversation, a page body or a secret (guarded). Cleanup: `pruneOrchestration(keepTasks: 150)` at launch drops artifacts/routing/graph rows of older finished tasks; task history stays. Migration tested fresh and from earlier schemas (every migration test opens a database that is upgraded through v10).


## V0.13 additions (schema v11 and v12)

* **v11 — `project_continuity`** (per project key: the next-step queue, last continuation, session counter) and **`project_checkpoints`** (a finished task's Git HEAD, branch, dirty paths, file hashes, tree fingerprint, validated / remaining / next, outcome; pruned to the last 30). Indexes `idx_tasks_workspace`. Nothing else about "where we left off" is stored — the view is derived on demand.
* **v12 — `experiments`** (contract, status, verdict, structured result, cleanup state, environment path), **`experiment_steps`** (typed step log; foreign key with cascade — status updates are upserts, never REPLACE), **`visual_observations`** (picture HASH, provider, query, outcome, short detail, injection-note count — no pixels), **`asset_evaluations`** (fact classes, usage reasoning, recommendation).
* Launch reconciliation: running experiments → INTERRUPTED (never resumed), orphan environments removed (marker-checked) and headless editors inside them stopped; checkpoints pruned to 30; visual observations to 500.
* Migration tests: fresh v12, upgrade from v10 / v11, no column that can hold a picture.
