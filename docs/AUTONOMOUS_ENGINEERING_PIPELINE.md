# V1.0 autonomous engineering quality & verified work pipeline (cloud / headless pass)

State vocabulary (AGENTS.md): PLANNED · IN PROGRESS · IMPLEMENTED · AUTOMATED TESTED · MANUAL TEST REQUIRED · MANUALLY VERIFIED · BLOCKED.
Nothing here is MANUALLY VERIFIED. No real project (Hamam included), Unity editor, macOS service, provider, model, microphone or UI was used. "AUTOMATED TESTED" means: run in the Linux harness described in §10 over
REAL disposable Git + Python fixtures and the REAL task / persistence / router code, **not** by `scripts/test.sh` on macOS — that run is still owed (§9).

Principle: a worker saying DONE is not WORK VERIFIED. A coding worker is an untrusted implementation contributor; only independent, observable evidence promotes work to VERIFIED. This pass adds the missing
engineering layer — typed assignment, observed change set, attribution, scope / tampering / quality checks, evidence-bound verification, bounded repair, review, rollback planning, grounded reports —
as PURE policy around the ONE existing orchestrator. **No new orchestrator, task engine, approval system, router, memory, state store, scheduler or database table.**

## 1. What the repository already did (inspected, not assumed)

| Area | Repository truth |
|---|---|
| Who writes files | Providers are text-in / text-out. A coding worker returns SEARCH/REPLACE edit blocks; only `Tasks/ProjectTools` applies them (capability + workspace guard + write lease + hash check + dirty-file approval). |
| Roles | `AgentContracts` (analysis, coding, research, unity, computer, qa, review): least-capability contracts, retry budgets, context budgets; the coding role is `modelHeavy`, one writer at a time. |
| Scope | `TaskScope` (proactive tasks): allowed step types, path prefixes, test-only, max files / steps, delete. Applies to PROACTIVE tasks, not to user-delegated coding assignments. |
| Ownership | `FileLeaseManager`: in-memory + persisted write leases per path, event-driven waiting, stale-lease reconciliation. File level, per task step. |
| Baseline | `GitTool.baseline` (read-only): dirty + untracked paths BEFORE the task; `TaskFileChange(beforeHash, afterHash, preexistingUserChange)`. No staged-file distinction, no cumulative attribution. |
| Review | `ReviewAuthority` (V0.6): deterministic facts outrank a reviewer; a blocking review issue needs verifiable evidence; `ReviewIndependence` (risk-based, not mandatory). |
| Routing | `ModelRouter` (pure, V0.3.1): local → free → premium tiers, `LocalModelPolicy`, verified-zero price only, explicit modes never fall back. `RoleRouting`: per-node ledger, role evidence. |
| Verification | build / test profiles through `ApprovedExecutables` (no shell); `ValidationKind` hard facts; `ActionReceipt` for UI-level actions. |
| Gaps | no typed engineering assignment (forbidden paths, acceptance criteria, magnitude); no test / guard / build-script tampering detection; no placeholder / suppression / secret / dependency / doc-truth checks on a worker's change; no claim-versus-observation reconciliation; no semantic repeated-failure detection; no stale-result detection; no rollback plan that provably spares user work; no grounded engineering report. |

## 2. The pipeline (decisions only; the engine executes)

OBSERVE (snapshot + Git facts) → PLAN (assignment, ownership, worker selection) → ASSIGN → IMPLEMENT (the worker proposes; JARVIS applies) → INSPECT (observed change set, attribution, scope, tampering) → VERIFY
(real build / tests at the final revision) → REVIEW (deterministic first; a model reviewer only where risk / breadth / sensitive files warrant, independent when required) → CORRECT (bounded loop with a precise brief)
→ VERIFY → CHECKPOINT → REPORT. A trivial deterministic edit does not need the ceremony: `ReviewPolicy.mode` returns `deterministicOnly` for a small clean verified change, and the planner asks for nothing beyond what the change class needs.

## 3. Modules (`Sources/Jarvis/Engineering/`, all pure; `scripts/guards_engineering.sh`)

