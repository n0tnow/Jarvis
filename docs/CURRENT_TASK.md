# Current Task

Version:
V0.11 — General Computer Use — **IN PROGRESS** (on `main`, not yet READY). Base: V0.10 (44966ba), V0.9, V0.8, V0.7, V0.6, V0.5, V0.4, V0.3.2, V0.3.1, V0.3, V0.2.1.

Task:
Typed, observable, policy-controlled, verifiable, cancelable interaction with ordinary macOS applications when no stronger structured mechanism exists: capability ladder (typed JARVIS capability → structured integration → controlled CLI → V0.9 browser DOM → macOS Accessibility → window-scoped vision → window-relative coordinates), observe → act → verify, semantic target resolution, consequence-based risk, secure-field/clipboard/terminal/quarantine protections, stale-screen protection, emergency stop. NOT V0.12. No tag, no COMPLETE.

State (checkpoint 1):
IMPLEMENTED · AUTOMATED TESTED (82 tests): `Sources/Jarvis/Computer/` — model, policy (consequence classifier, shortcuts, paths, text), capability resolver + EN/TR goal parser, target resolver, coordinates/stale checks, AX backend, window-scoped capture + on-device OCR vision, executor (virtual-macOS tested). NOT YET: task-engine integration, persistence (schema v9), UI, settings, fixture app, live test, verify.sh guards, docs.

Next Step:
Task-engine integration (TaskKind.computer, step type, capabilities, persistence, restart → INTERRUPTED), conversation/voice route, Computer screen + Settings, fixture app, `--computer-live-test`, guards, docs.

Blocked By:
Nothing. (Accessibility and Screen Recording are granted to the session that runs the live tests; JARVIS never grants itself anything.)

Notes:
- Git: main only, no tags, no AI co-author trailers (the user's brief overrides the harness attribution reminder).
- Decisions will be recorded as DEC-127… in docs/DECISIONS.md at the docs checkpoint.
