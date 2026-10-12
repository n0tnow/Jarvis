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
