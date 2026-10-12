# Proactive Reasoning, Opportunity Engine & Approval Policy (V0.5 — DEC-041…DEC-048)

V0.5 gives JARVIS controlled initiative. It is a **decision layer above the V0.4 task engine**:

```
V0.5 decides ─► V0.4 executes ─► V0.3.2 observes ─► V0.3.1 routes providers/models
```

It never edits files, never runs commands, never approves anything by itself and never polls. An action that policy allows becomes a
**normal V0.4 task** (persisted, planned, plan-validated, capability/workspace/lease checked, validated, repair/escalation-bounded,
cancellable, checkpointed, recoverable, sanitized, observable, reported). Code: `Sources/Jarvis/Proactive/`, `Persistence/OpportunityRepository.swift`
(schema v4), `Tasks/TaskScope.swift`, `UI/FullHUD/Tasks/ProposalsView.swift`.

```
finished V0.4 task ──► FindingExtractor (recorded facts: changed files, validation, failure)   review suggestions (model CLAIMS)
                               │                                                                       │
                               └────────────────────► OpportunityEngine.ingest ◄───────────────────────┘
        dedupe / cooldown / coalesce ─► OpportunityAssessor (deterministic; ≤1 budgeted model call that may only ADD caution)
        ─► OpportunityPolicy (deterministic precedence) ─► ignore | record | propose | requireApproval | autoAction
        propose/requireApproval ─► ProposalRecord (card) ─► user: Approve / Deny / Dismiss (HUD only) ─► ProposalService
        autoAction / approved ─► TaskEngine.submit(origin, scope, depth, deterministic id) ─► everything V0.4 guarantees
```

## Opportunity (durable)
`opportunities` row: project, origin (`taskFinding`, `validationFinding`, `reviewFinding`, `testFinding`, `buildFinding`, `analysisFinding`,
`userDeferredIdea`, `systemMaintenance`), origin task/step/run, title, bounded summary, category (`bug`, `testCoverage`, `maintenance`,
`refactor`, `performance`, `security`, `documentation`, `design`, `gameplay`, `asset`, `dependency`, `configuration` — descriptive only, never
authority), evidence, affected scope, structured assessment, policy decision + reasons, status, dedup key, related opportunity, occurrences,
cooldown, autonomy depth, proposed action, action hash, task id, source event. All text is sanitized and bounded; there is no column for model reasoning.

**Evidence** (`EvidenceItem`): `taskResult` / `validationOutput` / `fileReference` are *deterministic* (recorded by JARVIS); `reviewClaim` /
`modelClaim` are claims. Optional machine-checkable `EvidencePredicate` (`fileContains/fileLacks/fileExists/fileMissing`) lets a stale proposal be
detected. An unsupported idea may still become a proposal; it can never become an automatic action (strength < strong).

## Observation triggers (event-driven)
`TaskEngine.onFinished` (completed/failed) → at most 3 derived findings; `TaskEngine.onReviewSuggestions` (the reviewer may add ≤2 optional
`suggestions`). Derived findings today: *a completed development task changed application code but no test* (strong, direct, concrete: add one
regression test); *no test command found*; *tests/build still failing after repair* (never auto: no concrete action). Nothing runs while idle: no timers,
no filesystem watching, no repository scans, no "find something to improve" prompt (`verify.sh` + a unit test forbid timers/polling in `Proactive/`).

