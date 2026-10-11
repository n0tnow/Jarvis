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

A free model is a candidate only if: free-pool member (DEC-022) with fresh verification · engine ready, no cooldown (engine or model) · privacy gate (sensitive never; project code ⇒ zero-retention only) · fits context · **benchmark passed for the task's group** (Auto only) · ranked by pass rate, then median latency, then id.

## Explicit modes
`Local`, `OpenCode Free`, `Claude Code`, `Codex`: single engine, **no fallback**. Local refuses ineligible tasks; OpenCode Free refuses when no verified-free model qualifies or the task is sensitive; Claude/Codex refuse when not ready. Refusals are explained to the user.

## Reasons
`RoutingDecision.reasonJSON` (sorted keys, strings only), e.g. `{"category":"coding","coding":"true","codingBenchmarkPassed":"true","dataPolicy":"zeroRetention","freeVerified":"true","freeVerifiedAt":"…","localModelIneligible":"true","localViolations":"requiresCoding,…","mode":"auto","outcome":"selected","providerReady":"true","selected":"opencode/…","tier":"development-free-first","rejected.local":"policy:…"}`. Stored with every agent run.

## Escalation (bounded)
`fallbacks` is the ordered remaining eligible chain computed up front. `AgentRunner` uses it with `EscalationPolicy` (default: 1 repair attempt on the same model after a validation failure, then escalate once down the chain; hard cap on total attempts). No loops, no re-routing mid-run.

## Cooldown
`CooldownPolicy`: from the 2nd consecutive failure, 60 s · 2^(n−2), capped at 30 min; persisted in `provider_health`; a success resets it. A broken model is therefore not retried every few seconds.
