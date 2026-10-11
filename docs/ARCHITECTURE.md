# Architecture (V0.1)

Status: IMPLEMENTED · AUTOMATED TESTED (see `PROJECT_STATE.md`). Current: V0.3.1 (intelligence infrastructure on top of V0.3). Decisions behind it: `DECISIONS.md`.

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

## Conversation & command pipeline (V0.2 — DEC-016/017/018)

```
raw text ─► InputNormalizer ─► IntelligenceRouter ──┬─ .command(JarvisIntent)      ─► CommandExecutor ─► JarvisWindowControlling / JarvisStore
 (typed now;     fold, "Jarvis"      (pure: WHERE?)   ├─ .localResponse(greeting…)   ─► Phrasebook
  voice/LLM      prefix, fillers                      ├─ .reasoningRequired/.workerRequired ─► IntelligenceProviderRegistry (EMPTY in V0.2 → truthful "not connected")
  later)                                              └─ .unsupported
ConversationService (orchestrates, cancellation) ─► ConversationStore (messages, streaming-ready) ─► ConversationPanel / command-field feedback
```
- **Pure vs. effectful.** Normalizer, `CommandRouter`, `LocalConversation`, `IntelligenceRouter` are pure and unit-tested (alias tables in `CommandRouter`). Effects live only in `CommandExecutor` (windows/tasks) and `ConversationService` (store writes, provider tasks).
- **Window invariant preserved.** The executor calls `showFullHUD(section:)` etc.; Compact XOR Full is `WindowManager`'s job (DEC-015).
- **State.** Deterministic commands never touch `JarvisState`; only a (future) provider request sets `.thinking` → `.idle`.
- **Provider boundary.** `IntelligenceProvider.respond(to:) -> AsyncThrowingStream<IntelligenceEvent>`; `ConversationService.cancelCurrentResponse()` is the barge-in hook; messages support `pending → streaming → complete/failed`. Tests drive it with fake providers; V0.2 registers none. **V0.3 handoff:** implement a subscription-backed provider (official CLI/desktop/agent mechanisms only — no API keys, no web scraping) and `register` it; replace the "not connected" branch automatically because the router already classifies reasoning vs worker requests.
- **Compact origin.** Simple replies show as one line in the command field (fixed 392×448); navigation opens the Full HUD; reasoning/worker requests open the Full HUD Dashboard.

## Text input (V0.2.1, DEC-019)

`AppMenu` installs the standard main menu (Edit) so native editing shortcuts reach the focused `NSTextView` via the responder chain. `CommandField` hosts `ComposerField` (NSTextView in an NSScrollView): plain-text paste, Return/Shift+Return policy (`ComposerKeyPolicy`, pure + tested), bounded height (Full ≤6 lines then scrolls; Compact fixed 1 line). Both HUDs are non-activating panels (key without app activation).

## Providers (V0.3 — DEC-020/021; research: `PROVIDER_RESEARCH.md`)

```
ConversationService ─► IntelligenceProviderResolving ◄── ProviderManager (discovery, readiness, selection, sessions, states)
        │                                                    │ ExecutableLocator (GUI PATH is not trusted) · ProviderProbe (`--version`, `auth status` / `login status`)
        │ stream of IntelligenceEvent (.session/.textDelta/.finished, typed ProviderError)
        ▼                                                    ▼
 StreamCoalescer ─► ConversationStore            CLIProvider = CLIProviderSpec (args/stdin/parser) + ManagedProcess + ProviderLineParser
                                                      ├─ ClaudeCodeSpec: `claude -p --output-format stream-json --verbose --include-partial-messages --tools "" --safe-mode …`
                                                      └─ CodexSpec:      `codex exec [resume <id>] --json -s read-only --disable shell_tool …`
```
- **No shell, no API keys, no JARVIS network client.** Child env is an allowlist (`ProviderEnvironment`); prompts go over stdin; private empty working dir; short "no tools, never claim actions" instruction.
- **ManagedProcess:** byte-safe line splitting (UTF-8 safe), bounded stderr (diagnostics only, never an answer), real cancellation SIGINT→SIGTERM→SIGKILL of the process AND descendants (`proc_listchildpids`), `ProcessRegistry.killAll()` on app termination.
- **Providers never see deterministic commands or `workerRequired` requests** (router decides first; `CLIProvider.supports(.worker) == false`).
- **Continuity:** Claude `--session-id`/`--resume`; Codex `thread_id` → `exec resume`; fresh sessions (first turn, provider switch, failed resume) get a bounded context of previous provider-answered exchanges only.
- **State:** JARVIS goes Thinking only for a real provider generation and returns to Idle on completion/cancel/failure (never stuck in Error).

## Intelligence infrastructure (V0.3.1 — DEC-022…028)

