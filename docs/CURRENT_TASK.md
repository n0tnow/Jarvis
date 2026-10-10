# Current Task

Version:
V0.2 — Text conversation + intelligence router (on V0.1.1; V0.1.1 final fix `1b64d07` already pushed)

Task:
V0.2 implemented: conversation domain/store, deterministic EN/TR command router, executor, IntelligenceRouter, provider boundary (no provider registered), Full HUD conversation panel, Compact one-line feedback.

State:
READY FOR USER MANUAL TEST

Last Successful Step:
`scripts/verify.sh` → VERIFY PASSED (81 unit tests; smoke incl. 7 V0.2 acceptance scenarios on the real WindowManager; no network/API-key code). Captures regenerated.

Current Step:
Waiting for the user's manual test of `build/Jarvis.app` (README checklist items 17–22, plus 14–16 from V0.1.1).

Next Step:
User reports. Only after approval: decide tags (`v0.1.1`/`v0.2`?) and plan V0.3 (subscription-backed provider — verify current official tooling first; NO API keys, NO paid-API code, NO web scraping). **Do NOT start V0.3 or connect a provider before that.**

Files Being Worked On:
None.

Blocked By:
User manual verification.

Notes:
- Manual still required: typing real commands (EN/TR), Compact feedback readability, VoiceOver announcement of replies/approval (JARVIS-001), physical global hotkeys (JARVIS-011), real OPEN JARVIS click, Retina, second display.
- Build `scripts/build_app.sh`; verify `scripts/verify.sh`; captures `build/Jarvis.app/Contents/MacOS/Jarvis --capture captures` (git-ignored).
- Git: `main` only, linear; no tags; no AI trailers on new commits.