| File | What it decides |
|---|---|
| `EngineeringAssignment.swift` | The typed contract: objective, project, write scope (allowed / forbidden / protected globs; may modify tests / build scripts / guards / dependencies; may delete; expected file count), domains, requirements, constraints, acceptance criteria (a profile must pass · file exists / contains / does not contain · manual), verification profile labels, risk, dependencies, expected artifacts, budget (mapped onto the existing `TaskBudget`), required capabilities, provider preference, conventions, base revision, gate state. `validate()` rejects vague / empty / unscoped / unverifiable / traversing / critical-without-gate assignments; `promptBlock()` is bounded; `routingProfile()` produces the router's own `TaskProfile`. |
| `WorkerReport.swift` | `WorkerClaims` (status, files inspected / changed, commands, tests, artifacts, warnings, blocked reason, remaining work, commit, API assumptions, dependencies) — every field a CLAIM; a lenient parser; malformed output is a typed failure. |
| `WorkspaceSnapshot.swift` | Lightweight read-only snapshot (hash, size, binary per file + Git facts incl. staged / conflicted), a digest = "the revision", `SnapshotDiff`, `rebased(onto:)` (somebody else's unrelated change folded into the baseline), `GitStatusParser`, `ChangeAttribution` (task-produced · touched-a-user-dirty-file · unexplained; lost edits; pre-existing untouched). |
| `EngineeringFindings.swift` | `EngineeringFinding` (code, BLOCKER / MAJOR / MINOR / NOTE, path, evidence) and `PathClassifier` (test, build script, security guard, dependency manifest, documentation, generated, secret material, binary, source, config). |
| `ScopeEnforcer.swift` | Scope escape, forbidden / protected paths, unauthorised test / build / guard / manifest changes, deletions, user-dirty files, unexplained changes, magnitude versus the task's own expectation. |
| `TamperingDetector.swift` | Content level: deleted / skipped / weakened / changed tests, unconditional assertions, weakened guards and approval bypasses, build scripts that can no longer fail, placeholders (compared with the requirements), silent error suppression (language-aware), secrets (never echoed), destructive commands, injection constructs. |
| `EngineeringChecks.swift` | Dependency additions per manifest format + evidence check (package hallucination), API-assumption check, documentation truth, architectural drift / duplicate abstractions, diff statistics and deterministic condensation for reviewers. |
| `EngineeringVerification.swift` | `VerificationEvidence` (stage, profile, exit status, revision digest, timestamp, excerpt, counts), `VerificationPlanner` (proportional to the change class), `EngineeringVerifier.verify` — the one verdict (`verified` · `verifiedAutomated` · `needsReview` · `partial` · `inconclusive` · `failed`). |
| `RepairLoop.swift` | Bounded fix loop, semantic failure signatures, escalation, regression tracking, precise repair briefs. |
| `OwnershipAndLifecycle.swift` | Assignment-level write reservations (wait / merge / coordinate, deadlock detection), safe parallelism, staleness, cancellation gate, delegation gate, partial-work classification, worker hand-off. |
| `WorkerSelection.swift` | Capability-based selection with the cost rules, review independence, the review rubric and packet. |
| `RollbackAndHygiene.swift` | Rollback PLAN (never a reset), temporary-artifact hygiene, commit verification, external-action policy, convention discovery. |
| `EngineeringReport.swift` | The run record, checkpoint / resume revalidation, the grounded report (EN + TR) and the morning digest. |

## 4. Rules the pipeline encodes

* **Claims are not evidence.** `VerificationEvidence` is constructed only where it is defined (a guard enforces it); a claim is only compared. Evidence belongs to ONE revision: a green run from before the last edit leaves its stage open; a failing run at the final revision fails the work whatever else is green. Property-tested over 400 random claims.
* **Scoped assignments.** A write outside `allowed`, on a forbidden / protected path, or on credential / signing material is a BLOCKER; a read-only assignment that changed anything is a BLOCKER. Magnitude is judged against the task's own expected file count, never a universal threshold (2 expected / 73 changed → BLOCKER; 30–50 expected / 40 changed → fine).
* **Dirty tree = the user's work.** Pre-existing modified, staged and untracked files are never attributed to the task and never reset. A worker edit to one is flagged (`taskTouchedUserDirty`); a change no applied edit explains is `unexplained` — never silently the task's.
* **Tampering.** Deleting / skipping / disabling a test, removing assertions, replacing an equality by a weaker check, an assertion that cannot fail, a guard that lost lines, an approval / paid-provider bypass, a build script that can no longer fail, a removed test step → BLOCKER. A changed expectation → MAJOR (review why), not a blocker. A legitimate, authorised test addition is not flagged.
* **Quality.** Placeholders: constructs MAJOR in source, TODO comment MINOR (MAJOR when it names a stated requirement). Silent suppression: empty catch / except-pass / swallowed promise MAJOR, discarded `try?` MINOR. A credential-shaped value is a BLOCKER and is never echoed (the evidence is "line N of path").
* **Dependencies / APIs / docs.** A new dependency is surfaced (name, version, manifest) and needs evidence for package AND version; without authority it is a BLOCKER. An API the worker relied on needs a reference, a declaration in the project or a passing build. A doc saying MANUALLY VERIFIED without a person's record is a BLOCKER; AUTOMATED TESTED / REAL TESTED without evidence is MAJOR.
* **Verification is proportional.** Docs only → guards, no build. Source → build + unit tests. Shared core → + integration tests. Build scripts / guards / dependency manifests / test changes → full verification + elevated (independent) review. Unity C# → the editor validation is a MANUAL requirement stated plainly. UI → manual. A missing profile is "not available", never a pass.
* **Manual validation is a first-class state.** `verifiedAutomated` = everything JARVIS can check passed, a person must still validate (AUTOMATED TESTED · MANUAL TEST REQUIRED). Nothing becomes MANUALLY VERIFIED without a record a person made (`manualRecorded`).
* **Repair loop.** Every pass is counted (worker attempts 3 · verification runs 6 · provider requests 12 · wall clock 30 min by default, mapped onto the existing `TaskBudget`). Stops on: verified, a budget, the SAME failure repeating (semantic signature ignoring paths / line numbers / addresses / times: escalate once — Auto only — then stop), approval needed, architecture uncertainty, a security finding, provider unavailable. The brief carries objective, ACTUAL diff, the failing check, bounded logs, constraints, attempt number, and "do not regress: …"; never reasoning. A fix that breaks a criterion that passed before is called out as a regression.
* **Ownership / staleness / cancellation.** A second writer on an overlapping scope waits, is merged (same owner + group) or is handed to coordination (deadlock); read-only work never conflicts. A result is stale if the repository changed in the worker's scope or read set (or HEAD moved) after the assignment started; an unrelated change by somebody else is folded into the baseline instead of being blamed on the worker. After a cancel no write assignment starts and no late result is applied. Partial work is `usable` / `unsafe` / `unknown`, never complete.
* **Worker selection.** Capability metadata, not brand names. The local conversational model is never a coding / testing / review worker (also asserted against the real `ModelRouter` + `LocalModelPolicy`); paid only when explicitly chosen; unknown price is never free; an explicit choice never falls back; complex / critical work needs a premium-reasoning worker; cheaper tier first, then benchmark evidence. A model reviewer is only used where risk / breadth / sensitive files warrant it, and is a different worker than the implementer when independence is required and a zero-extra-cost alternative exists (otherwise the result says it was not independent).
* **Review.** Deterministic findings first; a model finding blocks only if it is a BLOCKER with evidence JARVIS can find (a quote in the condensed diff, a changed path, a recorded line); MAJOR needs a decision, MINOR / NOTE never block. The reviewer's packet is the objective, the criteria, the deterministic findings and the CONDENSED ACTUAL DIFF — never the implementer's prose.
* **Rollback.** A PLAN naming only files the TASK produced, restorable from a stored pre-task copy and still equal to what the task wrote. User-dirty files (unless a copy that includes the user's work exists), unexplained changes and files that changed again are never reverted — a person decides. There is no executor in the product layer; applying a plan is the engine's guarded file tools' job.
* **Commits and outward actions.** A claimed commit is checked (HEAD moved, commit exists, files in scope, no AI trailer, project style). A local commit needs an explicit allowance; push, force-push, pull request, merge, tag, publish, branch deletion are critical and never automatic.
* **Architecture.** A new type that re-solves a core system (a second orchestrator, approval system, router, state store, provider layer, memory) is surfaced MAJOR; a near-duplicate of an existing type is a MINOR note.
* **Reports.** Rendered from the run record only (objective, files, real evidence, findings, risks, manual checks, local commit); EN + TR; the morning digest counts verified / automated-only / blocked / failed / waiting from records.

## 5. Benchmark (synthetic, disposable fixtures, no provider)

Nine task kinds on Git + Python fixtures — simple bug fix, multi-file bug, test addition, refactor preserving behaviour, configuration bug, API misuse, error-handling bug, state bug, documentation + code consistency. Verification evidence is a REAL exit status (a syntax check and `python3 -m unittest` run inside the fixture).
Good workers: all 9 verified. Bad workers: 14 behaviours per task (claims done with no diff · wrong file · deletes a test · weakens an assertion · adds a dependency · placeholder · malformed output · changes the build script · secret-looking string · compile failure · unrelated file · huge diff · ignores the requirement · claims green tests that are red) × 9 tasks = 126 runs, every one caught, none verified.

## 6. Chaos, drift, soak

Driver composed of the REAL policies (not the engine): plan → worker times out → another worker returns a bad patch → verification fails → repair → verified → checkpoint → report; review blocking with / without evidence; repository drift during execution (a concurrent edit in scope → stale, never verified, the user's edit preserved; an unrelated edit → baseline rebased, task continues); an explicit-provider timeout storm (no paid worker, `providerUnavailable`); the same failure repeated (escalate once, stop); cancellation (no write after it). Soak: 12 engineering runs with timeouts, repeated failures, escalations, cancellation and 23 checkpoint round trips — see §7 for the figures.

## 7. Results (Linux harness; nothing here is a macOS or real-engine result)

| Run | Tests | Checks | Failures |
|---|---|---|---|
| Engineering pipeline (`EngineeringContractTests`, `…ObservationTests`, `…VerificationTests`, `…LoopTests`, `…SelectionTests`, `…BenchmarkTests`, `…SimulationTests`; 8 files incl. the support file) | 104 | 3 544 | 0 |
| Source-text guards (`guardrun.sh` equivalent of `verify.sh` + `guards_*.sh`, incl. `guards_engineering.sh`) | — | 282 passes | 0 fails |
| Previous passes (reliability / decision / background) | unchanged; not re-run in this pass (no file they cover was edited) | — | — |

Suites (tests each): assignment 5 · benchmark 6 · chaos 6 · checks 5 · dirty tree 3 · properties 7 · rollback 3 · real router 3 · snapshots 4 · soak 1 · temp artifacts 1 · failure signatures 2 · guard tampering 3 · lifecycle 5 · ownership 7 · path classes 2 · path globs 2 · quality detectors 5 · repair loop 7 · report / checkpoint 4 · review policy 4 · scope 5 · test tampering 3 · verification planner 4 · worker report 2 · worker selection 5 (104 in total).

Benchmark: 9 / 9 good workers verified with REAL build + test evidence at the final revision; 126 / 126 bad-worker runs (14 behaviours × 9 tasks) caught, 0 verified.
Soak (seed 2026, 12 runs, no real waiting): 120 events, 8 verified, 2 stopped by a rule (repeated failure / provider unavailable), 1 cancelled, 3 provider timeouts, 3 escalations, 23 checkpoint round trips, at most 3 attempts and 14 events per run (bounds 3 / 120), 0 illegal verifications, 0 paid-worker uses; whatever a verified run reports as changed equals what `git status` shows. Digest: "12 task(s) attempted: 8 verified, 1 blocked, 4 failed, 2 awaiting approval. 13 file(s) changed, 12 test run(s), 13 failed attempt(s)."
Properties (seeded): 400 random claims × 3 observations never verified; 150 random out-of-scope change sets never verified and always `scopeEscape`; 150 random dirty trees attribute exactly the applied edits to the task; 200 random lifecycle / risk / gate combinations; 200 random failure streams always terminate within their budget.

## 8. NOT WIRED — the integration seams (nothing below is claimed to run in the engine)

1. No engine call site builds an `EngineeringAssignment`, takes a snapshot, runs `EngineeringVerifier`, consults `RepairLoop`, `OwnershipRegistry`, `StalenessCheck`, `AssignmentGate` or `WorkerSelector`; the engine keeps its own scope (`TaskScope`), leases (`FileLeaseManager`), review authority and routing. Seams: `TaskEngine+Execution` after an edit set is applied (observe → verify → decide), `TaskEngine+Planning` where a coding step is created (assignment), `StepAgentRunner` job construction (worker selection input).
2. `GitTool` does not report staged files or conflicts (the pure `GitStatusParser` does); the engine's `GitBaseline` has no staged set.
3. There is no production process runner that produces `VerificationEvidence`; the engine's `ManagedProcess` results would have to be mapped (exit status, profile label, digest). Tests produce it from real fixture processes.
4. `PreTaskBackup` content storage (an artifact per file before a write) is not implemented; without it a rollback of a modified file cannot be planned automatically (the plan asks a person).
5. The run record / checkpoint is not persisted by the engine (no migration was added); `EngineeringCheckpointer` defines the encoding and the resume revalidation only.
6. Model review (`ReviewRubric.evaluate` with `ModelFinding`s) is not fed by a reviewer job; `ReviewPolicy.mode` / `packet` are the inputs a future job would use.
7. The morning digest is not routed from `ConversationService` (out of scope; see JARVIS-V1BG-6).
8. Unity: only the generic contract can represent C# / scene / prefab work (a MANUAL requirement is emitted for `.cs` changes); no Unity operation, bridge or editor was touched.

## 9. MANUAL TEST REQUIRED (local, non-voice, macOS)

1. `scripts/test.sh` then `scripts/verify.sh`: the eight new test files (`Engineering*.swift`) and `scripts/guards_engineering.sh` have not been compiled or run on macOS; the fixtures use `/usr/bin/env git` / `python3` through `Foundation.Process`.
2. Wire seam 1 behind a flag against a DISPOSABLE fixture (`--task-live-test` style): a coding task whose worker is a scripted fake CLI that (a) edits an out-of-scope file, (b) deletes a test, (c) claims success without a diff — confirm each is rejected and the report says why.
3. A dirty-tree run on a throw-away clone: modify a tracked file, stage another, leave an untracked file, run a task, confirm all three are byte-identical afterwards and listed as "left as they were".
4. A multi-hour fixture task with a deliberate unfixable failure: confirm the loop stops at the budget / repeated-failure rule with a readable reason, not at a timeout.

## 10. How this was verified (and what that is worth)

A Linux harness compiles the real `TaskModel` + persistence + router closure with the new files and runs the converted Swift Testing suites with a plain-function `#expect` shim. Fixtures are real `git` repositories in temporary directories and real `python3` runs. It does not exercise AppKit, SwiftUI, the engine's actors, Seatbelt, `ManagedProcess`, any provider or any macOS service. `scripts/guards_engineering.sh` is source-text checking and runs anywhere.

## 11. Parallel-session safety

All production code is NEW files under `Sources/Jarvis/Engineering/`; the only edit outside new files is one `source` line in `scripts/verify.sh`. No engine hook was added in this pass (a hook would need a macOS build). Not touched: ConversationService, FullHUDView, voice code, Computer Use, permissions, Hamam; no DEC rule weakened. DEC-294…300, JARVIS-V1EP-*, README 1322+ are appended; renumber on merge if another session used the same numbers.