```
                                   ConversationService  (text; deterministic commands & workerRequired never get here)
                                          │ resolve(kind, prompt) / escalate / runFinished
                                  IntelligenceCoordinator ── AuditRecorder ──► SQLite (agent_runs, activity, …) + ArtifactStore (files)
                  TaskClassifier ─► TaskProfile ─► ModelRouter (pure) ─► RoutingDecision{selected, fallbacks[], reasons{}}
                                          │ snapshot
                                  ProviderSupervisor ── health/cooldown (persistent) · ResourceManager (pressure, limits)
          ┌───────────────┬───────────────┼────────────────────────┐
     LocalRuntime     OpenCodeService   ProviderManager (V0.3)     AgentRunManager (background, bounded) ── OneShotRunner
   (python worker,    (catalog+prices,   Claude Code / Codex        └─ BenchmarkRunner (suite v1, real validators)
    JSON lines)        free registry)    CLIProvider · ManagedProcess
```
- **Pure vs effectful.** `TaskClassifier`, `LocalModelPolicy`, `ModelRouter`, `BenchmarkSummary/Policy`, `CooldownPolicy`, `OpenCodeCatalog` are pure and unit-tested; effects live in the runtime classes. All child processes still go through `ManagedProcess` (one audited launch point).
- **Cost classes.** `ProviderID.costClass`: local · freeCloud (OpenCode verified-free only) · subscription (Claude/Codex) · paidAPI (does not exist). Nothing can route to a paid API.
- **Local model.** `LocalRuntime` (state: notConfigured/modelMissing/runtimeMissing/idle/starting/ready/running/stopping/unavailable/failed) launches `jarvis_local_worker.py` from an isolated venv on demand, one job at a time, offline, exits on stdin EOF; idle/pressure/shutdown unload. `LocalQwenProvider` re-checks `LocalModelPolicy` itself (defence in depth).
- **OpenCode.** `OpenCodeService` reads `opencode models --verbose [--refresh]`, builds `ModelRecord`s (price-only free verification, 24 h freshness), `OpenCodeSpec.make` can only build a launch for a current free-pool model; runs in `provider-workspace/opencode` with a restrictive `opencode.json`.
- **Escalation.** The router returns an ordered fallback chain; `ConversationService` escalates at most once, only in Auto, only after a failure that produced no text; `AgentRunManager` additionally allows one same-engine repair after failed validation (hard cap 3 invocations).
- **Persistence.** `Persistence/` (SQLite engine, migrations, repository, artifacts, redaction) — see `PERSISTENCE.md`. A missing/corrupt database never stops JARVIS (auditing becomes a no-op / the file is moved aside).
- **Automated runs are inert.** `AppContext(stubIntelligence:)` (smoke/capture/`--no-providers`) uses a temp data directory and never contacts any provider; `--intelligence-live-test` uses its own `JARVIS/live-test` data directory.

## Agent observability (V0.3.2 — DEC-029…032; details `AGENT_OBSERVABILITY.md`)
Provider/worker output → `SafeProvider` (wraps every engine; `StreamSanitizer`, fail closed) → sanitized events → agent runtime **and** `ExecutionHub` (bounded `ConsoleBuffer`, coalesced revision, batched persistence into `agent_events`, sanitized output artifact) → `AgentObservatory` read model (`ProviderStateResolver`, `RunPhase`, `ProgressCalculator`) → Full HUD **Agents** section (provider cards, runs, console, history, timeline) and a 44 pt Compact summary strip. Stop is routed to the existing cancellation paths (`installStopRouting`). Launch reconciles stale runs to INTERRUPTED. Developer simulation (`ObservatoryDemo`) is isolated and never persisted. Schema v2 adds `agent_events`, `agent_run_steps` and run label/progress/activity columns.

## Autonomous task engine (V0.4 — DEC-033…040; details `AUTONOMOUS_TASK_ENGINE.md`)
```
GoalIntake ─► TaskEngine.submit ─► tasks/task_steps (SQLite) ─► PlannerAgent ─► PlanParser/PlanValidator ─► steps
   scheduler (withTaskGroup, event-driven) ─► executeStep
        analysis/codeChange/review ─► StepAgentRunner (ManagerAgentRunner → AgentRunManager.spawn → ModelRouter/Supervisor/Resources → SafeProvider)
        codeChange output ─► EditParser ─► ProjectTools.prepare ─► approvals (dirty files) ─► FileLeaseManager ─► apply ─► hash check
        build/test ─► CommandRunner (ApprovedExecutables, ManagedProcess, SafeToolOutput) ─► repairLoop (≤1 repair + ≤1 escalation)
        delete ─► approval ─► ProjectTools.delete
   ─► checkpoint/report artifacts ─► TaskBridge ─► JarvisStore.engineTasks ─► Compact card · Dashboard · Tasks screen · Approval card
```
`Sources/Jarvis/Tasks/`: `TaskModel` (kinds, capabilities, state machines, records) · `TaskPlan` (plan, parser, validator, planner prompt) · `Workspace` (`WorkspaceGuard`) · `ProjectTools` (+ `EditParser`, `UnifiedDiff`) · `CommandProfiles` (approved executables, discovery, runner, test counts) · `GitTool` (read-only) · `FileLeaseManager` · `TaskPrompts` (agent answers, targeted context) · `StepAgentRunner` (seam over `AgentRunManager`) · `TaskEngine` (+`+Planning`, `+Execution`, `+Lifecycle`) · `TaskReport` · `GoalIntake` · `TaskBridge`. Persistence: `Persistence/TaskRepository.swift` (schema v3). Dev-only scripted agents: `Services/Demo/TaskDemo.swift`.
Seams: `StepAgentRunner` (tests substitute a scripted runner; production = `ManagerAgentRunner`), `TaskSubmitting` (`ConversationService` → intake), `EngineTaskControlling` (HUD buttons → engine). The UI never touches the repository (`verify.sh`).

