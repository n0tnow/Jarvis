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

## DEC-033 — V0.4 executes USER-INITIATED goals only; the TaskEngine owns orchestration above the existing systems
Status: Accepted (V0.4)
Decision: A task starts only from a user goal (typed today; voice/LLM callers will use the same `GoalIntake` → `TaskEngine.submit`). The engine may make the implementation decisions needed to complete the approved goal, but never invents unrelated work: proactive proposals/autonomy policy are V0.5 and are NOT implemented. The engine adds orchestration only — routing stays with `ModelRouter`, lifecycle/cooldown with `ProviderSupervisor`, limits with `ResourceManager` (unchanged: 1 local · 2 free-cloud · 1 heavy · 3 total · depth 1), observation with `ExecutionHub`/the Observatory, sanitization with `SafeProvider`/`SafeToolOutput`, state with SQLite. A task is persisted BEFORE substantial execution begins. Goal intake keeps conversation, deterministic commands, knowledge questions and long text out of the engine.

## DEC-034 — Providers stay text-in/text-out; JARVIS applies changes through typed, capability-scoped tools; no shell
Status: Accepted (V0.4)
Context: V0.3 deliberately made providers conversation-only and `verify.sh` forbids `workspace-write`/dangerous flags. V0.4 needs project changes.
Decision: Do NOT relax provider sandboxes. A coding agent returns SEARCH/REPLACE / CREATE blocks as plain text; JARVIS parses and applies them with `ProjectTools` (prepare → approvals → write lease → atomic apply with rollback → hash verification). Task-scoped `TaskCapability` (`readProject`, `writeProject`, `runBuild`, `runTests`, `destructiveFileOperation`) is checked by every tool; `useNetwork`, `useBrowser`, `gitCommit`, `gitPush`, `purchase` can never be granted (stripped in `CapabilitySet.init`, pinned by tests and `verify.sh`). `destructiveFileOperation` is granted per approved action only. Build/test run via `CommandRunner` on an executable allowlist (no shell/env/downloader/Git) with a per-tool argument policy through `ManagedProcess` (argv, scrubbed environment, timeout, merged stderr, sanitized output). There is no generic "run a command" tool. Consequence: capability, workspace, lease, audit and sanitization are enforced in one place regardless of provider; the cost is that providers only see the context JARVIS builds (targeted files), not their own tool loops.

## DEC-035 — Machine-readable, validated plans; planning is never a local-model job
Status: Accepted (V0.4)
Decision: The planner returns ONE JSON object; `PlanParser`/`PlanValidator` enforce schema, ≤12 steps, unique ids, existing dependencies, no cycles, known step types/validations, task-kind capabilities, explicit destructive targets (only when the goal asked), prohibited operations, recursive-agent keys, paid providers and local-model development. A known-but-misplaced validation label is coerced to the step type's own validation (a real planner labelled a delete step "structuredResult"); unknown labels are rejected. A malformed plan is re-asked once, then on one other provider (Auto only); a policy violation is never repaired (`securityBlocked`). Task prompts are development work (`containsProjectCode`, `requiresCoding`) so `LocalModelPolicy` excludes the local model in code; free models need a passed coding benchmark in Auto and zero-retention for project code (DEC-025/026 unchanged).

## DEC-036 — Deterministic validation first; repair and escalation are bounded
Status: Accepted (V0.4)
Decision: "The agent says it worked" is never evidence. Edits are validated by hashes on disk, builds/tests by real exit status (counts only when the tool printed them), plans by schema + policy; only the review verdict (and the JSON shape of analysis answers) involves a model. A failing build/test with a preceding code step triggers at most ONE repair on the same engine (pinned, with the real failure output) and ONE escalation to another provider (Auto only, `exclude` = engines already used): ≤3 attempts per code step, each provider job allowing one format re-ask. Provider failures skip the repair. Explicit provider modes never escalate. Every attempt is persisted with engine/model/outcome/evidence. No unbounded retry loop exists anywhere.

