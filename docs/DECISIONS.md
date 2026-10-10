# Decisions

Only decisions actually established. To change one, add a new entry that supersedes it.

## DEC-001 — Native macOS application
Status: Accepted
Context: JARVIS must feel like an operating layer and run beside Unity/Xcode/browser/local models.
Decision: Swift + SwiftUI, AppKit where needed. No Electron, React, Tauri, web views, or Node shell.
Reason: Native look, window control, low resource use, direct macOS APIs later.
Consequences: All UI is native; web tech is out unless this decision is superseded.

## DEC-002 — Swift Package + script-assembled app bundle (no Xcode project)
Status: Accepted
Context: The dev machine has Command Line Tools only (no Xcode, so no `xcodebuild`).
Decision: `Package.swift` executable target; `scripts/build_app.sh` assembles and ad-hoc signs `build/Jarvis.app` using `Resources/Info.plist`. Tests via `scripts/test.sh` (extra linker flags for CLT's Swift Testing).
Reason: Only way to build natively here; zero dependencies.
Consequences: An Xcode project can be added later without moving sources. Don't rely on Xcode-only features (asset catalogs, XCTest UI tests) yet.

## DEC-003 — Deployment target macOS 14, Apple Silicon
Status: Accepted
Context: Installed macOS is 26.4 (arm64).
Decision: macOS 14.0 minimum.
Reason: `@Observable` and modern SwiftUI/AppKit APIs; wide enough compatibility.
Consequences: Avoid APIs newer than 14 without availability checks (e.g. `Color.mix` is 15+).

## DEC-004 — UI state separated from application/task state
Status: Accepted
Context: Future multi-hour background work must not depend on any window being open.
Decision: `JarvisStore` (application state) and `HUDState` (UI state) are separate; closing HUDs never mutates the store; the menu bar process stays alive.
Consequences: Background workers/task engine write only to the store.

## DEC-005 — All window control behind `JarvisWindowControlling`
Status: Accepted
Context: Voice/intent layer will need to show/hide/navigate the UI ("show report", "close report").
Decision: Views and future layers call the protocol; only `WindowManager` touches NSWindow/NSPanel.
Consequences: New window behaviours are added to the protocol + manager, not scattered in views.

## DEC-006 — JARVIS Core drawn in AppKit (Core Graphics + CADisplayLink), not SwiftUI Canvas/TimelineView
Status: Accepted
Context: Profiling showed a SwiftUI `TimelineView`+`Canvas` cost ~25–30 % of a core while animating — even with an empty canvas and at 4 fps (attribute-graph invalidation per tick, not drawing).
Decision: `CoreNSView` + `CoreRenderer`, display link capped at ≤24 fps, created only while visible and animating.
Reason: Measured ≈9 % of a core while animating, 0 % hidden.
Consequences: Don't move the animated core back into SwiftUI per-frame updates. Keep the SwiftUI center label static.

## DEC-007 — Demo data isolated in `Services/Demo`
Status: Accepted
Decision: Production code never depends on `DemoData`/`DemoScenario`; `AppContext` seeds the store. Demo panels are labelled DEMO / NOT CONNECTED.
Consequences: Real data replaces the seed without touching views.

## DEC-008 — V0.1 requests no macOS permissions and ships no AI
Status: Accepted
Decision: No microphone/accessibility/screen-recording/automation use; no `NS*UsageDescription` keys; no entitlements; no LLM/STT/TTS/network. No paid API dependency without explicit user approval; no API keys in the repo.
Consequences: Permissions are added only with the feature that needs them (and not merely to automate tests).

## DEC-009 — Custom `NSStatusItem` + borderless panels instead of `MenuBarExtra`
Status: Accepted
Context: Needed a non-"settings-popover" look, state-driven icon, programmatic show/hide, ESC, and anchored placement.
Decision: `StatusItemController` + `HUDPanel`/`FullHUDWindow` managed by `WindowManager`.
Consequences: We own dismissal rules (resign-key + re-open guard), positioning, and keyboard handling (accessory apps have no menu bar for ⌘W).

## DEC-010 — Verification without Screen Recording permission
Status: Accepted
Decision: Screenshots come from an in-process dev capture of the app's own windows (`--capture`); behaviour checks come from `--smoke-test` and `scripts/verify.sh`. The app itself never requests Accessibility/Screen Recording. External UI automation (System Events) is optional, user-approved, and not required to ship.
Consequences: Real-click/physical-key/VoiceOver checks that can't be automated stay MANUAL TEST REQUIRED — never report them as verified.

## DEC-011 — Git: `main` only, linear history, user-approved tags
Status: Accepted
Context: One user plus AI coding agents; branch overhead isn't wanted.
Decision: `main` is the single development branch (origin: https://github.com/n0tnow/Jarvis.git). No other branches or PRs unless the user asks. Conventional Commit messages; verified checkpoints are pushed; never force-push. Tags (`v0.1`, …) only after the user approves a milestone; V0.1 is not approved yet, so no tag exists.
Consequences: Full policy lives in `AGENTS.md` → "Git Workflow". Docs are updated before the commit they describe.

## DEC-012 — Neural background: isolated AppKit renderer, deterministic graph, bounded simulation
Status: Accepted
Context: V0.1.1 asked for subtle ambient "JARVIS is processing" visuals without regressing CPU (SwiftUI per-frame animation previously cost ~30 % of a core; DEC-006).
Decision: `NeuralGraph` (seeded, generated once: 45 nodes / ~70 edges) + `NeuralSimulation` (fixed-capacity pulse pool ≤14, no per-frame allocation of images) are pure Swift; `NeuralNetworkNSView` draws with Core Graphics on a `CADisplayLink` that exists only while the Full HUD is visible and Reduce Motion is off, at a per-state rate (5 fps idle … 15 thinking). SwiftUI only pushes state changes into it. Full HUD only; the Compact HUD intentionally has none (readability, fixed small size, CPU).
Consequences: Cost ≈ +2–3 points of one core while animating; idle-open ≈ 3 %. Do not drive it from SwiftUI TimelineView/Canvas. Core frame rate is also state-based (idle/error 10 fps, waiting 12, completed 20, active 24) to pay for it.

## DEC-013 — Global shortcuts: permission-free modifier polling, not event monitors/taps
Status: Accepted
Context: The user wants modifier-only global shortcuts (⌥⌘ → Compact HUD, ⌥⌘⌘ → Full HUD). Carbon hotkeys can't do modifier-only; `NSEvent` global monitors / `CGEventTap` need Accessibility or Input Monitoring; DEC-008 forbids adding permissions. Private APIs are out.
Decision: `GlobalHotkeyService` samples `NSEvent.modifierFlags` (+ `CGEventSource.secondsSinceLastEventType` for keyDown/mouse-down, so ⌥⌘+key and ⌥⌘+click are ignored) — 12 Hz at rest, 60 Hz only while Option is held — and feeds the pure `ModifierChordMachine`. Semantics: hold Option and press Command → Compact (fires 0.30 s later, or on Option release, if no second press); hold Option and press Command twice within 0.30 s → Full (fires on the second press, cancels the pending Compact). Either Command key. Level-based machine ⇒ no duplicate actions from key repeat; after an action it waits for Command release (+0.4 s cooldown after Full). Actions call `JarvisWindowControlling` (`toggleCompactHUD`, `toggleFullHUD`) only.
Consequences: Works while other apps are focused with no permission prompt. Costs ≈0.3 % of a core at rest. Limit: a chord is only recognised if no other key/click occurs; Shift/Control cancel it. Off switch: Settings → Enable global shortcuts. A shortcut editor is future work. If macOS ever gates these queries, fall back to asking the user to pick a different shortcut — do not silently add a permission.

## DEC-014 — Compact HUD has one canonical fixed size
Status: Accepted
Context: The window followed SwiftUI's intrinsic height (`.preferredContentSize` + `fittingSize`), so state changes resized it.
Decision: `CompactHUDLayout.size` = 392×448, applied at the window level and to the SwiftUI root; the task card has a fixed height; only inner content crossfades (0.2 s, none under Reduce Motion). The smoke test measures the real frame across all 7 states.
Consequences: Content that grows must fit inside the fixed frame (or the canonical size changes deliberately, in one place).

## DEC-015 — Exclusive HUD presentation is a WindowManager invariant
Status: Accepted
Context: The user found Compact and Full HUD visible at the same time (`showFullHUD` hid Compact, but `showCompactHUD` and `bringFullHUDForward` did not hide the other).
Decision: Compact visible XOR Full visible, enforced only inside `WindowManager` (`showCompactHUD` hides Full; `showFullHUD`/`bringFullHUDForward` hide Compact). Callers — menu bar, hotkeys, views, and future text/voice/LLM commands — must not coordinate it themselves.
Consequences: New code that shows a HUD must go through `JarvisWindowControlling`. The smoke test asserts the invariant at every checkpoint (all entry points, rapid repeats, no duplicate windows) and was mutation-checked to fail without the fix.

## DEC-016 — V0.2 conversation pipeline: separate stages, one execution layer
Status: Accepted
Context: V0.2 starts the intelligence architecture. Text, future voice and future LLM tool calls must share one path; no giant `handlePrompt()`.
Decision: `InputNormalizer` (fold/prefix/filler; original text kept) → `IntelligenceRouter` (pure: command | local reply | worker-required | reasoning-required | unsupported) → `ConversationService` (orchestration, cancellation, store writes) → `CommandExecutor` (HOW; window changes only via `JarvisWindowControlling`, task changes via `JarvisStore`) / `IntelligenceProviderRegistry` → `ConversationStore`. Deterministic commands are explicit English + Turkish aliases (folded ASCII), matched by exact phrase or "one target + navigation verbs, ≤5 tokens". Deterministic commands never change `JarvisState` or fake work; replies are built from real state. Conversation history and the Activity feed stay separate (only meaningful actions are logged).
Consequences: Add intents by extending `JarvisIntent` + `CommandRouter` + `CommandExecutor` (+ `Phrasebook`). Voice/LLM must call `ConversationService.submit` / the router / the executor, never window code.

## DEC-017 — Intelligence provider boundary; subscription-first rule (permanent)
Status: Accepted
Context: The user pays for ChatGPT and Claude subscriptions and does not want silent API charges.
Decision: `IntelligenceProvider` (streaming-shaped `AsyncThrowingStream<IntelligenceEvent>`, cooperative cancellation) + `IntelligenceProviderRegistry`. **V0.2 registers no provider**: reasoning/worker requests get a truthful "not connected" reply — no fake answers. No OpenAI/Anthropic API keys, no paid-API or billing-dependent code, no scraping/automating ChatGPT/Claude web UIs. A ChatGPT/Claude subscription does NOT imply API access. V0.3 will implement a provider using officially supported subscription-backed CLI/desktop/agent mechanisms, after verifying current official tooling.
Consequences: `scripts/verify.sh` fails if sources contain network/web code or API-key/endpoint references. The whole app works offline.

## DEC-018 — Conversation UI is command history, not a chat app
Status: Accepted
Decision: Full HUD Dashboard gets a thin-row `ConversationPanel` (monospaced role markers, no bubbles, bounded to the last 60 rows; store capped at 500) in the centre column; the latest JARVIS reply is also shown as one truncated line in the command field (Compact HUD and Full HUD, every section). Compact never shows history and keeps its fixed 392×448 geometry; requests needing more room (reasoning/worker) open the Full HUD from Compact.

## DEC-019 — Native text editing: main Edit menu + NSTextView composer + non-activating Full HUD panel
Status: Accepted
Context: The user could not paste into the command input. Reproduced and proven (V0.2.1): an accessory (LSUIElement) app has no main menu, and AppKit dispatches ⌘C/⌘V/⌘X/⌘A/⌘Z/⇧⌘Z through main-menu key equivalents, so every text field lost them (the global-hotkey poller was not involved — it never intercepts keys). A second cause surfaced while testing: opened from another app (hotkey), `NSApp.activate()` is not honoured for an accessory app, so the regular-window Full HUD never became key and could not receive typing at all.
Decision: (1) `AppMenu.install()` builds a standard main menu (Edit: Undo/Redo/Cut/Copy/Paste/Paste and Match Style/Delete/Select All; all `target = nil` → first responder). The menu bar is never shown, the key equivalents work. No per-shortcut key handling anywhere. (2) `ComposerField`: reusable NSTextView-backed multiline composer (plain-text paste, no smart substitutions, native undo/IME/context menu). Return submits; Shift/Option+Return = newline; pasted newlines are text and never submit; Return during IME composition belongs to the IME; ESC clears then dismisses. Height follows content up to `maxLines` (Full 6, then internal scroll; Compact fixed 1 line with internal scroll so the window never resizes). (3) `FullHUDWindow` is a non-activating `NSPanel` (like the Compact HUD) so it can be key without app activation.
Consequences: The pasteboard is read only by the native paste the user triggers — no monitoring, history or logging. New text inputs must use `ComposerField` (or at least keep the main menu). Smoke test drives real ⌘ key events (and saves/restores the pasteboard — dev tool only).
