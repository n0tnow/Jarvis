# Current Task

Version:
V0.3.2 — Agent Observatory & Live Consoles. Base: V0.3.1, V0.3, V0.2.1.

Task:
Make JARVIS observable (provider cards, runs, sanitized live console, truthful progress, history, timeline, Stop, restart reconciliation) behind one central sanitization boundary. NOT V0.4. No tag.

State:
**V0.3.2 — READY FOR MANUAL TEST.** A recovery ✅ · B security boundary ✅ · C data plane ✅ · D data-plane tests ✅ · E UI ✅ (Agents section, console, history, timeline, Compact strip) · F real tests ✅ (`--intelligence-live-test` 35/35) / perf ✅ / `verify.sh` ✅ (377 tests, smoke 89/0/2) / docs ✅. Nothing is MANUALLY VERIFIED.

Last Successful Step:
`scripts/verify.sh` → VERIFY PASSED; live test 35 passed, 0 failed; captures show Compact still 392×448.

Next Step:
User manual test: README items 40–66. Do NOT start V0.4 and do NOT tag until the user approves.

Blocked By:
Nothing.

Notes:
- Reference: `docs/AGENT_OBSERVABILITY.md`, DEC-029…032.
- Security incident carry-over: a V0.3.1 `credential.list` probe printed an OpenCode Go key into a tool output (user told to rotate). JARVIS only ever calls `opencode api model.list`; verify.sh forbids credential/integration operation names; never add an API console.
- Git: main only, no tags, no AI trailers.
