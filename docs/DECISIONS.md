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
Decision: (1) `AppMenu.install()` builds a standard main menu (Edit: Undo/Redo/Cut/Copy/Paste/Paste and Match Style/Delete/Select All; all `target = nil` → first responder). The menu bar is never shown, the key equivalents work. No per-shortcut key handling anywhere. (2) `ComposerField`: reusable NSTextView-backed multiline composer (plain-text paste, no smart substitutions, native undo/IME/context menu). Return submits; Shift/Option+Return = newline; pasted newlines are text and never submit; Return during IME composition belongs to the IME; ESC clears then dismisses. Height follows content up to `maxLines` (Full 6, then internal scroll; Compact fixed 1 line with internal scroll so the window never resizes). (3) `FullHUDWindow` is a non-activating `NSPanel` (like the Compact HUD) so it can be key without app activation. A non-activating panel of an inactive app sits BEHIND the frontmost app's windows at normal level (verified via the window server's z-order), so it is shown at `.floating` level and dropped to `.normal` on `windowDidResignKey` — it never permanently covers other apps.
Consequences: The pasteboard is read only by the native paste the user triggers — no monitoring, history or logging. New text inputs must use `ComposerField` (or at least keep the main menu). Smoke test drives real ⌘ key events (and saves/restores the pasteboard — dev tool only).

## DEC-020 — V0.3 policy change: approved subscription-backed provider integration (focused verify rules)
Status: Accepted (supersedes the V0.2 "no provider code at all" rule of DEC-017/`verify.sh`; subscription-first itself is unchanged)
Context: V0.3 adds real intelligence. The user pays for ChatGPT and Claude subscriptions and does not want API charges.
Decision: Allowed: driving the user's own, unmodified `codex exec --json` and `claude -p --output-format stream-json` as child processes (docs/PROVIDER_RESEARCH.md). Still forbidden and enforced by `scripts/verify.sh`: any JARVIS network client (URLSession etc.), paid-API/web endpoints and scraping, API keys (names only in the env scrub list), credential/token/cookie/keychain/`auth.json` access, `--bare`/dangerous flags/`danger-full-access`, shells (`sh -c`), clipboard reads outside native paste. The child environment is an allowlist (API-key/cloud variables never forwarded). Auth is always the vendors' own flow; JARVIS only calls their status commands. Automated runs (smoke/capture) stub providers so they never spend quota; real calls are an explicit opt-in (`--provider-live-test`).
Consequences: Anthropic's policy limits this to the user's own signed-in unmodified binary on their own machine (never offer login, never handle credentials); re-review before any redistribution.

