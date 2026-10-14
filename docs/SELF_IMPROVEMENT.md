# Controlled Self-Improvement (V0.14)

Status: IMPLEMENTED · AUTOMATED TESTED · REAL TESTED on disposable Git fixtures only · MANUAL TEST REQUIRED.

JARVIS does **not** silently modify itself. Levels (Settings → Adaptive learning; default **2 – Experiment**; there is no level 5):

| Level | Name | Allowed |
|---|---|---|
| 0 | Observe | record signals only |
| 1 | Learn | candidates, lessons, rules (proposed, not active) |
| 2 | Experiment | + disposable experiments / sandbox benchmarks |
| 3 | Propose | + write an improvement *proposal* (a document; nothing is changed) |
| 4 | Approved self-improvement | + apply an approved proposal as an ordinary development task |

## Applying a change

Requires **all** of: level 4; a request created by the user and approved in the HUD (`AdaptiveDecisionSource` is `hud` or `test` — a spoken or typed "yes" approves nothing); a recorded checkpoint (commit + branch + dirty state); a **clean** Git working tree; a configured target repository (`selfRepositoryPath`, assigned only by live tests — the app default is none, so the production JARVIS repository is never a self-change target unless the user configures it).

The change is then submitted once through `TaskEngine.submit` with the constraint marker "self-improvement (approved by the user)". It is a normal V0.12 development graph: Analysis → Coding → QA (build + tests) → independent Review, with the usual capability, lease, user-dirty-file and destructive-step rules. A failed or unvalidated change is **never promoted**; the checkpoint is kept for the user to revert (JARVIS never runs `git reset/clean/checkout/commit/push`).

## Boundaries

* No `SelfImprovementOrchestrator`; the adaptive layer has exactly one `engine.submit` (guarded).
* No file write, project tool or importer in the adaptive layer (guarded).
* Proposals are explained in plain language (`SelfImprovementService.explanation`) before approval: what, why (evidence), risk, files, validation.
* Source improvements come from evidence (e.g. a repeatedly slow path: ≥ 6 comparable tasks, > 3× median) — never from a model's wish.
* Nothing self-edits while idle. Restart reconciliation marks an interrupted self-change as interrupted; it resumes only by explicit action.

## Tests

`--adaptive-live-test --adaptive-section selfimprove`: approved change on a disposable fixture (validated, checkpoint kept), a failing change (not promoted), dirty tree refused, level too low refused, voice-equivalent approval refused. Rejection and security sections cover the refusals.
