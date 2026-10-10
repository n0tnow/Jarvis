# Architecture (V0.1)

Status: IMPLEMENTED · AUTOMATED TESTED (see `PROJECT_STATE.md`). Decisions behind it: `DECISIONS.md`.

## Shape

```
NSApplication (accessory, menu-bar agent)         App/main.swift, AppDelegate
 └─ AppContext  (composition root, lives for the whole process)
     ├─ JarvisStore      application state: JarvisState, tasks, activity, approval, display slots
     ├─ HUDState         UI-only state: Full HUD section, which surfaces are visible
     ├─ Preferences      UserDefaults-backed: reduceMotion, showDeveloperControls
     ├─ LocalCommandHandler   V0.1 command sink (no AI)
     └─ WindowManager    implements JarvisWindowControlling; owns every NSWindow/NSPanel
 StatusItemController    menu bar item; observes JarvisStore.state
```

Views read `AppContext` from the SwiftUI environment (`@Environment(AppContext.self)`); `@Observable` gives fine-grained updates. AppKit code observes the same models through `observeContinuously` (event-driven, no polling).

## Key separations

- **Application state vs UI state.** `JarvisStore` knows nothing about windows. `HUDState` knows nothing about tasks. Hiding/closing windows only touches `HUDState`. This is what lets long-running work (V0.4) continue with the UI closed.
- **Window control behind a protocol.** `JarvisWindowControlling` (`Services/WindowControlling.swift`) is AppKit-free: `showCompactHUD/hideCompactHUD/toggleCompactHUD`, `showFullHUD(section:)`, `hideFullHUD`, `bringFullHUDForward`, `showSettings`, `isCompactHUDOpen`, `isFullHUDOpen`. A future intent/voice layer calls this — e.g. "give me the report" = `windows.showFullHUD(section: .report)`.
- **Demo data isolated.** Only `Services/Demo/*` (and dev tooling) reference `DemoData`/`DemoScenario`; `AppContext` seeds the store with them. Replace the seed to go real.
- **Navigation.** `HUDSection` (dashboard, tasks, report, system, memory) → `FullHUDView` switch. Report/Memory are placeholders.

## State model

`JarvisState` (7 cases) is the single value every surface renders. `JarvisStore.setState` is a plain setter; `.completed` auto-returns to `.idle` after 6 s. Tasks are Codable value types (`JarvisTask`, `TaskStep`) with a pause-aware clock; **progress = completed steps / total steps** and nothing else.

State ↔ task coherence is enforced in the demo layer (`DemoScenario.apply`): idle pauses a running task; working/approval need a live task; completed completes it; error fails it; listening/thinking are foreground-only (a task may keep running). Real task logic (V0.4) must own these transitions instead.

## Windows

- **Compact HUD** — `HUDPanel` (borderless, floating, `canBecomeKey`). Anchored under the status item; hides on resign-key (0.25 s guard prevents the dismissing click from re-opening it); ESC via `cancelOperation`; height follows SwiftUI content (`NSHostingController.sizingOptions = .preferredContentSize`, top edge pinned).
- **Full HUD** — `FullHUDWindow` (borderless, resizable, clear background, normal level, movable by background). Sized to ~90 % of the visible frame (max 1480×920) on the screen of the menu bar item/pointer; centered. **Minimum size is enforced in `windowWillResize`** (NSHostingView overwrites `contentMinSize`). ESC/⌘W close it. Layout adapts at <1200 pt width (`hudIsNarrow`).
- **Settings** — `SettingsWindow` (titled; ESC/⌘W close).

## Rendering & resources

- Glass = `NSVisualEffectView` (`.hudWindow`) + deep-ink tint + hairline; fonts are system fonts; tokens in `UI/Theme/Theme.swift`.
- JARVIS Core: `CoreRenderer` (Core Graphics) inside `CoreNSView`, driven by a `CADisplayLink` (≤24 fps) that exists **only while** `isAnimating` (HUD visible ∧ Reduce Motion off). Hidden/idle = one static frame, 0 CPU. Rationale/measurements: DEC-006.
- Menu bar icon: cached template `NSImage`s per (state, frame); a 0.5 s timer runs only for listening/thinking/working.
- Nothing polls; elapsed-time labels tick at 1 Hz only while the task runs and the surface is visible.

## Dev tooling (compiled into the binary; inert without launch args)

`--smoke-test` (`App/SmokeTest.swift`), `--capture <dir>` (`App/DevCapture.swift`, uses the window server's image of *this process's own windows* — no Screen Recording permission), `--open-full/--open-compact/--section/--state/--close-after`. `AccessibilityAudit` walks the in-process AX tree (currently SKIPs: SwiftUI doesn't build it without an AX client).

## Extension points for later milestones (not implemented)

- V0.2: replace `LocalCommandHandler` with a command router (needs a response channel; today it only writes to the activity log).
- V0.4: task engine writes `JarvisStore`; needs task-id-addressable mutations (today `mutateActiveTask` targets the first active task) and Codable display slots/approval for persistence; add an "interrupted" status for crash recovery.
- Voice (V0.5–0.7): something must arbitrate `setState` between STT/LLM/task engine.
- Self-controlled UI (V0.8): protocol may need `currentSection`, `hideSettings`, and a "don't steal focus" open variant.
