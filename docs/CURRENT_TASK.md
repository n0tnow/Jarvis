# Current Task

Version:
V0.11 — General Computer Use — **READY FOR MANUAL TEST** (committed on `main`). Base: V0.10 (44966ba), V0.9, V0.8, V0.7, V0.6, V0.5, V0.4, V0.3.2, V0.3.1, V0.3, V0.2.1.

Task:
Typed, observable, bounded, policy-controlled, verifiable and cancelable interaction with ordinary macOS applications when no stronger structured mechanism exists. A capability LADDER decides first (V0.4 project tools > V0.6 Unity bridge > controlled CLI > V0.9 browser DOM > macOS Accessibility > window-scoped on-device vision > window-relative coordinates); Computer Use is an ordinary V0.4 task (`TaskKind.computer`) and never an authority of its own. NOT V0.12 (advanced multi-agent / routing). No tag, no COMPLETE.

State:
IMPLEMENTED · AUTOMATED TESTED (1258 unit tests / 176 suites, 120 of them Computer tests on a virtual macOS; `scripts/verify.sh` PASSED; smoke 132/0/2; idle 0.02 CPU-s per 8 s at 73 MB) · REAL TESTED (`--computer-live-test`, release build: 88 passed / 0 failed / 2 skipped — real Accessibility against the JARVIS-owned fixture app, a real on-device-OCR vision click on three displays incl. Retina, real Finder / System Settings / Blender navigation, cancel + emergency-stop + hard-kill/resume, secure-field / purchase / terminal / injection fixtures, spoken-equivalent route) · **MANUAL TEST REQUIRED** (README 584–703). Docs: `docs/GENERAL_COMPUTER_USE.md`, DEC-127…156, KNOWN_ISSUES JARVIS-V11-1…18. Not validated: Xcode (not installed), a running Unity Editor, model vision (does not exist), the physical ⌃⌥⌘ chord, model-assisted planning on a real model.

Next Step:
Wait for the user's manual test. Do NOT start V0.12 without explicit approval. Accessibility must be allowed by the user for `Jarvis.app` (System Settings → Privacy & Security → Accessibility); JARVIS never grants it to itself.

Blocked By:
Nothing.

Notes:
- Git: main only, no tags, no AI co-author trailers (the user's brief overrides the harness attribution reminder).
- Nothing in the Computer layer runs while idle: no AX traversal, no capture, no clipboard read; the only timer is the ⌃⌥⌘ emergency sampler during a session.
- The live test needs the session that runs it to have Accessibility (and Screen Recording for the vision part): it reports `BLOCKED — ACCESSIBILITY PERMISSION REQUIRED` otherwise and weakens nothing.
