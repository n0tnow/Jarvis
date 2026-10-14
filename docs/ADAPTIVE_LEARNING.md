# Adaptive Learning (V0.14)

Status: IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (`--adaptive-live-test`) · MANUAL TEST REQUIRED (README 1000+).

JARVIS learns from its own recorded work. **Learning is data, never authority** (DEC-215): a learned lesson, rule, workflow, skill or routing nudge can add a requirement, a warning or a preference — it can never approve, grant a capability, install, delete, send, purchase, weaken a safety rule or change the sandbox. The V0.12 orchestrator stays the only orchestrator; there is no `SelfImprovementOrchestrator`.

## Pipeline

1. **Signals** (`SignalExtractor`) — derived from rows JARVIS already stores: task outcomes and steps, repair attempts, experiments, asset evaluations, computer sessions, proposal decisions, agent runs, MCP activity. Idempotent per source; every signal carries an *episode* (the independence unit — three signals from one task count once).
2. **Patterns** (`PatternDetector`) — deterministic. Documented thresholds (`LearningThresholds`): ≥ 3 independent episodes for any candidate, ≥ 3 successes for a workflow, ≥ 3 sessions for a capability gap, ≥ 4 runs for a routing nudge, 90-day window. Confidence = n/(n+2) with a 30-day half-life and a contradiction factor. One weak event never creates anything.
3. **Admission** — ONE door, `LearningService.admit`: secret gate → authority gate → injection gate → rule vocabulary → evidence must resolve to real rows → overgeneralisation (narrow scope 3 / broad scope 6 episodes, counter-evidence ratio 0.25) → dedupe / cooldown. Every refusal is audited with its reason. A rejected candidate is not proposed again for 14 days and only if its evidence doubles.
4. **Lifecycle** — OBSERVED → CANDIDATE → TESTING → VALIDATED → PROPOSED → APPROVED → ACTIVE, with REJECTED / SUPERSEDED / DISABLED / RETIRED. Rules and workflows must pass `LearningTester` before they can be proposed. Activation is a request decided in the HUD (`AdaptiveDecisionService`, source `hud` only). Optional standing auto-promotion exists only for LOW-risk workflows and is OFF by default.
5. **Corrections** — "No, do it this way" (EN/TR) is recorded as a durable cue; it becomes a candidate only through the same thresholds.

Kinds: lesson, rule, preference, workflow, routingAdjustment, capabilityGap, mcpRecommendation, skillRecommendation, sourceCodeImprovement, knownLimitation.

## Rules (closed vocabulary)

A learned rule is a structured record, not code. Seven actions: `requireExperiment`, `requireExtraValidation`, `requireIndependentReview`, `preferWorkflow`, `avoidSource`, `addWarning`, `preferCapability`; three comparisons; scope global / project / task-kind. Evaluation (`RuleEngine`, narrowest scope first) can only **add** requirements. Rules can be disabled, re-enabled, reverted to the previous definition (history kept) and retired from the Learning screen. Rule text that names approval, install, delete, send, purchase, sandbox or shell is refused at admission.

## Where learning is used

* Planning (`TaskEngine+Orchestration`): `learnedContext` and `applyLearnedRequirements` add validation / review / experiment steps; an active Skill whose triggers match the goal supplies the starting template (the normal graph validator and role contracts still apply).
* Asset evaluation: a rule can require a disposable-project experiment or add a warning.
* Routing: `RoutingAdjustment` nudges are bounded (|bias| ≤ 0.2), only order providers that are already eligible (price, privacy, security first) and are never read for an explicit provider choice.
* Capability gaps: repeated local-vision fallbacks, missing tools etc. become a *gap* candidate with a recommendation (native, Skill or MCP) — never an install.

## Storage and privacy

SQLite v13: signals, candidates, evidence refs, rules, rule revisions, skills, audit, requests, improvement proposals. No blob, image, transcript or reasoning column; text is sanitised on write. Memory (V0.10) is separate: memory cannot activate learning and learning never writes memory.

## Idle

Nothing runs on a timer. Extraction starts from a user request ("what did you learn?"), a finished task, or a live test. See `scripts/guards_v14.sh`.

## Tests

Unit: `AdaptiveLearningTests`, `AdaptiveEngineTests`, `AdaptiveAssistantTests`. Real: `--adaptive-live-test` sections learning, gap, rules, workflow, selfimprove, rejection, overlearning, security, soak, ui (labels REAL / ENGINE / POLICY in the output).
