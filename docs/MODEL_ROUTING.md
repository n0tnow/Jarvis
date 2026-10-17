# Model routing (V0.3.1, DEC-022/024/025/026)

Status: IMPLEMENTED · AUTOMATED TESTED (≈60 routing/policy tests) · REAL TESTED end-to-end (see PROJECT_STATE).

```
text ─► TaskClassifier ─► TaskProfile ─┐
                                        ├─► ModelRouter (pure) ─► RoutingDecision{selected | refused, fallbacks[], reasons{}, rejected{}}
RouterSnapshot ────────────────────────┘      ▲
  engines (state, cooldown) · registry models · benchmark summaries · model cooldowns · resources · settings · preference
```

## Task profile
Category (conversation, classification, extraction, summarization, formatting, explanation, research, coding, testing, review, debugging, repositoryModification, architecture, security), complexity (trivial…critical), privacy (public/normal/sensitive), `requires{Coding,Testing,RepositoryModification,TechnicalReview,ComplexReasoning,Tools}`, project-code flag, domain tags, context estimate. Built from text by `TaskClassifier` (EN + TR, deterministic, conservative) or supplied by the caller (agents, benchmarks).

## Local model (hard policy)
Eligible only if none of: any `requires…` flag, forbidden category (coding/testing/review/debugging/repositoryModification/architecture/security), domain unity/multiplayer/security/csharp, complexity > simple, context > ≈3000 tokens, project code. Also needs: allowed in settings, runtime usable, memory pressure normal, no thermal throttling, no other local job running.

## Auto order
| Task | Order |
|---|---|
| lightweight (policy passes) | Local → OpenCode free → Claude Code → Codex |
| development / moderate knowledge | OpenCode free → Claude Code → Codex |
| complex/critical, architecture, security | Claude Code → Codex (free cloud and local are skipped) |

A free model is a candidate only if: free-pool member (DEC-022) with fresh verification · engine ready, no cooldown (engine or model) · privacy gate (sensitive never; project code ⇒ zero-retention only) · fits context · **benchmark passed for the task's group** (Auto only) · ranked by pass rate, then **zero-retention before others**, then median latency, then id.

## Explicit modes
`Local`, `OpenCode Free`, `Claude Code`, `Codex`: single engine, **no fallback**. Local refuses ineligible tasks; OpenCode Free refuses when no verified-free model qualifies or the task is sensitive; Claude/Codex refuse when not ready. Refusals are explained to the user.

## Reasons
`RoutingDecision.reasonJSON` (sorted keys, strings only), e.g. `{"category":"coding","coding":"true","codingBenchmarkPassed":"true","dataPolicy":"zeroRetention","freeVerified":"true","freeVerifiedAt":"…","localModelIneligible":"true","localViolations":"requiresCoding,…","mode":"auto","outcome":"selected","providerReady":"true","selected":"opencode/…","tier":"development-free-first","rejected.local":"policy:…"}`. Stored with every agent run.

## Escalation (bounded)
`fallbacks` is the ordered remaining eligible chain computed up front. `AgentRunner` uses it with `EscalationPolicy` (default: 1 repair attempt on the same model after a validation failure, then escalate once down the chain; hard cap on total attempts). No loops, no re-routing mid-run.

## Cooldown
`CooldownPolicy`: from the 2nd consecutive failure, 60 s · 2^(n−2), capped at 30 min; persisted in `provider_health`; a success resets it. A broken model is therefore not retried every few seconds.

## Provider-removed models
OpenCode can list a model as `active` while its API answers `410 … has been deprecated`. JARVIS maps 404/410 to a typed "model removed" error, blocks the model (`blockedReason = provider reports the model as removed`, sticky for 24 h even if the catalog still says free), escalates the request, and stops a running benchmark for that model after the first such error. Benchmark evidence (Auto requires it) is the second line of defence: a model that cannot answer never qualifies.

