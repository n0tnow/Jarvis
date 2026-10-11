# JARVIS Project State

> New agent? Read this file first, then `docs/CURRENT_TASK.md`. See `AGENTS.md` for the bootstrap order.

## Current Version

V0.3 — real intelligence through the user's own Claude Code / Codex subscriptions (on top of V0.2.1; app version string still `0.1.1`). V0.1–V0.2.1 were manually tested by the user.

## Current Milestone

V0.3: real intelligence providers (conversation only; autonomous workers are V0.4)

## Status

**V0.3 — READY FOR MANUAL TEST**
(Automated + REAL verification passed. Not manually verified by the user. Do NOT mark COMPLETE, do NOT tag, do NOT start V0.4.)

## Current Objective

Hand V0.3 to the user: manual test of `build/Jarvis.app` with their own signed-in Claude Code / Codex (README checklist items 26–32).

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

## V0.3 additions (IMPLEMENTED · REAL TESTED · MOCK TESTED · UI MANUAL TEST REQUIRED)

- **Providers (DEC-020/021, `docs/PROVIDER_RESEARCH.md`):** `ProviderManager` (states notInstalled/installed/authRequired/ready/running/rateLimited/unavailable/failed; Auto → Claude Code then Codex; explicit choice never silently falls back), `ExecutableLocator` (GUI PATH not trusted: override, PATH, ~/.local/bin, Homebrew, nvm, `/Applications/ChatGPT.app/Contents/Resources/codex`; highest version wins), `ProviderProbe` (`--version`, `claude auth status` / `codex login status` — Codex prints its verdict on **stderr**; an API-key login is reported UNAVAILABLE, never READY), `CLIProvider` (ClaudeCodeSpec / CodexSpec), `ManagedProcess` (the only `Process` launch point; argv array, stdin prompt, env allowlist that scrubs API keys, SIGINT→SIGTERM→SIGKILL of the whole process tree, `killAll` on quit/signals).
- **Conversation-only:** Claude `--tools "" --safe-mode --permission-prompts none`; Codex `-s read-only` + `--disable shell_tool/browser_use/computer_use/plugins/hooks/apps/memories`; private empty cwd; short JARVIS instruction. `workerRequired` and deterministic commands never reach a provider.
- **Streaming/continuity/stop:** Claude token deltas, Codex message-level (documented limitation); 40 ms UI coalescing; official sessions (`--resume` / `exec resume`) with bounded-context fallback; STOP GENERATION (button, ⌘., "stop generating") kills the real process; next turn waits until the old one is gone.
- **UI:** provider badge + STOP in the Conversation panel, System-panel row, Settings provider section (preference, status, refresh, custom paths, login instructions). Compact stays 392×448; long answers go to the Full HUD. State is Thinking only during real generation.
- **Review hardening (read-only reviewer):** provider-reported session ids validated (cannot become flags), config dirs must be absolute existing directories, line splitter byte-capped, status numbers matched as standalone tokens, idle timeout longer for Codex, failed/timed-out sessions never reused, sessions dropped on provider switch, cancel-while-resolving launches nothing, JARVIS never clobbers a state it does not own.

## V0.2.1 additions (IMPLEMENTED · AUTOMATED TESTED · physical keyboard MANUAL TEST REQUIRED)

- **Native editing (DEC-019, JARVIS-R12):** root cause proven (accessory app had no main menu → ⌘V/⌘C/⌘X/⌘A/⌘Z dead; plus regular-window Full HUD could not become key when activation was denied). Fix: `AppMenu` (Edit menu) + `ComposerField` NSTextView composer (plain paste, multiline, Return/Shift+Return, IME-safe, bounded height, internal scroll) + non-activating Full HUD panel. Smoke test sends real ⌘ key events and checks paste/copy/cut/select-all/undo/redo, multiline paste not submitting, Compact 100-line paste staying 392×448, focus transfer in both directions. No clipboard monitoring or logging.

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

Nothing. Waiting for user manual verification of V0.3.

## Pending (outside V0.1)

Everything in `docs/ROADMAP.md` from V0.2 onward — PLANNED, not started.

## Known Issues

See `docs/KNOWN_ISSUES.md`. Headline: VoiceOver labels on custom buttons — MANUAL VERIFICATION REQUIRED; Retina rendering not verified (dev machine screen was 1×).

## Tested

**V0.3 (2026-10-11) — `scripts/verify.sh` → VERIFY PASSED:** 183 unit tests (serial, real child processes) · smoke 85 PASS / 0 FAIL / 2 SKIP · focused provider policy rules · idle CPU ≈0.2 %.
- **REAL TESTED** (`Jarvis --provider-live-test`, real requests through ConversationService → ProviderManager → provider → parser → store): Claude Code 2.1.277 and Codex 0.153.4 — exact-reply, complete 30-number answer, incremental streaming (Claude: real deltas; Codex: one message, as documented), follow-up context (PINEAPPLE), STOP kills the process tree with no orphans (Claude 0.6 s, Codex 1.6 s), UI recovers, deterministic command launches no provider, worker request launches no provider.
- **MOCK TESTED** (fake CLIs): crash, timeout (idle/total), rate limit, auth required, malformed output, session loss + retry, provider switching, process-group/orphan kill, SIGTERM-ignoring process, app-termination cleanup, busy refusal, API-key login rejection, env scrubbing.
- **MANUAL TEST REQUIRED:** real typing/Stop button/⌘. in the HUD, Settings picker feel, Compact→Full hand-off by eye, multi-minute answers, subscription limit hit, quitting mid-stream.
- CPU (release, M5, % of one core; A/B against the V0.2.1 build on the same machine shows no regression — the host is busier than during the V0.2 numbers below): closed ≈0.2 % · Compact working ≈1.2 % · Full idle ≈4.5 % · Full thinking/working ≈15–17 % (V0.2.1 build: identical). Real streaming with Full HUD open: JARVIS ≈20 % + provider ≈7–16 %. RSS 65 MB idle, ≈150 MB with Full HUD.

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

See `docs/DECISIONS.md` (DEC-001…DEC-021). Key ones:
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

**Wait for the user's manual V0.3 test** (`README.md` → V0.3 additions, items 26–32). Do not start V0.4 (persistent task engine / workers) without approval.

## Git

`main` only; `origin` = https://github.com/n0tnow/Jarvis.git; V0.3 commits start at `58c6948`; **no tag**; no AI co-author trailers (user rule). Policy: `AGENTS.md` → Git Workflow, DEC-011.

## Last Updated

2026-10-11 — V0.3 implemented, REAL TESTED with both providers, verified. READY FOR MANUAL TEST.