## DEC-037 — Workspace containment, write leases and user-change protection
Status: Accepted (V0.4)
Decision: A development task has one explicit project root (`WorkspaceGuard`: absolute, existing, narrow; relative paths only; `..`/`~` rejected; symlinks resolved with `realpath` and verified inside; `.git`, `.ssh`, `.env*`, keys/credentials protected for read and write; credential-looking files are never sent to providers). Writers need a per-file lease (`FileLeaseManager`: persisted, case-insensitive, all-or-nothing, waiting second writer, stale after crash). Before the first write a Git baseline is recorded; touching a file that already has uncommitted changes needs an approval (SEARCH/REPLACE edits preserve the user's other changes; flagged `preexistingUserChange`). JARVIS never resets, cleans, checks out, commits or pushes (no such operation exists in `GitTool`; `verify.sh` forbids them).

## DEC-038 — Durable tasks, checkpoints, restart reconciliation, explicit resume
Status: Accepted (V0.4)
Decision: Task/step/attempt/approval/lease/file-change state lives in SQLite (schema v3); coherent boundaries write a checkpoint artifact (plan version, step states + evidence, changed files with hashes, Git baseline, leases, approvals, cumulative diff) and the terminal state writes a report built only from persisted records. At launch stale `running/planning/ready` tasks become INTERRUPTED (never "running forever"), stale leases and agent runs are reconciled, waiting approvals wait again — nothing resumes automatically (a restart must not silently spend quota or repeat work). An explicit `resume` reconciles each interrupted step by idempotency: read/build/test rerun; a code step inspects the disk first (verified → kept, untouched → redone, diverged → fail `workspaceChanged`); a delete is never replayed without a fresh approval. Quitting JARVIS is not a denial (waiting approvals survive). A task does not run after the process exits (no daemon).

## DEC-039 — Destructive actions and user-dirty files wait for approval
Status: Accepted (V0.4; the full approval/autonomy policy is V0.5)
Decision: `delete` steps (only plannable when the goal asked for deletion, with explicit targets, risk high) and edits to files with uncommitted user changes create a durable `approvals` row (task `waitingForApproval`, step `waitingForApproval`); nothing executes until `TaskEngine.decide`. Denial resolves safely (task `failed` · `approvalDenied`, files untouched). Purchases, paid-provider activation, credential changes, git push, deployments and project-wide deletion are not available in V0.4 at all.

## DEC-040 — The task engine reuses the V0.3.2 Observatory; progress comes from validated steps; no Pause
Status: Accepted (V0.4)
Decision: No parallel monitoring UI. Every step execution is an `agent_runs` row + hub run with `task_id`; deterministic tools run as `ProviderID.tool` runs (never routed, not in `allCases`, no provider card). Run ownership `.task` routes Observatory Stop to the whole task (existing cancellation, propagated downward). Task progress = validated steps / non-skipped steps (`ProgressSource.structuredSteps`, persisted); provider prose has no input path. Engine tasks are projected into `JarvisStore` (`JarvisTask.engine`) so Compact/Dashboard/Tasks use the existing components; Compact stays 392×448. Autonomous tasks cannot be paused (a provider process cannot be paused truthfully); Stop and (after a restart) Resume exist.

## DEC-041 — V0.5 is a decision layer above V0.4; it never executes
Status: Accepted (V0.5)
Decision: Proactive reasoning (`Sources/Jarvis/Proactive/`) observes, detects, assesses and decides; it has no file-write, process, network or credential code and never approves anything. Every automatic or approved action becomes an ordinary V0.4 task (`TaskEngine.submit` with persisted `origin`, `originTaskID`, `originOpportunityID`, `autonomyDepth`, `scope`), so persistence, planning, plan validation, capabilities, workspace containment, leases, validation, repair/escalation limits, cancellation, checkpoints, recovery, sanitization, observability and reports all apply unchanged. `verify.sh` and unit tests enforce it (no writes/processes/timers in `Proactive/`, read-only `ProjectTools`, task creation only through `OpportunityEngine`).

## DEC-042 — Deterministic policy outranks model confidence; models can only add caution
Status: Accepted
Decision: `OpportunityPolicy` is a pure function with fixed precedence (critical > design/product/security > scope > low-risk local maintenance), then capped by the autonomy mode. Confidence is derived from checkable evidence and is only evidence: it can make a result quieter (propose → record), never louder. Model output (assessor JSON, review suggestions) is merged monotonically (`mergeModelAssessment`: risk only up, design impact only on, effects/capabilities only added, restrictive category adopted); authority-bearing fields are never parsed; a model's requested capabilities are requests checked against the V0.4 capability system (never-grantable ones ⇒ critical approval). A model-supplied file reference is a claim, not strong evidence.

## DEC-043 — Event-driven, budgeted proactive reasoning; no continuous cloud cognition
Status: Accepted
Decision: Triggers are task completion/failure and review suggestions (held until the task ends). Findings derive from facts JARVIS recorded (changed files, validation results, failures) — no model call. A free-text finding may use ONE assessor call per originating task (development routing: never the local model; free benchmarked OpenCode first, then Claude/Codex; reason recorded). No timers, no polling, no filesystem watching, no repository scans, no idle provider calls. Proactive reasoning can be switched off in Settings.

## DEC-044 — Autonomy modes, conservative default, narrow auto actions, bounded chains
Status: Accepted
Decision: `Observe Only` / `Ask Before Acting` (default) / `Low-Risk Autonomous`. AUTO_ACTION requires every one of: low-risk mode, concrete action, origin = a user task at depth 0, budget left, category testCoverage/maintenance/bug, direct relation, low risk, reversible, non-destructive, no design impact, no external effect, small scope, capabilities ⊆ {read, write, build, test}, strong evidence, confidence ≥ 0.6. Budget: 1 automatic task per originating user task, depth 1; automatic and approved-proposal tasks may record or propose but never create automatic tasks. Critical actions and design/product decisions need explicit approval in every mode.

## DEC-045 — Proposals and approvals: scope-bound, durable, user-only, never a capability
Status: Accepted
Decision: Proposal approval reuses the V0.4 `approvals` table (kind `proposal`, `proposal_id`, `scope_hash`). `ProposalService` is the only writer of decisions (HUD buttons via `DecisionSource`; no text API ⇒ no self-approval). The approval binds to `action_hash` (opportunity, workspace, goal, scope, kind, risk, category); a changed proposal is refused. Approving a proposal that needs capabilities/external effects/destructive actions V0.4 lacks ends as `unsupported` — approval never creates a capability. The generated task carries a `TaskScope` enforced in the plan and on every edit (`scopeExceeded` ⇒ nothing beyond scope runs; opportunity `needsReapproval`). Stale proposals are re-validated against machine-checkable evidence and become `obsolete` instead of modifying the project.

## DEC-046 — Deduplication, coalescing, cooldown and idempotency
Status: Accepted
Decision: Identifier/synonym-folded token keys + similarity per project/scope; same event ⇒ one record; related easy-to-merge findings coalesce into one card; deny = 14-day, dismiss = 3-day cooldown (persisted), ignored proposals expire after 7 days; reworded asks about the same file are suppressed during a cooldown unless materially new deterministic evidence appears. Ids are deterministic (opportunity ← event key, proposal ← opportunity, task ← proposal/opportunity) and launch reconciliation completes half-finished decisions exactly once.

## DEC-047 — Unity is reached through a JARVIS-owned Editor bridge over a local file spool (no third-party MCP, no socket)
Status: Accepted (V0.6)
Decision: The bridge is a small C# Editor package (`UnityBridge/com.jarvis.bridge`, embedded in the app, installed as `Packages/com.jarvis.bridge` only after an approval, no manifest edit). Requests/responses/status are files under `<project>/Library/JarvisBridge` written with atomic renames; JARVIS watches them with vnode sources and a process-exit source (event-driven, nothing polls while idle). No third-party Unity MCP was installed or used. Rationale: the requirement is typed, capability-controlled, observable operations, not "MCP"; a file spool needs no socket/network/permission, survives domain reloads, and keeps the JARVIS binary free of network code. See `docs/UNITY_PROJECT_AGENT.md`.

## DEC-048 — Unity capability layer lives inside V0.4; only typed operations exist
Status: Accepted
Decision: `UnityOperation` is a closed enum; there is no operation (and no provider-facing tool) that carries C#, a menu item, a command, a shell line or AppleScript, and the bridge rejects unknown operations itself. Unity work is expressed as V0.4 steps (`unityInspect/Edit/Compile/Test/PlayMode/Validate`) with new task capabilities (`inspectUnity`, `readUnityConsole`, `modifyUnityScene`, `saveUnityScene`, `createUnityPrefab`, `runUnityCompile`, `runUnityTests`, `controlUnityPlayMode`, `deleteUnityObject`). Analysis tasks get inspection only; development tasks the bounded set; deletion is not a task capability (goal must ask + per-action approval); package installation, project upgrade, Asset Store and downloads are not capabilities at all. A Unity agent only PROPOSES typed actions; JARVIS validates, applies and verifies them; no parallel task engine, approval system or log viewer.

## DEC-049 — Deterministic Unity evidence outranks subjective review; no fake visual validation
Status: Accepted
Decision: Compile state, test results, expected object/component/property state and new-Console-error deltas are facts produced by the editor through JARVIS' tools; a model cannot contradict them. They prove compilation/structure/tests — not architecture, gameplay or visual quality, which stay review/proposal matters. Unity reports always state "Visual validation: NOT PERFORMED" (nothing captures or inspects an image in V0.6).

## DEC-050 — Review authority (generic; supersedes "a failing review always fails the task")
Status: Accepted
Decision: `ReviewAuthority` decides what a review verdict means for every task: a passing review passes; a failing review fails the task only if (a) no hard validator (build/test/Unity compile/tests/state/Play) has passed, or (b) it names a *blocking* issue whose quoted evidence JARVIS finds in the recorded diff/evidence/changed paths, or (c) the user's constraints require a review gate. Otherwise the step passes with the review kept as advice in the report. A failing hard validator is never rescued by a review. Reason: the V0.5 live test showed a free reviewer rejecting an in-scope, test-passing change on a judgement call.

## DEC-051 — Script edits stay on the V0.4 file path; scenes/prefabs only through Editor APIs
Status: Accepted
Decision: C# changes use `codeChange` (workspace guard, hashes, leases, Git baseline, rollback info); scene/prefab/serialized changes use Editor APIs (Undo-recorded `SerializedObject`/`AddComponent`/…) through the bridge. Scene YAML is never rewritten by JARVIS or a model.

## DEC-052 — All Unity output is untrusted and sanitized at single choke points
Status: Accepted
Decision: Editor answers pass `UnityResponseSanitizer` in `UnityConnection.perform` (identity strings validated by shape); Console entries and compiler errors are sanitized in their initializers; the launched editor's stdout is drained through the stream sanitizer into a bounded in-memory tail. Raw Unity output is never written to SQLite, artifacts, events, reports or provider context. A Console baseline is captured per Unity task so existing errors are never attributed to it.

## DEC-053 — Play Mode policy
Status: Accepted
Decision: Persistent project mutation (scene operations and script edits) is refused while Play Mode is active, in the Swift policy and independently in the bridge. A Play step waits for the editor to *report* each transition, observes for a bounded time, and always leaves Play Mode again; it never takes over a Play Mode it did not start, except one left in an editor JARVIS itself owns.

## DEC-054 — User-owned unsaved state and project versions are protected
Status: Accepted
Decision: Scenes dirtied by anything other than JARVIS are *user-dirty*: a mutation/save touching them needs an approval (deny ⇒ nothing changes); opening scenes or running tests with dirty scenes is refused. Scene files with uncommitted Git changes need the V0.4 approval too. A project declaring another Unity version is never opened/migrated without an explicit approval; the editor is started with `-disable-assembly-updater`.

## DEC-055 — Serialised editor access; per-project connections; JARVIS closes only editors it owns
Status: Accepted
Decision: One mutating Unity step (edit, compile, test, Play Mode, script change) per project at a time (`UnityMutationLock`). Handles are re-resolved every step and invalidated when the editor session changes. Each project has its own connection (spool, pid, session), editors are matched to projects by `-projectPath` — never "the first Unity process" — which also leaves room for several editors / Multiplayer Play Mode later. Only editors started by JARVIS are closed (graceful `shutdown`, idle one-shot, app quit).

## DEC-056 — Fixtures only; no acquisition; the real game is never an automated target
Status: Accepted
Decision: Automated V0.6 acceptance runs on a disposable fixture copied to a temp folder and a headless editor started and owned by the test. The user's real project is never opened or modified by automated tests. No Asset Store, downloads, licence handling, package installation or purchases exist in V0.6 (V0.7+).

## DEC-057 — Voice is an I/O layer around the existing conversation pipeline, never a second intelligence
Status: Accepted (V0.7)
Decision: Spoken input and typed input converge BEFORE routing: a FINAL transcript is submitted through the same `ConversationService.submit` (wired once, in `AppContext`; the only difference is `source: .voice`, a label with no authority). Router, `GoalIntake`, providers, `TaskEngine`, V0.5 policy, persistence and observability are unchanged. Only the FINAL transcript ever enters the pipeline; a partial transcript is provisional, lives in the composer area, and is never a message, a task goal, a log line or a database row. A spoken task goal becomes a normal V0.4 task (`tasks.input_channel = 'voice'`, schema v6, informational only: `origin` stays `userTask`, capabilities/risk/approvals are identical). `verify.sh` and unit tests pin that the voice layer cannot reach approvals, tasks, files, repositories or the conversation store.

## DEC-058 — Push-to-Talk is "hold the right Option key alone"; release is the end of the utterance; no always-on microphone in V0.7
Status: Accepted (V0.7)
Decision: PTT reuses the permission-free modifier-state sampling of the ⌥⌘ chords (one `GlobalHotkeyService`, no event tap/global monitor/Carbon hotkey, DEC-008/013): the RIGHT Option key (device-dependent flag bit read from the session flag state — `NSEvent.modifierFlags` hides it) held alone for 0.25 s with no other key or click starts capture; releasing it stops capture IMMEDIATELY (before any recognition work); an extra modifier or another key during the arming phase cancels (typing AltGr characters on a Turkish layout can never open the microphone); key repeat cannot restart it. Release — not VAD — is the authoritative endpoint (continuous endpointing, wake word, hands-free listening and barge-in belong to V0.8). The microphone engine is created on press and destroyed on release; nothing runs while idle; voice is OFF by default and the first press asks macOS for the microphone (never at launch, never in tests).

## DEC-059 — Raw audio is ephemeral; the microphone usage string is the only privacy key
Status: Accepted (V0.7)
Decision: Audio exists only in memory for one push-to-talk session (bounded: 60 s hold limit, bounded frame queue, 75 s helper buffer) and is never written to disk, SQLite, artifacts, logs or the repository (`verify.sh` greps for audio-writing code, audio columns and audio file types; the live test scans the data directory). Voice diagnostics record lengths, language, provider and latencies — not transcripts and not audio. `Info.plist` gains exactly `NSMicrophoneUsageDescription`; no entitlement; `verify.sh` fails on any other `NS*UsageDescription`. `AVCaptureDevice` appears in one file (`Voice/MicrophoneAccess.swift`), `AVAudioEngine` in one (`Voice/AudioInput.swift`).

## DEC-060 — Speech providers sit behind small protocols; selection is cost-first and explicit choices never fall back
Status: Accepted (V0.7)
Decision: `SpeechToTextProvider` / `TextToSpeechProvider` expose truthful availability (READY / needs explicit setup / unavailable), capabilities (languages, partial mode, language detection, confidence, cost class, network), and lifecycle (`unload`, `shutdownNow`). `VoiceProviderSelection` (pure): a PAID or UNKNOWN cost class is never auto-selected; Auto picks by measured accuracy among READY providers; under memory pressure a model-loading provider is skipped; an explicit choice that is not ready is refused with the reason (no fallback). No API key, paid API, cloud speech endpoint or credential exists anywhere (`verify.sh`). Nothing is downloaded by JARVIS: models/assets are installed only by an explicit user action (`scripts/setup_voice_ai.sh`, Settings → Install).

## DEC-061 — Default speech recognition: local Whisper (MLX) when installed and memory is normal; Apple on-device speech otherwise
Status: Accepted (V0.7) — evidence in `docs/VOICE_IO.md`
Decision: Measured on synthetic Turkish/English/technical speech (same fixtures, same host): Whisper-small (MLX) beats Apple's on-device recogniser on technical words and Turkish diacritics, detects Turkish/English for real and exposes a confidence; Apple is faster (≈60 ms finalisation vs ≈200 ms) and has native streaming partials but no language detection and no setup. Auto therefore prefers Whisper when it is installed and memory pressure is normal, and falls back to Apple (reason recorded). Both are local/system, offline, key-less and free. Apple's `SpeechTranscriber` has no Turkish on macOS 26.4, so Apple Speech uses `DictationTranscriber` (verified for tr-TR and en-US). Whisper is not natively streaming: previews are produced by re-decoding the audio so far (stated as such in the UI and docs).

## DEC-062 — Default speech output: Apple system voices with incremental sentence synthesis (not native streaming)
Status: Accepted (V0.7)
Decision: `AVSpeechSynthesizer` (on-device, free, Turkish "Yelda" + English voices present on the dev Mac; user may pick any installed voice, premium voices if the user installed them). It synthesises complete phrases one after another, so speech starts at the first stable sentence while the rest of the answer is still arriving — described everywhere as incremental sentence synthesis, never as native streaming. Neural alternatives (Piper, Kokoro, XTTS) were researched/benchmarked and are optional future providers (license/size/Turkish-support trade-offs in `docs/VOICE_IO.md`).

## DEC-063 — The spoken answer is the shown answer; speech rendering is presentation; long answers are bounded
Status: Accepted (V0.7)
Decision: `VoiceResponseSpeaker` follows the very messages the conversation shows (no second model call, no separate "text to say"). `SpeechChunker` (deterministic, streaming-safe — chunking is independent of how deltas are cut, property-tested) releases only stable sentences; `SpeechRenderer` removes markdown/URLs/paths/emoji and normalises symbols per language without folding Turkish letters or adding content; code blocks and tables are never read (one short note). `LongAnswerPolicy`: at most ≈520 characters / 7 phrases are spoken, then "The full answer is on screen." Typed turns are not spoken; task completion is never announced spontaneously (text/UI only) — background speech that surprises the user is deferred to a future, explicit design.

## DEC-064 — Speech can always be stopped at once; a stale phrase can never play
Status: Accepted (V0.7)
Decision: `stopSpeaking()` silences playback immediately and drops queued/in-flight phrases; it is reachable from the Stop button (Compact, Full), the menu bar, "stop talking", a new typed message, and a new Push-to-Talk (which stops speech BEFORE the microphone opens — an explicit stop, not conversational barge-in, which is V0.8; no echo cancellation exists, so JARVIS never listens while speaking). Chunk ids are unique across turns and every provider event is checked against the turn's in-flight set, so events from an earlier turn are ignored.

## DEC-065 — A spoken (or typed) "yes/approve" never approves anything
Status: Accepted (V0.7)
Decision: Approvals remain HUD buttons (V0.4 `TaskEngine.decide`, V0.5 `ProposalService`); there is no code path from text — typed or spoken — to a decision. While an approval is pending, a short reply made only of approval/denial words ("yes", "approve", "do it", "onayla", "evet", "hayır") is answered with "approvals are decided only with the buttons in the HUD" instead of being sent to a model (`ApprovalGuard`; typed and spoken alike); real requests that merely contain such a word are untouched. Voice carries no extra trust, and no less.

## DEC-066 — Voice sessions are ephemeral; the voice layer owns no durable state
Status: Accepted (V0.7)
Decision: Voice state (`IDLE/REQUESTING PERMISSION/LISTENING/TRANSCRIBING/THINKING/SPEAKING/ERROR`) is in memory and starts IDLE at every launch — LISTENING/SPEAKING/TRANSCRIBING are never restored. `listening` is shown only while capture really runs; `speaking` only once audio started; failures return to IDLE (an error clears itself after 6 s) and text stays fully usable. Preferences (enabled, language, providers, voices, rate) are UserDefaults like all other settings; the only database change is the informational `tasks.input_channel` column.

## DEC-067 — Speech helper resource policy: on demand, idle unload, pressure unload — decided by measurement
Status: Accepted (V0.7)
Decision: The Whisper helper (≈0.86 GB resident while loaded, ≈1.6 s cold start, 0 % CPU idle) starts on the first utterance, unloads after 120 s idle (Settings), and unloads on memory-pressure rise (`ResourceManager.observePressureRise`, same event as the local model); it never unloads during an utterance; Auto skips it under pressure. No Unity-specific rule exists: the combined measured state (Unity + provider + Whisper) stays within the 16 GB budget, and the pressure signal is the arbiter. Apple's recogniser and synthesiser run in system services (a few tens of MB observed). The helper is launched only through `ManagedProcess`, killed with the app tree on quit/SIGTERM (live-tested) and never outlives JARVIS (stdin EOF).

## DEC-068 — Roadmap correction (supersedes the V0.7+ rows of the V0.6 roadmap)
Status: Accepted (V0.7)
Decision: V0.7 Voice I/O Foundation (this milestone) · V0.8 Natural Voice Session (wake word, VAD, hands-free turn-taking, barge-in, interruption) · V0.9 Web Research & Asset Acquisition · V0.10 Project Memory · V0.11 General Computer Use · V0.12 Advanced Multi-Agent / Routing · V1.0 integrated stable JARVIS. Asset acquisition is NOT V0.7. Items of the old plan that are not in the new list (Unity multiplayer workflows, self-controlled UI, reports) are unscheduled backlog attached to the nearest milestone (see `docs/ROADMAP.md`).


## DEC-069 — Wake mode is opt-in; the microphone model changes explicitly
Status: Accepted (V0.8)
Decision: Wake listening is OFF by default (`Key.wakeEnabled … ?? false`), is never started unconditionally (only `HandsFreeCoordinator.applySettings()` — saved preference + voice enabled + microphone allowed + helper installed), and the menu bar/Settings can switch it off at any time; Push-to-Talk (right ⌥) is unchanged and works with wake mode off, failed or unavailable. Turning wake mode off stops the helper and removes the microphone engine.
Why: continuous listening is the largest privacy change since V0.7; it must be a visible, deliberate choice. `verify.sh` and unit guards pin the default and the single entry point.

## DEC-070 — The wake word is detected locally by a small head on frozen speech features, trained on synthetic speech
Status: Accepted (V0.8)
Decision: `jarvis_sentinel_worker.py` (ONNX Runtime, CPU, one thread, offline, no key) runs openWakeWord's frozen mel + speech-embedding models (Apache-2.0, release v0.5.1, pinned SHA-256) and the JARVIS head `jarvis_head.npz` trained locally (`scripts/train_wake_head.sh`) on synthetic speech from Supertonic 3 with augmentation and three hard-negative mining rounds. Shipped rules: threshold 0.9, patience 3 (240 ms), utterance-initial (`WakeContextGate`, segment ≤ 1.6 s). The pretrained "hey jarvis" model is NOT used (CC BY-NC-SA weights, phrase "Hey Jarvis", bare word 19 %). Cloud/keyed engines (Porcupine) and continuous-STT wake are excluded by policy.
Why: measured on 133 held-out clips (unseen Apple voices) and 2.9 h of ordinary speech: 70/70 positives, 0 false events (`docs/NATURAL_VOICE.md` §3, `tune_wake_rules.py` sweep). Honest limits: synthetic evidence only; acoustic look-alikes can fire (JARVIS-V08-1).

## DEC-071 — The wake buffer is bounded and memory-only; full STT never runs before the wake word
Status: Accepted (V0.8)
Decision: Before wake only the sentinel hears audio: a ≤ 3 s ring (`AudioRing`), an energy gate that sends the helper nothing in a quiet room, a bounded 120-frame queue, 100 ms messages; no recogniser session, transcript, task or log exists. A lone "Jarvis" never opens the recogniser (`continuationSeconds` decides whether speech continues in the same breath). Nothing is written to disk (no audio code, no schema; live test scans the data and runtime directories).
Why: the privacy model must be provable, not promised.

## DEC-072 — Wake is activation, not authentication; voice authority is unchanged
Status: Accepted (V0.8)
Decision: Anyone near the microphone can wake JARVIS; a hands-free transcript has exactly the authority of typed text and passes `ConversationService.submit(source: .voice)`; spoken "approve/yes/evet onayla/tamam yap" never approves (ApprovalGuard, V0.7 DEC-065, live-tested through the wake path); no voice biometrics, no spoken confirmation protocol; media, other people and JARVIS' own voice are not trusted more than typing.
Why: authentication is out of scope; the existing approval boundary is the safety net.

## DEC-073 — VAD is Silero (in the sentinel); the energy detector only gates
Status: Accepted (V0.8)
Decision: Silero VAD (MIT, 1.8 MB ONNX) runs in the same helper as the wake head (no extra runtime). The adaptive-energy detector failed in 12 dB noise (never ended a segment, fired on a fan) and is used only as the idle gate (`EnergyGate`). VAD never carries authority.
Why: benchmark on pause/noise fixtures (`bench_vad.py`).

## DEC-074 — Natural endpointing is hint-based, bounded and LLM-free
Status: Accepted (V0.8)
Decision: `EndpointPolicy`: 0.5–0.65 s after a finished sentence, 1.0 s unknown, 1.5 s unfinished, hard cap 1.7 s, turn cap 45 s; the hint is the recogniser's provisional transcript, refreshed by an immediate preview when the VAD closes; a stop after a hesitation («Unity'deki.») is not trusted.
Why: 0.9 s hesitations must not split a turn (measured); finished commands should not wait a full second (0.5–0.68 s measured).

