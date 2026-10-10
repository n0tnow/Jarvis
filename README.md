# JARVIS

A native macOS menu-bar AI operating layer (long-term). **V0.1 is only the application foundation + HUD**: native shell, state architecture, Compact HUD, Full HUD, demo data. There is **no AI, no voice, no network, and no macOS permission request** in this version.

- **Version:** V0.1 (`0.1.0`) — **READY FOR MANUAL TEST** (not yet manually verified by the user)
- Handoff for agents: `PROJECT_STATE.md`, `AGENTS.md` (includes the Git workflow: `main` only, linear history)

## Requirements

- macOS 14+ on Apple Silicon (built/tested on macOS 26.4, M5)
- Swift 6.x toolchain / Command Line Tools. **Xcode is not required** (and wasn't installed on the dev machine).

## Build, run, test

```bash
scripts/build_app.sh          # builds build/Jarvis.app (release, ad-hoc signed)
open build/Jarvis.app         # menu bar icon appears (no Dock icon)
scripts/verify.sh             # full automated verification
scripts/test.sh               # unit tests only
```

Quit: right-click the menu bar icon → Quit JARVIS (or ⋯ menu in the Compact HUD).

## Current features

| Feature | Status |
|---|---|
| Menu bar item with state-specific glyphs | IMPLEMENTED · AUTOMATED TESTED (partial) · MANUAL TEST REQUIRED |
| Compact HUD (state, active task, step, elapsed, progress, Open/Pause/Stop, command) | IMPLEMENTED · MANUAL TEST REQUIRED |
| Full HUD (Dashboard, Tasks, System; Report/Memory placeholders) | IMPLEMENTED · MANUAL TEST REQUIRED |
| JARVIS Core visualization for all 7 states | IMPLEMENTED · VISUALLY VERIFIED (screenshots) |
| Window-management layer for future UI self-control | IMPLEMENTED · AUTOMATED TESTED |
| Demo task, activity feed, agents/tools panels (DEMO) | IMPLEMENTED |
| Developer state simulator | IMPLEMENTED |
| Settings (Reduce Motion, Developer Controls) | IMPLEMENTED |
| Launch at Login | PLANNED (disabled placeholder) |
| Report view, Memory view | PLANNED (V0.8) |
| Text conversation, LLM, workers, task engine, voice, Unity MCP, browser/computer control | PLANNED (V0.2+) — see `docs/ROADMAP.md` |

## Architecture overview

`JarvisStore` (what JARVIS is doing: state, tasks, activity) is separate from `HUDState` (which windows/sections are showing). Windows are controlled only through `JarvisWindowControlling`/`WindowManager`. Details: `docs/ARCHITECTURE.md`.

## Directory structure

```
Package.swift                 SwiftPM manifest (no dependencies)
Resources/Info.plist          LSUIElement agent, no usage strings
Sources/Jarvis/
  App/        entry point, AppContext (composition root), launch options, dev smoke test / capture
  Core/       JarvisState, JarvisStore, HUDState, Preferences, observation bridge
  Models/     JarvisTask, ActivityEvent, display slots
  Services/   window management, local command handler, Demo/ (demo data only)
  UI/         Theme, MenuBar, CompactHUD, FullHUD, Components, VisualEffects, Settings
Tests/JarvisTests/            unit tests (Swift Testing)
scripts/                      build_app.sh, test.sh, verify.sh
docs/                         architecture, decisions, roadmap, issues, log, current task
captures/                     dev screenshots (git-ignored)
```

## Known limitations

See `docs/KNOWN_ISSUES.md`. Notably: no persistence (in-memory only), demo data only, custom-button VoiceOver labels need a manual check, Retina rendering unverified, dev tooling is compiled into the release binary.

## Next milestone

V0.2 — text conversation + command router. **Do not start until the user approves V0.1.**

## Manual test checklist (V0.1)

1. `scripts/build_app.sh && open build/Jarvis.app` — an icon appears in the menu bar; no Dock icon; **no permission dialog**.
2. Click the icon → Compact HUD opens under it. Click the icon again → closes. Open it, press **ESC** → closes. Open it, click elsewhere → closes.
3. In Compact HUD click **OPEN JARVIS** → Full HUD opens, centered, in front. Compact HUD is gone.
4. Press **ESC** (and try the **CLOSE** button, and ⌘W) → Full HUD closes; menu bar icon is still there.
5. Reopen Compact → OPEN JARVIS again → the demo task is where you left it (Multiplayer Synchronization, step 4/6).
6. Click each state chip in the DEV · STATE SIMULATOR strip (Idle, Listening, Thinking, Working, Approval, Complete, Error). Check: core visual, state chip, task chip and menu bar icon all change coherently; Complete returns to Idle after ~6 s; Approval shows Approve/Deny.
7. Compact HUD: **PAUSE** → status PAUSED and clock stops; **RESUME**; **STOP** → "No active task". Dev strip → **RESET DEMO TASK** (Full HUD) restores it.
8. Type `test` + Return in either command field → appears in Activity feed, brief Thinking → Complete.
9. Full HUD: switch tabs (Dashboard / Tasks / Report / System / Memory). Drag the window edges to resize; it must not go below ~980×620 and nothing should overlap or clip badly. Move/drag it by its background.
10. Right-click the menu bar icon → menu works (Open JARVIS, Settings…, Quit). Open Settings: toggle Reduce Motion (animation stops/slows) and Show Developer Controls (strip disappears).
11. Look at quality: contrast, text size, glass/blur, the "JARVIS is present" feel. Test on a Retina display and, if available, a second display and light/dark menu bar.
12. **VoiceOver check (MANUAL VERIFICATION REQUIRED):** with VoiceOver on, focus the Compact HUD buttons (OPEN JARVIS / PAUSE / STOP / state chips) and confirm each announces a sensible name; in the Approval state confirm "Approval required: Run multiplayer tests" is announced.
13. Activity Monitor: JARVIS should be ~0% CPU when idle/HUDs closed.

Report anything odd and I'll add it to `docs/KNOWN_ISSUES.md`.
