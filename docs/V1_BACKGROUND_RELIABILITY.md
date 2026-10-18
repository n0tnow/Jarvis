# V1.0 background intelligence, task reliability & efficiency (cloud / headless pass)

State vocabulary (AGENTS.md): PLANNED · IN PROGRESS · IMPLEMENTED · AUTOMATED TESTED · MANUAL TEST REQUIRED · MANUALLY VERIFIED · BLOCKED.
Nothing in this document is MANUALLY VERIFIED. Nothing here used a microphone, speaker, wake word, TTS/STT, Accessibility, Screen Recording, Safari, Finder, Unity, Computer Use, the Keychain, a real model or a real
provider. "AUTOMATED TESTED" below means: executed in the Linux harness described in §9 (Swift 6.0 `swiftc`, the REAL task model + persistence code), **not** by `scripts/test.sh` on macOS — that run is still owed
(MANUAL TEST REQUIRED, §8).

Goal: JARVIS can work on a long project task for hours — checkpoint, recover from transient failures, stop for an approval, not waste model calls, and report exactly what happened. The method: first write down what
the repository really does, then add only PURE, tested policies around the one existing orchestrator. **There is no new orchestrator, no new scheduler, no new task state, no new database table.**

## 1. What the repository actually does (inspected, not assumed)

| Area | Repository truth |
|---|---|
| Task states | 9 (`created planning ready running waitingForApproval completed failed cancelled interrupted`), 10 step states, explicit `allowedNext` tables behind `TaskStateMachine.canMove`; the engine's `transition` rejects and logs an illegal move. |
| Scheduler | event-driven `scheduleLoop`; `readySteps`: pending/ready step whose dependencies passed / skipped / (optional and failed). Parallelism: ≤ 2 read-only nodes, 1 under pressure (`ConcurrencyPolicy`). No timers. |
| Checkpoints | `writeCheckpoint` → an artifact (atomic file write, hash + size in SQLite) at coherent boundaries (before approval, after steps). |
| Restart | `reconcileTasksAfterRestart`: planning/ready/running → **interrupted** (never "running forever"), running/verifying steps → interrupted, stale leases marked; waiting-for-approval tasks keep waiting. Resume is an explicit user action (`resume()` → `recoverSteps` + `revalidateCompleted`). |
| Approvals | persisted `ApprovalRecord`; `requestApproval` reused a persisted APPROVED record for the same (step, action text) **with no expiry** (gap G1, fixed below). Decisions only from HUD buttons (DEC-041…, DEC-203). |
| Retries | repair ≤ 1 per step, escalation ≤ 1, capacity waits ≤ 40, provider timeout 600 s, graph wall-clock timeout. No task-level retry budget, no classification beyond `FailureCategory` (G2). |
| Providers | `ProviderSupervisor`: persisted cooldown / health, one bounded local-worker restart. Paid providers never automatic (DEC-022…028). |
| Resources | `ResourceManager` (`ConcurrencyLimits`, memory-pressure / thermal / low-power observers; no battery level); per-role `ContextBudget` (chars / memory items / artifacts / files). |
| Retention | `activity_events` capped at 2 000 rows; agent events per run; `pruneOrchestration`; learning / memory / computer / MCP tables have prunes. |
| Persistence reads | `TaskRepository.engineTasks` uses `compactMap`: a row that cannot be decoded is **silently skipped** (G6). |
| Completion wording | `ActionReceipt.successIsClaimable` + `ActionPhrasebook.render`; `ResponseClaimFirewall` for model text (previous pass). |

### Gaps found (and what became of each)

