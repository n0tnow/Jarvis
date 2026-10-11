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
