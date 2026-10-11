# JARVIS

A native macOS menu-bar AI operating layer (long-term). V0.1 was the native foundation + HUD; V0.2 added text conversation and a deterministic command router; **V0.3 connects real intelligence**: anything that isn't a built-in command is answered by **your own signed-in Claude Code or Codex** (subscription-backed, conversation-only, tools disabled). JARVIS itself has **no API keys, no network client, no macOS permission request, and never touches your credentials**; autonomous project work is not enabled yet (V0.4).

- **Version:** V0.3 — real intelligence via your own Codex / Claude Code subscriptions — **READY FOR MANUAL TEST** (app version string `0.1.1`; V0.1–V0.2.1 were manually tested by the user). Details: `docs/PROVIDER_RESEARCH.md`.
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

**Commands you can type** (Full HUD or Compact command field; optional “Jarvis,” prefix, case/punctuation ignored):

| Say | Does |
|---|---|
| open / show / go to the report · tasks · system · memory · dashboard · settings | opens the Full HUD on that section (Compact closes) |
| what are you doing? · status · what state are you in? | answers from the real state/task |
| pause / resume / stop (the task) | controls the demo task, confirms, logs activity |
| open compact · open full hud · open Jarvis · close Jarvis | HUD control |
| clear conversation | clears the conversation |
| hello · thanks | tiny local replies |
| raporu aç · görevleri göster · ayarları aç · sistemi aç · belleği göster · görevi duraklat · devam et · görevi durdur · durum nedir · sohbeti temizle · Jarvis'i kapat | Turkish equivalents |
| anything else (“Explain how neural networks work.”, “Explain this Swift function: …”) | answered by the selected provider (Claude Code / Codex), streamed into the Conversation panel; **stop generating** (or the STOP GENERATION button, ⌘.) cancels it |
| autonomous work (“Fix my Unity multiplayer, run it and keep working until it passes.”) | classified `workerRequired`: **no provider is started**; JARVIS says execution isn't enabled yet (task engine = V0.4) |

Quit: right-click the menu bar icon → Quit JARVIS (or ⋯ menu in the Compact HUD).

## Current features

| Feature | Status |
|---|---|
| Menu bar item with state-specific glyphs | IMPLEMENTED · AUTOMATED TESTED (partial) · MANUAL TEST REQUIRED |
| Compact HUD (fixed 392×448 in every state; task, step, elapsed, progress, Open/Pause/Stop, command) | IMPLEMENTED · AUTOMATED TESTED (frame measured across states) · MANUAL TEST REQUIRED |
| Ambient neural-network background (Full HUD, state-reactive, pauses when hidden / Reduce Motion) | IMPLEMENTED · AUTOMATED TESTED (lifecycle) · VISUALLY VERIFIED · MANUAL TEST REQUIRED |
| **Text commands** (EN + TR) → router → executor → real UI/task actions; Conversation panel; honest "provider not connected" replies | IMPLEMENTED · AUTOMATED TESTED (unit + 7 acceptance scenarios on the real WindowManager) · MANUAL TEST REQUIRED |
| **Real intelligence:** Claude Code (token streaming) and Codex (message-level) via their official CLIs; Auto / Codex / Claude Code selection; follow-up context; STOP GENERATION that really kills the process; provider status in Settings | IMPLEMENTED · **REAL TESTED** through the JARVIS stack (`--provider-live-test`) · MOCK TESTED (fake CLIs, 183 unit tests) · MANUAL TEST REQUIRED |
| Native text editing (⌘V/⌘C/⌘X/⌘A/⌘Z), multiline composer | IMPLEMENTED · AUTOMATED TESTED (real key events) · physical keyboard MANUAL TEST REQUIRED |
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

### V0.2 additions (text conversation + command router)
17. Full HUD → type `open the report` + Return: the Report section opens, the **Conversation panel** (Dashboard) records `YOU open the report` / `JARVIS Opening the report.`; the command field clears, keeps focus, and shows the last reply as one grey line.
18. Try `what are you doing?`, `pause the current task`, `resume`, `status`, `Jarvis, show me the tasks`, `raporu aç`, `görevleri göster`, `hello`, `thanks`, `clear conversation`. Replies must reflect the real demo task (title, step, paused/running). `pause` twice → “already paused” notice; with no task (after `stop`) → “no active task” notice.
19. `Explain quantum mechanics.` and `Fix my Unity multiplayer system.` → an amber notice saying no provider/worker is connected. **No fake answer, no state change.**
20. Compact HUD: type `what are you doing?` → one truncated reply line in the command field; the window stays exactly 392×448. Type `show tasks` → Compact disappears, Full HUD opens on Tasks (never both visible). Paste a very long text → still no resize.
21. Blank/space-only Return does nothing. 50 quick submissions keep order and never duplicate windows. The conversation should read like a command history, not a messenger — tell me if it is too dense, too small, or too chatty.
22. Offline check: disconnect from the network; everything above still works (nothing uses the network).