| # | Gap | Resolution in this pass |
|---|---|---|
| G1 | an approved decision never expired and the reuse check did not look at its age | **engine hook (2 lines)**: reuse only while `ApprovalFreshness` allows (low/medium 12 h, high 2 h, critical never; an expired approval falls through to a NEW request). |
| G2 | no classification of "is this failure worth another try?" and no task-level retry budget | `RetryClassifier` / `RetryLedger` (per step 3, rate-limited 2, per task 12, capped exponential backoff, seeded jitter) — IMPLEMENTED, AUTOMATED TESTED, NOT WIRED. |
| G3 | no model-request / retry / tool-failure / consecutive-verification budget per task | `TaskBudgetLedger` — IMPLEMENTED, AUTOMATED TESTED, NOT WIRED. |
| G4 | stuck detection = the 600 s provider timeout only | `StuckTaskDetector` (previous pass) is pure and tested; NOT WIRED. |
| G5 | no single answer for "what would replaying this interrupted step do?" | `StepReplayPolicy` + `VerificationPolicy` — IMPLEMENTED, AUTOMATED TESTED, NOT WIRED (the engine's `recoverSteps` keeps its own, compatible rules). |
| G6 | an undecodable task row disappears silently | pinned by a test as current behaviour; OPEN (`JARVIS-V1BG-3`). |
| G7 | "paused", "retrying", "waiting for a dependency", "blocked" are not states and must not become states | `TaskStatusDeriver` derives them from persisted state — no new transitions to prove. |
| G8 | the morning questions had no single structured source | `TaskDigest` + `MorningBrief` — IMPLEMENTED, AUTOMATED TESTED, NOT WIRED to the conversation (that file is out of scope for this pass). |
| G9 | readiness duplicated inside the engine | **engine hook (1 line)**: `readySteps` delegates to `StepReadiness.ready` (identical rule, now tested, also used for "what can continue while a branch waits"). |

## 2. Modules added (all pure value logic; no timer, log, persistence, process, network, approval or capability API — `scripts/guards_background.sh`)

| File | What it decides |
|---|---|
| `Reliability/TaskStatusDeriver.swift` | queued / planning / ready / running / verifying / retrying / waitingForApproval / waitingForDependency / paused / blocked / completed / failed / cancelled from `TaskState` + step records; `ForbiddenTransitions` regression list. |
| `Reliability/StepReadiness.swift` | satisfied / ready / blockedByFailure / independentWhileBlocked. |
| `Reliability/RetryPolicy.swift` | `RetryClass`, `RetryClassifier`, `RetryLedger` (the answer is a typed `RetryDecision` with the reason when it gives up). |
| `Reliability/TaskBudget.swift` | wall clock 10 h · model requests 400 · provider retries 40 · tool failures 60 · 6 consecutive verification failures; one warning at 80 %, then `exhausted(dimension)` = checkpoint + block, never a silent stop. |
| `Reliability/StepReplayPolicy.swift` | side-effect class of every `StepType`; replay decision per crash point and evidence; inconclusive verification never repeats a non-idempotent action. |
| `Reliability/ApprovalBinding.swift` | approval bound to (task, step, operation, target, parameters, risk) with an FNV digest; time-to-live per risk; `ApprovalReuse.evaluate`. |
| `Reliability/ProjectDrift.swift` | project binding (the task's recorded workspace always wins over the focused project), fingerprint comparison (files, HEAD, branch, dirty tree, conflicts, detached HEAD, moved folder), `DriftAction`, `forbiddenReactions` (never reset / clean / checkout / commit / push / force / discard). |
| `Reliability/TaskEventLog.swift` | bounded structured event log (capacity, dedupe of identical repeats into one counted entry, important events never merged, redaction through `SecretGate`, 200-char detail, a `dropped` counter) and `NotificationPolicy` (no retry spam: only completed / failed / blocked / approval needed; rate limited). |
| `Reliability/UsageLedger.swift` | honest accounting: requests, latency, failures per provider / task; tokens only when a provider reported them (`runsWithoutTokens` is counted, never estimated); `estimatedCost` is nil unless a price is supplied. |
| `Reliability/ContextSelector.swift` | invariants (objective, project identity, pending approval, failed verification, constraint, prohibition) are rendered verbatim and never dropped; the rest is ranked and capped; older history becomes ONE line of counts; the line's room is reserved inside the budget. |
| `Reliability/WorkerAdmission.swift` | which worker may start given what runs, memory pressure, power / thermal state (a benchmark only on explicit request; optional heavy work yields; required work is never blocked by power state; the large local model never next to Unity); process ownership (only `startedForTask` processes are terminated at task end, never shared or user-owned ones). |
| `Reliability/TaskDigest.swift` | the task report and the five morning questions (EN + TR) from structured state only. |
| `Decision/DecisionQuality.swift` | routing confusion report (ids only) and a safety-first quality gate. |

Previous pass, reused unchanged: `StuckTaskDetector`, `ProviderResilienceBook` + `FallbackPolicy` (circuit closed → open → half-open; never paid; an explicit choice never falls back), `ResourceBudget`, `OvernightPolicy`, `ProgressTruth`, `ResumeValidator` + `CheckpointHygiene`.

## 3. Semantics (the rules the policies encode)

* **No new states.** `paused` = `interrupted` (resume is explicit, DEC-190/201); `retrying` = a running step with >1 attempts; `waitingForDependency` = nothing in flight, work left whose dependencies are not satisfied; `blocked` = a REQUIRED step failed (or an approval was denied) and nothing active remains. A forbidden-transition list (completed→running, cancelled→retrying, failed→completed, waitingForApproval→running/completed without a decision path, interrupted→completed …) is asserted against the real `TaskStateMachine`.
* **Checkpoint.** Content is machine state only. `CheckpointHygiene` refuses chain-of-thought markers, secret-shaped text and raw-audio references and clips evidence to 400 characters; a checkpoint whose bytes do not match the recorded hash (a torn write, a missing file) is not truth (`ArtifactStore.verify`; tested by truncating a file) and a half-written JSON never decodes.
* **Resume.** `ResumeValidator` (previous pass) revalidates project, artifacts, provider, approval and external state; `StepReplayPolicy` decides per interrupted step: read-only → replay; idempotent write → skip if the effect is observed, replay if the world is unchanged, else revalidate first; non-idempotent write that MAY have happened → ask a person (never a blind repeat); critical → never replayed without a fresh approval; diverged files → ask.
* **Idempotency table** (pinned by test): read-only = analysis, review, build, test, Unity inspect/compile/test/validate, research read/search/extract/verify/report, experiment; idempotent write = code change, Unity edit, acquire, Unity play mode; non-idempotent write = computer act, delegated computer / research, import; critical = delete, approval gate.
* **Verification inconclusive** ("the form was submitted; the check timed out"): read-only → re-check once; idempotent write → re-inspect once then record UNVERIFIED; non-idempotent / critical → record UNVERIFIED and do NOT repeat. Success wording needs a passing verification (property-tested over every kind × status × verification × language).
* **Retry.** transient / network / timeout → backoff 2 s ×2 capped at 60 s (rate limit doubles it), ≤ 3 per step (2 if rate limited), ≤ 12 per task; deterministic validation failure → the engine's one repair, never a blind repeat; permission / approval / invalid input / permanent / security / cancelled → never retried. Giving up is typed (`notRetryable` / `stepBudgetExhausted` / `taskBudgetExhausted`) and recommends "checkpoint-and-pause" or "block-or-fail".
* **Provider failure** (previous pass + this pass): one transient retry, then a fallback that is not the provider that just failed, whose circuit is not open and which is never paid; an explicit user choice never falls back; with every provider unavailable the task pauses (unattended) or asks (present).
* **Jev efficiency.** Deterministic grammar answers cost 0 model calls and 0 Jev calls; Jev is asked only after a deterministic abstention of a short command-shaped sentence (`abstentionsOnly`), never for a recognised command, never polled, bounded retry, in-memory salted-hash pattern cache (previous pass). A broader decision cache was NOT added: a cache of executing decisions would let a stale answer outlive a changed project / gate state — the benefit (a few ms per repeat) does not justify the risk.
* **Context efficiency.** `ContextSelector` (invariants verbatim; ≤ 6 recent turns, ≤ 4 memory snippets, 2 000-char tool results, 600-char items; one deterministic compaction line). No model summarises safety-relevant content.
* **Unattended / overnight.** SAFE and in-scope PROJECT-WRITE steps continue; an approval, a user-dirty-file edit, an ambiguity or a critical action PAUSES that branch; independent branches continue (`StepReadiness.independentWhileBlocked`, `OvernightPolicy.continuable`); nothing is guessed; an approval is never given by the policies, by time, by memory or by a spoken "yes".
* **Approval expiry / binding.** low/medium 12 h, high 2 h, critical never reusable; a changed target, parameter, risk or task = a different approval; an expired approval asks again.
* **Progress truth.** validated steps only; no model percentage (`ResponseClaimFirewall` rejects task percentages; `ProgressTruth` derives progress); a skipped step is not counted as measurable.
* **Event log.** capacity 400 (engine) / test 120, aggregation of identical repeats, `dropped` counted so nothing is lost without a number (test: Σ counts + dropped = events recorded), detail redacted and clipped, important events never evicted before aggregatable ones.
* **Drift.** the task's recorded workspace is its project (focusing another project does not move it); a changed HEAD / branch / dirty tree / conflict / moved folder is detected; reactions never include a destructive git command.
* **Cancellation.** unchanged engine behaviour (cancel propagates to the runner, pending approvals become `cancelled`); `ProcessHygiene` states which processes a finished task must reap (only the ones it started FOR the task).
* **Resources (16 GB).** declared-memory budget (previous pass); admission blocks optional heavy work under memory pressure or constrained power; battery LEVEL is not available to the engine (`PowerContext.batteryFraction` optional, unused by the engine) — documented limitation.
* **Database.** the real SQLite layer in isolated temp directories: restart reconciliation is exact and idempotent, an undecodable row does not hide healthy ones, history stays bounded, concurrent writers do not corrupt (`PRAGMA integrity_check`), 40 tasks × 120 steps ≈ small and fast.

## 4. Deterministic benchmark and routing confusion report

Hand-written corpora, ids only; `Benchmarks/decision_confusion_report.json` is generated by `DecisionConfusionReport` (not edited). See §6 for the measured figures. The gate fails on SAFETY first (an unexpected executing false positive, a must-not-execute case executed) and reports coverage separately; the held-out and blind sets are spent (report-only).

## 5. Overnight simulation (policy composition, NOT the TaskEngine)

`Tests/JarvisTests/OvernightSimulationTests.swift`: a seeded, fake-clock driver over 50–200 steps (mixed read-only / write / critical / non-idempotent) composing the REAL task model, `StepReadiness`, `RetryLedger`, `TaskBudgetLedger`, `StepReplayPolicy`, `VerificationPolicy`, `ProviderResilienceBook` + `FallbackPolicy`, `TaskEventLog`, `NotificationPolicy`, `TaskStatusDeriver`, `TaskDigest`. It injects transient provider failures, a mid-night outage window, permanent failures, inconclusive verifications and restarts (before and after a step's effect). Invariants checked on every run: zero illegal transitions; no critical step ever runs unattended; no paid provider; retries within budgets; the event log never loses an event without counting it; a non-idempotent step applies its effect at most once; completion is claimed only when every step passed or was skipped; the same seed reproduces the same night. What it does NOT prove: that the engine wires these policies (see §7).

## 6. Results (Linux harness; nothing here is a macOS or real-engine result)

| Run | Tests | Checks | Failures |
|---|---|---|---|
| Task reliability core + overnight simulation + scaling + database reliability (`TaskReliabilityCoreTests`, `OvernightSimulationTests`, `DatabaseReliabilityTests`) | 53 | 1 419 | 0 |
| Decision quality + completion-claim property tests (`DecisionQualityTests`, `CompletionClaimPropertyTests`) | 11 | 1 941 | 0 |
| Previous-pass suites (decision lexicon, reliability policies, soak) | unchanged; not re-run in this pass (no file they cover was edited) | — | — |
| Source-text guards (`scripts/guardrun.sh` equivalent of `verify.sh` + `guards_*.sh`) | — | 274 passes | 0 fails |

Routing quality (deterministic recognizer, no model, no Jev; ids only in `Benchmarks/decision_confusion_report.json`):

| Corpus | Cases | Answered | Exact | Executing false positives | Must-not-execute held |
|---|---|---|---|---|---|
| main | 353 | 299 (84.7 %) | 296 (83.9 %) | 0 | 0 / 0 |
| held-out (spent) | 78 | 57 (73.1 %) | 57 (73.1 %) | 0 | 0 / 0 |
| adversarial A | 322 | 261 (81.1 %) | 254 (78.9 %) | 1 (`adv-referent-019`, documented hand-off to Project Continuity, DEC-282) | 57 / 57 |
| blind B (spent) | 199 | 148 (74.4 %) | 141 (70.9 %) | 0 | 47 / 47 |

Confusion groups that matter for safety (stop-speech ↔ cancel-task, application ↔ project, navigation ↔ research, visibility ↔ application-running, project-open ↔ continuation, provider capability ↔ selection): 0 confused cases on main, held-out and blind B; 1 in "conversation vs action" on adversarial A (the documented one). The misses that remain are ABSTENTIONS (the router handles them), the largest cell being `project_task/task → abstain` (10 on main).

Overnight simulation (seeded, fake clock, the real task model and policies composed in a test driver; NOT the engine):

* calm night, seed 1: 120 steps, 1.57 simulated hours, 81 steps passed, 6 critical / non-idempotent steps waiting for a person, 33 steps pending behind them, 81 model requests (= executions, no hidden calls), 8 checkpoints, 178 events, 5 notifications, derived status `waitingForApproval`.
* chaos (40 seeds × 50–198 steps = 4 960 steps; 30 % transient failures, 10 % permanent failures, 20 % inconclusive verifications, a restart every 11 attempts, a provider outage window): 1 732 attempts, 452 retries (all inside the 3-per-step / 12-per-task budgets), 111 restarts (before and after a step's effect), 30 UNVERIFIED records instead of repeats, 3 677 events of which 76 were evicted and COUNTED (Σ counts + dropped = events recorded), **0 illegal transitions, 0 critical steps run unattended, 0 paid-provider uses, 0 non-idempotent steps applied twice**; end states: 0 completed (critical steps always wait), 31 paused (providers exhausted → pause rather than spin), 8 waiting, 1 blocked.
* scaling: the event log ingests 100 000 events in ≈ 9 s versus ≈ 0.45 s for 5 000 (ratio 20.4 for 20× the events: linear; ≈ 90 µs per event in the adversarial case of ~650 distinct keys against a capacity of 400, where every eviction rebuilds the open-aggregate index). Readiness over a 5 000-step chain, context selection over 20 000 items and 50 000 retry decisions stay inside their asserted bounds.

## 7. NOT WIRED — the integration seams (nothing below is claimed to run in the engine)

1. `RetryLedger` / `TaskBudgetLedger` / `StuckTaskDetector` are not consulted by `TaskEngine` (the engine keeps repair ≤ 1, escalation ≤ 1, capacity waits ≤ 40, provider timeout 600 s, graph timeout). Seam: `TaskEngine+Execution` where a step attempt ends.
2. `StepReplayPolicy` is not called by `recoverSteps`; the engine's own recovery is compatible (inspect-first steps re-check file hashes) but does not consult the typed policy.
3. `ApprovalBinding` digests are not stored in `approvals` (no migration was added to avoid a schema conflict); only the age rule is wired (G1).
4. `TaskEventLog` is not persisted by the engine; the engine's `activity_events` (2 000 rows, redacted) remains the durable log.
5. `TaskDigest` / `MorningBrief` are not routed from `ConversationService` (out of scope for this pass); a HUD or voice front-end has to call them.
6. `ContextSelector` is not used by `ProjectContextBuilder` / the providers' prompt assembly (the per-role `ContextBudget` still bounds those).
7. `WorkerAdmission` is not called by `ResourceManager` / `TaskEngine` admission; the engine keeps `ConcurrencyPolicy`.
8. `UsageLedger` is not fed by `ProviderSupervisor`.
9. Provider circuit state (`ProviderResilienceBook`) is in memory; the engine's persisted cooldown stays the durable record.

## 8. MANUAL TEST REQUIRED (local, non-voice, macOS)

1. `scripts/test.sh` and `scripts/verify.sh` — the new test files compile and run under XCTest/Swift Testing on macOS (they were run in a Linux harness only; `Tests/JarvisTests/DatabaseReliabilityTests.swift` needs the real SQLite build).
2. Run a 30–60 minute development task against a disposable fixture project (`--task-live-test` style) with the Mac idle and the lid open; quit JARVIS in the middle; relaunch and confirm: the task is **interrupted** (not running), the passed steps are still passed, "resume" continues from the first non-passed step, no passed step is repeated.
3. Same, with an approval waiting for hours: confirm the approval is still pending after relaunch, confirm that approving after ≥ 2 h (a HIGH-risk action) shows a NEW request when the engine restarts the step.
4. Unplug the network mid-task (OpenCode FREE): the step fails with a typed reason, is retried by the engine's own rules, and the task does not spin.
5. Kill the local model worker mid-task: exactly one restart, then a clear failure.
6. Confirm Activity Monitor shows no orphan process from JARVIS after a cancelled task and after a quit.
7. Confirm idle CPU stays ≈ 0 with a task waiting for approval (no polling).

## 9. How this was verified (and what that is worth)

A Linux harness compiles the real `TaskModel` + persistence closure (31 files) with the new Reliability files and runs the converted test suites against them with a plain-function Swift Testing shim (`#expect` → counted check). The DB tests use the real `JarvisDatabase` (SQLite, WAL) in a temporary directory. Decision / corpus tests use the real recognizer. This does not exercise AppKit, SwiftUI, the engine's actors, Seatbelt, real processes or any macOS service. `scripts/guards_background.sh` is source-text checking and runs anywhere.

## 10. Parallel-session safety

Files edited outside new files: `Sources/Jarvis/Tasks/TaskEngine.swift` (one line), `Sources/Jarvis/Tasks/TaskEngine+Execution.swift` (one line + comment), `scripts/verify.sh` (one `source` line). Everything else is new. Not touched: ConversationService, FullHUDView, VoiceCoordinator, HandsFreeCoordinator, Computer Use UI, permission code, Hamam, any DEC-rule weakened.
