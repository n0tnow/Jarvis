# JARVIS Project State

> New agent? Read this file first, then `docs/CURRENT_TASK.md`. See `AGENTS.md` for the bootstrap order.

## Current Version

V0.1 (app version string `0.1.0`)

## Current Milestone

Native macOS Foundation + HUD

## Status

**V0.1 — READY FOR MANUAL TEST**
(Automated verification passed. Not manually verified by the user. Do NOT mark COMPLETE and do NOT start V0.2 until the user approves.)

## Current Objective

Hand V0.1 to the user for manual UI/UX testing of `build/Jarvis.app`.

## Completed (IMPLEMENTED)

- Native Swift/SwiftUI/AppKit menu-bar agent (no Dock icon), zero third-party packages, macOS 14+ / arm64.
- `JarvisState` (idle, listening, thinking, working, waitingForApproval, completed, error) as the single state driving every surface.
- Task model (`JarvisTask`, steps, statuses, pause-aware clock); progress derived only from step statuses.
- In-memory activity feed (capped at 200), demo agents/tools/project panels (clearly tagged DEMO / NOT CONNECTED).
- Menu bar `NSStatusItem`: state-specific template glyphs (distinct shapes), ~2 Hz timer only in animated states, right-click menu (Open / Compact / Settings / Quit).
- Compact HUD (borderless floating panel): identity, state, active task + step + elapsed + step-segmented progress, OPEN JARVIS / PAUSE-RESUME / STOP, command field, dev state strip.
- Full HUD (large borderless resizable window, centered, screen-adaptive, min 980×620 enforced): Dashboard (System/Project/Tasks · Core · Activity/Agents/Tools), Tasks, System; Report and Memory are PLANNED placeholders (V0.8). Section navigation via `HUDState.section`.
- JARVIS Core visualization: Core Graphics renderer driven by a capped `CADisplayLink` that exists only while the HUD is visible and Reduce Motion is off.
- Window-management layer (`JarvisWindowControlling` / `WindowManager`): show/hide/toggle compact, show(section)/hide/bringForward full, settings.
- Demo/dev mode: state simulator (compact + full), reset demo task, add demo event; demo state switching keeps the task coherent (Completed completes it, Error fails it, Idle pauses it).
- Local command field (no AI): records command in activity feed; from idle runs a harmless thinking→completed demo transition.
- Settings: Reduce Motion, Show Developer Controls, Launch at Login (disabled placeholder, NOT implemented).
- Build/verify tooling: `scripts/build_app.sh`, `scripts/test.sh`, `scripts/verify.sh`; dev launch args (`--smoke-test`, `--capture`, …).
- Persistent memory docs (this set).

## In Progress

Nothing. Waiting for user manual verification.

## Pending (outside V0.1)

Everything in `docs/ROADMAP.md` from V0.2 onward — PLANNED, not started.

## Known Issues

See `docs/KNOWN_ISSUES.md`. Headline: VoiceOver labels on custom buttons — MANUAL VERIFICATION REQUIRED; Retina rendering not verified (dev machine screen was 1×).

## Tested

**AUTOMATED TESTED** (`scripts/verify.sh` → `VERIFY PASSED`; 2026-10-10):
- Build (release) OK; bundle `build/Jarvis.app` assembled; ad-hoc signature valid (strict/deep); arm64; Info.plist lints; `LSUIElement=true`.
- 17/17 unit tests (task model, store, command handler, state↔task coherence).
- Smoke test (real window manager/store/status item): 28 PASS, 0 FAIL, 2 SKIP (in-process accessibility audit — SwiftUI AX tree not materialized without an AX client).
  Covers: status item has image+frame; app survives last-window-close policy; Compact open/close; Full open/close, fits screen, centered, min size enforced; display link running while Full HUD open and stopped when hidden; menu-bar icon timer runs only in animated states; reopen preserves section/activity/steps/clock; **real ESC `NSEvent`** dismisses Full and Compact; `showFullHUD(section: .report)` navigates; all 7 states coherent with task + icon tooltip; pause/resume.
- Permission audit: no `NS*UsageDescription` keys, no entitlements, no permission-gated API usage in sources.
- Console: no stdout/stderr output from the app during smoke/capture/launch runs.
- Resources (release, M5): idle/closed ≈ 0% CPU, ~40 MB; Compact open ≈ 1%; Full HUD open + animating ≈ 9% of one core; Full HUD closed with Working state ≈ 1.6% (menu-bar icon timer only).

**VISUALLY VERIFIED** (in-process captures, `captures/`): Compact (idle/working), Full HUD all 7 states, Tasks/Report/System/Memory sections, Full HUD at minimum size. Screen was 1× (no Retina check).

**REAL-EVENT VERIFIED earlier in recovery** (System Events from the host terminal, no app permission): real menu-bar click opens Compact HUD; second click closes it; real ESC closes Compact HUD.

**MANUAL TEST REQUIRED** (not verified by anyone yet): see "Next Action" and `docs/CURRENT_TASK.md`. Notably: real click on OPEN JARVIS, real ESC on Full HUD, resize by dragging, click-outside dismissal, multi-display, light/dark menu bar, VoiceOver, Retina rendering, overall look & feel.

**MANUALLY VERIFIED BY USER:** nothing yet.

## Important Decisions

See `docs/DECISIONS.md` (DEC-001…DEC-011). Key ones:
- Native Swift/SwiftUI/AppKit only (no Electron/React/Tauri/web UI).
- UI/window state (`HUDState`) separated from application/task state (`JarvisStore`); closing HUDs never touches tasks.
- All window control goes through `JarvisWindowControlling`.
- No AI, no network, no permissions in V0.1; no paid API dependency without explicit user approval.
- Demo data lives only in `Services/Demo`.

## Do Not Change Without Reason

- `JarvisWindowControlling` protocol shape and `WindowManager` ownership of all NSWindow logic.
- `JarvisStore` ↔ `HUDState` split.
- AppKit `CoreNSView` renderer (SwiftUI `TimelineView`/`Canvas` cost ~25–30% CPU — see DEC-006).
- Min-size enforcement via `windowWillResize` (NSHostingView overwrites `contentMinSize`).
- Zero-permission posture of V0.1 (Info.plist has no usage strings; no entitlements).

## Files Changed In Current Milestone

Everything (baseline commit `feat(v0.1): establish native macOS Jarvis foundation`). Key areas: `Package.swift`, `Sources/Jarvis/{App,Core,Models,Services,UI}`, `Tests/JarvisTests`, `Resources/Info.plist`, `scripts/`, `docs/`, root `*.md`.

## Current Blocker

None.

## Next Action

**Wait for the user's manual V0.1 test** (checklist in `README.md` → "Manual test checklist"). Do not begin V0.2 until the user approves V0.1.

## Git

`main` only; `origin` = https://github.com/n0tnow/Jarvis.git; baseline commit pushed; **no `v0.1` tag yet** (tag only after user approval). Policy: `AGENTS.md` → Git Workflow, DEC-011.

## Last Updated

2026-10-10 — Git workflow established and verified V0.1 baseline published to origin/main. Status unchanged: READY FOR MANUAL TEST.