## DEC-075 — One turn manager coordinates I/O only
Status: Accepted (V0.8)
Decision: `TurnMachine` (pure) + `HandsFreeCoordinator` (effects) own wake/VAD/utterance/endpoint/response/barge-in states; the V0.7 `VoiceCoordinator` still owns the capture/STT/submit session; Push-to-Talk wins over hands-free at any time; follow-up windows (8 s, ≤ 8 turns) are bounded and not opened after a PTT turn; restart never restores an active state. No reasoning, approval, file or task code is reachable (structural guards).
Why: one authoritative state, no second assistant.

## DEC-076 — Barge-in uses JARVIS' own known output, not an echo canceller
Status: Accepted (V0.8)
Decision: Speech is played by JARVIS' own output engine (`SpeechPlayer`), so the reference level is known; `BargeInDetector` fires on mic ≥ 8 dB above the predicted echo + VAD speech + ≥ 0.3 s + ≥ 65 % duty; coupling learned per playback but capped; transcripts that quote JARVIS' own recent speech are dropped. Voice Processing I/O was measured and rejected as the default (≈ 15 % of a core continuously, partial cancellation of other processes' audio, fragile (re)initialisation). No claim of full-duplex AEC.
Why: simplest robust solution with evidence (real coupling on this Mac; closed-loop live test: onset→decision 320 ms, stop 24–36 ms, no false barge-in).

## DEC-077 — JARVIS must never create a turn from its own voice
Status: Accepted (V0.8)
Decision: Wake events are ignored unless the turn manager is in WAKE and nothing of JARVIS is audible and 0.7 s passed since it spoke (ring cleared); VAD during speech feeds only the barge-in detector; the post-recognition quote filter is the last net. Tested with JARVIS saying «Jarvis» over its own echo.
Why: mandatory requirement; also protects against media saying the name only to the extent that the rules (utterance-initial, patience) do.

## DEC-078 — The preferred JARVIS voice is local neural (Supertonic 3); Apple system voices remain the fallback
Status: Accepted (V0.8) — naturalness NOT verified by a human
Decision: `neural-supertonic` (ONNX Runtime CPU helper, model `Supertone/supertonic-3` @ `724fb5ab…`, OpenRAIL-M weights / MIT code, 381 MB, ≈ 0.5 GB RSS, offline, no key, cost class LOCAL) is chosen by Auto when installed, healthy and memory pressure is normal; otherwise `apple-synthesizer`. Category: incremental chunk TTS. Rejected: Chatterbox (1.8–3.2 GB, 4.2 GB peak, 2 s first audio), Piper (three unrelated speakers, NC/unclear voice licences, GPL engine), Kokoro (no Turkish).
Why: same speaker style in Turkish and English, latency/memory/licence acceptable. Quality is a listening decision (manual A/B in Settings → Voice).

## DEC-079 — JARVIS Voice Identity v1 is original and provider-independent
Status: Accepted (V0.8)
Decision: `JarvisVoiceIdentity` describes the character (mature male, calm, precise, restrained, medium-low, short pauses); `VoiceIdentityMapper` maps it to a synthesiser (presets Default = M5, Calm = M3, System Fallback). No actor/performer/person is imitated or cloned; no reference-voice input exists (`verify.sh`).
Why: the product identity must not depend on, or infringe, anyone's voice.

## DEC-080 — Microphone and speaker have explicit owners
Status: Accepted (V0.8)
Decision: `MicrophoneHub` is the only path to the microphone engine (wake subscription, utterance, Push-to-Talk adapter; engine exists only while subscribed); `SpeechPlayer` is the only output engine (output only, no input node); helpers go through `HelperHost` → `ManagedProcess`.
Why: no two capture engines, no PTT-vs-wake fights, testable transitions.

## DEC-081 — Voice turns ask the existing provider for a speakable answer; the answer stays one
Status: Accepted (V0.8)
Decision: `ResponsePresentation.voiceConversation` prepends a one-line preamble to the prompt of voice turns (all providers); no second model call rewrites anything; speech = the shown answer (V0.7 DEC-063).
Why: concise spoken answers without a second, contradictory text.

## DEC-082 — Mixed-language handling is bounded
Status: Accepted (V0.8)
Decision: `LanguageContinuity` keeps the reply language inside a conversation; `TechnicalTerms` only restores canonical spelling of a fixed term list in final transcripts (never adds/guesses words). Whisper turbo stays an optional model.
Why: mixed Turkish/English recognition is still the weakest case; no hallucinating post-processing.

## DEC-083 — No surprise speech
Status: Accepted (V0.8)
Decision: JARVIS speaks only answers to voice turns, previews and the wake acknowledgement; task completion, proposals and approvals are never announced aloud; a spoken acknowledgement of the wake word is optional (default: a short sound, no speech).
Why: V0.8 adds presence, not interruptions.

## DEC-084 — Helper supervision and resource policy
Status: Accepted (V0.8)
Decision: `HelperHost` (state, bounded restarts: 3 per 10 min then cooldown, controlled stop, tree kill at quit), sentinel liveness ping only while audio flows, neural voice on demand + 180 s idle unload + memory-pressure unload (the 124 MB sentinel stays), Auto falls back to Apple under pressure.
Why: correctness over premium voice quality; no orphans; no idle timers.

## DEC-085 — Models and runtimes are installed only by explicit scripts; weights are never committed
Status: Accepted (V0.8)
Decision: `scripts/setup_voice_ai.sh --natural` (pinned revisions/checksums) and `scripts/train_wake_head.sh`; `verify.sh` forbids tracked `onnx/npz/safetensors/gguf/audio`; JARVIS and its helpers never download (`auto_download=False`, `HF_HUB_OFFLINE`).
Why: no surprise multi-GB downloads, reproducible provenance (`NATURAL_VOICE.md` §3.3, §8).

## DEC-086 — Roadmap name for V0.8
Status: Accepted (V0.8)
Decision: V0.8 is "Natural Voice & Presence" (local wake word, VAD, hands-free turn taking, barge-in, self-speech suppression, neural JARVIS voice, prosody/identity, conversational latency). V0.9 Web Research & Asset Acquisition · V0.10 Project Memory · V0.11 General Computer Use · V0.12 Advanced Multi-Agent/Routing · V1.0 stable. Supersedes only the V0.8 row name of DEC-068.

## DEC-087 — Barge-in measures the speech band in 20 ms slices; speech inside a deaf window is re-checked
Status: Accepted (V0.8; refines DEC-078/079, supersedes nothing)
Decision: the barge-in level is taken from the microphone after a 250 Hz second-order high-pass (`SpeechBandFilter`) and fed to `BargeInDetector` in 20 ms slices, so the ≥ 65 % duty rule works per slice (a dense click train or a door thud no longer looks like speech while the VAD is saturated by JARVIS' own echo). `TurnMachine` re-checks the VAD (`.deaf` timer) when speech began inside the acknowledgement/post-speech deaf window and is still going after it (a «Jarvis, … open the Tasks screen» comma pause used to lose the rest of the sentence). A diagnostics-only, text-free event trace (`HandsFreeCoordinator.eventTrace`, 80 entries, memory only) records names and times of turn events.
Why: found by the closed-loop live test (clicks at +6 dB and a thud interrupted the answer; the one-breath English command was lost); both failures were reproduced and fixed with unit tests. Limits: JARVIS-V08-5 (a quiet voice under a loud echo may not interrupt).



## DEC-088 — Five authority levels, kept apart; V0.9 implements three
Status: Accepted (V0.9)
Decision: RESEARCH · ACQUISITION · IMPORT/PROJECT WRITE · ACCOUNT ACTION · COMMERCIAL are different authorities (`AuthorityLevel`). V0.9 implements the first three, each with its own typed capability (`researchWeb`, `downloadToQuarantine`, `importIntoProject`). Account actions (sign in, accept terms, claim, OAuth) and commercial actions (purchase, subscription, paid trial, paid API) have **no code path**; they are always "open it yourself". `useNetwork`/`useBrowser` stay ungrantable; the typed web capabilities are the only door.
Why: "find me a free asset" must never drift into "I signed up and paid for it".

## DEC-089 — Research is an ordinary V0.4 task with a fixed plan
Status: Accepted (V0.9)
Decision: `TaskKind.research` / `.acquisition` (an import is a `.development` task). Plans are deterministic (`ResearchPlanner`: search → read → extract → [verify → compare] → report), every step has a validation and a budget; models are called only inside steps for validated JSON (≤3, deep ≤5). No autonomous browse-until-satisfied loop, no new agent runtime. Voice and the V0.5 proposal path reach it through the same `TaskIntake`.
Why: reuse approvals, cancellation, checkpoints, restart reconciliation and observability instead of a second engine.

## DEC-090 — Web content is untrusted data, never instructions
Status: Accepted (V0.9)
Decision: page/search/API text is fenced (`UntrustedContent.fence` + preamble, invisible characters stripped), scanned for instruction patterns (reported, ignored), and cannot create steps, approvals, downloads or tool calls. A model-extracted claim is accepted only if its quoted excerpt is verbatim in the cited page (`Grounding.isGrounded`); a model-invented URL is replaced by the page that mentioned it.
Why: the web is where prompt injection lives.

## DEC-091 — Evidence honesty: snippets are not evidence; UNKNOWN is never good news
Status: Accepted (V0.9)
Decision: search snippets are discovery only; price, licence, compatibility, availability, security and API behaviour are decided only by an official/first-party non-snippet source (`SourceClassifier.mayDecide`). UNKNOWN price is never free, unknown licence is never safe, a promotion is not free, stale (> 24 h) price evidence must be re-verified before an automatic download. Fact / assessment / recommendation are separate in the report; contradictions are listed, not resolved silently.
Why: this is what makes the answer usable for a decision.

## DEC-092 — HTTP/structured first; one read-only browser tier; no computer use
Status: Accepted (V0.9)
Decision: order of access: structured API / plain HTTP → system WebKit in a non-persistent store (read-only, constant extraction script, private ranges blocked, torn down when idle) → stop and report "interaction required". No Safari/Chrome cookies or passwords, no Keychain web credentials, no CAPTCHA bypass, no clicking/typing in pages (that is V0.11). Playwright/Node was evaluated and not adopted (adds a runtime and a browser download, gives nothing the system WebKit lacks for reading).
Why: zero new dependencies; smallest possible capability.

## DEC-093 — Search sources: keyless, honest, no evasion
Status: Accepted (V0.9)
Decision: DuckDuckGo HTML (robots `Allow: /`; a challenge page stops the provider), GitHub, Hacker News, Stack Exchange (public API; the HTML pages answer 403 and are not scraped around), Poly Haven, Kenney, a deterministic Unity ScriptReference resolver. Excluded: Brave (key), any paid search API, the Unity Asset Store (account-bound, no public API). Queries sent to AND-matching engines are shortened (`SearchTerms.core`).
Why: no key, no cost, no terms violations.

## DEC-094 — One URL policy, production-grade everywhere
Status: Accepted (V0.9)
Decision: `URLPolicy`/`URLGate` refuse loopback, private, link-local/metadata, CGNAT, multicast, numeric-IP spellings, `file:`/`ftp:`/custom schemes, credentialed URLs and `%` in the authority; DNS is checked before connecting, every redirect hop is revalidated, the connected address is checked again; sessions are ephemeral (no cookies/credentials/cache); per-host rate limits. Tests use the SAME policy with *virtual public hosts* — there is no loopback exemption.
Why: an SSRF fix that tests bypass is not tested.

## DEC-095 — Downloads go to a quarantine and are not trusted
Status: Accepted (V0.9)
Decision: https only, bounded (250 MB/file, 600 MB/session, time, redirects, disk), incremental SHA-256+MD5, published checksums compared (never invented), `.part` deleted unless complete and verified, content sniffed (HTML-as-zip, MIME lies, executables refused), `com.apple.quarantine` set, files only under `acquisitions/`. Archives are listed before extraction (traversal, absolute paths, symlinks, special files, bombs, ratio, depth, lying size headers, CRC); tar.gz/`.unitypackage` are listed only; rar/7z are rejected. DOWNLOADED ≠ INSPECTED ≠ VALIDATED_FOR_IMPORT.
Why: a download is untrusted input to a machine that builds games.

## DEC-096 — Acquisition policy matrix
Status: Accepted (V0.9)
Decision: purchase/paid → rejected; free-but-login/claim → rejected as account action; no verified route → rejected; automatic only for a public direct download with FREE_VERIFIED ≤ 24 h, a licence that allows commercial use and modification from an official source, origin trust ≥ 3 and ≤ 100 MB; everything else needs a HUD approval listing the exact reasons. The candidate is re-verified immediately before downloading. Approval grants no capability; voice cannot approve.
Why: the cheap, safe case is frictionless; every doubt is a human decision.

## DEC-097 — Import belongs to V0.4/V0.6, not to research
Status: Accepted (V0.9)
Decision: import is a separate development task with the capability `importIntoProject`, a plan the user approves (destination `Assets/ThirdParty/<slug>-<id6>`, files, skipped scripts/native/executables, bytes, source, licence), `AssetImporter` (workspace-guarded, hash-verified, never overwrites, only from a READY artifact, provenance file) and, in Unity projects, a V0.6 compile step. Code-bearing content is skipped unless explicitly approved. Automated tests import only into disposable fixtures; the user's real game is never an automated target.
Why: V0.6 already owns project writes and Unity state.

## DEC-098 — Explainable ranking with topical relevance
Status: Accepted (V0.9, corrected by the first live run)
Decision: weights: licence 0.20, price 0.15, compatibility 0.13, friction 0.09, trust 0.08, style fit 0.08 (model assessment, text only, labelled), maintenance 0.04, **topical relevance 0.23**. Hard violations (not free when free-only, no commercial use, account needed, incompatible, **matches none of the requested subject words**) mark a candidate *not recommended* regardless of score. Relevance compares stemmed non-generic subject words with the candidate's name/description/link.
Why: the first live run ranked a plunger, a drain cleaner and a flower equally with a bucket for "bucket and sink".

## DEC-099 — Research persistence: URLs and hashes, not pages
Status: Accepted (V0.9)
Decision: schema v7 stores sessions, queries, sources (URL, final URL, hash, bounded excerpt, method, trust), claims (evidence refs), candidates and acquisitions; reports are artifacts; **no page bodies, HTML or binaries in SQLite**. A restart marks in-flight research/downloads *interrupted*; only an explicit user Resume continues; a failed/cancelled task ends its research row.
Why: privacy, size, and a database that stays small.

## DEC-100 — Bounded research, nothing in the background
Status: Accepted (V0.9)
Decision: fixed budgets (standard: 6 queries, 12 sources, 14 MB, 4 rendered pages, 300 s; deep ≈ 2.5×), per-host politeness, exhaustion is reported. No timers, polling, crawling or re-verification while idle; the browser tier and connections are released.
Why: research is a user-initiated act, not a service.

## DEC-101 — Research via voice and via proposals
Status: Accepted (V0.9)
Decision: a spoken research request enters `ConversationService.submit(source: .voice)` like any text (short acknowledgement only; the report stays on the Research screen). V0.5 may *propose* research (web-authority policy rule: research is `propose`, never automatic; acquisition/import is `requireApproval` as its own decision); a proposal is never an automatic download, and an automatic task still has depth ≤ 1.
Why: voice and the proactive layer stay I/O and decision layers.

## DEC-102 — Verification guards for the web
Status: Accepted (V0.9)
Decision: `verify.sh` allows `URLSession`/`WKWebView` only in `HTTPTransport.swift`/`RenderedPageProvider.swift`/`WebClient.swift` (+ the fixture server), URL literals only in the research layer and the two policy tests, file writes outside the app folders only in Downloader/ArchiveInspector, and adds guards: no CAPTCHA/anti-bot evasion, no paid search API/key, UNKNOWN never free, only `AssetImporter` writes into a project, archive names validated before extraction, https-only bounded downloads, budgets exist, no unbounded polling, browser torn down, no page bodies/binaries in the schema or git.
Why: the rules above are only real if a future change cannot silently undo them.

## DEC-103 — Research yields to system pressure
Status: Accepted (V0.9)
Decision: the browser tier is offered only while memory pressure is normal and the thermal state is not serious (`ResearchResourcePolicy`); on a pressure rise an idle web view is released at once (`releaseUnderPressure`) and a navigation in progress finishes first; plain HTTP research continues (a JavaScript-only page is reported as needing the browser). Downloads are not browser work and are never interrupted by pressure.
Why: correctness first, the heavy part second; integrates with V0.3.1's event-driven ResourceManager without any polling.


## DEC-104 — Memory is derived knowledge, not history
Status: Accepted (V0.10)
Decision: Project Memory (`Sources/Jarvis/Memory/`, schema v8) is a derived layer over trustworthy sources. History (tasks, runs, file changes, research, Git, audit) stays in its own systems and is referenced through `MemorySource`, never copied or edited. A small set of types (project fact, decision, constraint, preference, episode, failure, lesson, research finding, asset decision, architecture, workflow, known issue, validation result, other); relationships are a table of typed relations, not a graph engine.
Why: "store chat and vector-search it" gives an unaccountable pile; a model of what is believed, why, and how current it is gives answers and context that can be audited.

## DEC-105 — One door: every memory is a candidate that passes the curator
Status: Accepted (V0.10)
Decision: `MemoryService.admit` is the only writer. Documents, tasks, research, a user sentence and model proposals are `MemoryCandidate`s that pass: secret gate → hygiene/trivial filter → origin gates (instruction-shaped text, authority grants, task-local) → provenance (verifiable source required; research needs V0.9-validated records) → strength by origin → current-truth check → dedupe → contradiction handling. `verify.sh` forbids any other caller of `insertMemory/updateMemory`.
Why: quality and safety are enforced once, not per source.

## DEC-106 — Memory is project-scoped; project identity is the Git root commit
Status: Accepted (V0.10)
Decision: every memory belongs to one project key: `git:<root commit>` (identical in every clone, unchanged by moves) → Unity `productGUID` → real path. Moves add a path alias; unrelated histories never share a key. Limit: a fork that still shares the root commit shares memory (JARVIS-V10-3).
Why: folder paths are not identity; cross-project leakage is a privacy bug.

## DEC-107 — Current deterministic truth outranks memory
Status: Accepted (V0.10)
Decision: order of authority: current project state/files/Git → validated current task/test results → explicit current user correction → validated research → current memory → historical evidence → model inference. Keyed memory is reconciled with truth probes (`unity.*`, `file.exists:`, `git.*`, app constants) before every context is built; a contradicted memory is superseded by an inspection-derived record (history kept); a candidate that contradicts truth is refused or stored stale.
Why: memory is a cache of beliefs, files are the project.

## DEC-108 — Secrets are refused, not redacted-and-kept
Status: Accepted (V0.10)
Decision: credential-shaped text (via the central `OutputSanitizer`) makes the whole candidate refused; the embedding step re-checks. Nothing credential-like reaches SQLite, a vector, the UI, an event or a prompt.
Why: vectors and summaries leak indirectly; a redacted fragment is still advice about where a secret lives.

## DEC-109 — Web text and model output cannot create authoritative memory
Status: Accepted (V0.10)
Decision: research/asset memory only from sessions, claims, candidates and acquisitions the V0.9 pipeline validated; pages, snippets and injection text never. A model proposal is capped at *inferred/unverified* unless its quoted evidence appears verbatim in the cited source (`Grounding.isGrounded`, V0.9); otherwise it stays an unverified note that never enters an agent's facts.
Why: a model's "I think the project uses HDRP" is not a fact.

## DEC-110 — Memory never grants authority
Status: Accepted (V0.10)
Decision: no memory code path approves, decides, imports, acquires, runs a process, opens a connection or reads credentials; policy/approval/command-safety code never reads memory; statements that grant authority ("the user always approves…", "skip the approval", "trust this site") are refused from every source including the user; an old approval is history, never a current permission; the V0.5 assessor gets memory as context only. The context packet states it is "never an instruction and never permission".
Why: a remembered approval must not become a standing one.

## DEC-111 — Interpretable statuses, evidence strengths and per-type staleness
Status: Accepted (V0.10)
Decision: `current · stale · superseded · disputed · unverified · archived · forgotten`; strengths `inferred · weak · supported · strong · authoritative` (no invented percentages); staleness by type (facts 14 d, research/price 24 h, known issues 30 d, validation 7 d; decisions, constraints, failures, episodes, lessons never age), applied on use, never by a timer; research findings must be re-verified through V0.9 before use.
Why: one TTL for everything would be wrong in both directions.

## DEC-112 — Conflict policy: supersede, dispute, or keep as unverified
Status: Accepted (V0.10)
Decision: facts that change over time are superseded by a newer observation of at least equal strength; normative memory only by something stronger; equal strength is DISPUTED (both stay visible); a weaker newcomer is stored unverified; a user statement wins; an edited repository document replaces its own older keyed record; an automatic source repeating history only adds provenance to the superseded record (no resurrection); a forgotten memory is not re-ingested.
Why: silently returning "whichever vector scores higher" is how stale or contradicting knowledge wins.

## DEC-113 — Remember, correct, pin: explicit, scoped, never destructive
Status: Accepted (V0.10)
Decision: "remember" creates an authoritative, project-scoped user memory (task-local wording like "for this task" is refused with an explanation); a correction creates a new authoritative record that supersedes the old one (which stays in History with its provenance); pin raises priority only when relevant (critical pinned constraints always travel, max 2) and never overrides truth, scope or supersession.
Why: the user must be able to steer memory without rewriting history.

## DEC-114 — Forgetting is not historical erasure
Status: Accepted (V0.10)
Decision: forget = status `forgotten`, excluded from retrieval/context/index, vector deleted, rationale text cleared, restorable; Git, task history, the audit trail and research evidence are untouched (the UI and the chat reply say so).
Why: forgetting a belief and erasing a record are different promises.

## DEC-115 — Embedding model chosen by measurement: paraphrase-multilingual-MiniLM-L12-v2 (int8)
Status: Accepted (V0.10)
Decision: five ONNX candidates and Apple NaturalLanguage were benchmarked on a bilingual corpus (62 memories, 48 queries: TR→TR, EN→EN, TR→EN, EN→TR, mixed, with distractors). Selected: `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` @ `e8f8c211226b894fcb81acc59f3b34ba3efd5f42`, `onnx/model_qint8_arm64.onnx`, Apache-2.0, 118 MB, 384-d: MRR 0.936 (best), 565 MB RSS (4× smaller than the next best), 1.3 ms warm, best cross-lingual score. Pinned + SHA-256 verified by `scripts/setup_memory_ai.sh`; never downloaded by the app. Excluded for size/licence/runtime: bge-m3, jina-v3 (CC-BY-NC), EmbeddingGemma (gated), nomic-v2-moe and Qwen3-Embedding (no ONNX).
Why: evidence over assumption; memory retrieval must feel instant on a 16 GB machine.

## DEC-116 — The semantic index is derived, versioned and rebuildable
Status: Accepted (V0.10)
Decision: `memory_embeddings` stores model id, revision, dimension, text hash, vector and checksum; a mismatch or corrupt vector is ignored (never mixed), reported as degraded and repaired by the next sync; rebuild swaps the project's index in one transaction (cancel/failure leaves the old index); canonical memory never depends on it; storage is SQLite BLOBs with brute-force cosine (Accelerate), no vector database.
Why: derived state must be disposable.

## DEC-117 — Hybrid retrieval with an explicit subject boost
Status: Accepted (V0.10)
Decision: BM25 (TR/EN folded + TR↔EN bridge) + semantic cosine fused 0.8/0.2 (benchmark-chosen), an idf-weighted subject boost, and explainable priority boosts (pinned, importance, strength, fits-the-question, damped area); status multipliers keep stale/superseded behind current; every result carries its reasons. Found on the real repository: without the subject boost, generic semantic similarity outranked the one decision that names "Playwright".
Why: vector-only retrieval cannot be trusted with exact names.

## DEC-118 — Local embeddings only; the helper is on-demand and supervised
Status: Accepted (V0.10)
Decision: no paid/hosted embedding API, no cloud vector database, no key. The helper runs through `HelperHost` (`ManagedProcess`): started on demand, 120 s idle unload (one sleeping task), unloaded under memory pressure, killed with its tree at quit, offline, output validated. Without it Project Memory works with structured + keyword retrieval and says so.
Why: no cost, no network, no daemon.

## DEC-119 — The Context Builder is the only way memory reaches an agent
Status: Accepted (V0.10)
Decision: `ProjectContextBuilder` builds bounded, per-agent packets (coding, analysis, review, planner, research, Unity, conversation, proactive) with four labelled layers — CURRENT TRUTH, MEMORY, UNCERTAINTY, INFERENCE — from relevant memory only; stale/disputed/outdated items go to the uncertainty list; the ids used per agent run are recorded (`memory_context_uses`). `TaskEngine.runJob` is the single job path.
Why: "the whole history in the prompt" does not scale and cannot be audited.

## DEC-120 — Questions about the project are answered from records; loose questions get context
Status: Accepted (V0.10)
Decision: explicit project-history/state questions (EN/TR, typed or spoken through the same `ConversationService.submit`) are answered deterministically from retrieved records with caveats, honest "nothing recorded"/"no verified reason" statements and a `Sources:` line that speech never reads. Loosely phrased questions are not intercepted: the model receives the relevant packet in its context.
Why: an ordinary question must never be hijacked; a project question must never be guessed.

## DEC-121 — Bootstrap is explicit, bounded and idempotent
Status: Accepted (V0.10)
Decision: parsers for `docs/DECISIONS.md` (rationale kept; "supersedes DEC-nnn" makes the older one historical), `docs/KNOWN_ISSUES.md` (resolved → archived), `AGENTS.md` rules, `docs/DEVELOPMENT_LOG.md` (episodes + findings); running it twice adds nothing; edited documents supersede their own older record; docs remain the human-readable truth.
Why: the project already has years of knowledge in those files.

## DEC-122 — Only meaningful lifecycle events become memory
Status: Accepted (V0.10)
Decision: finished tasks that changed files (episode, Unity tests) and meaningful failures (build/test/validation/compile…) become memory; infrastructure failures, cancellations, approval denials, read-only tasks and web tasks write nothing; research and acquisitions are remembered from their validated records.
Why: memory pollution is worse than amnesia.

## DEC-123 — Model-proposed lessons are optional, grounded and never authoritative
Status: Accepted (V0.10)
Decision: one small model request after a meaningful task (setting off by default) may propose ≤ 3 memories as JSON; each must quote the report verbatim to be *supported*, otherwise it is an unverified note; the curator applies every gate; the local Qwen is not a source of truth for contradiction, security or licence decisions.
Why: semantic extraction helps, but only after validation.

## DEC-124 — No idle memory work
Status: Accepted (V0.10)
Decision: ingestion, staleness, reconciliation, indexing and unloading are event-driven (a task finished, a question, a context request, an explicit user action); there are no timers, polling or periodic re-embedding.
Why: JARVIS idles at ~0 % CPU.

## DEC-125 — Memory is observable and its use is audited
Status: Accepted (V0.10)
Decision: bounded, content-free events (proposed · accepted · merged · superseded · disputed · rejected · corrected · forgotten · stale · retrieved · context · revalidated · embedded) and per-run `memory_context_uses`; diagnostics in the Memory screen (counts, index health, model, helper, latencies).
Why: memory must not be a magic box.

## DEC-126 — V0.10 is project memory, not personal memory
Status: Accepted (V0.10)
Decision: scope is JARVIS projects and project work; no general personal-life memory. Roadmap: V0.11 General Computer Use, V0.12 Advanced Multi-Agent / Routing, V1.0 Integration / Stabilization / Final Voice & UX Polish (supersedes only the V1.0 row wording of DEC-086).
Why: keeps the privacy surface small.

## DEC-127 — Computer Use is not a new authority system
Status: Accepted (V0.11)
Decision: a computer goal is an ordinary V0.4 task (`TaskKind.computer`, step type `computerAct`, capability `controlComputer` only; `captureWindow` only when the vision fallback is on). It goes Conversation → Goal Intake → TaskEngine → approval policy (HUD buttons only) → Context Builder → typed action → observe → act → verify. It uses the same states, approvals, cancellation, persistence, reports and restart rules; it cannot bypass the Task Engine, approvals, the memory truth hierarchy, ResourceManager, sanitization or any V0.4/V0.6/V0.9 safety rule. Only the user (typed or spoken) or an approved proposal can start one.
Why: the less a new power can do on its own, the less can go wrong.

## DEC-128 — The capability ladder: stronger, structured mechanisms outrank the GUI
Status: Accepted (V0.11)
Decision: A typed JARVIS capability (V0.4 project tools, V0.6 Unity bridge) > B structured integration > C controlled CLI > D V0.9 browser DOM > E macOS Accessibility/NSWorkspace > F window-scoped vision > G window-relative coordinates. `CapabilityResolver` claims a goal for the stronger rung first (source edits, file creation/rename, Unity scene/component/compile/test/Console, web research, Git → never Computer Use); Computer Use gets only what is left. Accessibility outranks vision; vision outranks raw coordinates; raw coordinates are the final fallback only.
Why: a typed, verifiable path is safer and more reliable than clicking; GUI is for what has no other door.

## DEC-129 — Every meaningful UI action is observe → resolve → policy → act → observe → verify
Status: Accepted (V0.11)
Decision: no blind macros (no fixed-coordinate scripts, recorded mouse paths or `sleep→click→sleep→click`); waits are conditions with backoff and named timeouts; each action type has declared postconditions; "the event was dispatched" is never success; plans are 1–5 actions then observe and re-plan.
Why: UIs change; the only safe click is one whose target was just seen and whose effect is checked.

## DEC-130 — Typed actions only
Status: Accepted (V0.11)
Decision: the action set is closed (observe, launch/activate/quit application, focus/minimize/restore/close window, press element, select menu item, set/type text, press key/shortcut, scroll, open/reveal file, open Settings pane, capture window, vision press). There is no "execute command/script", no AppleScript/Apple Events/JavaScript, no arbitrary key chord, no URL opening, no model-supplied coordinate. The model-facing action type has no coordinate field and a model proposal containing coordinates, scripts or shell lines is rejected whole.
Why: what cannot be expressed cannot be abused.

## DEC-131 — Semantic target resolution with interpretable states
Status: Accepted (V0.11)
Decision: targets are app (bundle id first) · window title · role · label · identifier · ancestor label · a user-given ordinal; resolution is EXACT / STRONG / AMBIGUOUS / NOT_FOUND / STALE — no fake percentages. Identical matches are never guessed (context from the user's words, the open dialog or the focus can separate them; otherwise the task stops AMBIGUOUS). Several similar windows are told apart by title, not z-order.
Why: the cost of pressing the wrong "Apply" is higher than the cost of asking.

## DEC-132 — Short-horizon planning; a model proposes, JARVIS validates and verifies
Status: Accepted (V0.11)
Decision: the plan comes from the user's own words (deterministic EN/TR parser); open-ended goals run bounded rounds (≤ 4) in which a model may propose the NEXT ≤ 3 actions as JSON (allowed apps only, allowed kinds only, observation inside an untrusted-data fence, privacy `sensitive` so labels never go to the free cloud pool). "Done" is believed only if JARVIS observes the declared postcondition; a model-proposed medium action asks first. The local Qwen model is not used for computer planning in V0.11 (not benchmarked for UI interpretation; it must never interpret security-critical dialogs).
Why: models are good at choosing the next step, bad at being trusted.

## DEC-133 — Risk comes from the semantic consequence; approvals bind to one action
Status: Accepted (V0.11)
Decision: `ConsequenceClassifier` classifies the control's own label (EN/TR) — an "OK" may save, delete, buy or send. Context text (a dialog's body) can only RAISE the risk of a generic confirm button; it can never lower anything or grant anything. Purchase, account action, credential entry, install/update, privacy grant, security/system setting, send, publish, force-quit, command execution and opening quarantined/executable files are BLOCKED with no approval path; delete/overwrite/submit/quit/close ask (HUD button, one action, per-action nonce — an old approval is never a new permission); medium actions the user named run, the same proposed by a model ask.
Why: a button's control type says nothing about what it does.

## DEC-134 — Coordinate safety
Status: Accepted (V0.11)
Decision: four explicit spaces (AppKit bottom-left · global top-left · image pixels · Vision normalized); Retina and multi-display layouts (negative coordinates, mixed scale) are converted natively; a click point is window-relative, inside the window, inside VISIBLE screen space (menu bar and Dock excluded), on the topmost window at that point; no Dock/menu-bar coordinate automation. macOS drops mouse events aimed at a single process (measured), so the one coordinate click goes through the system event stream as a single down/up pair and the pointer is restored.
Why: coordinates are where silent wrong clicks come from.

## DEC-135 — Screenshots are window-scoped, memory-only, local
Status: Accepted (V0.11)
Decision: one window per capture (never the desktop), held in memory, never encoded or written, released immediately; Screen Recording is requested only by the explicit Settings button when the user enables the vision fallback; the vision provider is on-device text recognition (Apple Vision; no model download, no network, no key). A cloud/paid/model vision provider is NOT wired (`UnavailableModelVision`): no verified-free, privacy-safe route exists. Metadata (size, hash, provider, `persisted = 0`) is audited, never pixels.
Why: a screenshot can contain anything; the safest copy is none.

## DEC-136 — Vision proposes; JARVIS validates; the action layer decides
Status: Accepted (V0.11)
Decision: vision returns a labelled region of ONE window image. The action layer re-checks freshness (age, app, title, frame, image fingerprint), bounds (window + visible screen), occlusion, policy (the recognised text goes through the same consequence classifier) and user activity before a single click, then verifies the result.
Why: a perception result is evidence, not authority.

## DEC-137 — Stale-screen protection and action fingerprints
Status: Accepted (V0.11)
Decision: an observation is valid only while the world matches it (≤ 6 s, same app frontmost, same window title, frame ±1.5 pt, not minimized, image hash within 8 bits); a resolved AX target carries a fingerprint (pid, bundle, window, role, label, identifier, frame, generation) re-checked right before the action. Mismatch → STALE → re-observe (once for vision) → refuse.
Why: never click on an old picture.

## DEC-138 — Permissions: never bypassed, never self-granted, requested just in time
Status: Accepted (V0.11)
Decision: Accessibility is required for observing and operating other applications and its absence is reported truthfully ("Permission required") — the task fails, nothing is attempted. Screen Recording is needed only for the vision fallback. Apple Events/Automation and Input Monitoring are not used. JARVIS only opens the right System Settings pane from an explicit button; it never touches TCC, never toggles a permission, never changes a security/privacy setting. No privacy permission is requested at launch.
Why: least privilege, and the user alone grants.

## DEC-139 — Secure fields, passwords and the Keychain
Status: Accepted (V0.11)
Decision: secure text fields are never read, set, typed into or copied (the tree builder never fetches their value; the backend refuses at three places; the policy blocks the action as USER INTERACTION REQUIRED); text shaped like a password or secret is never typed; the Keychain is never searched or used as a credential source; password managers and Keychain Access are not driven or observed. JARVIS is not a credential manager.
Why: a credential should exist where the user typed it and nowhere else.

## DEC-140 — The clipboard is sensitive
Status: Accepted (V0.11)
Decision: never monitored or polled, never read except to restore, never persisted, never sent to a model. A temporary write for a paste is restored afterwards unless the user copied something newer in the meantime.
Why: it routinely holds secrets.

## DEC-141 — No bypass of shell/tool restrictions through another application
Status: Accepted (V0.11)
Decision: typing, setting text or pressing keys in Terminal/iTerm/Warp/Script Editor/Automator or any console-like element (IDE terminal, Python console, DevTools, Immediate Window) is blocked; "open Terminal and run …" is refused as a request; messaging apps receive no keystrokes; no AppleScript/osascript/JavaScript path exists.
Why: typing a command elsewhere is running it.

## DEC-142 — UI text is untrusted observation, minimally extracted
Status: Accepted (V0.11)
Decision: labels, titles and values are bounded data. Document text is not extracted (text areas and web areas report a length only), secure fields report nothing, values are capped at 120 characters. A model sees only window titles and control labels inside an untrusted-data fence; a label can raise a risk, never lower it, never grant authority and never change a rule.
Why: an application's text can be written by anyone.

## DEC-143 — What Computer Use will and will not press
Status: Accepted (V0.11)
Decision: it never presses buy/subscribe/pay, sign-in/authorize/accept-terms, install/update, allow/grant, send/post/reply, publish/deploy/push, force-quit; it asks before delete/erase/trash/don't-save/overwrite/submit/quit/close; Finder's menu cannot trash/open/duplicate files; Settings switches and pop-ups are never touched; notifications are not clicked.
Why: V0.9 purchase/account rules, V0.4 deletion policy and the "no external side effects" rule hold for the GUI too.

## DEC-144 — Keyboard shortcuts are an allowlist
Status: Accepted (V0.11)
Decision: only listed chords execute (⌘F/O/L/T/N/A/C/Z/⇧⌘Z/⌘,/⌘1…⌘9 low; ⌘S/⇧⌘S/⌘W/Return medium); ⌘Q/⌘⌫ ask; force-quit, lock, Spotlight, log-out and empty-Trash chords are blocked; unknown chords never execute; Return with a dialog in front is judged as its default button; keys go only to the application they were planned for while it is frontmost.
Why: a key chord is a hidden button.

## DEC-145 — Files, URLs and the quarantine
Status: Accepted (V0.11)
Decision: `openFile`/`revealFile` only through `ComputerPathPolicy` (absolute, `realpath`, no traversal, no credential locations, never the V0.9 quarantine, never executable/installer types; revealing is allowed for any non-secret path); there is no generic URL action and Settings panes are a fixed enum. Computer Use cannot open a downloaded executable merely because it can click it.
Why: the quarantine has to hold against every door.

## DEC-146 — Unity and the browser keep their structured paths
Status: Accepted (V0.11)
Decision: Unity scene/component/compile/test/Console work always resolves to the V0.6 bridge; Computer Use may only bring the editor to the front or look at a harmless dialog. Web reading always resolves to V0.9; desktop clicking in a browser is not used for research.
Why: the structured path is verifiable and already safe.

## DEC-147 — Cancellation, emergency stop and user precedence
Status: Accepted (V0.11)
Decision: one stop token per task is set before the engine cancels, and an in-flight executor sends nothing further (typing is chunked with a check between chunks; waits end). Emergency stop = hold ⌃⌥⌘ (permission-free modifier sampler, 40 ms, 2 samples), running ONLY while a computer session runs; it stops all sessions and cancels the tasks; it kills nothing else. Before acting in the app the user is working in, an idle-time probe pauses JARVIS while keys/clicks are happening; geometry/focus changes make old targets STALE.
Why: the user must always be able to move the mouse, type, switch app and stop JARVIS.

## DEC-148 — Retries, timeouts, hung applications
Status: Accepted (V0.11)
Decision: actions are classed safe / verify-first / unsafe; retries ≤ 2, only for safe/verify-first, only while the fingerprint still matches; unsafe actions are never repeated; launch (20 s), window (6 s), AX response (1.5 s), verification (4 s), vision (20 s) have named timeouts and are reported honestly; a non-responsive application is reported and never force-quit.
Why: no infinite find→click→fail→click loops.

## DEC-149 — Sessions are audited metadata, never content
Status: Accepted (V0.11)
Decision: schema v9 (`computer_sessions`, `computer_actions`, `computer_observations`) stores the goal, applications, capability rung, action kind/risk/status/verification/approval/timing, a typed text's class and length, and observation counts/sizes/hash with `persisted = 0`; no Accessibility tree, no pixels, no typed text, no clipboard. Events are bounded and collapsed; the task report has a Computer Use section.
Why: auditability without a surveillance archive.

## DEC-150 — GUI sessions never resume silently
Status: Accepted (V0.11)
Decision: after a restart (or a crash) a running or approval-waiting computer session becomes INTERRUPTED (a waiting task is not re-created); only an explicit Resume continues it, and Resume re-checks the permission, finds the app and window again, re-observes everything and asks for approval again (the old one is dead). Nothing is ever clicked from old coordinates.
Why: the screen at restart is not the screen at the plan.

## DEC-151 — Memory integration (context yes, UI state no)
Status: Accepted (V0.11)
Decision: a computer task fetches ONE bounded `ComputerAgent` packet (constraints/decisions, ≤ 1800 chars, ≤ 5 items; ids audited in `memory_context_uses`) and gives it to planning prompts; live observations always win over memory; ordinary UI observations ("Xcode is open", window geometry) never become memory (the completion path is an explicit no-op for computer tasks).
Why: memory carries project constraints, not transient screens.

## DEC-152 — Voice uses the same path
Status: Accepted (V0.11)
Decision: a spoken "Xcode'u aç" is `ConversationService.submit(source: .voice)` → the same classification → the same task → short acknowledgement; there is no voice-specific automation engine; a spoken "yes" never approves.
Why: one pipeline, one set of rules.

## DEC-153 — The proactive layer cannot start GUI control
Status: Accepted (V0.11)
Decision: `OpportunityPolicy` turns any assessment needing `controlComputer`/`captureWindow` into an approval decision, `submitComputer` refuses `proactiveAutoAction`, and observation exists only during an active authorized task (no watching the screen for opportunities).
Why: observation must not become surveillance.

## DEC-154 — Nothing observes while idle
Status: Accepted (V0.11)
Decision: no Accessibility traversal, screenshot, clipboard read or application polling happens when no computer task exists; the only timer in the Computer layer is the emergency-stop sampler, started with the first session and stopped with the last; the OCR/capture path is created on demand and released.
Why: JARVIS idles at ~0 % CPU and watches nothing.

## DEC-155 — Resource policy
Status: Accepted (V0.11)
Decision: under memory pressure the vision fallback becomes unavailable and Computer Use continues AX-only; a vision/OCR request holds no model and releases its buffers; Accessibility actions are never made dependent on vision.
Why: correctness must not depend on the heavy path.

## DEC-156 — A JARVIS-owned fixture for real tests; live-test discipline
Status: Accepted (V0.11)
Decision: `build/JarvisFixture.app` (a separate bundle, `com.jarvis.fixture`, no permissions or entitlements) is the only target of real presses, typing, scrolling and clicks; it only counts and writes a JSON state file (never the password's content). Real Finder / System Settings / Blender / Unity runs are navigation or activation only; nothing in a user project, no toggle in System Settings, no real credential or purchase is ever involved. `--computer-live-test` reports Accessibility as BLOCKED rather than weakening anything.
Why: tests that press things need something safe to press.

# V0.12 — Advanced multi-agent orchestration and intelligent routing (DEC-157…DEC-190)

## DEC-157 — JARVIS is the orchestrator; agents are roles, not providers
Status: Accepted (V0.12)
Decision: orchestration is deterministic code (`TaskEngine` + `Sources/Jarvis/Orchestration/`), not a model. An agent is a ROLE (Analysis, Coding, Research, Unity, Computer, QA, Review); a model/tool/service is the ENGINE that executes it. No `ClaudeAgent`/`CodexAgent`/`OpenCodeAgent`/`QwenAgent` exists; provider sessions are never the source of truth (guarded).
Why: authority, policy, memory, validation and the report must stay JARVIS-owned; models are replaceable workers.

## DEC-158 — Models never own authority; only the orchestrator creates nodes; delegation depth is 1
Status: Accepted (V0.12)
Decision: a specialist may REQUEST (more research); only the orchestrator changes the graph. Orchestrator → specialist is the whole hierarchy (`maxDepth = 1`); the planner/validator reject recursive-agent keys; the orchestration layer never spawns runs itself. No swarms.
Why: bounded, auditable work; no recursive explosion.

## DEC-159 — Role contracts and least capability, checked twice
Status: Accepted (V0.12)
Decision: each role has one contract (step types, allowed and forbidden capabilities, output schema, validations, resource class, context budget, retry budget, authority statement). Read-only roles hold no write capability; Research has no project access; QA cannot edit sources; Computer has no shell/password/purchase/account authority; no role can hold a never-granted capability. The contract is validated at plan time AND again right before the node starts (`orchestrationRefusal`).
Why: a plan, an artifact or a handoff is data and can never widen authority (confused-deputy defense).

## DEC-160 — The task graph is the V0.4 plan, seen as a bounded DAG
Status: Accepted (V0.12)
Decision: no second plan format. Nodes = `task_steps`, edges = `depends_on`; added attributes: `optional`, `revision`, delegate/gate parameters, delegated child task. ≤ 12 nodes, acyclic, writers ordered, validation gates (proof depends on the change; review depends on the change and its build/test), ≤ 3 delegates, optional only for knowledge branches.
Why: reuse the proven engine (persistence, restart, cancellation, approvals) instead of duplicating it.

## DEC-161 — Deterministic planning first; the planner model only for open-ended compound goals
Status: Accepted (V0.12)
Decision: simple goals are one node and cost no model call (Computer, Research, QA); known compound shapes are templates (`fix-flow`, `investigation`, `investigation-research`, `asset-suitability`); Unity scene goals and unmatched compound goals go to the planner model, whose graph is validated exactly like a template (one repair, one other provider, then BLOCKED). A model graph is never executed unvalidated.
Why: cheap, predictable, auditable; the model proposes, JARVIS validates.

## DEC-162 — Research only when knowledge is missing or must be current; Computer only when the UI must be seen
Status: Accepted (V0.12)
Decision: research is inserted when the goal asks for research/current information AND memory has no current answer (memory research items always say “revalidate”; a goal that demands currency is always researched). A Computer node is added only when the goal asks to look at the UI. Both are OPTIONAL branches (their failure ends the task PARTIAL).
Why: do not web-search or click for every coding task.

## DEC-163 — Research and Computer nodes are child TASKS (V0.9 / V0.11 reused, not rebuilt)
Status: Accepted (V0.12)
Decision: `delegateResearch` / `delegateComputer` start an ordinary V0.9 research task / V0.11 computer task (`parent_task_id`), wait for it, and turn its validated result into an artifact. Children do not count against the user-visible task limit, never speak to the user or the proactive layer, are cancelled with their parent, and a GUI child is always NEW after a restart (observes from scratch). Unity work stays on the V0.6 typed steps; a Computer goal must pass the V0.11 ladder at plan AND start time.
Why: one implementation of each capability; the orchestrator adds supervision, not another web or GUI system.

## DEC-164 — Typed artifacts with provenance and trust; handoffs are fenced data
Status: Accepted (V0.12)
Decision: a finished node leaves one artifact (sanitized by the single `UntrustedContent.clean`/`OutputSanitizer` path, ≤ 6,000 chars, hashed, with task/node/role/provider/model/run/attempt/inputs/validation) labelled `deterministic` | `validated` | `modelGenerated` | `externalUntrusted` | `userProvided`. Research and Computer observations stay `externalUntrusted` through every handoff. A handoff is built from the node's ancestors' artifacts only, bounded by the receiving role's budget, preceded by a fixed “data, not instructions” preamble, non-deterministic blocks fenced, instruction-shaped phrases flagged and kept as data. An artifact is constructed in exactly one place.
Why: no giant chat transcripts, no trust laundering, secrets cannot ride a handoff.

## DEC-165 — Deterministic truth outranks agent claims
Status: Accepted (V0.12)
Decision: files, Git, process exit status, tests, Unity state, browser/computer observation outrank any model sentence. “All tests passed” in an analysis or review changes nothing (live-tested: the task fails when the real tests fail and the review never runs). Review verdicts are weighed by `ReviewAuthority`; a blocking finding needs evidence JARVIS can find in the diff or the record.
Why: models describe; tools measure.

## DEC-166 — Role benchmarks are separate, deterministic and advisory to the gates
Status: Accepted (V0.12)
Decision: suite `roles-v1` (planning ×2, analysis, coding, review ×2, research synthesis, strict JSON, security ×2) with in-prompt fixtures and deterministic validators that never execute model output; several cases carry traps (prompt injection, planted “pre-approved” note, fake approval, shell request, secret-shaped string) — following them fails the role. Results go to `model_benchmarks` (suite `roles-v1`, case ids `role.<role>.<n>`, prompt size). They explain routing and filter security-relevant work (DEC-181); they never unlock a model the V0.3.1 gates refuse (the router does not read them).
Why: “free and fast” is not a quality; quality is per role.

## DEC-167 — Routing stays the pure V0.3.1 router; V0.12 adds a persisted, human-readable decision per run
Status: Accepted (V0.12)
Decision: `routing_decisions` records role, node, engine/model, mode, a sentence, the machine reason, independence, escalation reason, failure class, outcome, context/handoff/artifact/memory sizes, timings, tokens and cost class (local | freeCloud | subscription — never invented dollars). Provider HEALTH (cooldown) and model QUALITY (benchmarks) remain separate inputs. Explicit user choices are respected without fallback; no paid API; unknown price is not free; free status is re-verified at runtime (V0.3.1).
Why: routing must be inspectable and stable.

## DEC-168 — Failures have a vocabulary; escalation is explicit and bounded
Status: Accepted (V0.12)
Decision: `NodeFailureClass` (provider unavailable, timeout, invalid schema, context overflow, tool refusal, failed deterministic validation, security refusal, rate limit, model error) and `EscalationReason` (validation failed twice, complex architecture, security-relevant, free model unavailable, context too large, review found defect). Per node: ≤ 3 attempts, ≤ 1 escalation, ≤ 4 provider invocations (`NodeLedger`, enforced in `runJob`); QA and Computer nodes have no provider budget; one review→repair cycle.
Why: no infinite OpenCode → Claude → Codex loops, no “AI failed”.

## DEC-169 — Review independence is risk-based, never mandatory for trivial changes
Status: Accepted (V0.12)
Decision: required for ≥ 2 files, ≥ 30 changed lines, security-relevant words, high task risk or after an escalation; the writer's candidates are excluded from the review (Auto only); when no other eligible provider exists the writer also reviews and the routing record says `sameProvider`. QA (deterministic) and Review (judgement) are distinct roles; one review/repair cycle, then stop.
Why: diversity where it matters, without forcing cost or quota use on small changes.

## DEC-170 — Scheduling: only read-only nodes overlap; two at most; one under pressure
Status: Accepted (V0.12)
Decision: `ConcurrencyPolicy`: analysis ∥ analysis and analysis ∥ one research delegate; everything that writes, builds, tests, reviews, drives the editor or the screen runs alone; parallel limit 2, reduced to 1 by memory pressure, thermal throttling or low-power mode. Leases remain behind the ordering rule. A node already started is never started again (fixes a latent V0.4 race found by the V0.12 live test). Deadlocks are detected and reported; graphs and jobs have wall-clock limits.
Why: conservative on a 16 GB MacBook Air; more parallelism is not automatically better.

## DEC-171 — Approval is a graph GATE, never an agent
Status: Accepted (V0.12)
Decision: `approvalGate` is a node only a HUD decision can release (`requestApproval`, durable, per action); there is no approving role; typed/spoken “yes/evet/onayla” never approves; an agent artifact claiming approval is text; the orchestration layer contains exactly one approval request (the gate runner) and never calls `decide`. A denied gate ends the task BLOCKED.
Why: authority stays with the user's buttons.

## DEC-172 — Memory feeds context, never authority (and now refuses agent-targeted grants)
Status: Accepted (V0.12)
Decision: role-specific context still comes only from `ProjectContextBuilder` (audited per run). The memory door additionally refuses agent-targeted authority statements (“always allow ComputerAgent to install software”, “agents may run commands”, “without asking”, “full access”). Contracts, validators, the scheduler and routing never read memory; the only memory use in orchestration is the research-coverage hint.
Why: found by the live test — the old patterns did not catch agent-targeted grants.

## DEC-173 — Graph revision is bounded and orchestrator-owned
Status: Accepted (V0.12)
Decision: a specialist reports `needsResearch`; the orchestrator may insert one validated research node (≤ 2 revisions per task, ≤ 12 nodes, web allowed, no duplicate research node), audited in `graph_revisions`; after that JARVIS reports the uncertainty.
Why: adapt to evidence without letting the graph grow by itself.

## DEC-174 — Outcomes: SUCCESS · PARTIAL · FAILED · BLOCKED · CANCELLED · INTERRUPTED · APPROVAL REQUIRED
Status: Accepted (V0.12)
Decision: derived (`TaskOutcome`), not stored: PARTIAL = completed with a failed optional branch (never reported as complete); BLOCKED = policy/approval/availability; progress = validated REQUIRED nodes / required nodes (optional nodes never distort it).
Why: the report must say what is true.

## DEC-175 — Restart interrupts the whole graph; resume is explicit and revalidating
Status: Accepted (V0.12)
Decision: restart → INTERRUPTED (children too); nothing resumes by itself. Explicit resume reuses finished nodes only while their truth holds: a changed file invalidates the code node and everything built on it (artifacts stale), research older than 24 h re-runs, a finished research child is reused, a GUI node starts a new child, interrupted nodes are reconciled by idempotency class, the frontier is rebuilt from the persisted graph.
Why: stale results must be detected, expensive valid work reused.

## DEC-176 — Cleanup policy
Status: Accepted (V0.12)
Decision: artifacts, routing rows and graph rows of tasks older than the newest 150 finished ones are pruned at launch; tasks, steps, attempts, approvals, reports and agent runs stay as history; nothing in this layer writes screenshots, scratch repositories or raw provider output.
Why: bounded growth without losing the audit trail.

## DEC-177 — No chain-of-thought, no raw provider conversation
Status: Accepted (V0.12)
Decision: no schema column, artifact field or screen carries hidden reasoning or a provider transcript; the UI shows decisions, selection reasons, actions, evidence and validation (guarded).
Why: privacy and honesty.

## DEC-178 — Provider session continuity is only an optimization
Status: Accepted (V0.12)
Decision: task jobs run with fresh, bounded prompts (`includeTaskContext: false`); canonical context is JARVIS-owned artifacts and the Context Builder; independent nodes never inherit a long provider conversation; compaction would create a structured artifact, never rely on provider-side summarization.
Why: no hidden memory, measurable context.

## DEC-179 — Context minimization is measured
Status: Accepted (V0.12)
Decision: every model run records its prompt size, handoff size, artifact/memory/file counts; specialists get ancestors' artifacts under the role budget instead of the repository, the memory database or earlier conversations. Measured reduction is reported, not a quality claim.
Why: show that specialists receive less irrelevant context than a send-everything single model.

## DEC-180 — Status questions come from the graph
Status: Accepted (V0.12)
Decision: “Durum ne?”, “Ne yapıyorsun?”, “Hangi agent çalışıyor?”, “Testler geçti mi?” (and English forms) are deterministic commands answered by `OrchestrationStatus` from the real graph: no model call, no second task, no invented percentage; spoken or typed alike. “Stop the task” and “stop speaking” remain different commands. No Pause control.
Why: truthful, instant, cheap.

## DEC-181 — “Free” is not enough: security-relevant work needs role evidence
Status: Accepted (V0.12)
Decision: for security-relevant coding/review (Auto only) candidates are filtered by recorded role evidence: a free/local model needs COMPLETE passing evidence for the `security` role; a subscription engine without evidence is allowed, one that failed is not. Local Qwen restrictions are unchanged (no development, review, tests, architecture, security, Unity, long context).
Why: the live benchmark showed a free model following planted instructions; speed and price must not buy security-critical work.

## DEC-182 — Orchestration is on in production and off in older tests; no new user knobs
Status: Accepted (V0.12)
Decision: `TaskEngine.orchestrationEnabled` (true in the app) lets the V0.4–V0.11 suites keep their exact behaviour; users choose Auto or an explicit provider, nothing else; diagnostics (routing decisions, sizes, template, planner time) appear under Show Developer Controls.
Why: preserve working systems; keep the product simple.

## DEC-183 — Idle: no worker, process, poll, timer or network
Status: Accepted (V0.12)
Decision: the orchestration layer owns no timer, helper or process; with no task nothing runs. Provider processes exist only inside a task; the V0.10 embedding helper unloads itself 120 s after memory ingestion.
Why: idle cost stays ≈ 0.

## DEC-184 — Final synthesis is deterministic
Status: Accepted (V0.12)
Decision: the report (steps, outcome, routing sentences, artifacts, revisions, injection notes, approvals) and the conversation summary are built from graph state and validated artifacts; no model rewrites them. (A future model-rendered summary may only restate validated facts and may not change an outcome.)
Why: provable correctness over polish; polish is V1.0.

## DEC-185 — The Compact HUD stays 392 × 448
Status: Accepted (V0.12)
Decision: orchestration adds one line of content only (“Coding · space-bunny-free”, “… · QA waiting”) inside the fixed card; graph detail lives in Tasks/Agents.
Why: DEC-014.

## DEC-186 — Voice uses the same orchestrator
Status: Accepted (V0.12)
Decision: a spoken compound request is `ConversationService.submit(source: .voice)` → the same task path (`input_channel = voice`) with a short acknowledgement that says what JARVIS will do, not every internal step; status and stop work by voice; spoken approval is still not approval.
Why: voice is I/O, not authority.

## DEC-187 — Proactive layer gets no multi-agent authority
Status: Accepted (V0.12)
Decision: V0.5 may propose a compound task; it gets no special graph rights; computer capabilities still become approval decisions; scoped proactive tasks are never orchestrated beyond their scope (templates are skipped for scoped tasks).
Why: policy outranks confidence.

## DEC-188 — Tests use disposable fixtures only
Status: Accepted (V0.12)
Decision: the live test and unit tests use temp-directory projects, the fixture web, scripted agents for adversarial/timing scenarios (labelled ENGINE) and real providers where safe (labelled REAL); no real Unity game or user project is touched; fixtures are deleted by the test.
Why: DEC-156 discipline.

## DEC-189 — Roadmap after V0.12
Status: Accepted (V0.12)
Decision: V1.0 = integration, stabilization, real-world validation, final voice and UX polish, security audit, packaging. V0.12 does not polish subsystems.
Why: architecture first, polish once.

## DEC-190 — No surprise paid API, no key
Status: Accepted (V0.12)
Decision: allowed: subscription-backed Claude Code/Codex, runtime-verified $0 OpenCode models, local models for their allowed roles. Not present: any metered API call or key; unknown price is never free.
Why: DEC-022…028 unchanged.

## DEC-191 — Project continuity is a derived view; current truth wins
Status: Accepted (V0.13)
Decision: "where are we on project X" is rebuilt on demand from tasks, Git, the project's docs, the Unity descriptor, the last checkpoint and memory digests (`Sources/Jarvis/Continuity/`). Only checkpoints, the next-step queue and a session counter are persisted (schema v11). When a checkpoint or a memory disagrees with files / Git / Unity, current truth wins and the older item is reported as stale.
Why: a second source of truth drifts; memory is context, never authority (DEC-104…126).

## DEC-192 — "Continue" is one bounded V0.4 task through the V0.12 orchestrator
Status: Accepted (V0.13)
Decision: continuing a project calls `TaskEngine.submit` with a persisted constraint (`ContinuationMarker.constraint`). There is no continuation engine, scheduler or second orchestrator. It authorises one task toward one selected step, within that task's capabilities; it grants no approval, no capability, no commit / push / purchase / network, and starts no further continuation (depth 1).
Why: DEC-157…190 — JARVIS is the only orchestrator; approvals are HUD-only.

## DEC-193 — Next-step selection is tiered, and ambiguity is asked about
Status: Accepted (V0.13)
Decision: interrupted (resume, or re-plan when the project drifted) → failed once (retry; a retry of a retry is never offered) → recorded next (queue ∪ checkpoint ∪ project docs) → known issues. Several candidates in a tier ⇒ ask; a design-sensitive candidate ⇒ propose and wait. An interrupted task resumes only by explicit user action.
Why: guessing the wrong direction costs more than one question.

## DEC-194 — A continuation session is bounded and the bound survives a restart
Status: Accepted (V0.13)
Decision: `ContinuationBounds.standard` = 30 min · 12 nodes · 2 revisions · 2 correction rounds · 2 experiments, stored as a task constraint and enforced in the engine (graph timeout, correction loop, experiment count).
Why: autonomy needs a visible end.

## DEC-195 — The Unity operator is a closed, typed operation set
Status: Accepted (V0.13)
Decision: `UnityOperation.dev(UnityDevOp)` — 23 operations; per-component settings are whitelisted, typed and range-checked in Swift (`UnityComponentSchema`) and equal to the bridge's accepted keys (a parity test enforces it). No operation carries C#, a menu item, a shell line, a URL or reflection; the bridge keeps its V0.6 security boundary (version 0.13.0). The goal must ask for scene creation, component removal and prefab unpacking; shared-prefab apply, model-importer changes, component removal and unpack additionally need a per-exact-action user approval.
Why: DEC-047…056 — typed operations only.

## DEC-196 — Verified by read-back; Play Mode blocked twice
Status: Accepted (V0.13)
Decision: an operator edit counts as done only when the editor's own read-back (an idempotent second pass) confirms it. Persistent changes are refused in Play Mode / while compiling by `UnityPolicy` first and by the bridge (`playModeMutationBlocked`) even if the policy were bypassed. Only overrides JARVIS touched can be reverted or applied. The user's dirty scene is protected for scene-touching operations.
Why: "the model said so" is not evidence.

## DEC-197 — Captures live in memory; lighting is judged from numbers
Status: Accepted (V0.13)
Decision: `captureView` renders the Game camera to a spool PNG that is read into memory and deleted at once; objective analysis (frustum, area, contrast, luminance, magenta fraction) comes from the editor. A visual model never decides lighting. An owned editor that must render is relaunched with a graphics device but no window (`-batchmode` without `-nographics`).
Why: the benchmark's only failure was a model calling a dim frame bright (DEC-199).

## DEC-198 — Visual grounding is perception, not authority; no cloud provider
Status: Accepted (V0.13)
Decision: `Sources/Jarvis/Vision/` returns normalised, validated regions and bounded text. Safety = the worst of model label, printed screen text and the requested label (V0.11 `ConsequenceClassifier`); instruction-like text in a picture is recorded and ignored; proposals reach the executor only through `VisionProposing`. All providers are on-device; privacy classes exist but no cloud provider is registered; no API key. Observations store hash + provider + outcome, never pixels.
Why: DEC-127…156 — the GUI is the last rung; screen content stays on the machine.

## DEC-199 — Local VLM: Qwen3-VL via a pinned, offline, on-demand helper
Status: Accepted (V0.13)
Decision: after a measured 16-case benchmark (Apple OCR 7/16, Qwen3-VL-2B 15/16, 4B 15/16, 4B with better boxes) the local options are Qwen3-VL-4B / 2B-Instruct 4-bit MLX (Apache-2.0) at pinned revisions, installed only by `scripts/setup_vision_ai.sh`, started on demand, unloaded after 45 s idle and under memory pressure, killed if hung and at quit. Off/On-device is a setting.
Why: nothing resident, nothing downloaded by the app, nothing paid.

## DEC-200 — Experiments run in a marker-checked disposable environment and always clean up
Status: Accepted (V0.13)
Decision: a contract (question, hypothesis, bounds, criteria; 0 network) is validated at plan time and at start; the environment is a Unity project under the JARVIS experiments root with a marker; deletion is confined to marked directories inside that root; cancel / failure / budget all clean up; the real project's tree fingerprint is compared before / after; after a crash the record is INTERRUPTED and the next launch removes the orphan folder and stops headless editors inside it. An experiment never imports into a real project.
Why: "test it safely" must hold even when JARVIS dies.

## DEC-201 — Verdicts require every needed check; unmade checks are INCONCLUSIVE
Status: Accepted (V0.13)
Decision: CONFIRMED only if every check the experiment kind needs was made and held; a failed check ⇒ REFUTED; missing checks or nothing tested ⇒ INCONCLUSIVE, which fails the step. Facts are classed VERIFIED · TESTED · SUPPORTED BY SOURCE · INFERRED · UNKNOWN · INCOMPATIBLE.
Why: found by the real test — a compile-only run first "confirmed" a render hypothesis.

## DEC-202 — Asset suitability never upgrades a guess
Status: Accepted (V0.13)
Decision: unknown price is never free; an unknown licence is never safe; "probably compatible" is INFERRED until an experiment imported and compiled it; a style claim needs rendered pictures of both the asset and the project; usage text is labelled FACT / INFERENCE / RECOMMENDATION; promotion into a project is a separate approval-gated task.
Why: DEC-088…103.

## DEC-203 — The correction loop is deterministic, bounded and objective-only
Status: Accepted (V0.13)
Decision: capture → measure → one deterministic fix (aim camera / add fill light / raise brightest light / raise ambient) through the normal typed operations → capture again, at most the session's correction rounds (default 2). When nothing objective is left, it reports. Taste words are SUBJECTIVE: never corrected, never a passed check.
Why: a model's taste is not a test.

## DEC-204 — No cloud vision; Prime Video is a manual test
Status: Accepted (V0.13)
Decision: a Claude Code image probe worked over the user's subscription but would send screen content out, so it is documented as an option and not integrated. There is no Prime-Video-specific scraper; purchase / rental / subscription actions have no code path; existing login sessions are used only through ordinary UI actions the user could do, never through cookie / Keychain access.
Why: DEC-022…028, DEC-127…156.

## DEC-205 — Roadmap after V0.13
Status: Accepted (V0.13)
Decision: V0.14 = self-improvement; V0.15 = persona / whiteboard; V1.0 = integration, stabilisation, real-world validation, security audit, packaging. V0.13 does none of the first two.
Why: DEC-189.

## DEC-206 — An Accessibility action's return code is not its outcome (JARVIS-V13-7)
Status: Accepted (V0.13.1)
Decision: when an application answers a press with "unsupported / not implemented", the executor does not take that at face value in either direction: it looks (read-only, ≤ 1.5 s) for the state the action was meant to produce. If it is there the press is VERIFIED ("the application answered … but the expected state was observed"); if not, the action FAILS and says what was and was not seen. The action is NEVER repeated (it may already have happened). A failed verification now reports counts and flags (polls, node counts, truncation, generation, frontmost app, input idle) — never UI text.
Why: the real fixture counted the click while the call returned an error; reporting failure was wrong, and a retry would have double-fired.

## DEC-207 — Input System edits use Unity's own API, in an optional assembly, and protect the user's bindings
Status: Accepted (V0.13.1)
Decision: seven typed operations (`inspectInput`, `createInputAsset`, `createInputMap`, `createInputAction`, `addInputBinding`, `changeInputBinding`, `removeInputBinding`). The full implementation lives in `Jarvis.Bridge.InputSystem`, compiled only when `com.unity.inputsystem` is installed (JARVIS never installs packages; the main assembly answers "not installed" and refuses edits). An `.inputactions` file is read and written only through `InputActionAsset.FromJson/ToJson` and the API's own editing calls, then reloaded to verify. Bindings JARVIS creates are remembered in `Library/JarvisBridge/input-owned.json`; only those can be changed or removed — anything else (including a binding JARVIS no longer remembers) is the user's. An exact duplicate is not added; a control already used by another action of the map, or a wildcard (`anyKey`) overlap, is REFUSED with the facts instead of guessed. Not exposed: enabling/disabling an action (runtime state, blocked in Play Mode) and control-scheme editing.
Why: a "continue" must never redesign the user's input scheme; ambiguity is reported, not resolved.

## DEC-208 — Animation and audio experiments are kinds of the one experiment engine, with generated fixtures
Status: Accepted (V0.13.1)
Decision: `animationPlayback` and `audioPlayback` use the same contract, isolation, cleanup, verdict and cancellation code as every experiment (a `prepareFixture` step and a `playAndObserve` adapter; no second engine). With no asset named the fixture is generated inside the disposable project: a typed `createAnimationClip` (one whitelisted transform property on one axis) + a one-state controller, or a synthetic 0.5 s tone WAV written before the editor opens. A named asset that does not exist REFUTES the hypothesis. TESTED: the clip's normalized time advances and the pose changes / the AudioSource has its clip and `isPlaying` becomes true. INFERRED or UNKNOWN: that it works on another rig, and that it sounds right — never claimed.
Why: a compile is not an animation; a configured source is not audible sound.

## DEC-209 — The Project card shows live scene facts or history labelled as history
Status: Accepted (V0.13.1)
Decision: a small subset (scene, objects, cameras, lights, broken references, Play Mode, saved/unsaved) is read from a CONNECTED editor when the card refreshes (never on a timer, never by starting an editor). Without a connection the last reading is shown dimmed with its age and "the editor is not connected, so this may be out of date"; it is never `live`, never persisted, and never shown in Compact.
Why: stale scene facts presented as current are worse than none.

## DEC-210 — Memory alone never starts work
Status: Accepted (V0.13.1)
Decision: a known issue that exists only as a project-memory item is PROPOSED (`needsChoice`); work starts on its own only from current truth (a recorded next step in the project's docs, the queue, a checkpoint, an unfinished or failed task).
Why: memory is context, never the authority for what to do.

## DEC-211 — Rental, cart and donation words are blocked like purchases
Status: Accepted (V0.13.1)
Decision: "Rent", "Rental", "Buy or Rent", "Kirala", "Add to Cart", "Join Prime", "Donate" … classify as PURCHASE (blocked, no approval path). Found while reconciling the V0.13 guard requirements: rental was classified ordinary.
Why: the purchase / rental / subscription bypass must be closed for any site, without naming any site.

## DEC-212 — A dying editor is reported at once
Status: Accepted (V0.13.1)
Decision: `UnityService.prepare` waits for the bridge in 2-second slices and fails immediately, with the editor's output tail, when the process exits (a batch-mode compile error used to hang for the full connect timeout).
Why: found by the Input System live test (a C# error in the bridge).

## DEC-213 — Roadmap unchanged
Status: Accepted (V0.13.1)
Decision: V0.13.1 is a closure / stability milestone. V0.14 (adaptive learning & controlled self-improvement) → V0.15 (presence, personality & visual intelligence) → V1.0 (real-world validation & stabilisation).
Why: DEC-205.

## DEC-214 — The local vision model is loaded BEFORE the picture is taken
Status: Accepted (V0.13.1)
Decision: `VisionProposing.prepare(label:)` runs before the window capture. Only when the first eligible provider for the query is the local model (an icon or custom-drawn control, not an OCR-readable label) is the model loaded, and never under memory pressure. The 6 s observation-age rule (`ComputerLimits.maxObservationAge`) is unchanged.
Why: a cold load (~5 s) plus the counting check made the screenshot older than the rule, so a correct stale-screen refusal looked like a flaky icon-only press. The cause was the order of operations, not the rule.

## DEC-215 — Learning is data, never authority
Status: Accepted (V0.14)
Decision: a learned lesson, rule, workflow, skill, routing nudge, MCP server or model output never becomes an authority source. It can add a requirement, a warning or a preference; it cannot approve, grant a capability, install, delete, send, purchase, weaken a safety rule or change the sandbox. Policy, approval and command code never read learned data to decide.
Why: the user's V0.14 brief ("JARVIS remains the orchestrator"); the same principle as DEC-104 (memory) and DEC-182 (handoffs). `verify.sh` guards it.

## DEC-216 — The V0.12 orchestrator stays the only orchestrator
Status: Accepted (V0.14)
Decision: no `SelfImprovementOrchestrator`, `AdaptiveOrchestrator` or `MCPOrchestrator`. A self-change, a learned Skill or an MCP-assisted step is an ordinary V0.4/V0.12 task; the adaptive layer has exactly one `engine.submit` (self-improvement, started from an approved request) and never plans or saves graphs.
Why: DEC-157; a second orchestrator would be a second authority.

## DEC-217 — Learning thresholds and independence
Status: Accepted (V0.14)
Decision: a candidate needs ≥ 3 independent episodes (`LearningThresholds.minimumEvents`; an episode is the independence unit, so several signals from one task count once); workflows ≥ 3 successes, capability gaps ≥ 3 sessions, routing nudges ≥ 4 runs, 90-day window. Confidence n/(n+2), 30-day half-life, contradiction factor. Narrow scope needs 3, broad scope 6 episodes; counter-evidence ratio above 0.25 blocks. A rejected candidate has a 14-day cooldown and reappears only if its evidence doubles.
Why: one weak event must never create a global rule; overlearning is a tested failure mode.

## DEC-218 — ONE admission door for learned text
Status: Accepted (V0.14)
Decision: every candidate passes `LearningService.admit`: secret gate → authority gate (the memory gate patterns plus voice approval / "user always approves" shapes) → injection gate → rule vocabulary → evidence must resolve to real rows → overgeneralisation → dedupe/cooldown. Refusals are audited with a machine-readable reason. Nothing is stored before the door.
Why: DEC-107 (one memory door) applied to learning; guarded by `verify.sh`.

## DEC-219 — Closed rule vocabulary that can only add requirements
Status: Accepted (V0.14)
Decision: seven action kinds (requireExperiment, requireExtraValidation, requireIndependentReview, preferWorkflow, avoidSource, addWarning, preferCapability), three comparisons, three scopes. No action names approve / grant / install / delete / send / purchase / sandbox / shell / execute. Evaluation is narrowest-scope-first and can only tighten.
Why: a rule is data a person can read and disable; it must not be a scripting language.

## DEC-220 — Approval boundary: `AdaptiveDecisionSource` is hud or test
Status: Accepted (V0.14)
Decision: promotion, rule/skill activation, self-improvement, and MCP install / update / removal / enable-with-more-permission are REQUESTS bound to a scope hash (sorted-key JSON, so the hash is stable). Only the HUD view models (and the test harness) decide them. Voice, typed chat, memory, proactive and orchestration code cannot. A spoken or typed "yes" creates and approves nothing. Optional standing auto-promotion exists only for LOW-risk workflows and is OFF by default.
Why: DEC-043/DEC-064 (HUD-only approval, voice has no authority) extended to the adaptive layer.

## DEC-221 — Self-improvement levels 0–4, default Experiment, no level 5
Status: Accepted (V0.14)
Decision: Observe, Learn, Experiment (default), Propose, Approved self-improvement. A self-change needs level 4, an HUD-approved request, a recorded checkpoint and a CLEAN Git tree; it runs as an ordinary V0.12 development task (QA + independent review); a failed change is never promoted. `selfRepositoryPath` is assigned only by live tests (disposable fixtures): the app default targets nothing, so the production JARVIS repository is never edited by itself.
Why: the brief ("no silent source modification"); DEC-040 (JARVIS never runs git reset/clean/checkout/commit/push).

## DEC-222 — Skills are validated graph templates
Status: Accepted (V0.14)
Decision: a Skill is a `WorkflowTemplate` validated by the V0.12 graph/plan validators plus learned-workflow restrictions (generic step types only; a code change must be followed by validation). Matching only chooses the starting template; the normal planner checks, role contracts and approvals still apply. A Skill that keeps failing stops being preferred.
Why: reuse without a new execution path.

## DEC-223 — Learned routing is a bounded nudge
Status: Accepted (V0.14)
Decision: `RoutingAdjustment` is limited to |bias| ≤ 0.2 and only orders providers that are already eligible under the V0.3.1 price/privacy/security policy. An explicit provider choice never reads it; UNKNOWN price is never made automatic by learning.
Why: DEC-022…028.

## DEC-224 — MCP servers are capabilities with a status machine
Status: Accepted (V0.14)
Decision: DISCOVERED → INSPECTED → SANDBOXED → BENCHMARKED → RECOMMENDED → APPROVED → INSTALLED → ACTIVE (⇄ DEGRADED / DISABLED) → REMOVED, plus REJECTED / BLOCKED. There is no edge from a pre-approval status to ACTIVE. Registration, update and removal are never automatic.
Why: "never auto-install a production MCP; no automatic MCP update".

## DEC-225 — The MCP sandbox is Seatbelt + sanitised environment, and says what it is not
Status: Accepted (V0.14)
Decision: `sandbox-exec` profile (network denied unless the envelope allows it; writes only in the sandbox directory; home reads denied except the sandbox and runtime root; Keychain/security Mach services denied by name) plus an environment built from scratch, a private directory, own process tree, timeouts and memory sampling. The boundary text lists what is NOT enforced (kernel CPU/memory caps, world-readable system files, an exhaustive Mach filter, separate account or VM). `sandbox-exec` is deprecated by Apple; if it disappears, the report says "sanitised environment only".
Why: "Do not claim isolation you do not have."

## DEC-226 — Typed wrappers inside a permission envelope; BROAD tools never exposed
Status: Accepted (V0.14)
Decision: agents reach an MCP only through `MCPWrapper`s. The registered envelope (read, projectWrite, network, process, account, credential, destructive) is the maximum; shell/arbitrary-code tools are classified BROAD and never exposed; account / credential / destructive envelopes are never automatic (a person must be present). Server output is sanitised, bounded data; instruction-shaped text is counted, never obeyed.
Why: DEC-182-style handoff discipline; an MCP is untrusted.

## DEC-227 — Discovery reuses V0.9 research; the bar is evidence, not popularity
Status: Accepted (V0.14)
Decision: candidates come from the official MCP registry and the GitHub API (unauthenticated, rate-limited, no key), README text as data. A recommendation needs a known licence, activity within a year, an unarchived repository, macOS compatibility, no arbitrary-code tool, a verifiably free price (UNKNOWN is never free) and no credential requirement JARVIS would have to supply. Discovery is on demand only.
Why: DEC-088…103.

## DEC-228 — Benchmark in the sandbox, recommendation rule is deterministic
Status: Accepted (V0.14)
Decision: start/list, domain read-only cases, write cases only on fixtures, determinism, cold/warm latency, RSS, implied permissions, network need, unknown-tool rejection, confinement cases, cleanup. RECOMMENDED needs ≥ 75 % applicable cases passed, clean cleanup, known licence, verified-free price, no uncontained high finding, no credential need. A benchmark is evidence about this version in this sandbox, not a statement of safety.
Why: honest comparison with native tools and Skills.

## DEC-229 — The restart budget is spent only by failures
Status: Accepted (V0.14)
Decision: `failureTimes` (not every stop) drive the bounded restart budget. A clean one-shot idle stop is not a failure.
Why: found by the soak — idle stops were degrading healthy servers.

## DEC-230 — MCP removal deletes only recorded owned files
Status: Accepted (V0.14)
Decision: exact recorded paths inside JARVIS' own server folder; symlinks are removed, not followed; the folder only if empty; the active-task check is re-run at execution time; disabled ≠ removed. Unused servers produce advice, never a deletion.
Why: ownership-safe deletion in the brief.

## DEC-231 — Real UI tests drive the product's AXBackend from a child process
Status: Accepted (V0.14)
Decision: `--live-ui-child <pid>` runs the Accessibility driver in a child; calling AX on the own process crashes SwiftUI. An AX press error (-25200) can still have worked, so the test verifies state, not the return code (DEC-206).
Why: real clicks on the Learning and Capabilities screens without a second AX implementation.

## DEC-232 — Live tests label their evidence
Status: Accepted (V0.14)
Decision: output is labelled REAL (real process/engine/network), ENGINE (real engine, scripted agents) or POLICY (deterministic gate). Live tests use disposable Git fixtures and `live-test-adaptive` / `live-test-mcp` data directories; the real Hamam project is never a target.
Why: AGENTS.md "distinguish automated testing from manual verification".

## DEC-233 — Roadmap unchanged
Status: Accepted (V0.14)
Decision: V0.14 (adaptive learning, controlled self-improvement & MCP/Skill registry) → V0.15 (presence, personality & visual teaching) → V1.0. V0.15 is NOT started.
Why: DEC-213.

## DEC-234 — Response presentation is presentation only
Status: Accepted (V0.15)
Decision: `ResponsePolicy` (depth detection, shortening, address policy, concise acknowledgement wording) only chooses how much of an already-determined answer is shown or spoken. It cannot reach the task engine or the store, never drops a sentence that carries a failure, refusal, unknown, missing piece, permission, warning or pending decision, never turns FAILED into “almost done” or UNKNOWN into “ready”, and uses no model (deterministic rules). Evidence-bearing answers (Project Memory with citations) are shown whole unless a short one is requested. Default style is Concise.
Why: "personality must not alter evidence"; the brief's presentation-policy rule. `guards_v15.sh` (g15_pure), `DailyShapeTests`.

## DEC-235 — The conversational working context is bounded, ephemeral, typed and powerless
Status: Accepted (V0.15)
Decision: `ConversationWorkingContext` keeps ≤ 16 typed referents for ≤ 30 minutes / 30 turns, in memory only (not Codable, not persisted, never written to Project Memory or learning, forgotten on restart). Only validated records and the user's own words enter (research candidate records, a named project, the user's earlier request, typed Unity results); labels that are instruction- or secret-shaped are refused. A resolved follow-up is rewritten into an explicit sentence that takes the normal route (router → task intake → V0.12); the context cannot approve, grant a capability or start work by itself. “Devam et” stays with Project Continuity (current truth outranks conversation).
Why: DEC-104/DEC-215 (memory and learning are never authority) applied to short-term references; the V0.15 brief.

## DEC-236 — A follow-up never guesses a destructive target, and “yes” never chooses
Status: Accepted (V0.15)
Decision: delete/remove follow-ups resolve only from something the user explicitly chose or named and only when it is the single candidate; otherwise JARVIS asks (“Silinecek hedefi tahmin etmem”). Ordinal deletes ask for confirmation of the one found. A bare yes/no never completes a clarification. The approval guard now covers EVERY pending decision (task approval, adaptive request, proposal) via `hasPendingDecision` and runs before follow-up resolution. Deleting still follows the normal approval policy afterwards.
Why: DEC-065/DEC-220; recency is not consent.

## DEC-237 — “Efendim” is a small deterministic address policy
Status: Accepted (V0.15)
Decision: Turkish only; at wake and at a decision request always; in Natural style also at greeting, task acceptance and completion, never twice within 4 replies; Minimal = wake + decisions; Off = never; English never. The only state is a turn counter and the last use.
Why: natural use without roleplay or repetition.

## DEC-238 — Readiness is a read-only picture with distinct states
Status: Accepted (V0.15)
Decision: `ReadinessService` builds the picture from probes of what JARVIS already knows (provider status probe, runtime inspection, permission preflights, stored MCP facts). Building it starts no process, asks for no permission, spends no quota, reads no credential. READY needs a safe check that ran; present-but-unverified is AVAILABLE; idle-by-design is NOT RUNNING; stored health is labelled stored; the Paid API row has no action. It is read on appear, on Recheck and after a user action — never polled.
Why: "do not claim authenticated status merely because an executable exists"; DEC-017/DEC-021.

## DEC-239 — Setup is a closed list of typed actions that run packaged scripts
Status: Accepted (V0.15)
Decision: `SetupAction` is the only way the app installs anything: five installs (local model runtime, Whisper, natural voice, visual model, memory search), permission buttons, Recheck, Select Existing Model Folder. An install runs one script from `JARVIS.app/Contents/Resources/setup/scripts` directly (no shell string, no argument from outside), with the provider environment allowlist, after a confirmation (source, size, destination) and a disk check (1.25× installed size), one at a time, cancellable (process tree), idempotent (pinned revisions / SHA-256 inside the scripts; an existing valid installation is reused). No sudo, no URL or command field, no installer for Claude Code / Codex / OpenCode / MCP servers, no paid dependency, no bundled model. Existing model folders are referenced where they are after validation (config + weights, inside home or an external volume, no escaping link).
Why: the brief's dependency-manager rules; the scripts already carry the pins; a generic installer would be an authority.

## DEC-240 — JARVIS.app: ad-hoc signed, hardened runtime, one entitlement, not sandboxed, not notarized
Status: Accepted (V0.15)
Decision: `scripts/package-app.sh` builds `JARVIS.app` (bundle id unchanged, version 0.15.0, build = commit count, temporary generated icon replaceable by `Resources/AppIcon.icns`). Signing: a keychain identity when one exists, else ad-hoc (this Mac has none). Hardened runtime on; the only entitlement is the microphone. Not sandboxed (Computer Use, provider CLIs, local helpers, Unity and the MCP sandbox cannot live in the App Sandbox); not notarized (private local use; notarization needs credentials and is not claimed). The Info.plist keeps exactly one privacy key. The bundle contains no database, model or fixture (checked by the script and by `guards_v15.sh`).
Why: V0.15 brief §46–48; honesty about the security model.

## DEC-241 — Launch at Login, single instance and notifications are user-controlled and minimal
Status: Accepted (V0.15)
Decision: Launch at Login uses `SMAppService.mainApp` only (one file), OFF by default, state read from macOS, no LaunchAgent / daemon / hand-written plist. A plain launch (no `--flag`) hands over to a running copy through the running-application list; developer and live-test launches are exempt; reopening shows the Compact HUD. Notifications are opt-in, requested only when switched on, generic text, never project content; sub-steps never notify. `verify.sh` guards updated: `SMAppService` and `UNUserNotificationCenter` are allowed in `Readiness/SystemIntegration.swift` only; LaunchAgent/Daemon/launchctl stay forbidden everywhere.
Why: "no hidden persistence", "user-controlled".

## DEC-242 — Installed mode and development mode are separate
Status: Accepted (V0.15)
Decision: the installed app assumes no repository, source tree, `.build`, working directory, test resource or development server (`guards_v15.sh`: `#filePath`, `currentDirectoryPath`, `swift run`, `xcodebuild` only in live-test/dev files; `Bundle.main` only for identity and packaged setup scripts). Mutable state stays in Application Support / Caches. Messages that used to say “run scripts/setup_*.sh” now say “press Set Up in System & Readiness” (development builds keep the script hint).
Why: the no-Terminal acceptance test.

## DEC-243 — The voice output architecture stays pluggable; the final voice is deferred
Status: Accepted (V0.15)
Decision: `TextToSpeechProvider` (+ `SpeechRenderer`, `SpeechChunker`, `VoiceSelection`) is the provider boundary: Apple system voices and the local neural voice are two providers; a final custom voice becomes a third provider without touching `ConversationService` or `TaskEngine`. No voice is selected, cloned or downloaded in V0.15. Task acknowledgements can be silenced (`ConversationMessage.silent`); completions are spoken only when voice is enabled and nothing else is being said.
Why: Bilal deferred the choice; DEC-057…086 unchanged.

## DEC-244 — Stop speech is not stop task
Status: Accepted (V0.15)
Decision: “Sus / sessiz ol / stop talking / stop speaking / quiet” → `.cancelGeneration` (speech and answer generation); “Görevi durdur / stop task / cancel task” → `.stopTask`. The router vocabulary was extended; the executor documents that speech-stop never reaches the task layer. Turkish follow-up words written without diacritics (“onu kullan”) are recognised as Turkish for reply language.
Why: the brief's interruption semantics.

## DEC-245 — V0.15 is the last feature milestone; V1.0 is validation
Status: Accepted (V0.15)
Decision: after V0.15 no major feature is added. V1.0 = real-world validation & stabilization (daily use, Hamam on a copy, real voice, real Computer Use, defects, latency, packaging polish, the final voice provider if chosen). Whiteboard / visual teaching are out of scope and have no placeholder architecture. V1.0 is NOT started.
Why: the user's roadmap decision; DEC-233.

## DEC-246 — V1.0 stabilisation fix 1: capability questions are deterministic, depth targets the last answer, Push-to-Talk says when Voice is off
Status: Accepted (V1.0, stabilisation — no new milestone)
Decision: (1) “What can you use / which models and providers / can you use X / do you have X / what tools / what can you do” are answered from the readiness records by `ReadinessAssistant` (new intents `providers`, `canUse`, `tools`, `capabilities`; strict grammar: a question about JARVIS only — any verb or noun outside the vocabulary makes it a request that keeps its normal route). No model is called, nothing is started (OpenCode stays NOT CHECKED), READY/AVAILABLE/RUNNING, INSTALLED/SIGNED IN, NOT CHECKED/UNAVAILABLE and OPTIONAL/MISSING stay distinct (`ReadinessItem.installed` carries what is known about the files). (2) “Detaylı anlat / kısa söyle” target the answer IMMEDIATELY before the request, read from the conversation itself; the presenter remembers what each deterministic answer really is by the text shown (a model's or command's answer is simply its own text); a whole answer says there is no further VERIFIED detail instead of inventing any; no previous answer → a plain notice. (3) The Push-to-Talk handler is attached whenever PTT is switched on, even with Voice off (the installed app ships with Voice OFF): the hold is answered with a visible hint and the microphone stays closed; Readiness gains a “Voice input · Push-to-Talk” row (OFF / READY / DEGRADED) with an explicit Turn On Voice button, and the Microphone row is renamed “Microphone permission” and says it does not mean PTT is on; bounded PTT state-transition diagnostics (counters + short label, no other key, no text, no audio).
Why: three defects found in the first real use of the installed app (the model behind the conversation invented “I have no access to Claude”; “detaylı anlat” re-rendered an older answer; the right ⌥ hold did nothing while every voice dependency read READY).
