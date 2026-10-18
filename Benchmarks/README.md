# Benchmarks (V1.0 decision milestone)

* `decision_corpus.json` — hand-written ground truth for command understanding (`jarvis.decision-corpus/1`): typed intent, action, target, flags, gate and whether the Level-0 grammar is expected to decide the case exactly. No model defines or edits it. Validated by `DecisionCorpusValidator`; measured by `DecisionBenchmarkRunner` (any `DecisionProviding`: the deterministic grammar, a mock, a live classifier in Phase B). The deterministic cases were written next to the grammar — add fresh held-out utterances before trusting any accuracy figure.
* `local_model_probes.json` — deterministic qualitative probes for the local conversational model (`jarvis.local-model-probes/1`): string-level rubric checks over eight categories. Turkish naturalness, mixed-language quality and tone are human review fields. Run by `LocalModelBenchmark` on the user's Mac in Phase B; `DryRunModelRunner` exercises the harness without a model and reports every measurement as NOT MEASURED.

Procedure and acceptance: `docs/V1_DECISION_INTELLIGENCE_PHASE_B.md`.
* `decision_heldout.json` — the 78 Phase B held-out cases (SPENT for tuning, see docs/V1_RELIABILITY_PASS.md).
* `decision_adversarial.json` — adversarial set A (322), written before the semantic lexicon; Turkish morphology, polite forms, typed referents, corrections, approvals, must-not-execute negatives. Labels carry `ambiguous` (the right behaviour is to ask) and the tag `mustNotExecute`.
* `decision_blind.json` — blind set B (199), written after A and the lexicon were frozen and measured once. Never edit a label; write a NEW blind set instead of reusing a spent one.
* Measure with the headless tool: `Jarvis --decision-benchmark --adversarial Benchmarks/decision_adversarial.json --blind Benchmarks/decision_blind.json --project-names "Hamam,Hammam,Turkish Hammam Simulator"` (the registry names are a stand-in for bare project names, never part of the grammar). New metrics: executing false positives, must-not-execute held, ambiguity asked.

