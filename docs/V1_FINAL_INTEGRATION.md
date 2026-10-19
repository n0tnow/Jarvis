# V1.0 final integration — production wiring, consolidation, automated verification

Status: **IMPLEMENTED · AUTOMATED TESTED (Linux harness, real TaskEngine) · macOS UNCOMPILED by `scripts/test.sh` / `scripts/verify.sh` · MANUAL TEST REQUIRED.** Not merged, not tagged. This milestone adds no feature: it connects what earlier passes built and proves the connection.

Golden invariant: **NO VERIFIED ACTION → NO COMPLETION CLAIM.**

## 1. Integration map (Cloud branch `claude/laughing-albattani-uzdlr6`)

* One branch, linear history, fast-forwardable onto `origin/main` (`merge-base` = `origin/main` head `e9dfd5f`, 29 commits ahead). No other source branch exists in the repository; nothing was merged, rebased or force-pushed.
* DEC numbers are unique and continuous: DEC-267…308 (earlier passes), **DEC-309…318 (this pass)**. JARVIS-V1EP-1…7, V1JV-1…8, V1BG-1…7 are unchanged in number; **V1FI-1…6** are new. README manual checks continue at 1331+.
* Guards: every `scripts/guards_*.sh` is sourced by `scripts/verify.sh` (decision, reliability, background, engineering, jev and the new **integration** family). Linux source-guard run: **293 pass / 0 fail**.

## 2. What is connected (and where)

```
request → Decision (grammar first; Jev only on an abstention, DISABLED by default)
        → router (the one V0.3.1 router) → TaskEngine (the one orchestrator)
        → EngineeringAssignment (derived from the task record)           [seam: engineeringBegin]
        → worker (a claim)                                               [seam: engineeringStaleness / Gate]
        → ACTUAL repository state (snapshot, git facts, real diff)       [seam: engineeringAfterApply]
        → VerificationEvidence from CommandRunner, bound to a revision   [seam: engineeringDigest / RecordEvidence]
        → review / policy → bounded repair (inside the engine's loop)    [seam: engineeringRepairGate]
        → completion gate → verified | NOT VERIFIED | refused           [seam: engineeringCompletionGate]
        → checkpoint (existing artifact) → revalidated resume            [seam: Checkpoint.engineering]
        → grounded report (persisted final report read back by report(for:))
```

Files: `Tasks/EngineeringSeam.swift` (pure glue; no process / approval / network / credential API), `Tasks/TaskEngine+Engineering.swift` (the hooks), small edits in `TaskEngine`, `+Execution`, `+Lifecycle`, `TaskReport`, `GitTool` (`facts`, `contents`), `Decision/JevTargetResolver.swift`, `AppContext+Daily` (registry hook). Applies only to `TaskKind.development` with a code-change step; research, Unity, computer, experiment, conversation and navigation tasks never enter it.

## 3. Behaviour that is guaranteed (and tested)

* **Worker output is a claim.** A structured worker report is parsed into `WorkerClaims`, compared with observed state, and never constructs or replaces `VerificationEvidence`. The only production `VerificationEvidence(` constructor is `EngineeringSeam.evidence` (DEC-311; pinned by `guards_engineering.sh`).
* **Verification is revision-bound.** Evidence carries the workspace digest taken before the run; any later edit makes it stale; a cancelled run yields none; a timeout is exit 124 / failed; exit 0 with failing counts does not pass; tool caches are ignored so a verification run cannot invalidate itself.
* **Review before the write.** The prospective before/after texts are reviewed (scope, tampering, placeholders, dependencies, secrets, destructive commands); a blocker means nothing is written. `.git/**` and `.jarvis/**` are forbidden paths, so a worker cannot edit the verification profile.
* **Completion.** Verified → completed ("Verified by JARVIS' own runs at the final revision"; manual requirements listed). No approved profile → completed as **NOT VERIFIED** (honest summary, non-engineering semantics unchanged). Blocker / failing run at the final revision / stale evidence / missing required stage / unchanged repository → the task **fails**.
* **Dirty work is the user's.** A pre-existing dirty file is never attributed to the worker and never reset; the existing dirty-file approval still applies; staged and conflicted paths come from `GitTool.facts`.
* **Budgets do not multiply.** The semantic repair gate sits inside the engine's one repair loop and can only stop earlier; an integrated test pins total provider jobs.
* **Persistence and resume.** The run state lives in the existing checkpoint artifact (no second database, no reasoning). On resume the stored snapshot is compared with the workspace: unchanged → continue; any change since the snapshot (even in a file the task also edited) → fail safe with `workspaceChanged`, nothing written; the one exception is a file back at its pre-edit hash (a lost edit, redone — pinned by an existing safety test); a torn / altered checkpoint → fail safe; changes recorded but no engineering state → fail safe.
* **Rollback stays a plan.** No `git reset` / `clean` / `checkout` / `commit` / `push` anywhere (source guard unchanged); `RollbackPlanner` is not called (DEC-315).
* **Jev.** Default `disabled`; shadow allowed; gated read-only exists but is not the default; gated execution is impossible (`executionIsEnabledInProduction = false`); the zero-Jev fast path is unchanged; Jev has no path to engineering authority (the seam and the Decision layer share no authority API); the project-registry hook is wired (DEC-318).

