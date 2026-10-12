# Current Task

Version:
V0.10 — Project Memory — **IN PROGRESS** (working on `main`). Base: V0.9 (459468f, READY FOR MANUAL TEST), V0.8, V0.7, V0.6, V0.5, V0.4, V0.3.2, V0.3.1, V0.3, V0.2.1.

Task:
Derived, provenance-backed, queryable project knowledge (decisions, constraints, failures, lessons, research/asset decisions, facts) with contradiction/supersession/staleness handling, hybrid retrieval (structured + lexical + local semantic), a bounded per-agent Context Builder, user remember/correct/forget/pin, a Memory screen, and bootstrap from the project's own docs. Memory is a DERIVED layer: history tables stay history; current deterministic truth outranks memory; memory is never authority. NOT V0.11 (computer use). No tag, no COMPLETE.

Done so far (committed checkpoints):
Embedding research + selection (5 ONNX candidates + Apple NaturalLanguage benchmarked on a 62-memory / 48-query TR/EN/mixed corpus; MiniLM-L12 int8 selected, hybrid weight 0.8 semantic) · schema v8 · `Sources/Jarvis/Memory/` model, text utils, safety gates, `MemoryService` (curator: secret/poison/authority/trivial gates, provenance, dedupe, contradiction, supersession, dispute, truth reconciliation, staleness, correction, forget, restore, pin, lessons consolidation), project identity (Git root commit → Unity GUID → path), truth probes, intent parser (EN/TR), embedding helper (`scripts/setup_memory_ai.sh`, `jarvis_embed_worker.py`, `EmbeddingHostController`), derived `MemoryIndex` (sync, atomic rebuild, corrupt/model-change handling), hybrid `MemoryRetriever`, `ProjectContextBuilder` (agent profiles, budgets, truth/memory/uncertainty/inference layers) · 57 memory unit tests.

Remaining: ingestion extractors (docs/bootstrap, tasks, research, assets) · wiring (AppContext, `runJob` injection + audit of memory ids, ConversationService memory questions/remember/correct/forget, voice via the same path, V0.5/V0.9 touch points) · answers with citations · Memory screen + Settings + diagnostics · `--memory-live-test` (bootstrap the real JARVIS repo, real TR/EN queries) · verify.sh guards · docs (`PROJECT_MEMORY.md`, DEC-104…, README checklist) · full verify · commits + push.

Next Step:
Continue the list above. Do NOT start V0.11.

Blocked By:
Nothing.

Notes:
- Git: main only, no tags, no AI co-author trailers (the user's brief overrides the harness attribution reminder).
- Memory never runs while idle: no timers, no re-embedding churn; embedding helper starts on demand and unloads after 120 s idle / memory pressure.
- Selected embedding model: sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2 @ e8f8c211226b894fcb81acc59f3b34ba3efd5f42 (Apache-2.0, int8 ONNX, 118 MB).