## Windows

- **Invariant (DEC-015):** Compact XOR Full visible, enforced only in `WindowManager`.
- **Compact HUD** — `HUDPanel` (borderless, floating, `canBecomeKey`). Anchored under the status item; hides on resign-key (0.25 s guard prevents the dismissing click from re-opening it); ESC via `cancelOperation`; **fixed canonical size** `CompactHUDLayout.size` (392×448, DEC-014): window and SwiftUI root share it, `sizingOptions = []`, task card fixed-height, only inner content crossfades.
- **Full HUD** — `FullHUDWindow` (borderless, resizable, clear background, normal level, movable by background). Sized to ~90 % of the visible frame (max 1480×920) on the screen of the menu bar item/pointer; centered. **Minimum size is enforced in `windowWillResize`** (NSHostingView overwrites `contentMinSize`). ESC/⌘W close it. Layout adapts at <1200 pt width (`hudIsNarrow`).
- **Settings** — `SettingsWindow` (titled; ESC/⌘W close).

## Rendering & resources

- Glass = `NSVisualEffectView` (`.hudWindow`) + deep-ink tint + hairline; fonts are system fonts; tokens in `UI/Theme/Theme.swift`.
- JARVIS Core: `CoreRenderer` (Core Graphics) inside `CoreNSView`, driven by a `CADisplayLink` (≤24 fps) that exists **only while** `isAnimating` (HUD visible ∧ Reduce Motion off). Hidden/idle = one static frame, 0 CPU. Rationale/measurements: DEC-006.
- Menu bar icon: cached template `NSImage`s per (state, frame); a 0.5 s timer runs only for listening/thinking/working.
- Neural background (Full HUD only, DEC-012): `NeuralGraph` (seeded, generated once) + `NeuralSimulation` (≤14 pulses) are pure; `NeuralNetworkNSView` draws with Core Graphics on a `CADisplayLink` at 5–15 fps by state, torn down when hidden / Reduce Motion; SwiftUI (`NeuralBackground`) only forwards state changes. The core's own frame rate is also state-based (10–24 fps).
- Nothing else polls except the hotkey service (below); elapsed-time labels tick at 1 Hz only while the task runs and the surface is visible.

## Global shortcuts (DEC-013)

`GlobalHotkeyService` (Services/Input) polls modifier state (12 Hz at rest / 60 Hz while Option is held; permission-free) → pure `ModifierChordMachine` → `JarvisWindowControlling.toggleCompactHUD()` / `toggleFullHUD()` (wired in `AppDelegate`). Compact = hold ⌥ + press ⌘; Full = hold ⌥ + press ⌘ twice within 0.30 s (Compact never flashes first). `toggleFullHUD`: hidden → show; frontmost → hide; visible but behind → bring forward. Toggle in Settings.

## Dev tooling (compiled into the binary; inert without launch args)

`--smoke-test` (`App/SmokeTest.swift`), `--capture <dir>` (`App/DevCapture.swift`, uses the window server's image of *this process's own windows* — no Screen Recording permission), `--open-full/--open-compact/--section/--state/--close-after`. `AccessibilityAudit` walks the in-process AX tree (currently SKIPs: SwiftUI doesn't build it without an AX client).

## Extension points for later milestones (not implemented)

- V0.2: replace `LocalCommandHandler` with a command router (needs a response channel; today it only writes to the activity log).
- V0.4 is implemented (see above). Later: V0.5 proactive reasoning + approval policy builds on `TaskEngine.submit`, the approval gate and the report/checkpoint data.
- Voice (V0.5–0.7): something must arbitrate `setState` between STT/LLM/task engine.
- Self-controlled UI (V0.8): protocol may need `currentSection`, `hideSettings`, and a "don't steal focus" open variant.
