# Current Task

Version:
V0.1.1 (V0.1 + user-requested UX fixes; V0.1 baseline d827a9e was manually tested by the user, direction approved)

Task:
V0.1.1 — (A) fixed-size Compact HUD, (B) ambient neural-network background, (C) modifier-only global hotkeys ⌥⌘ / ⌥⌘⌘

State:
IN PROGRESS

Last Successful Step:
Automated verification completed: `scripts/verify.sh` → VERIFY PASSED (17/17 unit tests; smoke 28 PASS / 0 FAIL / 2 SKIP; signature, plist, permission audit, idle CPU all PASS). Screenshots re-captured from the current build. All project-memory docs written.

Current Step:
A DONE (commit: fix(compact-hud)): Compact HUD is now a canonical fixed 392×448 (`CompactHUDLayout.size`); root cause was `sizingOptions=.preferredContentSize` + `fittingSize` in WindowManager. Smoke test measures the real frame across all 7 states. B DONE (commit: feat(hud) neural background; DEC-012; 24/24 unit tests; smoke covers lifecycle/Reduce Motion). NEXT: C (⌥⌘ / ⌥⌘⌘ hotkeys), then docs + verify + captures.

Next Step:
User follows the "Manual test checklist" in `README.md` and reports results. Only after the user approves V0.1: update PROJECT_STATE (MANUALLY VERIFIED), then — with explicit approval — plan V0.2.
**A new agent must NOT start V0.2 or add features before that approval.**

Files Being Worked On:
None.

Blocked By:
User manual verification.

Notes:
- Manual checks still required: real OPEN JARVIS click, physical ESC on Full HUD, resize drag, click-outside dismissal, VoiceOver names/announcement (JARVIS-001), Retina/second display, overall look & feel.
- Real-click System Events automation was declined twice by the user and not retried (recorded as MANUAL TEST REQUIRED).
- Build: `scripts/build_app.sh` (no Xcode on this machine). Verify: `scripts/verify.sh`. Screenshots: `captures/` (git-ignored, not in the repo; regenerate with `build/Jarvis.app/Contents/MacOS/Jarvis --capture captures`).
- Git: `main` only, remote `origin` = https://github.com/n0tnow/Jarvis.git. Baseline commit `feat(v0.1): establish native macOS Jarvis foundation` pushed. **No `v0.1` tag** — tag only after the user approves V0.1. Policy: AGENTS.md → Git Workflow.