## Task engine routing (V0.4)
Task prompts (planner, analysis, coding, review) are routed through the SAME `ModelRouter`: `jobProfile` marks them development work (`requiresCoding`, `containsProjectCode`, category coding/repositoryModification/review, complexity ≥ moderate, privacy from the goal), so the local model is excluded by `LocalModelPolicy` in code, free models need a passed **coding** benchmark in Auto and must be zero-retention for project code, and Claude Code/Codex are the escalation tier. Task-level repair pins the engine that wrote the last edit; task-level escalation passes `exclude` (engines already used) so the router's ordered fallback chain yields the next eligible provider. Explicit modes never escalate. Real result (V0.4 live test, OpenCode 2.0.26): Auto → `opencode/space-bunny-free` (benchmarked 13/13, zero-retention) planned, analysed, fixed and reviewed the fixture; no escalation was needed.

## Proactive reasoning routing (V0.5)
Findings derive from recorded facts and need no provider. A free-text finding may use one budgeted `OpportunityAssessor` job per originating task through the normal router with a development profile (`requiresCoding`, `containsProjectCode`): never the local model, free benchmarked OpenCode first, Claude/Codex after, explicit user modes respected, no paid API. The router's answer is evidence for the assessment only: policy (not the model) decides authority. Real result (V0.5 live test): one assessor call on `opencode/space-bunny-free`, reason recorded; the structured findings used 0 provider calls.

## Unity routing (V0.6)
Unity coding/debugging/scene reasoning is development work: every Unity prompt (planner with a Unity section, analysis, `codeChange`, `UnityAgent`, review) is built with the V0.4 job profile (`requiresCoding`, `containsProjectCode`, domain "unity"), so `LocalModelPolicy` forbids Local Qwen (domain `unity`/`csharp` are forbidden domains; verified by a unit test). Auto prefers a benchmarked OpenCode FREE model, then Claude/Codex per the existing rules; explicit modes never fall back; no paid API. Real result (`--unity-live-test`): `opencode/space-bunny-free` fixed a real Unity compile error (≈10 s) and a real failing EditMode test (≈18 s, incl. review) with Unity's own compiler/tests as the validation. Unity tool steps (inspect/edit/compile/test/play/validate) use no provider; only the scripted-planner scenarios of the live test used 0 provider calls.

## Voice (V0.7)
Voice adds NO routing path: a final transcript is routed exactly like typed text (deterministic commands never reach a model, `workerRequired` becomes a V0.4 task, reasoning goes through `ModelRouter`; the local-model policy is unchanged and voice grants Qwen no new authority). Speech recognition and synthesis are not "models" of this router: they are I/O providers with their own cost-first selection (`VoiceProviderSelection`, DEC-060) — PAID/UNKNOWN never auto, explicit choice never falls back — and nothing here ever calls a paid or cloud speech API. A spoken answer is the shown answer; no model call is made to "write something to say".


## Natural voice (V0.8)
Still no routing path: a hands-free transcript is `ConversationService.submit(source: .voice)` like Push-to-Talk and typing. The only change a provider sees is `ResponsePresentation.voiceConversation` — a one-line preamble in the prompt of voice turns asking for a short, speakable answer (Claude, Codex, OpenCode free models and the local Qwen alike); there is no second model call to rewrite an answer and the local-model policy, the free-pool rules and the fallback rules are untouched. The speech engines (local neural voice, Apple, Whisper, the wake sentinel) are LOCAL/SYSTEM cost-class helpers outside the model router: PAID/UNKNOWN speech is never selected automatically and there is no cloud speech path.

## V0.9 — research model calls

Research steps call models only through the existing router as `ResearchAgent` jobs (text in, validated JSON out): query refinement (≤1), fact/candidate extraction (≤1–2), style assessment (≤1) — at most 3 per research (deep: 5). The `TaskProfile` is extraction/classification/summarisation, `requiresCoding = false`, `containsProjectCode = false`, privacy inherited from the task. Free cloud / local rules are unchanged (sensitive text never goes to free cloud; paid never; explicit provider choice never falls back). Page text reaches a model only fenced as untrusted data (`UntrustedContent`) and only bounded excerpts; a model reply is accepted only if it validates and (for facts) its quoted evidence is verbatim in the page. The live runs used Claude Code and the local Qwen model; structured providers (Poly Haven, Kenney, GitHub, docs resolver) need no model at all.

## V0.10 — memory and routing

