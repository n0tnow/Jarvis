# Current Task

Version:
V0.3 (real intelligence providers) — READY FOR MANUAL TEST

Task:
Hand V0.3 to the user. Nothing else is in progress. V0.4 (persistent task engine / autonomous workers) is NOT started and needs explicit approval.

State:
V0.3 A research ✅ · B discovery ✅ · C ProviderManager ✅ · D Claude Code ✅ · E Codex ✅ · F streaming ✅ · G cancellation ✅ · H Settings/UI ✅ · I REAL test through the JARVIS stack ✅ (both providers) · J verification + docs ✅

Last Successful Step:
`scripts/verify.sh` PASSED (183 unit tests, 85 smoke PASS/0 FAIL/2 SKIP, focused provider policy, idle CPU ≈0.2 %); `--provider-live-test` PASSED for Claude Code and Codex.

Current Step:
Commit/push done (see git log). Waiting for manual test.

Next Step:
User manual test (README items 26–32). Then, only with approval: tag decision and V0.4.

Files Being Worked On:
None.

Blocked By:
Nothing.

Notes:
- Subscription-first (DEC-017/020): no API keys, no paid endpoints, no scraping, no credential access; the user's own signed-in `claude`/`codex` are driven as child processes.
- Do NOT mark V0.3 COMPLETE or tag until the user approves. Git: main only, no tags, no AI trailers.