## DEC-021 — Provider architecture
Status: Accepted
Decision: `ConversationService` depends only on `IntelligenceProviderResolving`. `ProviderManager` (discovery via `ExecutableLocator` — GUI PATH is not trusted; auth readiness via the vendors' status commands; states notInstalled/authenticationRequired/ready/running/rateLimited/unavailable; Auto = first READY of Claude Code, Codex; an explicit choice NEVER silently falls back) creates `CLIProvider`s (a `CLIProviderSpec` + `ManagedProcess` + pure line parsers). Conversation-only: Claude `--tools "" --safe-mode`, Codex `-s read-only` + `--disable shell_tool …`; a short "no tools, never claim actions" instruction (verified necessary). Continuity: official sessions (Claude `--session-id`/`--resume`, Codex `exec resume <thread>`), bounded provider-exchange-only context for fresh sessions and after switches; one retry if a resume fails. Streaming: Claude token deltas, Codex message-level (documented limitation); deltas coalesced to ~25 UI updates/s. Cancellation: consumer cancel → SIGINT → SIGTERM → SIGKILL of the process and all descendants; verified no orphans; app termination kills every provider process. `workerRequired` never reaches a provider (V0.4).

## DEC-022 — Cost policy: three provider classes, verified-zero FREE, no paid API, no silent billing
Status: Accepted (V0.3.1; extends DEC-017/020)
Context: The user must never be surprised by charges. OpenCode lists priced and free models side by side.
Decision: Engines are `local` (no money), `freeCloud` (OpenCode models whose CURRENT provider metadata says price 0), `subscription` (the user's own Claude Code / Codex plans, V0.3 rules) and `paidAPI` (does not exist; refused). A model is FREE only if ALL cost components read 0 in `opencode models --verbose` data, its status is `active`, it belongs to the keyless Zen provider `opencode` served from `opencode.ai`, and the verification is ≤ 24 h old. A name containing "free", a cached flag, or a third-party list never counts. Unknown price ⇒ never routed automatically; price > 0 ⇒ blocked; zero-priced models of the credentialed `opencode-go` plan are excluded. `OpenCodeSpec.make(for:)` cannot even construct a launch spec for anything else. If no free model qualifies, JARVIS escalates to Claude Code / Codex per V0.3 rules or refuses — it never uses a paid endpoint or an API key.
Consequences: Free status expires and is re-read (`opencode models --refresh`); a price change revokes membership on the next refresh.

## DEC-023 — SQLite for operational state; files for large artifacts
Status: Accepted
Decision: System SQLite (WAL, one serialised writer, read connections, versioned migrations, corrupt-file recovery that moves the file aside) at `~/Library/Application Support/JARVIS/jarvis.sqlite`, never inside the repository. Large content (reports, screenshots, provider output, benchmark output, checkpoints, logs) is stored as files under `artifacts/…`; SQLite holds path/type/size/SHA-256/relations. Prompts and answers are never stored whole (hash + length + redacted excerpt; no excerpt for sensitive tasks). No server/ORM/dependency. Details: `docs/PERSISTENCE.md`.

## DEC-024 — The local model is for lightweight tasks only (enforced in code)
Status: Accepted
Decision: `LocalModelPolicy` is the single gate: coding, testing, repository modification, technical review, complex reasoning, tool needs, Unity/multiplayer/security/C# domains, project code, complexity above "simple" and contexts above ≈3000 tokens are all ineligible for the local model — in Auto routing AND when the user explicitly picks "Local" (explicit Local on such a task is refused with an explanation, never rerouted). `TaskClassifier` is deliberately conservative: any technical signal wins over a lightweight one. Pinned by unit tests per forbidden class.

## DEC-025 — OpenCode integration: CLI per task, restricted workspace, verified-free pool
Status: Accepted (research: `docs/OPENCODE_RESEARCH.md`)
Decision: `opencode run --pure --format json -m opencode/<id> [-s <session>]`, prompt on stdin, in a private empty workspace whose `opencode.json` rejects/denies every tool (`"*":"ask"` is auto-rejected headless; edit/web/outside-directory/task/skill/question/lsp/doom-loop explicitly denied). `bash` is NOT denied outright because that makes the free tier return 403 (JARVIS does not work around it). No `--auto`, no server/SDK/`--attach`, no credentials touched, scrubbed environment. JARVIS orchestrates; OpenCode is a one-shot worker. Free models are used for development/knowledge work only after passing the benchmark suite for that group (Auto); explicit "OpenCode Free" may use any verified-free model. Data handling per the Zen docs is stored per model: tasks containing project code go only to zero-retention models; sensitive tasks never go to free cloud.

## DEC-026 — Model router: deterministic, policy-first, auditable
Status: Accepted
Decision: `ModelRouter` is a pure function of (`TaskProfile`, `RouterSnapshot`). Auto tiers: lightweight → Local → OpenCode free → Claude → Codex; development/moderate knowledge → OpenCode free (verified + benchmarked + healthy + privacy-OK) → Claude → Codex; heavy/architecture/security → Claude → Codex. Explicit modes (Local, OpenCode Free, Claude Code, Codex) never fall back. Every decision has a flat, machine-readable reason (`selection_reason` in `agent_runs`) plus the bounded ordered fallback chain used for escalation. Provider/model failures put the subject into persistent cooldown with exponential backoff. Details: `docs/MODEL_ROUTING.md`.

## DEC-027 — ProviderSupervisor, resource-aware routing, bounded background agents
Status: Accepted
Context: Four engines with different lifecycles share a 16 GB laptop with Unity/Xcode/browsers.
Decision: `ProviderSupervisor` discovers/inspects every engine, keeps persistent per-engine and per-model health (`provider_health`; cooldown = 60 s·2^(n−2) from the 2nd consecutive failure, capped at 30 min; cancels/busy/refusals are not failures; rate limits cool down until their reset or 15 min), supervises the local worker (crash → mark unhealthy → at most ONE restart per 10 min with a ping/pong health check → ready | unavailable; never a loop) and unloads the local model when idle, under memory pressure, and on shutdown. CLI providers are NOT kept alive: each Claude/Codex/OpenCode request is its own child process. `ResourceManager` is event-driven (memory-pressure dispatch source, thermal and low-power notifications — nothing polls). Conservative limits for 16 GB (`ConcurrencyLimits`): 1 local inference job (≈3.4 GB peak, GPU-bound), 2 free-cloud workers (each CLI ≈0.3–0.6 GB RSS), 1 heavy development agent (shares subscription limits), 3 agents in total, depth 1 (an agent cannot spawn agents), ≤3 children per parent. Slots are claimed synchronously at decision time (race-free); capacity pushes an Auto request to the next policy engine, an explicit mode is rejected instead.
Consequences: V0.4 can add queueing/scheduling on top; the foundation only runs one-shot, validated, audited work — no planning, tools or file writes.

## DEC-028 — Audit trail, benchmark history and minimal context
Status: Accepted
Decision: Every provider run (conversation or agent) is an `agent_runs` row with task, parent, engine, model, cost class, the machine-readable selection reason, privacy, timing, status, tools (refused attempts are recorded as `attempted-refused:<tool>`), files, validation, retries, escalation from/to, error category, prompt SHA-256 + length, provider-reported token counts and a redacted result excerpt (none for sensitive tasks). Benchmark results are stored per model/case/suite with latency, duration, malformed flag and an artifact of the (redacted) raw output; scores are derived only from recorded results ("3/4", never an invented percentage) and expire after 14 days. A model's benchmark status is `passed` only when every group meets policy. Context for background agents comes from `ContextRetrieval` (active task + ≤3 recent results + ≤2 problems, ≤1200 chars), never from the whole database.

## DEC-025 addendum (V0.3.1) — OpenCode generations
Status: Accepted
Decision: JARVIS supports OpenCode's classic (1.18.x) and v2 (1.19+) CLI generations, chosen at runtime from the CLI's own `--help` (`OpenCodeCapabilities`). Classic: `models --pure --verbose [--refresh]` + `run --pure …` + `opencode.json`. v2: documented `opencode api model.list` (bounded polling; the ONLY api operation ever invoked) + `run --standalone …` + `opencode.jsonc` with ordered `permissions` rules (`* ask`; deny `execute`, `edit`, `webfetch`, `websearch`; never deny `shell`/`read`). Free = every cost tier zero + status active + enabled + keyless provider `opencode`. Unknown generation ⇒ free pool disabled, never guessed. A clean exit with text is a complete answer when the v2 stream lacks its terminal event. `verify.sh` forbids credential/integration operation names.

## DEC-029 — One central sanitization boundary; raw provider output never becomes state
Status: Accepted (V0.3.2; motivated by the V0.3.1 `credential.list` incident that printed a credential into a tool output)
Decision: All provider/process/tool output is untrusted. It is sanitized exactly once, in `Observability/OutputSanitizer.swift` (`StreamSanitizer` per run, fed from `SafeProvider`), BEFORE it can reach SwiftUI observable state, console buffers, activity events, SQLite, artifact files or reports. `AgentConsoleEvent` sanitizes in its initializer; the hub, repository and artifact store accept only sanitized values; `SafeProvider` wraps every engine built by `IntelligenceCoordinator`. Render-time-only redaction is forbidden. The sanitizer fails closed (withheld marker, never raw text) and masks keys split across chunks. `Redactor` (V0.3.1) now delegates to it. JARVIS never invokes or exposes `credential.*` / `integration.*` and has no generic OpenCode API console (only `model.list`). `verify.sh` enforces the confinement (hub entry only via SafeProvider, events/artifacts written only by hub/repository, no raw `agent_events` INSERT, coordinator wraps SafeProvider). Tests use obviously fake secrets only.
Consequences: a bug in a provider parser cannot leak; the cost is a regex pass per streamed chunk (measured below in `AGENT_OBSERVABILITY.md`/PROJECT_STATE).

## DEC-030 — Observation is a second consumer of ONE execution; progress and states are never invented
Status: Accepted
Decision: The console shows the same stream the agent runtime consumes (no second provider process, no attach/tail). Progress percentage exists only for declared structured/weighted steps; real CLI/local runs are `unknown` (indeterminate, elapsed time) and `progressSource` is persisted. Provider state is a pure function (`ProviderStateResolver`): RUNNING only from an active hub execution; READY ≠ RUNNING; downloaded ≠ loaded; STARTING while the local model loads. Stale RUNNING rows from a previous process become INTERRUPTED with a persisted reason at launch. Developer simulation is `isSimulated`, labelled, never persisted.

## DEC-031 — Agent Console is read-only; Stop only through existing cancellation; no Pause
Status: Accepted
Decision: The console has no input because none of the Claude Code / Codex / OpenCode / local integrations accepts same-session input (capability matrix in `AGENT_OBSERVABILITY.md`). Stop = the existing cancellation path (kills the real process tree; run ends CANCELLED). No Pause for agents (cannot be done truthfully). No pty, shell or `sh -c`. A future interactive "Developer Terminal" is a different feature and needs explicit approval and its own decision record.

## DEC-032 — Bounded observability memory and persistence
Status: Accepted
Decision: Per run ≤600 console events / ≤80 000 characters / ≤1 000 000 characters of output log (then marked truncated); ≤400/4 000 characters per event summary/detail; UI revisions coalesced (~120 ms); SQLite writes batched (~500 ms); events older than 30 days pruned at launch. Hidden consoles cost nothing per frame (no view, no timers); the console view is AppKit `NSTextView` (selectable, native ⌘C), never a per-token SwiftUI text diff.
