# JARVIS

A native macOS menu-bar AI operating layer (long-term). **V0.1 is only the application foundation + HUD**: native shell, state architecture, Compact HUD, Full HUD, demo data. There is **no AI, no voice, no network, and no macOS permission request** in this version.

- **Version:** V0.1.1 (`0.1.1`) — **READY FOR MANUAL TEST**. (V0.1 was manually tested by the user: direction approved; V0.1.1 adds three requested fixes — not yet verified by the user.)
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

**Global shortcuts** (work while any app is focused; no permission): hold **Option** and press **Command** → toggle Compact HUD (fires ~0.3 s later unless it turns out to be a double press). Hold **Option** and press **Command twice quickly** (within 0.3 s) → toggle Full HUD. Either Command key. Ignored if you add another key, a click, Shift or Control (so ⌥⌘D, ⌥⌘-click etc. are untouched). Turn off in Settings → Enable global shortcuts.

Quit: right-click the menu bar icon → Quit JARVIS (or ⋯ menu in the Compact HUD).

## Current features

| Feature | Status |
|---|---|
| Menu bar item with state-specific glyphs | IMPLEMENTED · AUTOMATED TESTED (partial) · MANUAL TEST REQUIRED |
| Compact HUD (fixed 392×448 in every state; task, step, elapsed, progress, Open/Pause/Stop, command) | IMPLEMENTED · AUTOMATED TESTED (frame measured across states) · MANUAL TEST REQUIRED |
| Ambient neural-network background (Full HUD, state-reactive, pauses when hidden / Reduce Motion) | IMPLEMENTED · AUTOMATED TESTED (lifecycle) · VISUALLY VERIFIED · MANUAL TEST REQUIRED |
| Global shortcuts ⌥⌘ (Compact) and ⌥⌘⌘ (Full), no permission needed | IMPLEMENTED · AUTOMATED TESTED (logic + scripted integration) · **MANUAL TEST REQUIRED** (physical keys from another app) |
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
13. Activity Monitor: JARVIS should be ≈0–0.5% CPU when idle/HUDs closed (hotkey polling is tiny).

### V0.1.1 additions
- **HUD exclusivity:** only one HUD is ever visible. Full open → click the menu-bar icon or press ⌥⌘ → Full closes, Compact opens. Compact open → OPEN JARVIS or ⌥⌘⌘ → Compact closes, Full opens. Never both.
14. **Compact HUD fixed size:** open the Compact HUD and click through all seven state chips (Idle, Listening, Thinking, Working, Approval, Complete, Error), also after STOP (no active task) and with Settings → Show Developer Controls off. The outer window's **width and height and position must never change** (no jump, no clipping); only the inside crossfades quickly. Turn on Settings → Reduce Motion: the crossfade disappears.
15. **Global shortcuts (from Finder or another app, not JARVIS):** press **⌥⌘** (Option held, tap Command) → Compact HUD opens; again → it closes. Press **⌥⌘⌘** (Option held, tap Command twice quickly) → the **Full HUD opens directly — the Compact HUD must not flash first**; again → it closes (or comes forward if it was behind another window). Holding the keys down must not open duplicate windows or flicker. Try ⌥⌘D (Dock hide) / ⌥⌘-click: JARVIS must not react. Is 0.3 s comfortable for the double Command? Tell me if not. Settings shows both shortcuts and an on/off switch.
16. **Neural background:** Full HUD → Listening (gentle inward pulses), Thinking (busiest), Working (steady flow), Approval (slow, few), Complete (one settling ripple then calm), Error (brief disruption then calm), Idle (nearly static). It should be **subtle** and text must stay perfectly readable. Settings → Reduce Motion: the network becomes a static drawing. Close the Full HUD: Activity Monitor CPU returns to ≈0–2%. (Expected while animating: ≈10–13% of one core, ≈3% when Idle/Approval.)

Report anything odd and I'll add it to `docs/KNOWN_ISSUES.md`.