## 4. Results (Cloud, Linux harness over the REAL TaskEngine — not macOS)

How it ran: the real 262-file TaskEngine closure type-checks with Apple-only frameworks stubbed at prep time (the stubs live outside the repository); the real engine runs against real SQLite, real Git and real Python fixtures, a scripted provider (`ScriptedRunner`), the real `CommandRunner` / `ManagedProcess`. No provider, network, key, GUI, voice or Unity was used.

| Run | Tests | Checks | Failures |
|---|---|---|---|
| Engine suites: `TaskEngineTests`, `TaskEngineSafetyTests`, `TaskEngineExtraTests` + new `EngineeringIntegrationTests` (16), `EngineeringSeamTests` (5), `EngineeringFinalSoakTests` (1) — one binary, completed run | **68** | **6 621** | **0** |
| Decision / Jev regression: Core, Lexicon, Reliability, Quality, `JevGateTests`, `JevRegistryHookTests` | **149** | **2 205** | **0** |
| Source guards (`verify.sh` + `guards_*.sh` source-text part) | 293 | — | **0 failed** |

Scenarios (all in `EngineeringIntegrationTests` unless noted; each asserts what the task may CLAIM):

| Scenario | Result |
|---|---|
| verified success (real fix, real passing tests, evidence bound to the final revision, run stored in the checkpoint) | PASS |
| false success (worker claims green, tests actually fail) → task fails, no "verified" | PASS |
| no diff (worker claims a change, nothing changed) → refused | PASS |
| test tampering (assertion removed / test skipped) → nothing written | PASS |
| dirty worktree (user's uncommitted README) preserved byte for byte, task completes | PASS |
| stale result (repository changed while the worker ran) → not applied | PASS |
| concurrent tasks on one project → one fix, no doubled edit, never interleaved writes | PASS |
| cancel during worker / during verification → nothing applied or claimed after the cancel | PASS |
| restart + resume (unchanged workspace) → completes, verified | PASS |
| resume after drift (user edit while JARVIS was off) → `workspaceChanged`, no worker, nothing written | PASS |
| corrupt (torn) checkpoint → fails safe, nothing written | PASS |
| provider failure → bounded, honest, never "completed" | PASS |
| verifier timeout → failed evidence, never "verified" | PASS |
| malicious worker output (instructions, secrets, claims of approval) → data only | PASS |
| git facts (staged / conflicted) and integrated retry budget | PASS |
| accelerated soak (`EngineeringFinalSoakTests`): 16 tasks × 8 worker temperaments on one engine → 4 completed, 2 cancelled, 10 failed, **0 illegal completions**, coding attempts ≤ `maxStepAttempts`, provider jobs ≤ budget, nothing after a cancel, 0 leases left, bounded events | PASS |

Found by running (not by reading) and fixed in this pass: `report(for:)` rebuilt the report from the database and dropped the engineering state (a completed task would not have said "verified" after a restart) — it is now read back from the hash-verified persisted report; resume excluded the task's own files from drift detection, so a user edit to a file the task had also changed went unnoticed — fixed (with the lost-edit exception); a stale `.pyc` could mask a same-second, same-size fix in the test fixture — the fixture runs `python3 -B`; two duplicate type names (`TaskDigest`, `ClaimKind`) that would not have built on macOS — renamed (DEC-317).

Not run, honestly: `scripts/test.sh` (Cloud has no `swift` package manager: `swift: command not found`), `scripts/verify.sh` (zsh + macOS tools; under bash it stops at its first `print`), any real provider, any real Jev request, the app, Unity, voice, GUI. The harness itself crashes intermittently inside swift-corelibs-foundation's `Process` spawn on Linux (V1FI-2); a crashed run is discarded and the binary is rerun, a finished run is complete.

## 5. False-completion audit (production paths)

`finalizeSuccess` has one call site (`TaskEngine.runTask`, after the completion gate; pinned by `guards_integration.sh`). The `verified` completion value exists only inside `EngineeringSeam.completion`, which reads `EngineeringVerifier`'s verdict computed from the observed snapshot and `VerificationEvidence` produced by `CommandRunner` results; no provider text, review prose, memory, artifact or Jev answer reaches it. `report.verification` is derived from that value only. A non-engineering task's completion semantics are unchanged.

## 6. Not wired on purpose

`OwnershipRegistry` (the engine's file leases stay the runtime authority), `WorkerSelector` (the existing router stays the only router), `RollbackPlanner` (plan only), the remaining V1BG policies (V1BG-1 stays open), same-task independent work during an approval wait.

## 7. What must happen on the Mac

`scripts/verify.sh` (fix whatever small compile differences appear; do not weaken an assertion), then README 1331+. A live Jev measurement is the local step of `docs/JEV_DECISION_POLICY.md` §13; Cloud used no key.