### V0.3 additions (real providers)
**Prerequisite:** be signed in with the vendor's own flow: `claude auth login` (Claude Code) and/or `codex login` (Codex ships inside the ChatGPT app). Settings → Intelligence provider shows each provider's real state (READY / SIGN-IN REQUIRED / NOT INSTALLED) and has a Refresh button. JARVIS never asks for keys or passwords.
26. Settings → Intelligence provider: both providers should read READY (with versions). Try Auto, Claude Code, Codex.
27. Full HUD: type `Explain what a neural network is.` → the Conversation badge shows **THINKING · <provider>** with **STOP GENERATION**, text appears (Claude Code token by token; Codex as a whole message), then the badge returns to `<PROVIDER> · READY`. The JARVIS state chip returns to Idle.
28. Copy a multi-line Swift function from another app, paste it into JARVIS (⌘V), type a new line (Shift+Return) `Explain this function.`, Return → the answer refers to your code. Then `Explain that more simply.` → context-aware follow-up.
29. Start a long answer (`Write a long essay about the history of computing.`) and press **STOP GENERATION** (or type `stop generating`): output stops within a second. In Terminal `pgrep -lx claude codex` must show no process started by JARVIS afterwards (the Claude desktop app has its own `claude` processes).
30. Settings: choose a provider that isn't READY (e.g. rename the path or sign out of one) and ask something → a clear message with the official sign-in command, **no silent fallback** to the other provider. Deterministic commands (`raporu aç`, `show tasks`, `pause the task`) must never start a provider (no THINKING badge).
31. From the Compact HUD ask a normal question → Compact closes, Full HUD opens, answer streams there. Compact stays 392×448.
32. Quit JARVIS while an answer is streaming → no `claude`/`codex` child process is left behind.
Note: each request uses a little of your subscription (Codex ≈14k input tokens per trivial request, Claude ≈5k); Claude Code's and Codex's usage limits are shared with your other use of them.

### V0.2.1 additions (native text editing)
23. In another app copy some text (try multiline code or a log with Turkish characters) → open JARVIS → ⌘V pastes it in **both** the Compact and Full command inputs. ⌘A/⌘C/⌘X/⌘Z/⇧⌘Z and right-click → Paste/Copy also work. Test after opening JARVIS with the **⌥⌘ / ⌥⌘⌘ shortcut while another app is frontmost** — you must be able to type/paste immediately without clicking first.
24. Pasting several lines must NOT submit; **Return** submits, **Shift+Return** (or Option+Return) adds a line. A pasted trailing newline does not submit. In the Full HUD the input grows up to 6 lines then scrolls; in Compact it stays one line (scrolls) and the window stays exactly 392×448 even for a 100-line paste.
25. Compact → Full and Full → Compact: typing always goes to the visible one.

### V0.1.1 additions
- **HUD exclusivity:** only one HUD is ever visible. Full open → click the menu-bar icon or press ⌥⌘ → Full closes, Compact opens. Compact open → OPEN JARVIS or ⌥⌘⌘ → Compact closes, Full opens. Never both.
14. **Compact HUD fixed size:** open the Compact HUD and click through all seven state chips (Idle, Listening, Thinking, Working, Approval, Complete, Error), also after STOP (no active task) and with Settings → Show Developer Controls off. The outer window's **width and height and position must never change** (no jump, no clipping); only the inside crossfades quickly. Turn on Settings → Reduce Motion: the crossfade disappears.
15. **Global shortcuts (from Finder or another app, not JARVIS):** press **⌥⌘** (Option held, tap Command) → Compact HUD opens; again → it closes. Press **⌥⌘⌘** (Option held, tap Command twice quickly) → the **Full HUD opens directly — the Compact HUD must not flash first**; again → it closes (or comes forward if it was behind another window). Holding the keys down must not open duplicate windows or flicker. Try ⌥⌘D (Dock hide) / ⌥⌘-click: JARVIS must not react. Is 0.3 s comfortable for the double Command? Tell me if not. Settings shows both shortcuts and an on/off switch.
16. **Neural background:** Full HUD → Listening (gentle inward pulses), Thinking (busiest), Working (steady flow), Approval (slow, few), Complete (one settling ripple then calm), Error (brief disruption then calm), Idle (nearly static). It should be **subtle** and text must stay perfectly readable. Settings → Reduce Motion: the network becomes a static drawing. Close the Full HUD: Activity Monitor CPU returns to ≈0–2%. (Expected while animating: ≈10–13% of one core, ≈3% when Idle/Approval.)

Report anything odd and I'll add it to `docs/KNOWN_ISSUES.md`.
