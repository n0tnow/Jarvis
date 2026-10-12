# Current Task

Version:
V0.10 — Project Memory — **READY FOR MANUAL TEST** (committed on `main`). Base: V0.9 (459468f), V0.8, V0.7, V0.6, V0.5, V0.4, V0.3.2, V0.3.1, V0.3, V0.2.1.

Task:
Derived, provenance-backed, queryable project knowledge (decisions, constraints, failures, lessons, research/asset decisions, facts) with contradiction / supersession / staleness handling, hybrid Turkish/English retrieval on a rebuildable local index, a bounded per-agent Context Builder, remember / correct / forget / pin, a Memory screen and bootstrap from the project's own docs. Memory is DERIVED (history stays history), current project truth outranks it, and it is never authority. NOT V0.11 (computer use). No tag, no COMPLETE.

State:
IMPLEMENTED · AUTOMATED TESTED (1138 unit tests / 159 suites, `scripts/verify.sh` PASSED, smoke 125/0/2) · REAL TESTED (`--memory-live-test` 73/73: real SQLite, the real local embedding helper, the actual JARVIS repository as corpus (321 memories in 2.3 s), real TR/EN/mixed questions, contradiction / correction / forget / secret / web-poison fixtures, index rebuild / cancel / corruption, restart, memory pressure, idle, quit cleanup) · **MANUAL TEST REQUIRED** (README 464–583). Docs: `docs/PROJECT_MEMORY.md`, DEC-104…126, KNOWN_ISSUES JARVIS-V10-1…10.

Next Step:
Wait for the user's manual test. Do NOT start V0.11 without explicit approval. Optional one-time setup for meaning-based search: `scripts/setup_memory_ai.sh` (Project Memory works without it, with keyword + structured search).

Blocked By:
Nothing.

Notes:
- Git: main only, no tags, no AI co-author trailers (the user's brief overrides the harness attribution reminder).
- Memory never runs while idle: no timers, no re-embedding; the embedding helper starts on demand and unloads after 120 s idle / under memory pressure.
- Selected embedding model: sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2 @ e8f8c211226b894fcb81acc59f3b34ba3efd5f42 (Apache-2.0, int8 ONNX, 118 MB), chosen by measurement among 5 ONNX candidates + Apple NaturalLanguage.
