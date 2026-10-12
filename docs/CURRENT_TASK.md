# Current Task

Version:
V0.9 — Web Research & Asset Acquisition — **READY FOR MANUAL TEST** (committed on `main`). Base: V0.8 (7339edc), V0.7, V0.6, V0.5, V0.4, V0.3.2, V0.3.1, V0.3, V0.2.1.

Task:
Structured, evidence-backed web research (any topic; Unity assets first) + safe download acquisition into a quarantine + a separate approval-gated import. Research / acquisition / project import / account action / purchase are different authority levels (DEC-088): V0.9 implements the first three and never the last two. Everything runs as ordinary V0.4 tasks. NOT V0.10 (project memory). No tag, no COMPLETE.

State:
IMPLEMENTED · AUTOMATED TESTED (1043 unit tests, `scripts/verify.sh` PASSED, smoke 119/0/2) · REAL TESTED (`--research-live-test` 37/0 on the live public web, a real md5-verified CC0 file in the quarantine) · **MANUAL TEST REQUIRED** (README 344–463). Docs: `docs/WEB_RESEARCH.md`, `docs/ASSET_ACQUISITION.md`, DEC-088…102, KNOWN_ISSUES JARVIS-V09-1…12 and JARVIS-V08-15.

Next Step:
Wait for the user's manual test. Do NOT start V0.10 without explicit approval. V0.8 follow-up still open: rerun `scripts/train_wake_head.sh --quick` on the user's Mac — it now prints the generator log tail on failure (JARVIS-V08-15).

Blocked By:
Nothing.

Notes:
- Git: main only, no tags, no AI co-author trailers (the user's brief overrides the harness attribution reminder).
- Research never runs while JARVIS is idle; no background crawling; no paid search API; no API key; no cookie/password access; no CAPTCHA bypass; the user's real game was never touched by automated tests.
