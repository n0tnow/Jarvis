# Current Task

Version:
V0.11 — General Computer Use — **IN PROGRESS** (on `main`, not yet READY). Base: V0.10 (44966ba), V0.9, V0.8, V0.7, V0.6, V0.5, V0.4, V0.3.2, V0.3.1, V0.3, V0.2.1.

Task:
Typed, observable, policy-controlled, verifiable, cancelable interaction with ordinary macOS applications when no stronger structured mechanism exists: capability ladder (typed JARVIS capability → structured integration → controlled CLI → V0.9 browser DOM → macOS Accessibility → window-scoped vision → window-relative coordinates), observe → act → verify, semantic target resolution, consequence-based risk, secure-field/clipboard/terminal/quarantine protections, stale-screen protection, emergency stop. NOT V0.12. No tag, no COMPLETE.

State (checkpoint 2):
IMPLEMENTED · AUTOMATED TESTED (104 Computer tests) · REAL TESTED (`--computer-live-test` 86 pass / 0 fail / 2 skip against a JARVIS-owned fixture app + real Finder/System Settings/Blender): `Sources/Jarvis/Computer/` + `TaskEngine+Computer.swift` (TaskKind.computer, schema v9), conversation/voice route, Computer screen + Settings, fixture app target. NOT YET: verify.sh guards, smoke checks, full-suite regression run, docs (GENERAL_COMPUTER_USE.md, DEC-127…, README checklist), release build verification.

Next Step:
verify.sh guards, smoke checks, regression run, release build, docs and decisions, final live-test evidence, commit.

Blocked By:
Nothing. (Accessibility and Screen Recording are granted to the session that runs the live tests; JARVIS never grants itself anything.)

Notes:
- Git: main only, no tags, no AI co-author trailers (the user's brief overrides the harness attribution reminder).
- Decisions will be recorded as DEC-127… in docs/DECISIONS.md at the docs checkpoint.
