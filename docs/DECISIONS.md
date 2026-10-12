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

