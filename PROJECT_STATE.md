# JARVIS Project State

> New agent? Read this file first, then `docs/CURRENT_TASK.md`. See `AGENTS.md` for the bootstrap order.

## Current Version

V0.2 — Text conversation + intelligence router (on top of V0.1.1; app version string still `0.1.1`). V0.1 baseline `d827a9e` and V0.1.1 were manually tested by the user (direction approved; one bug found and fixed in `1b64d07`).

## Current Milestone

V0.2: text conversation + deterministic command router + provider boundary (no real AI)

## Status

**V0.2 — READY FOR MANUAL TEST**
(Automated verification passed. V0.2 is not yet manually verified by the user. Do NOT mark COMPLETE or tag, and do NOT start V0.3 / connect any AI provider until the user approves.)

## Current Objective

Hand V0.2 to the user for manual testing of `build/Jarvis.app` (README checklist items 17–22): type commands in English/Turkish, conversation panel, Compact one-line feedback, truthful "provider not connected" replies.

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

## V0.2 additions (IMPLEMENTED · AUTOMATED TESTED · MANUAL TEST REQUIRED)

- **Pipeline (DEC-016):** `InputNormalizer` → `IntelligenceRouter` (command | local reply | worker-required | reasoning-required | unsupported) → `ConversationService` → `CommandExecutor` (windows only via `JarvisWindowControlling`; tasks via `JarvisStore`) → `ConversationStore` → UI. Text is not privileged: voice/LLM will call the same service/router/executor.
- **Deterministic commands, EN + TR:** open report/tasks/system/memory/dashboard/settings; status ("what are you doing?" from real state); pause/resume/stop task; open compact/full, close; clear conversation; hello/thanks. Anything else → classified reasoning/worker → truthful "none is connected yet" (nothing faked/started). Bare ambiguous words need addressing JARVIS.
- **Provider boundary (DEC-017):** `IntelligenceProvider` (streaming, cancellable) + registry, **empty in V0.2**. Subscription-first rule: no API keys, no paid-API code, no ChatGPT/Claude web scraping; `verify.sh` fails on network/API-key/endpoint references. Fully offline.
- **UI (DEC-018):** thin-row Conversation panel on the Dashboard (not a chat app), one-line latest-reply feedback in both command fields (tail-truncated, expires after 20 s, hover for full text), VoiceOver announcement of replies, command field focuses on open. Compact stays 392×448.
- **Fixes along the way:** narrow-layout top bar bug (JARVIS-R10), approval card ordering at minimum size, review findings (JARVIS-R11).

## V0.1.1 additions (IMPLEMENTED · AUTOMATED TESTED)

- **D. HUD exclusivity** (user-reported, fixed): Compact XOR Full enforced in `WindowManager` (DEC-015); 12 smoke checks, mutation-verified.

- **A. Compact HUD fixed geometry:** 392×448 via `CompactHUDLayout`; root cause was `.preferredContentSize`+`fittingSize`; smoke test measures the real frame across 7 states × dev strip on/off × task/none. Inner crossfade 0.2 s (off under Reduce Motion). DEC-014.
- **B. Neural background (Full HUD only):** seeded 45-node graph, bounded pulse simulation, AppKit/Core Graphics display link 5–15 fps by state; paused when hidden, static under Reduce Motion; Compact HUD intentionally has none. DEC-012.
- **C. Global shortcuts:** ⌥⌘ → Compact; ⌥⌘⌘ → Full (second ⌘ within 0.30 s, Compact never flashes first), either ⌘ key, permission-free polling (12 Hz rest / 60 Hz while ⌥ held), ignores ⌥⌘+key/click/Shift/Control; Settings shows them + off switch. DEC-013. **Physical use from another app is MANUAL TEST REQUIRED.**

## In Progress

Nothing. Waiting for user manual verification.

## Pending (outside V0.1)

Everything in `docs/ROADMAP.md` from V0.2 onward — PLANNED, not started.

## Known Issues

See `docs/KNOWN_ISSUES.md`. Headline: VoiceOver labels on custom buttons — MANUAL VERIFICATION REQUIRED; Retina rendering not verified (dev machine screen was 1×).

## Tested

**AUTOMATED TESTED** (`scripts/verify.sh` → `VERIFY PASSED`; 2026-10-10):
- Build (release) OK; bundle `build/Jarvis.app` assembled; ad-hoc signature valid (strict/deep); arm64; Info.plist lints; `LSUIElement=true`.
- 81/81 unit tests (task model, store, state↔task coherence, chord machine, hotkey service, neural graph/simulation, compact constants, **normalization, EN/TR alias routing, intelligence routing + 17 routing regressions, command execution with a fake window controller, conversation flow, provider streaming/cancellation/failure with fake providers, feedback line**).
- Smoke test (real window manager/store/status item): 28 PASS, 0 FAIL, 2 SKIP (in-process accessibility audit — SwiftUI AX tree not materialized without an AX client).
  Covers: status item has image+frame; app survives last-window-close policy; Compact open/close; Full open/close, fits screen, centered, min size enforced; display link running while Full HUD open and stopped when hidden; menu-bar icon timer runs only in animated states; reopen preserves section/activity/steps/clock; **real ESC `NSEvent`** dismisses Full and Compact; `showFullHUD(section: .report)` navigates; all 7 states coherent with task + icon tooltip; pause/resume.
- Permission audit: no `NS*UsageDescription` keys, no entitlements, no permission-gated API usage in sources.
- Console: no stdout/stderr output from the app during smoke/capture/launch runs.
- V0.2 CPU (release, M5, % of one core): idle/closed ≈0.2 % · Compact open Working ≈1.8 % · Full HUD Idle ≈3.3 %, Working ≈11 %, Thinking ≈12 % (no meaningful regression vs V0.1.1; conversation panel adds nothing per frame).
- Resources (release, M5, % of ONE core; V0.1 baseline → V0.1.1):
  idle/HUDs closed ≈0% → ≈0.3% (12 Hz hotkey polling) · Compact open ≈1% → ≈2% (Working) · Full HUD animating ≈9% → Listening ≈10%, Working ≈11%, Thinking ≈12.5% · Full Idle/Approval ≈3% · closed with Working ≈1.6% → ≈1.7% · RSS 40 MB idle, ≈95–110 MB after first HUD open.

**VISUALLY VERIFIED** (in-process captures, `captures/`): Compact (idle/working), Full HUD all 7 states, Tasks/Report/System/Memory sections, Full HUD at minimum size. Screen was 1× (no Retina check).

**REAL-EVENT VERIFIED earlier in recovery** (System Events from the host terminal, no app permission): real menu-bar click opens Compact HUD; second click closes it; real ESC closes Compact HUD.

**MANUAL TEST REQUIRED** (not verified by anyone yet): see "Next Action" and `docs/CURRENT_TASK.md`. Notably: real click on OPEN JARVIS, real ESC on Full HUD, resize by dragging, click-outside dismissal, multi-display, light/dark menu bar, VoiceOver, Retina rendering, overall look & feel.

**MANUALLY VERIFIED BY USER:** nothing yet.

## Important Decisions

See `docs/DECISIONS.md` (DEC-001…DEC-018). Key ones:
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

`main` only; `origin` = https://github.com/n0tnow/Jarvis.git; commits: baseline `d827a9e`, then V0.1.1 commits; **no tag yet** (tag only after user approval — convention to decide with the user: `v0.1.1`). Policy: `AGENTS.md` → Git Workflow, DEC-011.

## Last Updated

2026-10-10 — Git workflow established and verified V0.1 baseline published to origin/main. Status unchanged: READY FOR MANUAL TEST.
