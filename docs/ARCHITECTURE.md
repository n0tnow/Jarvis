# Architecture (V0.1)

Status: IMPLEMENTED · AUTOMATED TESTED (see `PROJECT_STATE.md`). Current: V0.12 (multi-agent orchestration — see the last section) on V0.11 (general computer use) on V0.10 (project memory: derived, provenance-backed knowledge, hybrid retrieval, bounded agent context) on V0.9 (web research & asset acquisition: cited research, quarantine downloads, approval-gated import — all ordinary V0.4 tasks) on V0.8 (natural voice & presence: wake word, VAD, hands-free turns, barge-in, neural voice — an I/O layer, no authority) on V0.7 (voice I/O around the conversation pipeline; V0.6 Unity agent, V0.5 proactive layer, V0.4 task engine below). Decisions behind it: `DECISIONS.md`.

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

## Proactive reasoning (V0.5 — DEC-041…046; details `PROACTIVE_REASONING.md`)
```
TaskEngine.onFinished / onReviewSuggestions ─► OpportunityEngine ─► FindingExtractor (recorded facts) ─► ingest
   dedupe · cooldown · coalesce ─► OpportunityAssessor (deterministic; ≤1 budgeted call that may only add caution) ─► OpportunityPolicy (pure)
   record │ propose │ requireApproval ─► ProposalRecord ─► UI buttons ─► ProposalService (only decision writer) ─► approved
   autoAction ───────────────────────────────────────────────────────────────────────────────────────────────────┘
   ─► OpportunityEngine.startTask ─► TaskEngine.submit(origin, scope, depth, deterministic id)   ← the ONLY execution path (V0.4)
```
`Sources/Jarvis/Proactive/`: `OpportunityModel` · `OpportunityPolicy` · `OpportunityNormalizer` · `OpportunityAssessor` · `FindingExtractor` · `EvidenceRevalidator` · `OpportunityEngine` · `ProposalService`; `Tasks/TaskScope.swift` (origin + scope enforcement); `Persistence/OpportunityRepository.swift` (schema v4); UI: `ProposalsView` (Tasks screen), Settings → Autonomy, Dashboard summary, Compact "N SUGGESTIONS" tag.