Agent jobs may carry a bounded Project Memory packet (≤ 3,000 characters, roughly 600–800 tokens; budgets per agent kind in `ProjectContextBuilder.profile`) in front of the prompt; `TaskProfile.estimatedContextTokens` is raised by its size so routing sees the real prompt. The packet changes **context, not routing policy**: free/local/paid rules, privacy, explicit-provider behaviour and escalation are untouched. Embeddings are **local only** (no hosted embedding API, no key). The optional model-proposed-lessons step (`MemoryAgent`, off by default) is a small structured-output job (`summarization`, simple) routed like any other; the local Qwen is not used as an authority for contradictions, security or licence decisions.

## V0.11 — Computer Use and model routing
Computer Use calls a model in exactly one place: the optional bounded planner (`ComputerPlanner` job type `ComputerPlanner`, ≤ 4 rounds, each proposing ≤ 3 typed actions). The job profile is `classification`, moderate complexity, **privacy `sensitive`** (window titles and control labels can be private → never the free cloud pool; the user's own subscription providers only), no project code, structured output. The local Qwen model is deliberately **not** used for UI interpretation (not benchmarked; it must never interpret security-critical dialogs, complex visual state or approvals — DEC-132). The deterministic parser, the policy, the resolver and the verifier use no model. Vision is local on-device text recognition (no model, no routing, no key). Automated runs and `--computer-live-test` make no model request.

## V0.12 — routing per ROLE
The router is unchanged and still decides eligibility (price re-verified at runtime, privacy, local-model policy, health/cooldown, V0.3.1 benchmark gate, explicit user choice). V0.12 adds around it, per model run: a **persisted decision** (`routing_decisions`: role, engine/model, mode, a sentence such as “Selected space-bunny-free for Coding because development work goes to a verified-free OpenCode model first, it is currently verified $0 with zero data retention, it passed the … benchmark, the task is moderate.”, machine reason, sizes, timings, tokens, cost class); **review independence** (risk-based exclusion of the writer's candidates); **role evidence** for security-relevant coding/review (a free/local model needs COMPLETE passing evidence in the `security` role of the `roles-v1` suite; a subscription engine without evidence is allowed, one that failed is not; Auto only — explicit choices are respected); a per-node **invocation budget** (≤ 4); a failure vocabulary (`NodeFailureClass`) and explicit escalation reasons. Role benchmarks live in `model_benchmarks` (suite `roles-v1`) and never feed the V0.3.1 Auto gate. Local Qwen restrictions are unchanged. One task may legitimately use OpenCode Free for coding and Claude for review; Auto chooses per node, not per task. Telemetry (`routingTelemetry`) answers “which model succeeds most for each role / how often does free escalate / which role uses the most context” from recorded facts.


## V0.13 additions

* Continuation tasks use the SAME Auto routing as any task (the persisted constraint only carries bounds). Status questions never reach a provider.
* Visual grounding is routed by privacy class (on-device › subscription › free cloud) and sensitivity (desktop / project / synthetic); desktop and project pictures never go to a cloud provider; no cloud provider is registered.
* The local vision model is chosen in Settings (Qwen3-VL 4B or 2B, applies after relaunch); it is never selected by name inside the engine.
* A real continuation of a documented one-file fix routed to OpenCode FREE / Claude Code through the V0.12 router like any other graph.

## Routing levels and the Decision layer (V1.0 decision milestone, DEC-267…274)
A philosophy, not a second router — the V0.3.1 `ModelRouter` and the V0.12 orchestrator are unchanged:
* **Level 0 — deterministic.** Known status / navigation / settings / stop / project-open / media / visibility commands (`DeterministicCommandRecognizer`): no model, no network, microseconds.
* **Level 1 — decision intelligence.** The optional remote classifier (Jev; disabled by default; shadow = compare only; gated = a closed read-only set) for what Level 0 does not understand.
* **Level 2 — local conversational model** (today Qwen3.5-4B): natural conversation and small transformations; whether a larger local model is worth it is measured in Phase B (`LocalModelBenchmark`), never assumed.
* **Level 3 — verified-free OpenCode**: coding / review / tests / research where the V0.3.1 price rules allow.
* **Level 4 — Claude Code / Codex**: hard reasoning and escalation, as before.
`DecisionPlanner.passThrough` hands everything it does not own to the existing pipeline and `ModelRouter`; a classifier's confidence never replaces approval, verification, risk policy, an `ActionReceipt` or a tool permission.
