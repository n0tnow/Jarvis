# Project Operator (V0.13)

JARVIS can answer "where are we on project X?" and, when told to, continue that project as a **bounded, ordinary task**. This document is the contract for Project Continuity (`Sources/Jarvis/Continuity/`).
States used here: IMPLEMENTED · AUTOMATED TESTED · REAL TESTED · MANUAL TEST REQUIRED. Nothing below is MANUALLY VERIFIED until the user says so.

## 1. What it is — and is not

* A **derived view**. Nothing about "where we left off" is stored as a second source of truth. The view is rebuilt on demand from: tasks, Git (branch / HEAD / dirty files), the project's own docs (`PROJECT_STATE.md`, `docs/CURRENT_TASK.md`, `TODO.md`, "Next Step" / "Remaining Work" sections), the Unity descriptor (V0.6) and the last checkpoint. Project memory (V0.10) contributes digests only.
* **Current truth wins.** A checkpoint or a memory that disagrees with files / Git / Unity is shown as *stale* and never used to decide anything (`ContinuityReconciler`).
* **Not an orchestrator.** "Continue" submits one V0.4 task through `TaskEngine.submit` with the persisted constraint `ContinuationMarker.constraint`. V0.12 stays the only orchestrator (graphs, roles, gates, approvals).
* **Not a scheduler.** Nothing runs while idle: no timer, no poll, no file watcher. It runs when asked, and once when a task finishes (to write a checkpoint).

## 2. Persistence (schema v11)

`project_continuity` (queue + session counter per project key) and `project_checkpoints` (Git HEAD, file hashes, validated / remaining, the task id; pruned to the last 30). Everything else is recomputed. Restarting JARVIS loses nothing that matters and invents nothing.

## 3. Identity and questions

The project is resolved through the V0.10 identity / aliases (name, folder, Git root, Unity project). Status questions in English and Turkish ("Hamam projesinde ne durumdayız?", "where did we leave off?", "what did we do last?", "what is next?") are answered **locally** from the view — no provider is called for a status.

## 4. Continue

"Continue where we left off" / "Kaldığımız yerden devam et" is recognised by `ContinuityIntent` (phrases, not keywords alone).

**What it authorises:** one bounded task toward the single selected next step, with the normal V0.4 policy, capabilities and approvals.
**What it does not authorise:** anything outside that step's capabilities; any approval (approvals are HUD buttons only); a design change; a push / commit / purchase / network; a second continuation started from inside the first (depth 1).

Selection tiers (`ContinuationSelector`): **interrupted** (resume — or re-plan if the project drifted) → **failed once** (retry; a retry of a retry is never offered) → **recorded next** (queue ∪ checkpoint ∪ docs) → **known issues**.
Several candidates in a tier ⇒ JARVIS **asks**. A design-sensitive candidate (`MajorDesign`) ⇒ JARVIS **proposes** and waits.

## 5. Bounds (`ContinuationBounds.standard`)

30 minutes · 12 nodes · 2 revisions · 2 correction rounds · 2 experiments. They are persisted as a task constraint (so they survive a restart) and enforced in the engine (`TaskContext.continuation`) — the graph timeout, the correction loop and the experiment count read them.

## 6. Restart, drift, failure

* Restart: a running continuation becomes INTERRUPTED. It resumes **only** by explicit user action, and the resume re-observes first.
* External drift (files / branch / Unity changed since the checkpoint): the reconciler reports it; an interrupted plan is **re-planned**, not blindly resumed. JARVIS' own file changes are not "interference".
* Failed task: retried once on request; non-retryable categories (policy, approval, capability) ask the user.

## 7. Surfaces

Full HUD → Tasks → **Project** card (state, last checkpoint, next candidate, bounds, Continue / Choose). Compact HUD (392×448) shows one line: `Hamam · Continuing · Editing`. Settings → Operator: the continuation switch.

## 8. Tests

Automated: `ContinuityCoreTests` (35), `ContinuityEngineTests` (11), migration tests. Real: see README manual checks 'V0.13' — the restart / drift / failed / interrupted scenarios against a **disposable** project clone. The real Hamam project is never an automated target.

## 9. V0.13.1: Scene Profile on the Project card (DEC-209) and memory-only (DEC-210)

The Full HUD Project card shows a compact **Scene** block: scene name, object / light / camera / renderer counts and the active render pipeline. It has two labelled states — **live** (an owned editor is connected right now; read through the typed `sceneProfile`) and **stale** (the last facts, with the time they were read, shown greyed with "as of …"). Nothing starts an editor to fill it, nothing polls: with no connected editor you see the stale block or nothing. A stale value is never presented as live and never decides anything. The Compact HUD is unchanged (392×448, one line).

`ContinuationSelector`: a *known issue* that exists only in memory is offered as a choice, never started on its own — memory alone never starts work.
