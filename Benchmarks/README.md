# Benchmarks (V1.0 decision milestone)

* `decision_corpus.json` — hand-written ground truth for command understanding (`jarvis.decision-corpus/1`): typed intent, action, target, flags, gate and whether the Level-0 grammar is expected to decide the case exactly. No model defines or edits it. Validated by `DecisionCorpusValidator`; measured by `DecisionBenchmarkRunner` (any `DecisionProviding`: the deterministic grammar, a mock, a live classifier in Phase B). The deterministic cases were written next to the grammar — add fresh held-out utterances before trusting any accuracy figure.
* `local_model_probes.json` — deterministic qualitative probes for the local conversational model (`jarvis.local-model-probes/1`): string-level rubric checks over eight categories. Turkish naturalness, mixed-language quality and tone are human review fields. Run by `LocalModelBenchmark` on the user's Mac in Phase B; `DryRunModelRunner` exercises the harness without a model and reports every measurement as NOT MEASURED.

Procedure and acceptance: `docs/V1_DECISION_INTELLIGENCE_PHASE_B.md`.
