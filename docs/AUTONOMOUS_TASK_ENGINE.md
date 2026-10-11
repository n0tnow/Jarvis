# Autonomous Task Engine (V0.4 — DEC-033…DEC-040)

V0.4 turns a **user-initiated goal** into a durable, planned, executed, validated and reported task — bounded, auditable, restart-safe.
It does **not** decide on its own what to build (that is V0.5). Code: `Sources/Jarvis/Tasks/`, `Persistence/TaskRepository.swift`.

```
User goal ─► GoalIntake ─► Task (SQLite, BEFORE any work) ─► Planner ─► structured Plan ─► PlanValidator
                                                                              │ (rejected plans never run)
          ┌───────────────────────────────────────────────────────────────────┘
          ▼
   TaskEngine scheduler (event-driven) ── ready steps ──► executors
          analysis / codeChange / review ─► AgentRunManager.spawn (ModelRouter · ProviderSupervisor · ResourceManager · SafeProvider · ExecutionHub)
          build / test                    ─► CommandRunner (ManagedProcess, approved profile, no shell, SafeToolOutput)
          delete                          ─► approval gate ─► ProjectTools.delete
          codeChange output ─► EditParser ─► ProjectTools.prepare/apply (capability · workspace · dirty-file approval · write lease · hash verify)
          every step ─► deterministic validation ─► passed | repair (bounded) | escalate (bounded) | failed
   ─► checkpoint (artifact) ─► report (artifact) ─► conversation summary ─► Observatory / Tasks screen / Compact card
```

## Principles

* **Providers are text-in / text-out workers.** They never touch the filesystem or run commands (the V0.3 conversation-only flags stay;
  `workspace-write` remains forbidden in `verify.sh`). A coding agent returns SEARCH/REPLACE blocks; **JARVIS** applies them. Capability,
  workspace, lease, audit and sanitization checks therefore live in ONE place.
* **Validation is deterministic where possible.** Build/test = a real process exit status; edits = hashes on disk; plans = schema + policy.
  Only the review verdict (`reviewPass`) and the structure of analysis answers involve a model.
* **Nothing is faked.** Progress = validated steps / steps (`ProgressSource.structuredSteps`); a provider saying "90 % done" has no input path.
  Counts like "12 tests" are shown only when the tool printed them. A step is never "passed" without its validation evidence.
* **Existing systems stay authoritative:** `ModelRouter` (provider/model choice), `ProviderSupervisor` (lifecycle/cooldown), `ResourceManager`
  (limits: 1 local · 2 free-cloud · 1 heavy · 3 total · depth 1), `ExecutionHub` (observation), `SafeProvider`/`SafeToolOutput` (sanitization),
  SQLite (state), the V0.3.2 Observatory (visibility). The engine adds orchestration only.

## Goal intake (`GoalIntake`)

| Text | Result |
|---|---|
| "How are you?" / "Open Agents." / "stop" | not a task (local reply / deterministic command) |
| "Explain NetworkPlayer." / "What is a mutex?" | not a task — knowledge answer from a provider (question leaders win over technical nouns) |
| "Analyze the multiplayer issue." (a project is chosen) | **read-only task** (`readProject` only) |
| "Fix the multiplayer synchronization problem." | **development task** (`readProject`, `writeProject`, `runBuild`, `runTests`) |
| "Delete the whole old networking implementation." | development task flagged `destructive` → the planner MAY plan `delete` steps, each waits for approval |
| any long paragraph | not a task merely for being long |

Without a project folder a development goal starts nothing and says why. Typed text is never privileged: voice/LLM callers will use the same intake.

## Task model and state machines (`TaskModel.swift`)

`TaskState`: created → planning → ready → running ⇄ waitingForApproval → completed | failed | cancelled; `interrupted` (stale after a restart)
→ planning/running only by an **explicit resume**. Terminal states never move. `TaskStepState`: pending → ready → running → verifying →
passed | failed | cancelled | skipped; `waitingForApproval`; `interrupted`. `verifying → running` is the repair edge. `ApprovalState`
pending → approved | denied | cancelled. `LeaseState` active → released | stale. Illegal transitions are rejected and logged (`TaskStateMachine`).
UI code cannot mutate any of them (`verify.sh` forbids repository access from `UI/`).

Persisted (schema v3, `docs/PERSISTENCE.md`): goal (bounded, redacted), kind, risk class, workspace root, git baseline, capabilities, progress +
`progressSource`, current step/activity, failure category/reason, cancel flag, recovery note, plan version, accumulated active seconds,
checkpoint + report artifact ids; per step: key, type, dependencies, expected outcome, validation kind, risk, state, attempts, run id, result,
evidence; attempts (primary / repair / escalation / recheck); approvals; file leases; file changes (before/after hash).

## Planning and plan validation

The planner (`PlannerAgent`) is an ordinary routed job: development profile ⇒ **never the local model** (`LocalModelPolicy` forbids it in code),
verified-free benchmarked OpenCode first, Claude Code / Codex when needed (Auto only; explicit modes never fall back). The answer must be ONE
JSON object (`PlanParser`, fences/prose tolerated). `PlanValidator` runs before anything is scheduled:

schema · ≤ 12 steps · titles/descriptions bounded · unique ids · dependencies exist · no self-dependency · no cycle · known step types
(analysis, codeChange, build, test, review, delete) · known validation per type · capability granted for the task kind (read-only tasks cannot
contain writing steps) · `delete` only when the goal asked for it, with explicit workspace-relative targets, declared high risk · prohibited
operations (git push/commit/reset/clean, sudo, rm -rf, curl/wget, credentials, purchase, deploy…) · recursive-agent keys (`subagents`, `spawn`, …) ·
paid providers · "local model" for development. A malformed plan is re-asked once (format repair) and then on one other provider (Auto);
a policy violation is **not** repaired — the task fails as `securityBlocked`. Plans that fail never run.

## Scheduler

Event-driven (`withTaskGroup`; wakes only when a step finishes — no polling, no timers deciding correctness). A step is ready when all
dependencies passed (a skipped dependency had nothing to do). Concurrency is deliberately small: only read-only **analysis** steps run side by
side (max 2); anything that writes, builds, tests or reviews the result runs alone. Capacity rejections from `AgentRunManager` WAIT on a
capacity-changed event (bounded) instead of failing or spinning. Max 2 active tasks. `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)`
prevents App Nap while tasks run (no permission needed). Closing the HUDs never stops a task; quitting JARVIS checkpoints and interrupts it.

## Agents and tools

| Step type | Executor | Agent identity (Observatory) |
|---|---|---|
| analysis | provider, read-only, JSON answer | `AnalysisAgent` |
| codeChange | provider returns edit blocks → JARVIS applies | `CodingAgent` |
| build / test | approved command profile via `ManagedProcess` | `BuildTool` / `TestTool` (engine `JARVIS Tools`) |
| review | provider reads the final diff + real evidence | `ReviewAgent` |
| delete | approval, then `ProjectTools.delete` | `FileTool` |

Every run is an `agent_runs` row (parent task via `task_id`) and a hub run — so console, timeline, history, Stop and stale-run reconciliation
come from V0.3.2 unchanged. `ProviderID.tool` exists only for these runs: it is never routed and not in `allCases` (no provider card).
Context is step-specific and bounded: project tree (≤ 160 entries), files named by the goal/earlier results or found by search (≤ 6–7 files,
bounded bytes), real failure output for repairs. Files that look like they contain a credential are **never sent to a provider**.

## Workspace, capabilities, tools

`WorkspaceGuard`: absolute, existing, narrow root (not `/`, home, system or JARVIS data folders); every path is relative, no `..`, no `~`,
symlinks resolved with `realpath` and verified to stay inside; `.git`, `.ssh`, `.env*`, `*.pem`, `*.key`, `id_rsa*`, `credentials*`… are
protected for read **and** write. `TaskCapability` (`readProject`, `writeProject`, `runBuild`, `runTests`, `destructiveFileOperation`, and the
never-grantable `useNetwork`, `useBrowser`, `gitCommit`, `gitPush`, `purchase` — stripped in `CapabilitySet.init`). `ProjectTools`: ReadFile,
ListDirectory/ProjectTree, SearchProject, prepare/apply edits (atomic, all-or-nothing with rollback, permissions kept), DeletePath (needs
`destructiveFileOperation`, granted per approved action only), file hashes. `GitTool`: read-only baseline (repo?, branch, HEAD, dirty/untracked
paths). **There is no "run a shell command" tool.**

`CommandRunner`/`ApprovedExecutables`: executables `swift, python3, pytest, make, npm, node, cargo, go, dotnet, xcodebuild` resolved from fixed
system locations (never the workspace, never `env`/a shell); per-tool argument policy (`python3 -m unittest|pytest` or a workspace `.py` script —
never `-c`; `swift build|test`; `make <target>` without `-f`/variables; `npm test|run test|build|lint`; …); arguments limited to a safe character
set; timeouts; stdout+stderr merged and sanitized before the console, the evidence tail, SQLite or artifacts (`SafeToolOutput`). Profiles are
discovered (declared `.jarvis/project.json` first, then SwiftPM, Cargo, Go, npm, Makefile, Python tests) — never invented.
Build/test steps execute project code by design (that is what "run the tests" means); they run in the workspace only, with a scrubbed environment.

## File ownership (leases) and user changes

A step must hold the **write lease** of every file it changes (`FileLeaseManager`: in-memory authority + persisted rows, case-insensitive paths,
directory/file conflicts, all-or-nothing, re-entrant per owner). A second writer **waits** (event-driven; cancel-aware). The edit is prepared again
from the current content once the lease is held. Leases are released when the step ends and reconciled as stale after a crash.