## Assessment (structured)
`relevance, confidence, scopeSize, relation (direct/adjacent/unrelated), risk, reversibility, destructiveness, designImpact, externalEffects,
requiredCapabilities, evidenceStrength`. Derived deterministically from the finding and the origin task's recorded changes; keyword safety nets
detect design/product wording, external effects (purchase, git push, credentials, deploy, upload, messages, permissions…) and destructive intent
regardless of what a model says. **A model may only add caution** (`mergeModelAssessment`: risk only up, design impact only on, effects/capabilities
only added, a more restrictive category adopted, files filtered to existing ones; the model's own confidence is never merged). Fields that carry
authority in a model's JSON (`decision`, `approved`, `autoAction`…) are never parsed. Confidence is derived from evidence strength and is **evidence, not authority**.

## Policy (`OpportunityPolicy`, pure)
Precedence — a higher rule overrides a lower one whatever the confidence:
1. **CRITICAL → `requireApproval`**: any external effect, destructive/irreversible, critical risk, or a capability V0.4 never grants (`gitPush`, `gitCommit`, `purchase`, `useNetwork`, `useBrowser`).
2. **DESIGN/PRODUCT/SECURITY → `propose`**: meaningful design impact; categories design/gameplay/asset/dependency/security; refactors beyond the goal.
3. **SCOPE → `propose`/`record`**: medium/broad scope, adjacent or unrelated work (unrelated + weak evidence → record).
4. **LOW-RISK LOCAL MAINTENANCE → `autoAction`**, only if ALL hold: Low-Risk Autonomous mode; concrete action; origin is a USER task at depth 0; budget left; category testCoverage/maintenance/bug; direct; risk low; reversible; non-destructive; no design impact; no external effect; small scope (≤2 files); capabilities ⊆ {read, write, build, test}; evidence strong; confidence ≥ 0.6. Otherwise → propose (or record when evidence/confidence is negligible).
Then the **mode** caps it: Observe Only → `record` (reasons carry `wouldBe:<decision>`); Ask Before Acting → `autoAction` becomes `propose`. `ignore` for disabled proactive reasoning or relevance < 0.2. Every outcome stores concise machine-readable reasons (`directScope`, `reversible`, `mode:askBeforeActing`, `autonomyBudgetExhausted`, …); the card renders them in plain language.

## Modes, defaults, settings
`Observe Only` (record, no proposals, no actions) · `Ask Before Acting` (**default**: record + propose) · `Low-Risk Autonomous` (+ policy-approved automatic maintenance). Critical actions and design/product decisions need explicit approval in EVERY mode. Settings → Autonomy: radio group + explanation, "proactive reasoning" and "show proposals" toggles. Preferences: `autonomyMode`, `proactiveReasoningEnabled`, `showProposals`.

## Budget and anti-recursion
`AutonomyBudget`: 1 automatic task per originating user task, chain depth 1, ≤2 changed files / ≤8 steps for automatic work, 1 assessor call per origin task. Task depth: user 0 → auto/approved 1. An automatic or approved-proposal task may **record or propose** but never creates another automatic task (`autonomyChainDepth`, `autonomyBudgetExhausted`).

## Deduplication, coalescing, cooldown
Key = project + category group + normalised scope + identifier-aware, synonym-folded tokens (`NetworkPlayer lacks null guard` ≡ `Missing nil protection in NetworkPlayer`); similarity (Jaccard ≥ 0.6) on the same scope also matches. Same event delivered twice → one record (unique source event + deterministic id). Related test-coverage/documentation/maintenance findings about the same file **coalesce** into one open card. Deny → 14-day cooldown, dismiss → 3 days, ignored proposals expire after 7 days (persisted; survive restart); a finding of an easy-to-merge kind about the same file as a declined one is suppressed unless it brings materially new deterministic evidence (then a new opportunity is linked via `relatedOpportunityID`). No modal interruptions: proposals are passive cards.

## Proposals and approval
`proposals` row: opportunity, project, title, summary, reason, evidence, proposed action (goal, expected files, **scope**, validation plan), risk, design impact, reversibility, expected benefit, `action_hash`, status (`pending/approved/denied/dismissed/expired/obsolete/executed/unsupported`). The Tasks screen shows pending proposals (title, project, why, evidence, action, scope, risk, design change, reversibility, benefit, validation plan) with **Approve / Deny / Dismiss** of equal weight, nothing pre-selected; critical ones are visually distinct and say what happens if denied, and when JARVIS cannot perform them at all. Compact shows only a restrained "N SUGGESTIONS" tag (still 392×448).
* **No self-approval:** `ProposalService` is the only writer of decisions; its API takes a `DecisionSource` (`hud`/`test`) and no text; only the HUD buttons call it (`verify.sh`). A provider saying "Approved." / "Proceed without asking" changes nothing.
* **Scope-bound:** approval stores `action_hash = SHA-256(opportunity, workspace, goal, scope, kind, risk, category)`; a changed proposal is refused (`tampered`).
* **Approval grants scope, not capability:** approved proposals needing capabilities/external effects/destructive actions V0.4 does not have end as `unsupported` (nothing runs).
* **Expansion check:** the generated task carries a `TaskScope` (allowed step types, ≤8 steps, path allowlist or test-files-only, ≤N changed files, no deletes) enforced in the **plan** (the planner is told the scope; plans exceeding it are re-asked once, then fail `scopeExceeded`) and on **every edit** (`scopeExceeded`; never "repaired"). The opportunity becomes `needsReapproval`, the proposal expires, and the user can re-propose.
* **Stale proposals:** before creating the task, machine-checkable evidence is re-read; if every predicate is now false the proposal is `obsolete` and nothing is touched.

## Persistence, restart, idempotency
Schema v4 (transactional migration): `opportunities`, extended `proposals`/`approvals` (proposal id + scope hash), `tasks.origin/origin_task_id/origin_opportunity_id/autonomy_depth/scope`. Ids are deterministic (opportunity from the event key, proposal from the opportunity, task from the proposal/opportunity), so a crash between persisting a decision and creating its task is completed exactly once at launch (`OpportunityEngine.reconcileOnLaunch`/`retryQueued`); a pending proposal stays pending; approving twice does nothing; the same event never makes two opportunities.

## Task identity
`TaskOrigin`: `userTask`, `proactiveAutoAction` ("JARVIS AUTO TASK"), `approvedProposal` ("APPROVED PROPOSAL") — persisted, shown as a tag in Tasks, linked to origin task/opportunity; proactive tasks appear in Tasks and Agents like any task.

## Provider usage
Findings derive from recorded facts: **no provider call**. A free-text finding (no category/structure) may use ONE assessor call per origin task via the normal router (development profile → never the local model; free benchmarked OpenCode first, then Claude/Codex); the reason is recorded and shown in the activity feed. No paid API, no continuous cloud thinking: idle means idle.

## Security
Evidence, summaries, proposals and policy reasons are sanitized/bounded before storage; the decision layer has no file-write, process, network or credential code (guards in `verify.sh` and unit tests); approvals never enable `gitPush`, purchases, network or credentials; project boundary holds (a task only ever runs in its opportunity's workspace; dedup is per project).

## Limitations / what comes next
Findings are limited to what V0.4 records (plus optional reviewer suggestions) — there is no project-wide scanning (deliberately). Only a few deterministic extractors exist. Auto actions are narrow (regression tests, tiny maintenance). No notifications (permission). The Report screen is still a placeholder. **V0.6** — Unity Project Agent (Unity MCP, scene/prefab/editor automation); **V0.7** — web research + asset acquisition (licenses, free-price verification, purchases stay critical approvals); **V0.8** — project memory (richer, learned project context beyond operational opportunity/proposal state).

## V0.6 interplay
Unity findings are ordinary findings: V0.5 policy stays authoritative. Unity content/design wording (lighting, scene layout, UI flow, art direction, skybox, post-processing, camera angle…) is design impact → PROPOSAL (never AUTO in any mode); "purchase/Asset Store/paid asset" → critical (external effect `purchase`, unsupported); "delete unused prefabs" → destructive → approval. Unity capabilities are not in the auto-action capability set (`read/write/build/test` only), so no Unity mutation can ever be an automatic action. The decision layer has no reference to the Unity layer (guarded).

## Voice (V0.7)
The proactive layer is unchanged and has no voice code: proposals are approved only with HUD buttons (a spoken or typed "approve" is answered with a notice, never executed), and nothing proactive is ever spoken spontaneously. A voice-created task is a normal user task (`origin = userTask`, depth 0) for the budget and policy rules.


## Natural voice (V0.8)
Still no voice code in the proactive layer. Proposals are approved only with HUD buttons; "approve"/"evet onayla" said after the wake word is answered with the HUD-only notice (live-tested through the wake path with an isolated pending approval); nothing proactive is spoken spontaneously.

## V0.9 — research proposals (DEC-101)

The proactive layer may *propose* a research ("the task failed with an unknown API error — research it?"): `OpportunityAssessor` rebuilds the action deterministically (no project-read capability), `OpportunityPolicy` has a web-authority rule (web research may only ever be *proposed* — decision `propose`, never automatic; an action that needs `downloadToQuarantine` or `importIntoProject` is `requireApproval` as its own separate decision), and `OpportunityEngine.proposeResearch/startTask` start it through `TaskEngine.submitResearch` with `originTaskID`/`autonomyDepth`. Policy still outranks confidence.