## Unity Project Agent (V0.6 — DEC-047…056; details `UNITY_PROJECT_AGENT.md`)
```
V0.4 task (Unity project ⇒ unity capabilities) ─► plan (unityInspect/Edit/Compile/Test/PlayMode/Validate) ─► TaskEngine+Unity step
   ─► UnityConnection.perform: UnityPolicy (capability · Play Mode · dirty scenes · identity · paths) ─► typed UnityOperation ─► UnityFileSpoolTransport
   ─► <project>/Library/JarvisBridge/{requests,responses,status.json} ─► Editor package com.jarvis.bridge (fixed handler table) ─► Unity Editor
   ◄─ sanitized answer ◄─ deterministic validation (compile state · tests · expected state · Console delta) ─► evidence/report/checkpoint ─► V0.3.2 Observatory
```
`Sources/Jarvis/Unity/` (discovery, detector, protocol, transport, policy, service, lock, launcher, installer, generated package) · `Tasks/TaskEngine+Unity.swift` · `Tasks/ReviewAuthority.swift` · `UnityBridge/` (C# package + disposable fixture) · `Persistence` v5.

## Voice I/O (V0.7 — DEC-057…068; details `VOICE_IO.md`)
```
hold right ⌥ ─► GlobalHotkeyService (same permission-free modifier sampling as ⌥⌘) ─► PushToTalkMachine ─► VoiceCoordinator (ONE lifecycle authority)
   MicrophoneInput (AVAudioEngine, created on press / destroyed on release, 16 kHz mono frames) ─► STTSession ─► partial transcripts (provisional, composer area only)
   release ─► mic stops FIRST ─► finish() ─► FINAL transcript ─► ConversationService.submit(source: .voice)   ← the SAME entry point as typed text
        ─► IntelligenceRouter ─► deterministic command │ local │ provider │ TaskEngine (GoalIntake; tasks.input_channel = voice) ─► ConversationStore
   ConversationStore messages ─► VoiceResponseSpeaker ─► SpeechChunker ─► SpeechRenderer ─► TextToSpeechProvider (bounded queue, stop at once)
```
`Sources/Jarvis/Voice/`: `VoiceTypes` (states, capabilities, events, errors, metrics) · `VoiceCoordinator` (state machine, PTT lifecycle, handoff, JarvisState ownership) · `VoiceResponseSpeaker` (follows the shown answer, long-answer policy, turn/stale protection) · `SpeechChunker` + `SpeechRenderer` (pure, deterministic) · `PushToTalkMachine` (pure) · `VoiceSelection` (pure provider selection, cost-first) · `AudioInput` (`MicrophoneInput`) · `MicrophoneAccess` (the only permission file) · `SpeechToText` (protocols, `TranscriptText.clean` sanitizer hop) · `AppleSpeechSTT` (SpeechAnalyzer/DictationTranscriber) · `WhisperRuntime` (helper supervision + `WhisperSTTProvider`) · `TextToSpeech` · `AppleSpeechSynthesizer`. Helper: `scripts/voice-ai/jarvis_stt_worker.py` (offline, in-memory audio, exits on stdin EOF). UI: `UI/Components/VoiceViews.swift`, `UI/Settings/VoiceSettingsSection.swift`. Test/live-test only (`Services/Demo`, `App/VoiceLiveTest.swift`): `FixtureAudio`.
Seams for V0.8: `AudioInput` (any capture source), `VoiceCoordinator.pushToTalkPressed/Released` (any trigger — wake word/VAD can drive the same entry points), `VoiceResponseSpeaker.stop` (barge-in hook), `STTSession`/`TextToSpeechProvider` (streaming providers). Nothing of V0.8 exists.

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
- V0.4–V0.10 are implemented (see above). Later (DEC-068/086/126): V0.11 project memory, V0.11 computer use, V0.12 advanced multi-agent — all through `TaskEngine.submit` and the V0.5 policy.
- Voice (V0.7 done): `VoiceCoordinator` owns the voice lifecycle and only claims `JarvisState.listening` while capture runs (never clobbering another owner).
- Self-controlled UI (V0.10, with project memory): protocol may need `currentSection`, `hideSettings`, and a "don't steal focus" open variant.

## Natural voice & presence (V0.8 — DEC-069…086; details `NATURAL_VOICE.md`)
```
MicrophoneHub (ONE engine while anyone subscribes) ─ wake subscription (opt-in) ─► EnergyGate ─► SentinelRuntime ─► jarvis_sentinel_worker.py (wake head + Silero VAD; no STT, no network)
                                                    ─ utterance / PTT subscription ─► VoiceCoordinator.beginUtterance ─► STTSession ─► FINAL ─► ConversationService.submit(source: .voice)
SentinelRuntime events ─► HandsFreeCoordinator ─► TurnMachine (pure) ─► effects: start/end/discard utterance · stop speaking · acknowledge · single-shot timers
VoiceResponseSpeaker ─► PlayerBackedTTSProvider(NeuralSpeechEngine | AppleSpeechEngine) ─► SpeechPlayer (own AVAudioEngine, OUTPUT only) ─► reference levels ─► BargeInDetector
```
`Sources/Jarvis/Voice/Natural/`: `EndpointPolicy`, `TurnMachine` (+ `WakeContextGate`), `BargeInDetector`, `HandsFreeCoordinator` (+ `VoicePresence`), `AudioHub` (`MicrophoneHub`, `HubAudioInput`, `AudioRing`, `EnergyGate`), `HelperHost` (+ `RestartBudget`), `SentinelRuntime`, `NeuralVoice` (runtime, engine, provider), `VoiceIdentity`, `TranscriptGuards` (`WakePhrase`, `SelfSpeechFilter`, `LanguageContinuity`), `TechnicalTerms`, `WakeCue`; `Voice/SpeechPlayer.swift`, `Voice/PlayerBackedTTS.swift`. Helpers (`scripts/voice-ai/`): `jarvis_sentinel_worker.py`, `jarvis_tts_worker.py`, `jarvis_wake_head.py`, `jarvis_audio_features.py`; bench/training tooling in `scripts/voice-ai/bench/`. Test/live-test only: `Services/Demo/VoiceTestRig.swift` (scripted microphone, simulated speaker, scripted answers), `App/NaturalVoiceLiveTest.swift`.

## Web research & asset acquisition (V0.9 — DEC-088…103; details `WEB_RESEARCH.md`, `ASSET_ACQUISITION.md`)
```
Conversation (typed|voice) ─► GoalIntake/ResearchIntake ─► TaskEngine.submitResearch ─► V0.5 policy ─► TaskKind.research (fixed plan, budgets)
   steps: researchSearch ─► researchRead ─► researchExtract ─► [researchVerify] ─► researchReport          (typed step runners in TaskEngine+Research)
           │ providers (QueryBuilder)  │ WebClient ◄─ URLGate/URLPolicy (every hop) ◄─ HTTPTransport (the only URLSession)   │ RenderedPageProvider (the only WKWebView, read-only)
           ▼                           ▼ HTMLExtractor · SourceClassifier · UntrustedContent (fence+scan) · Grounding
   ResearchPipeline (actor) ─► PriceAnalyzer · LicenseAnalyzer · UnityCompatibilityAssessor · CandidateRanker ─► ResearchReport (artifact) ─► Research screen
Candidate ─► AcquisitionPolicy ─► [HUD approval] ─► TaskKind.acquisition ─► Downloader ─► quarantine (acquisitions/<id>/, provenance.json) ─► ArchiveInspector ─► readyForImport
readyForImport ─► (user) ─► submitImport = .development task + importIntoProject ─► approval ─► AssetImporter ─► Assets/ThirdParty/<slug>-<id6> ─► [V0.6 compile]
```
`Sources/Jarvis/Research/`: `ResearchModel`, `URLPolicy` (+ `URLGate`, `CanonicalURL`), `HTTPTransport`, `WebClient`, `HTMLExtraction`, `SourceClassifier`, `LicenseAnalyzer`, `PriceAnalyzer`, `UnityCompatibility`, `UntrustedContent`, `SearchProviders` (+ `SearchTerms`), `RenderedPageProvider`, `QueryBuilder` (+ `ResearchIntake`), `ResearchPipeline` (+ Candidates), `CandidateRanker`, `ResearchReportBuilder`, `ResearchPlanner`, `ResearchServices`, `ResearchViewModel`; `Research/Acquisition/`: `ArtifactSniffer`, `ArchiveInspector`, `Downloader`, `AcquisitionService`, `AssetImporter`. Persistence: `ResearchRepository` (schema v7). UI: `UI/FullHUD/Research/ResearchSectionView`, `UI/Settings/WebResearchSettingsSection`. Test/live-test only: `Services/Demo/ResearchFixtures.swift` (fixture site, virtual public hosts), `Services/Demo/ResearchDemo.swift`, `App/ResearchLiveTest.swift`.
Rules: research never writes files or runs processes; only `AssetImporter` writes into a project; no purchase/account code path exists; web text is data.

## Project memory (V0.10 — DEC-104…126; details `PROJECT_MEMORY.md`)
```
sources (docs · finished tasks · validated research · Unity/Git inspection · user sentences · optional grounded model proposals)
   └─► MemoryCandidate ─► MemoryService.admit  [secret · trivial · instruction/authority · provenance · current truth · dedupe · contradiction] ─► memory_items/sources/relations (schema v8)
                                                  └─ supersede / dispute / stale / forgotten · reconcileWithTruth (TruthProbing: Unity, files, Git, app constants)
retrieval: structured filters + BM25 (TR/EN fold + bridge) + cosine on the DERIVED index (memory_embeddings; MemoryIndex ◄─ EmbeddingHostController ◄─ HelperHost ◄─ jarvis_embed_worker.py, offline, on demand)
   └─► MemoryRetriever (0.8 semantic / 0.2 keyword + idf subject boost + explainable boosts) ─► MemoryAnswerer (cited answers) · ProjectContextBuilder (bounded packets per agent kind)
TaskEngine.runJob ─► packet in front of the job prompt ─► memory_context_uses(run id, memory ids) · ConversationService ─► ProjectMemory.recognizes/reply (remember · correct · forget · "what did we decide…") or the packet in the provider request
Full HUD ▸ MEMORY (MemoryViewModel) · Settings ▸ Project memory
```
`Sources/Jarvis/Memory/`: `MemoryModel`, `MemoryText` (+ `MemoryGate`), `MemoryService`, `MemoryTruth`, `ProjectIdentity`, `MemoryIntent`, `MemoryIngest` (parsers · `MemoryIngestor` · `ModelMemoryExtractor`), `MemoryRetrieval`, `MemoryIndex`, `EmbeddingRuntime`, `ProjectContextBuilder`, `MemoryAnswer`, `ProjectMemory` (facade), `MemoryViewModel`; `Persistence/MemoryRepository`; `UI/FullHUD/Memory/MemorySectionView`, `UI/Settings/MemorySettingsSection`; helper `scripts/memory-ai/jarvis_embed_worker.py` + `scripts/setup_memory_ai.sh`; benchmark `scripts/memory-ai/bench/`; live test `App/MemoryLiveTest.swift`.
Rules: memory is context, never authority; current project truth outranks it; the index is derived; nothing runs while idle.

## V0.11 — General Computer Use

```
Conversation / voice ─▶ GoalIntake (ComputerGoalParser: capability ladder first) ─▶ TaskEngine (TaskKind.computer)
        │                                                                   │ approvals (HUD only) · cancel · restart rules
        ▼                                                                   ▼
  stronger rung owns it?                             TaskEngine+Computer: plan (deterministic) / bounded model rounds
  V0.4 tools · V0.6 Unity · V0.9 web · Git                         │
        (normal path continues)                                     ▼
                                          ComputerExecutor: OBSERVE ▸ RESOLVE ▸ POLICY ▸ ACT ▸ OBSERVE ▸ VERIFY
                                              │  TargetResolver · ComputerPolicy · Coordinates/StaleCheck · retries/timeouts
                                              ▼
                                       UIBackend (protocol) ── AXBackend (real: AX, NSWorkspace, CGEvent, CGWindowList)
                                                           └── ScreenCapture (ScreenCaptureKit + Apple Vision OCR)
                                                           └── FakeUI (tests: a virtual macOS)
```

`ComputerRuntime` owns the backend, permissions (truthful, never prompting), vision gating (setting + permission + memory pressure), the timeline and the emergency-stop sampler (running only while a session runs). `Computer/` knows nothing about memory content, approvals' decisions or providers; `TaskEngine+Computer` is the only caller of the executor. Details, limits and measurements: `GENERAL_COMPUTER_USE.md`.

## Multi-agent orchestration (V0.12 — DEC-157…190; details `MULTI_AGENT_ORCHESTRATION.md`)
```
ConversationService (typed │ voice) ─► GoalIntake / compound-goal detection ─► TaskEngine.submit
   planPhase: OrchestrationPlanner (deterministic route │ template │ planner MODEL) ─► PlanValidator + GraphValidator ─► role graph (task_steps + depends_on, ≤ 12 nodes, DAG)
   scheduler: ConcurrencyPolicy (read-only pairs, 1 under pressure) ─► node: orchestrationRefusal (role contract) ─► specialist
        analysis/coding/review ─► runJob ─► ModelRouter/Supervisor/Resources (V0.3.1) ─► routing_decisions (sentence, sizes, cost class)
        build/test ─► QA tools · unity* ─► V0.6 · delegateResearch ─► child V0.9 task · delegateComputer ─► child V0.11 task · approvalGate ─► HUD decision
   ─► AgentArtifact (sanitized, bounded, trust-labelled) ─► HandoffBuilder (ancestors only, fenced data) ─► next node ─► deterministic validation outranks claims
   ─► TaskOutcome (SUCCESS │ PARTIAL │ …) ─► report from graph state ─► Tasks graph view · Agents (roles) · Compact line · status questions
```
`Sources/Jarvis/Orchestration/`: `AgentRole` (roles, contracts, limits) · `TaskGraph` (graph, `GraphValidator`, `ConcurrencyPolicy`, `TaskOutcome`) · `OrchestrationPlanner` (cues, templates, revision, planner prompt) · `Artifacts` (artifacts, trust, handoff) · `RoleRouting` (ledger, independence, explainer, scoreboard, failure/escalation vocabulary, role evidence) · `RoleBenchmarks` · `OrchestrationStatus` · `OrchestrationViewModel`; `Tasks/TaskEngine+Orchestration.swift`; `Persistence/OrchestrationRepository.swift` (schema v10); UI `TaskGraphView`; live test `App/OrchestrationLiveTest.swift`.


## V0.13 — Project operator (IMPLEMENTED · AUTOMATED TESTED · REAL TESTED · MANUAL TEST REQUIRED)

V0.12 stays the ONLY orchestrator. V0.13 adds four capabilities around it — none of them is a second engine:

```
user: "where are we?" / "continue"                                  ┌──────────────────────────┐
   │                                                                  │  Continuity/ (derived)   │
   ├─ status ──► ProjectContinuity ──► files · Git · tasks · docs ·   │  view · reconcile ·      │
   │             (local, no model)      Unity descriptor · checkpoint │  select · checkpoints    │
   │                                    · memory digests (truth wins) └──────────────────────────┘
   └─ continue ► TaskEngine.submit(goal, constraint=ContinuationMarker, bounds) ─► V0.12 graph ─► V0.4 steps
                                                                                     │
        Unity operator (UnityDevOp, 23 typed ops) ◄── unityEdit / unityInspect ◄────┤  correction loop (≤ 2 rounds)
        Visual grounding (Vision/, on-device) ◄── Computer Use vision rung ◄────────┤  perception only
        Experiments (disposable env in Caches) ◄── `experiment` step ◄──────────────┘  + asset evaluation (fact classes)
```

* **Continuity** (`Sources/Jarvis/Continuity/`): a derived view; only checkpoints, the next-step queue and a session counter are stored (schema v11). `docs/PROJECT_OPERATOR.md`.
* **Unity operator** (`Unity/UnityOperatorOps.swift`, `UnityOperatorResults.swift`, `OperatorCorrection.swift`, `Tasks/TaskEngine+UnityOperator.swift`, `+UnityCorrection.swift`, Editor package 0.13.0): closed typed operations, read-back verification, double Play-Mode block. `docs/UNITY_DEVELOPMENT_OPERATOR.md`.
* **Visual grounding** (`Vision/`): perception only; Apple Vision OCR + a local Qwen3-VL helper (`scripts/vision-ai`), worst-of safety, memory-only pictures. `docs/VISUAL_GROUNDING.md`.
* **Experiments** (`Experiments/`, `Tasks/TaskEngine+Experiment.swift`, schema v12): a bounded contract, a marker-checked disposable Unity project under `~/Library/Caches/JARVIS`, verdicts that need every check, asset facts by class. `docs/EXPERIMENTATION.md`.

Authority is unchanged: approvals are HUD buttons only; memory, artifacts, checkpoints, visual output and UI text never grant anything; the proactive layer starts none of it.

### V0.13.1 — closure and stability (no new layer)

Same orchestrator, same experiment engine: the Input System ops extend `UnityDevOp` (+ the optional `Jarvis.Bridge.InputSystem` assembly in the bridge package); `animationPlayback` / `audioPlayback` are kinds of `ExperimentKind` (`TaskEngine+ExperimentPlayback.swift`); `Continuity/UnitySceneFacts.swift` is a read-only live-or-history scene view for the Project card; `App/StabilitySoak.swift` is a dev-only bounded soak (`--stability-soak N`). The requirement-to-guard matrix is `docs/GUARD_MATRIX.md`.

## V0.14 — Adaptive learning, self-improvement & MCP/Skill registry (DEC-215…233; details `ADAPTIVE_LEARNING.md`, `SELF_IMPROVEMENT.md`, `MCP_REGISTRY.md`, `SKILLS.md`)

* `Sources/Jarvis/Adaptive/` — `LearningModel`, `LearningGate` (one admission door), `SignalExtractor`, `PatternDetector`, `LearningService`, `RuleEngine`, `AdaptiveDecisions` (HUD-only approval, scope-hash bound), `SelfImprovement`, `AdaptiveIntent`/`AdaptiveAssistant` (typed + spoken share one path), view models.
* `Sources/Jarvis/Capabilities/` — `MCPModel` (status machine, envelope), `MCPRegistry`, `MCPClient` (JSON-RPC over `ManagedProcess`), `MCPSandbox` (Seatbelt + sanitised env + honest boundary), `MCPInspector`, `MCPBenchmark`, `MCPStaging`, `SkillRegistry`. Discovery: `Research/MCPDiscovery.swift` (V0.9 stack).
* Persistence v13 (learning) and v14 (MCP registry); UI: Learning and Capabilities Full HUD screens, Settings → Adaptive learning, one optional Compact line (392×448).
* Hooks into existing systems are read-only requirements: planner (`learnedContext`, `applyLearnedRequirements`, Skill matcher), asset evaluation, bounded routing bias. No new orchestrator, no new approval source.

## V0.15 — Daily JARVIS, readiness, packaging (DEC-234…245; details `DAILY_JARVIS.md`, `CONVERSATIONAL_CONTEXT.md`, `APP_PACKAGING.md`, `FIRST_RUN_SETUP.md`)

* `Sources/Jarvis/Daily/` — `ResponsePolicy` (depth detector, shortening that never hides a negative fact, address policy, concise acknowledgement wording, `ResponsePresenter`) and `WorkingContext` (bounded ephemeral referents, `FollowUpParser`, `ReferenceResolver`, `ProjectSwitchParser`). Presentation and references only.
* `Sources/Jarvis/Readiness/` — `ReadinessModel` / `ReadinessService` (read-only picture from injectable probes), `ReadinessAssistant` (EN/TR readiness questions), `SetupRunner` (closed `SetupAction` list → packaged scripts, preflight, cancel), `ReadinessActions`, `SystemIntegration` (Launch at Login via `SMAppService`, opt-in notifications, single-instance rule, fixed System Settings panes), `Diagnostics`.
* Wiring: `App/AppContext+Daily.swift` (probes, notifier, setup runner, presenter hooks, task-finished presentation), `ConversationService` (depth re-render → project focus → follow-up resolution → readiness questions, all after the approval guard), `UI/FullHUD/System/ReadinessSectionView.swift` (Readiness card + first-run walk-through), `UI/Settings/DailySettingsSection.swift` (Startup, Daily JARVIS, About).
* Packaging: `scripts/package-app.sh`, `install-app.sh`, `verify-installed.sh`, `make-app-icon.swift`, `installed-probe.swift`; `Resources/Jarvis.entitlements`.
* Execution chain unchanged: User → voice / text → `ConversationService` → routing / task intake → `TaskEngine` → V0.12 orchestrator → typed capabilities → validation → result → presentation → text / voice. No second orchestrator, no new approval source, no new capability.

## V1.0 stabilisation fix 2 — where the new pieces sit
* **Production boundary:** `AppContext.demoMode` / `simulatorControlsVisible`; demo seeds only for developer launch options (`docs/PRODUCTION_TRUTH.md`, DEC-247).
* **Self-knowledge:** `Readiness/ReadinessAssistant` (ability intents) → readiness snapshot + project folder; `Readiness/CapabilityClaimGuard` (output side) and `JarvisInstruction.text` (input side) form the provider identity firewall (DEC-248). “Ekranıma bak” is a Computer Use goal (`ComputerGoalParser` 7b).
* **Settings & storage truth:** `Daily/SettingsAssistant` (closed registry, read-back evidence, undo), `Daily/StorageLedger` (what went where), `Daily/CorrectionIntent` (correction parser, `TurnMemory`, `SpeechTranscriptRepair`); all handled in `ConversationService.submit` BEFORE Project Memory (DEC-249/250). `ResponsePresenter.constrainModelOutput` holds model answers to the “efendim” cadence (DEC-251).
* **Hands-free lifecycle:** `HandsFreeCoordinator` sleep mode, Mac sleep/wake and bounded device-change recovery; `UI/Settings/VoiceStatusRows` is the pure model of the Voice overview (DEC-252). The V0.8 stack (MicrophoneHub → energy gate → sentinel → TurnMachine) is unchanged.
* **UI layout:** `VoiceStrip` has a fixed reserved height; `ConversationPanel` follows text only while pinned to the bottom (DEC-253).

## V1.0 stabilisation fix 3 — where the new pieces sit
`Persistence/StorageIsolation` (protected runs, isolated defaults/data, hard guards) · `Readiness/CodeIdentity` + permission rows in `ReadinessService` · `Services/Windows/FullHUDFramePolicy` (frame policy + `WindowDragRegion`) · `UI/Components/DesignSystem` + `Theme.Grid` · `UI/FullHUD/Settings/SettingsPageView`, `UI/Settings/VoiceControlCards` · `App/UICapture` (`--ui-capture`) and `App/PermissionReport` (`--permission-report`). See DEC-254…259.

## V1.0 stabilisation fix 4 — where the new pieces sit
`Actions/` (`ActionReceipt` + `ActionLedger`, `ActionIntent` grammar, `ActionService` + `ActionPhrasebook`, `PhoneticAppResolver`) above `ConversationService` · `Readiness/SystemStatus` (`SystemStatusSnapshot`/`Composer`) · `Voice/Natural/BargeInDetector` (`echoMatch`) · `Voice/Natural/EchoProvenance` (`UtteranceProvenance`, `PhantomGuard`, `VoiceDiagnostics`) wired in `HandsFreeCoordinator`/`VoiceCoordinator` · `Voice/SpeechToText` (`VoiceVocabulary` contextual terms) · `Computer/ComputerGoalParser` (media pattern) + AX pre-flight in `Tasks/GoalIntake`. See DEC-260…266.
