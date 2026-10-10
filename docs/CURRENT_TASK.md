# Current Task

Version:
V0.1.1 (user-requested UX fixes on top of V0.1 baseline `d827a9e`; V0.1 direction already approved by the user)

Task:
(A) fixed-size Compact HUD · (B) ambient neural-network background · (C) ⌥⌘ / ⌥⌘⌘ global shortcuts

State:
READY FOR USER MANUAL TEST

Last Successful Step:
`scripts/verify.sh` → VERIFY PASSED (36/36 unit tests; smoke incl. compact-geometry, neural lifecycle, scripted hotkey→window integration). Captures regenerated. Docs updated. See `PROJECT_STATE.md` for numbers.

Current Step:
Waiting for user manual verification of `build/Jarvis.app` (README → checklist items 14–16).

Next Step:
User tests: (1) Compact HUD never changes size across the 7 states; (2) ⌥⌘ / ⌥⌘⌘ from another app (no Compact flash before Full, no duplicates, 0.3 s feels right?); (3) neural background subtle/readable, static under Reduce Motion. Then decide the tag (`v0.1.1`?). **Do NOT start V0.2 or tag before the user approves.**

Files Being Worked On:
None.

Blocked By:
User manual verification.

Notes:
- Physical global-hotkey use from another app was NOT tested by an agent (JARVIS-011): MANUAL TEST REQUIRED. Chord logic and service→WindowManager path are automated with scripted modifier timelines.
- Still manual from V0.1: real OPEN JARVIS click, VoiceOver names (JARVIS-001), Retina, second display.
- Build: `scripts/build_app.sh`; verify: `scripts/verify.sh`; captures: `build/Jarvis.app/Contents/MacOS/Jarvis --capture captures` (git-ignored).
- Git: `main` only, linear; V0.1.1 commits pushed to origin/main; no tags.