Before the first write, a Git baseline is stored (branch, HEAD, dirty + untracked paths = the user's own work). Touching a file that already has
uncommitted changes needs an **approval**; denied → the file is untouched. Edits are SEARCH/REPLACE on the current text, so the user's
changes elsewhere in the file survive; the change is flagged `preexistingUserChange`. JARVIS never resets, cleans, checks out, commits or pushes
(`GitTool` has no such operation; `verify.sh` forbids them in the sources).

## Repair and escalation (bounded)

Per code step: primary attempt → (a failing build/test) **one repair on the same engine** (pinned, with the real failure output) → **one
escalation** to another provider (`exclude` = engines already used; Auto only) → failed. At most 3 attempts per code step; each provider job
itself allows one format re-ask. Provider failures skip the repair and escalate directly. Explicit provider modes never escalate. Every attempt
is persisted (`step_attempts`: kind, engine, model, outcome, evidence) and visible in the Observatory (retry/escalation events on the runs).
Review verdict `fail` fails the step (no automatic loop).

## Approvals

`delete` steps and edits to files with uncommitted user changes create a durable `approvals` row → task `waitingForApproval` → the Full HUD
approval card / Tasks buttons decide through the engine. Quit ≠ denial: a waiting approval survives a restart (re-created waiting state);
approvals of non-delete steps are superseded and re-asked because the edits they described are gone. Approval text never contains secrets.

## Cancellation, termination, recovery

* **Stop** (Tasks / Compact / "stop" / Stop on a task's run in Agents): `cancelRequested` persisted → no new steps → active agent runs cancelled
  through `AgentRunManager`, tool processes through `ManagedProcess.cancel` (SIGINT → SIGTERM → SIGKILL tree) → waits for children → leases
  released → CANCELLED + partial report + checkpoint. No second kill mechanism.
* **Quit/SIGTERM:** runners cancelled, running tasks/steps `interrupted` (waiting tasks stay waiting), checkpoint written, leases released.
  A task does not continue after the JARVIS process is gone (no daemon in V0.4).
* **Launch:** stale `running/planning/ready` tasks → `interrupted` with a persisted note; stale agent runs → `interrupted` (V0.3.2); stale leases →
  `stale`; waiting approvals wait again. Nothing resumes automatically.
* **Resume** (explicit): per step by idempotency — read/search/build/test steps run again; a code step first **inspects the disk**: edits verified
  (hash = recorded after-hash) → kept without asking the provider again; untouched → redone; diverged → the task fails explicitly
  (`workspaceChanged`); a delete is never replayed without a fresh approval (already gone → passed).
* **Sleep/wake:** the active-time clock pauses during sleep; on wake the state is re-evaluated, never assumed.

## Checkpoints and reports

A checkpoint artifact (`artifacts/checkpoints`) is written at coherent boundaries (plan accepted, each step end, approval waits, quit, final):
plan version, step states + evidence, changed files with hashes, Git baseline, held leases, pending approvals, failure, cumulative diff
(sanitized). The terminal **report** (`artifacts/reports`, markdown + JSON) is rebuilt from persisted records only: goal, steps validated,
providers/models and roles, files changed, validations (real command lines/exit codes/counts), repairs/escalations, approvals, warnings
(e.g. "no test run validated as passing"), failure category + step + suggested next action, or the stop point + cleanup. The conversation gets
a one-paragraph summary containing only those facts.

## Observability

No separate monitor: task runs appear in the V0.3.2 Agents section, labelled `TASK · <title>`, with console, timeline, history, provider/model,
retries and escalations. The Tasks screen lists needs-attention / active / recent tasks with steps, validation kind, attempts, evidence, Git
baseline; Compact shows the active task card (title, step n/m, validated count, percentage only from real steps, agents running) at the same
392×448. Pause does not exist for autonomous tasks (a provider process cannot be paused truthfully).

## Security

All provider output and all tool output cross a sanitizer before UI state, SQLite or artifacts (`SafeProvider`, `SafeToolOutput`; V0.3.2).
Task text is redacted on write; credential-looking files are withheld from prompts; no `credential.*`/`integration.*`; no paid API; no
network client; no shell; build/test executables are an allowlist; writes only through `ProjectTools`; `verify.sh` enforces these.

## Limitations (vs V0.5 and later)

User-initiated goals only: no proactive improvement proposals, no autonomy policy, no learning from tasks. Providers see only the context
JARVIS builds (no tool use inside the provider), so very large projects need targeted goals. The planner/coders are as good as the routed model
(free models are benchmarked, not guaranteed). One workspace per task; at most 2 active tasks. No notifications (a notification permission
would be required). No Git commit/push. Resume after a restart is explicit. Build/test steps run project code.

## V0.5 additions: task origin, scope and autonomy depth
`TaskRecord` gains `origin` (`userTask` / `proactiveAutoAction` / `approvedProposal`), `originTaskID`, `originOpportunityID`, `autonomyDepth` (user 0, automatic/approved 1) and an optional `TaskScope`. `TaskEngine.submit` accepts a deterministic `id` (idempotent creation: the same id never makes a second task). A task with a scope is enforced twice: the plan (`TaskScope.planViolations`: allowed step types, ≤ maxSteps, no deletes — the planner is told the scope; a violating plan is re-asked once, then the task fails `scopeExceeded`) and every edit (`editViolations`: path allowlist / test-files-only / max changed files — never repaired). `FailureCategory.scopeExceeded` is a policy failure. User tasks have no scope. See `PROACTIVE_REASONING.md`.
