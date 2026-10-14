# Development Log

Append-only engineering history. Newest entries at the bottom.

## 2026-10-10 — V0.1 Foundation (sessions 1–3, including two interruptions)

### Goal
Native macOS foundation + HUD, no AI. Then recover from interruptions, finish verification, write project memory.

### Environment
macOS 26.4, arm64 (M5), Swift 6.3.2, SDK 26.5, **Command Line Tools only (no Xcode)**; empty directory, no git history.

### Changes
- Swift Package + `scripts/build_app.sh` (ad-hoc signed bundle), `scripts/test.sh`, later `scripts/verify.sh`.
- Models/Core/Services/UI layers; `NSStatusItem` + Compact HUD panel + Full HUD window via `WindowManager`; design tokens; glass surfaces; 7-state core visualization; demo data/dev tooling; settings.
- Visual-inspection loop using an in-process capture tool (Screen Recording permission deliberately not requested).
- CPU investigation: SwiftUI Canvas/TimelineView ≈ 30 % of a core (independent of canvas content/fps) → AppKit `CoreNSView` + `CADisplayLink` ≈ 9 %; menu-bar icon caching.
- Recovery session: repo health re-verified; read-only reviews (architecture: no blockers; UI/a11y; test gaps) → fixes: state↔task coherence, narrow-width dev strip, approval VoiceOver announcement, Settings ESC/⌘W, accessibility identifiers, stronger smoke test (28 checks), `scripts/verify.sh`, 6 coherence unit tests.

### Tests
- Unit 17/17; smoke 28 PASS / 0 FAIL / 2 SKIP; `scripts/verify.sh` → VERIFY PASSED; screenshots of all states + minimum size; CPU idle 0 %, Full HUD animating ≈ 9 %.
- Earlier in recovery: real menu-bar click open/close and compact ESC observed via System Events (host-terminal AX).

### Problems Found (all fixed unless in KNOWN_ISSUES.md)
Incoherent dev state switching; text too small; truncation; min size (0,0); layout collapse at min width; high animation CPU; icon re-rasterization. Open: JARVIS-001…010.

### Decisions
DEC-001…DEC-010 (`DECISIONS.md`).

### Process notes
The user interrupted External-UI-automation (System Events) tool calls twice; not retried. Real OPEN JARVIS click and physical ESC on Full HUD are MANUAL TEST REQUIRED. Docs were not written until the final session — written now.

### Remaining Work
User manual test of V0.1 (README checklist). Then, only with approval: V0.2.

## 2026-10-10 — Git workflow + V0.1 baseline publish

### Goal
Establish a simple durable Git workflow and publish the verified V0.1 candidate.

### Changes
- Added `origin` = https://github.com/n0tnow/Jarvis.git; `main` only (DEC-011); "Git Workflow" section in `AGENTS.md`.
- `.gitignore` audited (build products, `.build/`, `captures/`, Xcode/macOS noise, secret-file patterns) — unchanged.
- Secret scan of the working tree: nothing found.
- Single baseline commit `feat(v0.1): establish native macOS Jarvis foundation` (no fabricated history). Repo-local author identity uses the GitHub noreply address.

### Tests
`scripts/verify.sh` re-run before the commit (see commit/PROJECT_STATE for results).

### Decisions
DEC-011. JARVIS-009 resolved.

### Remaining Work
User manual test of V0.1. No `v0.1` tag until approved.

## 2026-10-10 — V0.1.1: compact stability, neural background, global hotkeys

### Goal
Three user-requested fixes after manual V0.1 testing (overall direction approved): (A) Compact HUD must not resize between states, (B) subtle ambient neural-network visuals, (C) global ⌥⌘ / ⌥⌘⌘ shortcuts. No V0.2 work.

### Changes
- **A** `CompactHUDLayout` (392×448), window `sizingOptions=[]`, fixed-height task card, 0.2 s inner crossfade (off under Reduce Motion). Root cause: `.preferredContentSize` + `fittingSize`. Commit `fix(compact-hud)`.
- **B** `NeuralGraph`/`NeuralSimulation` (pure, seeded) + `NeuralNetworkNSView` (Core Graphics, CADisplayLink 5–15 fps by state, torn down when hidden/Reduce Motion) behind the Full HUD only; core frame rate made state-based. Commit `feat(hud)`; DEC-012.
- **C** `ModifierChordMachine` (pure) + `GlobalHotkeyService` (permission-free polling) + `toggleFullHUD`; Settings info rows + off switch; version → 0.1.1. DEC-013, DEC-014.

### Tests
Unit 36/36 (was 17): chord machine (single, double, timeout, early Option release, repeat flood, resets, invalidation by other key/click/Shift, cooldown), service, neural graph/simulation, compact constants. Smoke: compact frame constant across 7 states × dev strip on/off × task/no task; neural lifecycle + Reduce Motion + hidden stop; scripted ⌥⌘/⌥⌘⌘ → real WindowManager (Compact never flashes during Full chord, no duplicate windows). CPU table in PROJECT_STATE.

### Problems found
Settings window too short for the new section (fixed); capture tool lost compact focus intermittently (retry added); first neural pass was nearly invisible and +3 pts CPU (visibility raised, frame rates lowered, core fps made state-based).

### Decisions
DEC-012, DEC-013, DEC-014.

### Remaining Work
User manual test (README checklist: fixed compact size, global shortcuts from another app, neural look, Reduce Motion). No tag until approved.

## 2026-10-10 — V0.1.1 final fix: exclusive HUD presentation

### Manual test feedback
The user manually inspected V0.1.1 and found the overall UI acceptable. One final issue: Compact and Full HUD could be visible simultaneously (e.g. Full open → menu-bar icon/⌥⌘ → Compact opens next to it). Other earlier MANUAL TEST REQUIRED items are NOT recorded as user-verified (the user only reported this issue).

### Change
Root cause: one-directional exclusivity. `showCompactHUD` now hides Full; `bringFullHUDForward` hides Compact (`showFullHUD` already did). Lives only in `WindowManager` (DEC-015).

### Tests
12 new smoke checks on the real WindowManager: show Compact/Full from every starting state, menu-bar icon click action, OPEN JARVIS, ⌥⌘/⌥⌘⌘ through the real hotkey service (Compact never re-flashes), Full-behind toggle brings forward without Compact, 10× rapid repeats with no duplicate windows, an exclusivity assertion at every checkpoint, Compact still 392×448. Mutation check: removing the fix makes 5 of them fail.

## 2026-10-10 — V0.2: text conversation + intelligence router

### Goal
Conversation domain, deterministic command routing, execution layer and a future provider boundary — with NO real AI (subscription-first rule). Prerequisite V0.1.1 gate passed first (`1b64d07`).

### Changes
- Models/Core: `ConversationMessage`, `ConversationStore` (bounded, streaming-ready, feedback line), `JarvisIntent`/`RouteDecision`.
- Services/Conversation: `InputNormalizer`, `CommandRouter` (EN+TR aliases), `LocalConversation`, `IntelligenceRouter`, `IntelligenceProvider`+registry, `Phrasebook`, `CommandExecutor`, `ConversationService`. V0.1 `LocalCommandHandler` removed.
- UI: `ConversationPanel`, command-field feedback + focus, Compact feedback line (392×448 unchanged), `Announcer` (VoiceOver), approval card placement, narrow-layout top-bar fix.
- Tooling: smoke test now runs the 7 acceptance scenarios against the real WindowManager; `verify.sh` asserts no network/API-key code; DevCapture conversation scenarios.
- Process: 3 read-only subagents (UI review, routing edge-case review; architecture covered by earlier reviews). Their findings are in JARVIS-R11 / R10.

### Tests
Unit 81 (was 36); smoke 65 PASS (+2 SKIP) incl. 7 acceptance scenarios + 40 repeated commands; `verify.sh` PASS.

### Problems found
LazyVStack scroll-to-newest bug; routing false positives/negatives (see JARVIS-R11); narrow-layout env bug since V0.1 (JARVIS-R10).

### Decisions
DEC-016, DEC-017, DEC-018.

### Remaining Work
User manual test of V0.2. Then V0.3 (subscription-backed provider) only with approval; verify current official CLI/desktop/agent tooling first. No tag yet.

## 2026-10-10 — V0.2.1: native clipboard / text editing

### Trigger
User: cannot paste into the JARVIS input.

### Investigation (proof, not assumption)
A smoke reproduction first failed against the unfixed app: `NSApp.mainMenu == nil`; ⌘V/⌘C/⌘Z did nothing in the focused field editor. Second finding from instrumentation: with another app frontmost, `NSApp.activate()` was denied, the regular-window Full HUD stayed non-key (no typing possible). The hotkey poller was ruled out (reads modifier state only).

### Changes
`AppMenu` (Edit menu); `ComposerField` NSTextView composer replacing the SwiftUI TextField; Full HUD is a non-activating NSPanel; `ComposerKeyPolicy`; smoke editing suite (real key events via `NSApp.postEvent`, pasteboard saved/restored — dev tool only); 7 new unit tests (88 total).

### Decisions
DEC-019. JARVIS-R12.

## 2026-10-11 — V0.3: real intelligence providers

### Goal
Connect real intelligence without API keys: the user's own signed-in Claude Code / Codex, conversation only, streaming, real STOP, continuity, provider selection. Workers stay V0.4. Prerequisite V0.2.1 gate passed first.

### Changes
Research doc (`58c6948`); `Providers/` layer (discovery, probe, manager, CLIProvider, ManagedProcess, parsers); ConversationService provider path (coalesced streaming, busy refusal, cancel, retry-once on lost session, state ownership); provider badge/STOP/Settings/System row; `--provider-live-test`; focused `verify.sh` provider policy (DEC-020); DEC-021.

### Tests
183 unit (was 88), smoke 85 PASS, verify PASSED. REAL TESTED with both providers (see PROJECT_STATE). A/B CPU vs the V0.2.1 build: no regression.

### Problems found (all fixed)
`proc_listchildpids` count-vs-bytes bug left orphan grandchildren (found by real-process tests); lingering exit misreported as cancel; live test left the user's provider preference changed; test parallelism made real-process tests flaky (suite now `--no-parallel`); **Codex writes `login status` to stderr, so the billing-mode check wrongly marked it UNAVAILABLE — found only by the real run (the fake CLI printed to stdout); fixed and the fake now mirrors reality.** Reviewer findings (session-id-as-flag, unbounded line buffer, loose HTTP-status regex, stale sessions after failures/provider switch, cancel-while-resolving, state clobbering) fixed with regression tests.

### Decisions
DEC-020, DEC-021.

### Remaining Work
User manual test of V0.3. No tag. V0.4 only with approval.

## 2026-10-11 — V0.3.1: intelligence infrastructure

### Goal
Durable persistence + audit trail, OpenCode verified-free pool, on-device Qwen, ProviderSupervisor, policy-driven model router, bounded background-agent foundation. Not V0.4.

### Changes
`Persistence/` (SQLite engine, migrations, repository, artifacts, redaction) · `Intelligence/` (TaskClassifier, LocalModelPolicy, ModelRouter, benchmark suite + runner, OpenCodeCatalog/Service, LocalRuntime + worker, ProviderSupervisor, ResourceManager, AuditRecorder, IntelligenceCoordinator, AgentRunManager, ContextRetrieval) · OpenCode spec/parser/workspace per CLI generation · ConversationService now resolves by prompt, audits, escalates once · Settings (modes, OpenCode free pool + benchmarks, local model), System/Agents panels, provider badge · `--intelligence-live-test` · `verify.sh` policy additions · DEC-022…028, OPENCODE_RESEARCH, MODEL_ROUTING, PERSISTENCE docs. Commits: see `git log` (persistence, routing, local-ai, agents, opencode-v2, ui/docs).

### Real findings (found by REAL tests, all fixed)
- Local STOP left the runtime "busy" (provider reported stopped before the worker acknowledged) — JARVIS-R16.
- Agent concurrency slots were checked against a list filled too late — JARVIS-R17.
- `exo-free` listed active/free but the API returned 410 deprecated → typed removal, 24 h sticky block, benchmark early abort.
- OpenCode updated itself 1.18.34 → 1.19.0 (the user then chose to stay on it): `models --verbose` and `run --pure` disappeared. Researched the v2 docs, found the documented `api model.list` price source, `run --standalone`, the v2 permission model; **a canary found that v2 Code Mode (`execute`) could make a network request** → denied in the v2 config; v2 JSON streams may lack `step_finish`; v2 error events have another shape. JARVIS supports both generations by probing `--help`.
- Process note: while probing the v2 API I invoked `credential.list` and it printed the user's OpenCode Go key into the session output (never stored by JARVIS; user told to rotate). verify.sh now forbids credential/integration operation names.

### Decisions
DEC-022 … DEC-028 (+ DEC-025 addendum).

### Remaining Work
User manual test (README 33–39). V0.4 only with approval. No tag.

## 2026-10-11 — V0.3.2: agent observatory & live consoles

### Goal
Make agents/providers observable live (provider cards, run cards, sanitized console, history, timeline, Stop, restart reconciliation) with a security boundary strong enough that provider output can never leak a secret into state, storage or UI. Not V0.4.

### Changes
`Observability/` (OutputSanitizer + StreamSanitizer, ObservabilityTypes, ExecutionHub, SafeProvider, AgentObservatory, ObservatoryDemo) · schema v2 (`agent_events`, `agent_run_steps`, run label/progress/activity; `interrupted` status) · `AuditRecorder.reconcileStaleRuns` · coordinator wraps every engine in SafeProvider · Agents section (provider cards, runs, console on `NSTextView`, history, timeline), Compact summary strip, router aliases, `--demo-agents`/`--demo-stress` · tests (SanitizerTests, ObservatoryTests, ObservatoryConsoleTests, ObservatoryUITests; 377 total) · live test extended · `verify.sh` guards · DEC-029…032, `docs/AGENT_OBSERVABILITY.md`.

### Real findings (found by tests, fixed)
- JSON-field redaction regex back-referenced the wrong group → plain `"password": "…"` leaked (caught by a sanitizer unit test).
- A structured-sanitize second pass destroyed JSON keys; a dangling-keyword hold split `password:` from its value; fixed with a whole-word rule.
- Compact summary strip reserved space when idle and pushed the dev strip out of view → zero height when idle.
- Live test: a local run read RUNNING while the model was still loading (now STARTING); the hub phase never left `starting` for CLIs that answer at the end (now RUNNING once the process is launched); the "Reply with exactly: sk-test-…" prompt was routed as a worker request because of the word "test" (use a neutral fake key).
- Performance on this machine: Full Dashboard idle is 7.4 % with BOTH V0.3.2 and V0.3.1 (the 3.4 % in the V0.3.1 notes was a quieter host) → no regression.

### Decisions
DEC-029 … DEC-032.

### Remaining Work
User manual test (README 40–66). V0.4 only with approval. No tag.

## 2026-10-11 — V0.4: autonomous task engine

### Goal
User-initiated goal → durable task → structured plan → scheduled agents/tools → deterministic validation → bounded repair/escalation → report, restart-safe, observable through V0.3.2. Not V0.5.

### Changes
`Tasks/` (TaskModel + state machines, TaskPlan parser/validator/planner prompt, WorkspaceGuard, ProjectTools + EditParser + UnifiedDiff, CommandProfiles/ApprovedExecutables/CommandRunner, GitTool (read-only), FileLeaseManager, TaskPrompts/ProjectContext, StepAgentRunner seam, TaskEngine (+Planning/Execution/Lifecycle), TaskReport, GoalIntake/TaskIntake, TaskBridge) · schema v3 + `TaskRepository` · `ProviderID.tool`, `SafeToolOutput`, `ManagedProcess(mergeStderr:)`, AgentRunManager `exclude/pin/policy/owner` + cancellation forwarding + capacity wake-ups · Tasks screen, Compact card, project picker, run grouping · `--task-live-test`, `--demo-tasks`, scripted `DemoAgentRunner`, captures + smoke checks · verify.sh V0.4 guards · DEC-033…040, `docs/AUTONOMOUS_TASK_ENGINE.md`.

### Real findings (tests/live tests found them; all fixed)
- unittest/compilers print their summaries on **stderr**: build/test output must merge stdout+stderr (`mergeStderr`), otherwise counts/failure text were lost.
- A real free-model planner labelled a `delete` step with validation `structuredResult` → the whole plan was rejected. Validation is deterministic by step type, so a known-but-misplaced label is now coerced (unknown labels still rejected).
- "Delete the file …" was not routed as work (`delete` was not a worker verb) → added delete/erase/wipe/purge.
- A repair's re-run of the failing test was recorded as another *repair* attempt → new `recheck` attempt kind; report counts are exact.
- Review/skip: a step with nothing to do must be able to go `running → skipped`.
- Test harness: objects the engine holds weakly (HUD bridge) must outlive the test body (a dropped bridge made Stop a no-op and hung a test).
- Policy rejections inside an edit validator were reported as plain validation failures; they now keep their category (`workspaceViolation`/`capabilityDenied`) and are never "repaired".
- verify.sh: the plan validator's DENY-list of prohibited words ("curl", "sudo") tripped the launcher/pty guards — excluded that one file explicitly rather than weakening the guards.
- Perf: nothing regressed vs V0.3.2 on the same host; the 2 % with parked tasks is the pre-existing menu-bar icon animation of the Working state (1.5 % with the demo task alone) plus the demo runner's 20 Hz wait loop.

### Decisions
DEC-033 … DEC-040.

### Remaining Work
User manual test (README 67–91). V0.5 only with approval. No tag.

## 2026-10-12 — V0.5: proactive reasoning, opportunity engine & approval policy

### Goal
A decision layer above V0.4: notice useful things after a task, reason about them, and take only the initiative policy permits — never a second execution engine.

### Changes
`Proactive/` (model, deterministic policy, normaliser/dedup, assessor, finding extractor, evidence revalidator, OpportunityEngine, ProposalService) · `Tasks/TaskScope` (origin/scope/depth + enforcement in plan and edits, `scopeExceeded`) · schema v4 + `OpportunityRepository` · deterministic ids/idempotent task creation · Proposals UI, Settings → Autonomy, Dashboard summary, Compact tag · `--proactive-live-test`, `--demo-proposals`, captures, smoke checks · verify.sh V0.5 guards · DEC-041…046 · `docs/PROACTIVE_REASONING.md`.

### Real findings (tests/live tests found them; all fixed)
- The approval row was written without `proposal_id`/`scope_hash` (parameter list not extended) → proposal approvals were invisible; caught by the first engine test.
- A model-supplied file reference was counted as deterministic evidence ("strong") → a reviewer's suggestion could have become an automatic action. Evidence strength now comes only from JARVIS-recorded facts; suggestions are held until the task ends so deterministic findings are ingested first and suggestions coalesce into them.
- A real reviewer's suggestion won the race against the deterministic finding and consumed the autonomy budget; a denied proposal's reworded twin came back as a new card. Fixed by the ordering above, by coalescing same-origin findings into an opportunity whose task exists, and by suppressing reworded asks about the same file during a cooldown.
- `isTestPath` treated `latest.py` as a test file; now identifier-aware.
- verify.sh: the assessor's DETECTION keywords ("git push", "sudo") tripped the Git/pty guards — exempted that single file explicitly.

### Decisions
DEC-041 … DEC-046.

### Remaining Work
User manual test (README 92–125). V0.6 (Unity Project Agent) only with approval. No tag.


## 2026-10-12 — V0.6: Unity Project Agent & Editor Bridge

### Goal
Unity as a controlled execution environment inside the V0.4 engine (typed, observable, capability-checked), validated on a disposable fixture with a real editor.

### Changes
Embedded JARVIS Editor package (C#, file-spool) + disposable fixture · `Sources/Jarvis/Unity/` (discovery, detector, typed protocol, spool transport, policy, connection/service, mutation lock, launcher, installer) · Unity step types/capabilities/plan validation/migration v5 · `TaskEngine+Unity.swift` · `ReviewAuthority` (generic) · UI (project line, task section, Compact phrase) · simulated editor + ≈105 tests · `--unity-live-test` · verify.sh V0.6 guards · DEC-047…056 · `docs/UNITY_PROJECT_AGENT.md`.

### Real findings (found by tests/live runs; all fixed)
* The bridge's own first run showed the Unity Test Runner pops an unanswerable save-dialog for dirty scenes (run silently never started) → tests/`openScene` are refused with dirty scenes, and a stale "running" state is abandoned.
* `openScene` of the *same* scene would have discarded a user's unsaved edits → any dirty scene blocks it.
* `waitForStatus` returned the current status on timeout, so a timeout looked like "predicate satisfied" (Play Mode appeared to end by itself) → timeout now returns nil (transport and simulator).
* A PlayMode test run leaves Play Mode *after* reporting → the engine waits for an idle editor before reading results.
* The Play step's "always leave Play Mode" cleanup would have exited a Play Mode the step did not start (user's editor) → only a Play Mode the step started (or an owned editor's leftover) is left. Caught by the simulated-editor test, not the live test.
* `targetNotFound` mapped to a generic tool failure, so deleting an already-deleted object was not idempotent → mapped to `validationFailed` and handled.
* Cancelling during a Play observation waited the full 30 s on the simulator (cancellation not wired) → cancellable waiters everywhere.
* A fixture's Git state: the test's own broken script was "the user's uncommitted work" → committed before provider scenarios; the Git-dirty approval for scene *files* was added to Unity edits.
* Unity CPU in performance numbers first excluded helper processes (compiler servers) → now summed with descendants; JARVIS vs Unity vs providers reported separately.

### Real-provider result
OpenCode FREE `opencode/space-bunny-free` (routed by the real ModelRouter, Local Qwen excluded) fixed a real Unity compile error and a real failing EditMode test; Unity's own compiler/test runner validated both; the reviewer's verdict could not change the validated result.

### Decisions
DEC-047 … DEC-056.

### Remaining Work
User manual test (README 126–153). Visual validation, wider destructive operations and multi-editor orchestration are future work. V0.7 only with approval. No tag.

## 2026-10-12 — V0.7: Voice I/O Foundation

### Goal
Make JARVIS usable by voice (Turkish and English) without a second assistant: Push-to-Talk, streaming/incremental STT, incremental TTS, a truthful voice session state — all as an I/O layer on the SAME conversation pipeline, local/system only, no stored audio, no spoken approvals, measured latency and resources.

### Research (measured on this Mac, macOS 26.4, M5, 16 GB; details `docs/VOICE_IO.md`)
* Apple `SpeechTranscriber` (SpeechAnalyzer) supports 30 locales — **no Turkish**; `DictationTranscriber` does (tr-TR, en-US, native streaming partials, ≈60 ms finalisation) and needs no extra permission. `AssetInventory.status` reports "supported" for a dictation locale that is already installed and transcribes fine → readiness uses `installedLocales`.
* Whisper-small (MLX, helper process) beat Apple on technical/Turkish words (mean CER 0.05 vs 0.11, WER 0.18 vs 0.24 on 8 synthetic fixtures), detects Turkish/English for real, 0.2 s per utterance, ≈0.86 GB resident; Whisper-large-v3-turbo handles code-switching better (1.8 GB) → optional. `mlx-whisper` declares PyTorch but never imports it → installed `--no-deps` (venv 480 MB instead of 1.2 GB).
* Piper (ONNX) measured as an optional neural TTS (RTF 0.02–0.07, 200–290 MB; GPL-3/voice licences); `AVSpeechSynthesizer` chosen (free, on-device, 140–170 ms to first buffer, 21 ms to playback).
* `NSEvent.modifierFlags` hides the left/right Option bits; `CGEventSource.flagsState` exposes them (permission-free) → Push-to-Talk = right ⌥ alone.

### Changes
`Sources/Jarvis/Voice/` (coordinator, response speaker, pure PTT machine / chunker / renderer / selection, microphone input + permission, STT/TTS protocols, Apple recogniser, Whisper runtime + provider, Apple synthesizer) · `ConversationService.submit(source:)` + `InputSource` on messages and tasks (schema v6 `tasks.input_channel`) · `ApprovalGuard` (typed/spoken approval words never decide) · stop-talking + menu-bar Stop Speaking · Settings → Voice, voice strip/Compact chip/System row/mic mark · Preferences + `ResourceManager.observePressureRise` · `GlobalHotkeyService` gains the PTT machine (same sampling) · `scripts/voice-ai/` worker + `scripts/setup_voice_ai.sh` (pinned model, explicit) · `Info.plist` microphone string (only privacy key) · verify.sh V0.7 guards (nothing weakened; two narrow documented exemptions) · unit tests (chunker/renderer/PTT/coordinator/Whisper-with-fake-helper/selection/authority/guards/metrics) · `--voice-live-test` (+ `Services/Demo/FixtureAudio`) · docs, README checklist 154–223, roadmap correction (DEC-068).

### Real findings (found by tests / live runs; all fixed)
* The delta-cut property test caught a chunker bug: a trailing space was trimmed when a stream cut fell right after a sentence end ("TheEditMode"); and short sentences were not merged at the final flush.
* The coordinator judged "too short" before the last captured frames were counted (frames reach it asynchronously) → judged after the frame queue drains.
* A new Push-to-Talk during a standalone/Settings phrase did not stop it (state was not SPEAKING) → any active speech is stopped on every press.
* The first live run produced silent fixtures: `AVSpeechUtterance.volume = 0` (used for the silent playback tests) also muted `write()` rendering → rendering is never muted (Whisper rightly returned nothing for silence).
* `ManagedProcess.runOnce` caps output at 64 KB → a process listing was truncated in the live test.
* The router did not know "ekranını/sayfasını/bölümünü" → "görevler ekranını aç" was sent to a provider; added to the tolerated words (found by the Turkish end-to-end test).
* Live-test timing: the combined Unity+voice sample first ran after the Unity editor had exited (sample placed after the long benchmark) → moved before it.

### Results
Unit/smoke/verify: see `PROJECT_STATE.md`. `--voice-live-test`: 38/38 REAL checks with synthetic speech (the transcripts were identical across repeated complete runs); end to end release → first audible audio ≈ 240–290 ms (Apple) / ≈ 400–417 ms (Whisper); idle voice = 0.00 CPU-s per 6 s; real microphone plumbing proven (15 frames in 1.5 s, engine stops); SIGTERM of a child JARVIS leaves no helper.

### Decisions
DEC-057 … DEC-068 (voice is I/O; right-⌥ Push-to-Talk; ephemeral audio and the single privacy string; provider abstraction + cost-first selection; Whisper default / Apple fallback; Apple TTS with incremental sentence synthesis; spoken = shown; stop at once; no spoken approvals; ephemeral sessions; helper resource policy; roadmap correction).

### Remaining Work
User manual test (README 154–223): human speech (Turkish/English/mixed), TTS naturalness, VoiceOver, Reduce Motion, physical right-⌥ feel, background use. V0.8 (wake word, VAD, hands-free, barge-in) only with approval. No tag.



## 2026-10-12 — V0.8 Natural Voice & Presence

### Goal
Turn V0.7 Push-to-Talk into a natural voice presence without a second assistant: opt-in local wake word, VAD, natural endpointing, hands-free turn taking with a follow-up window, barge-in with self-speech suppression, a local neural JARVIS voice (Apple fallback), voice identity, low latency — all still `ConversationService.submit(source: .voice)`.

### Changes
`Voice/Natural/` (EndpointPolicy, TurnMachine, BargeInDetector + SpeechBandFilter, HandsFreeCoordinator, AudioHub = MicrophoneHub/AudioRing/EnergyGate, HelperHost, SentinelRuntime, NeuralVoice, VoiceIdentity, TranscriptGuards, TechnicalTerms, WakeCue) · `Voice/SpeechPlayer` + `PlayerBackedTTS` (own output engine; Apple synthesiser re-based on `AVSpeechSynthesizer.write`) · helpers `scripts/voice-ai/jarvis_sentinel_worker.py` (wake head on frozen openWakeWord features + Silero VAD), `jarvis_tts_worker.py` (Supertonic 3), `scripts/setup_voice_ai.sh --natural`, `scripts/train_wake_head.sh`, `bench/` · `ResponsePresentation.voiceConversation` (speakable answers from the existing provider) · Settings/Full HUD/Compact HUD (stays 392×448)/menu bar · `--natural-voice-live-test` with `Services/Demo/VoiceTestRig` (scripted microphone + simulated speaker) · verify.sh V0.8 guards · docs (`NATURAL_VOICE.md`, DEC-069…087, JARVIS-V08-1…13, README checklist 224–343).

### Research and benchmarks (details in `docs/NATURAL_VOICE.md`)
Wake: pretrained hey_jarvis vs a locally trained head on frozen features (2.9 h held-out). VAD: Silero vs energy. Echo: Voice Processing I/O vs reference-level gating on a real speaker→microphone loop. TTS: Supertonic 3, Chatterbox, Piper.

### Real findings (found by tests and live runs; all fixed)
* State-machine bugs: `case … where` guards applied to the last pattern only; barge-in state overwritten by `beginUtterance`; PTT during transcribing; `RestartBudget` blocked again after cooldown; transcribing stuck after an interrupted PTT (watchdog + empty transcript).
* Wake: v1 head too many false activations → mining; priming gap after resets → continuous model; mid-sentence wakes → utterance-initial rule; lone «Jarvis» must never open the recogniser → continuation timer.
* Endpointing: «Unity'deki.» stop after a hesitation is not trusted; question particles are not connectors.
* Echo: coupling learned from the pre-arrival silence made JARVIS' own Apple voice look like the user → skip the first 0.25 s, clamp −34…−10; click trains → duty rule; a 90 Hz thud and dense clicks while the VAD is saturated by the echo → 250 Hz high-pass + 20 ms slices (DEC-087).
* Speech that resumed inside the acknowledgement deaf window («Jarvis, … open the Tasks screen») was lost → `.deaf` re-check (DEC-087).
* Test rig: paced frame emission, quiet-frame level, bounded answers last ≈ 4–5 s so barge-in timing is phrase-based, a two-word synthetic Turkish clip is misread as English by Whisper (longer fixture), combined-sample bookkeeping.

### Results
Unit: see `PROJECT_STATE.md`. `--natural-voice-live-test`: 55/55 (loop simulated), 58/58 with `--natural-acoustic --natural-idle 6`, plus the optional `--natural-combined` sample next to `--unity-live-test`. Numbers: `docs/NATURAL_VOICE.md` §11.

### Decisions
DEC-069 … DEC-087.

### Remaining Work
User manual test (README 224–343): a human saying «Jarvis», recognition of a human voice, false wakes from real conversation and media, real-room barge-in, voice naturalness (A/B of the JARVIS presets), VoiceOver, Reduce Motion, battery. V0.9 only with approval. No tag.


## 2026-10-12 — V0.9 Web Research & Asset Acquisition

### Goal
General-purpose, evidence-backed web research (Unity assets first) with source quality, licence/price verification, safe quarantined downloads, artifact inspection and an approval-gated import — as ordinary V0.4 tasks, with account actions and purchases left out entirely.

### Changes
`Sources/Jarvis/Research/**` (URL policy/gate, transport, client, HTML extraction, classifier, licence/price/compatibility analyzers, untrusted-content fencing, providers, browser tier, query builder/intake, pipeline, ranker, report builder, planner, services, view model) · `Research/Acquisition/**` (sniffer, archive inspector, downloader, acquisition service, importer) · schema v7 + `ResearchRepository` · `TaskEngine+Research` + engine/intake/model integration · Research screen + Settings section · V0.5 web-authority rule and research proposals · fixture web with virtual public hosts · `--research-live-test` · verify.sh guards · docs (`WEB_RESEARCH.md`, `ASSET_ACQUISITION.md`, DEC-088…103, README 344–463).

### Research and decisions (details in the docs)
Search sources checked against robots/terms/keys (DuckDuckGo HTML yes; Brave needs a key; Asset Store account-bound). Real Poly Haven and Kenney page structures inspected before writing providers. Playwright evaluated and not adopted.

### Real findings (found by tests and the live run; all fixed)
* Foundation percent-decodes/IDNA-decodes hosts → raw-authority checks, NFKC fold, `%` rejected.
* Turkish dotless ı broke the glossary → `ResearchText.fold`; bare «ücretsiz» is not a research cue.
* Exclusivity crash: reading `ctx.record` inside `mutate(ctx)`.
* `/var` vs `/private/var` broke relative import paths.
* **Live run 1 (6 failures → product defects):** GitHub returned 0 results for sentence queries (it ANDs every word) → `SearchTerms.core`; Stack Overflow pages answer 403 → public API route (no evasion); failed/cancelled tasks left the research row on "searching/reading" → `markEnded`; **ranking had no relevance** — a plunger, a drain cleaner and a flower tied with a bucket → topical-relevance factor + hard rule; filler words crowded the nouns out of the structured query and one popular asset crowded out another → noun-first base query and per-word round-robin; GitHub removed from prop searches.
* Test expectations corrected, not product: a lying zip header is caught at extraction (listing passes); local-model/other registered helpers are not research leaks.
* Two structural guards caught real violations: UI reading the repository (moved into the view model) and a new `source: .voice` caller (developer live test listed beside `VoiceLiveTest`).

### Results
Unit 1044 (143 suites) · verify PASSED · smoke 119/0/2 · idle 0.02 CPU-s/8 s, 72 MB · `--research-live-test` 49/0 (≈ 3 min; includes the import of the real artifact into a disposable folder fixture and a real quit/relaunch). Also added after the first report draft: browser tier ↔ ResourceManager (memory pressure releases an idle browser and prefers plain HTTP, DEC-103).

### Also in this session
`scripts/train_wake_head.sh` now checks every generator job and keeps/prints the logs on failure (JARVIS-V08-15; root cause on the user's Mac not reproduced).

### Remaining Work
User manual test (README 344–463). V0.10 only with approval. No tag.


## 2026-10-13 — V0.10 Project Memory

### Goal
Make JARVIS understand a project's history and current state without one giant prompt: a trustworthy, provenance-backed, queryable model of what is known, why, how current it is and when it should influence work — memory as a derived layer over history, never authority.

### Changes
`Sources/Jarvis/Memory/` (model, text + gates, curator `MemoryService`, truth probes, project identity, intent parser, ingestion + parsers + grounded model extractor, hybrid retrieval, derived semantic index, embedding helper controller, `ProjectContextBuilder`, cited answers, `ProjectMemory` facade, view model) · schema v8 + `MemoryRepository` · `TaskEngine.runJob` context injection with per-run audit · conversation (remember / correct / forget / questions, provider context) · Full HUD Memory screen + Settings · `scripts/setup_memory_ai.sh`, `scripts/memory-ai/` (worker + benchmark) · `--memory-live-test` · `verify.sh` V0.10 guards · docs (`PROJECT_MEMORY.md`, DEC-104…126, README 464–583).

### Research (details in `docs/PROJECT_MEMORY.md` §7)
Five ONNX embedding candidates (MiniLM-L12 int8, granite-107m, arctic-embed-m-v2 int8, e5-base, e5-small) and Apple NaturalLanguage on a 62-memory / 48-query bilingual corpus: MiniLM-L12 int8 best (MRR 0.936, 118 MB, 565 MB RSS, 1.3 ms); Apple NL 0.521 with no cross-lingual ability. Fusion weights from the same benchmark (0.8 semantic / 0.2 keyword → MRR 0.964).

### Real findings (found by tests and the live run on the actual repository; all fixed)
* Rare subject words lost to generic semantic similarity ("Playwright" ranked #8) → idf-weighted subject boost; "nothing recorded" was not detected (semantic floor 0.30 too low) → answerability; answers quoted the first sentence of a long decision instead of the one that answers → relevant-sentence excerpts.
* Resolved issues were not parsed (`### JARVIS-R16` entries have an unlabeled body under `## Resolved`) and "supersedes DEC-nnn" was ignored → section-aware parsing and document-declared supersession.
* Intercepting loosely phrased questions ("How do I install Unity?") hijacked ordinary chat → only explicit project-history questions are answered from records; the rest get the packet as model context.
* Frame detection missed "Why did we choose…", "…atmıyoruz", "…seçtik", "constraint" → strong cues + first-person-plural verbs.
* Pinned items bypassed the relevance gate in the Context Builder and filled packets → relevance first, only pinned CRITICAL constraints always travel.
* `MainActor.assumeIsolated` inside service closures trapped off the main actor → lock-protected preference mirror; a `Set` literal with a duplicate element and a duplicate-key dictionary literal crash at run time → built from arrays, checked by a test; `String.hashValue` is randomised per process (flaky fake embedder) → FNV-1a; authority regex flagged restrictions ("never approves") as grants → restrictions are not grants.
* Name collisions (`EvidenceStrength`, `ContextBuilder`) → `MemoryStrength`, `ProjectContextBuilder`.
* The corpus is the repository itself, so live results move as the docs grow (the compound Turkish download question went from #5 to #7) → that query is reported as a known limit, not tuned away.
* Structural guards caught: UI reading the repository (V0.9), a new `source: .voice` caller, "WebKit"/"allow"/"web" words in strings, README fake key shape.

### Results
Unit 1138 (159 suites) · verify PASSED · smoke 125/0/2 · idle 0.02 CPU-s/8 s, 73 MB · `--memory-live-test` 73/73 (≈ 2 min).

### Decisions
DEC-104 … DEC-126.

### Remaining Work
User manual test (README 464–583). V0.11 only with approval. No tag.

## 2026-10-13 — V0.11 General Computer Use

### Goal
Let JARVIS operate ordinary macOS applications when no structured mechanism exists — observable, typed, bounded, policy-controlled, verifiable, cancelable — without becoming "a model clicking screenshot coordinates" and without a new authority.

### Changes
`Sources/Jarvis/Computer/` (model, consequence policy + shortcuts + paths + text classes, capability ladder, EN/TR goal parser + app catalog, semantic target resolver, coordinate/stale/fingerprint logic, `UIBackend` seam, `AXBackend` — the only Accessibility/CGEvent file, window-scoped ScreenCaptureKit capture + Apple Vision OCR, clipboard guard, observe→act→verify executor, bounded planner, adapters, runtime + ⌃⌥⌘ emergency sampler, view model) · `Tasks/TaskEngine+Computer.swift` (`TaskKind.computer`, step `computerAct`, capability `controlComputer`/`captureWindow`, sessions, adaptive rounds, report lines, restart rules) · schema v9 + `ComputerRepository` · conversation/voice route (`ComputerSubmitting`) · proactive policy guard · Computer screen + Settings section · `JarvisFixture` (separate test-dummy app) · `--computer-live-test` · 27 new verify.sh guards (plus narrow exemptions in 10 existing ones) and 7 smoke checks · 120 unit tests with a virtual macOS (`FakeUI`) · docs `GENERAL_COMPUTER_USE.md`, DEC-127…156, JARVIS-V11-1…18, README 584–703.

### Research (details in `docs/GENERAL_COMPUTER_USE.md` §14)
Vision: cloud/model routes rejected (text-only subscription CLIs, privacy, no verified-free image route); a local VLM rejected (RAM); Apple Vision text recognition chosen (free, on-device, 0.2–0.5 s per window) — VISION FALLBACK local OCR live-validated, model vision unavailable. macOS facts measured on this Mac: synthetic mouse events aimed at one process (`postToPid`) are ignored by AppKit → the click uses the system event stream with the pointer restored; AppKit's scroll-by-page action is advertised but unsupported → the scroll bar's `AXValue` is set instead; NSTabView tab buttons report selection in `AXValue`; a modal `NSAlert.runModal` window has subrole AXDialog with `AXModal`, a sheet is an AXSheet child of its window; the Dock keeps an invisible full-display window on every screen (layer 20) that must not count as "covering".

### Real findings (found by the live runs; all fixed)
* Pressing in "the front window" after the app opened a second window hit the wrong window → every window-scoped action and its verification now use the window the user named (several similar windows are told apart by title).
* A modal dialog window's own controls were flagged "covered by a dialog" → a dialog-type window is modal as a whole, a normal window with a sheet only below the sheet.
* Radio/tab selection was invisible (`AXSelected` unset) → selection also reads `AXValue == 1`.
* `AXScrollToVisible` / `AXScrollDownByPage` are listed but unsupported by AppKit scroll views, wheel events posted to a process did nothing, and rows outside a 40-child cap were never seen → scroll-bar `AXValue` jump computed from geometry (only when the tree is not truncated) then stepped scrolling with frame-aware change detection; `AXVisibleChildren` is preferred for huge containers; an element that exists in the tree is not necessarily visible.
* The vision click never arrived (`postToPid` mouse events dropped) → single HID down/up with the pointer restored, preceded by an occlusion check (and the Dock's invisible full-display window is ignored — found on the third display).
* Verifying "state changed" on an action that does not change visible state looped through three 4 s retries → declarative, idempotent postconditions for the live fixture tasks; retries stay bounded.
* A left-over modal alert kept the previous fixture alive (a polite quit is pending behind a modal) → the live test force-ends its OWN dummy app.
* Structural guards caught: permission-gated APIs and pasteboard words in the new files (narrow exemptions), `requestAccess…` naming (renamed), `source: .voice` in the live test, a `Preferences` comment containing a forbidden word.

### Results
Unit 1258 (176 suites; 120 Computer) · `scripts/verify.sh` PASSED · smoke 132/0/2 · idle 0.02 CPU-s/8 s, 73 MB · `--computer-live-test` (release) 88 passed / 0 failed / 2 skipped (Xcode not installed; no Unity Editor running) — Accessibility GRANTED to the session running the test; three displays incl. Retina; measurements in `GENERAL_COMPUTER_USE.md` §13.

### Decisions
DEC-127 … DEC-156.

### Remaining Work
User manual test (README 584–703). V0.12 only with approval. No tag.

## 2026-10-13 — V0.12 Advanced Multi-Agent Orchestration & Intelligent Routing

### Goal
Make V0.1–V0.11 work as one coherent system: JARVIS orchestrates role-bounded specialists over a validated task graph, routes each node explainably, hands results over as typed trusted-labelled artifacts, validates deterministically, and never widens authority.

### Changes
`Sources/Jarvis/Orchestration/` (roles + contracts + limits, task graph + `GraphValidator` + `ConcurrencyPolicy` + `TaskOutcome`, deterministic planner/templates/revision/planner prompt, artifacts + trust + fenced handoffs, routing explanations / node ledger / review independence / failure + escalation vocabulary / role evidence, role benchmarks, graph status, view model) · `Tasks/TaskEngine+Orchestration.swift` (orchestrated planning, authority check at node start, artifacts/handoffs, routing records, delegated research/computer nodes, approval gates, bounded revision, invalidation, review→repair cycle, status/Compact helpers, report lines) · `TaskEngine`/`+Planning`/`+Execution`/`+Lifecycle` hooks (policy-driven scheduler, optional nodes, deadlock + time limits, child tasks, cancel cascade, handoff injection, review independence, role-evidence jobs, graph-aware resume) · new step types/validations (`delegateResearch`, `delegateComputer`, `approvalGate`) · schema v10 + `OrchestrationRepository` · `TaskGraphView`, role-labelled Agents, Compact line · status intents (`showAgentStatus`, `showTestStatus`) · memory authority patterns · `BenchmarkRunner` generalised for the role suite · `--orchestration-live-test` (+ child restart modes, soak) · `OrchestrationScriptRunner` (dev only) · 20 verify.sh guards · 68 tests.

### Research (details in `docs/MULTI_AGENT_ORCHESTRATION.md`)
Design choice: the graph IS the V0.4 plan (no second plan format) so persistence, restart, cancellation and approvals are inherited; delegated research/computer nodes reuse V0.9/V0.11 as child tasks; parallelism limited by measured machine constraints (16 GB MacBook Air) to two read-only nodes; provider session continuity rejected as a source of truth (fresh bounded prompts); role quality measured by small deterministic benchmarks with traps instead of self-rating.

### Real findings (found by the live runs; all fixed)
* A dependent of two parallel readers could start twice (latent V0.4 race) → started nodes are excluded from the ready list.
* Memory accepted “always allow ComputerAgent to install software” → agent-targeted authority patterns.
* The free model followed planted instructions (security role 0/2 in one run, 2/2 in another) → role evidence filter for security-relevant work.
* A compound goal mentioning “research” was taken by the research intake → compound detection first.
* Child research tasks are newer than their parent → root-task selection; child hook returns early.
* A research clause needs its own subject for the V0.9 relevance filter.

### Results
See `docs/MULTI_AGENT_ORCHESTRATION.md` §14 and `PROJECT_STATE.md` (Tested). Unit 1326/188; verify PASSED; smoke 139/0/2; live 61/0/0; idle 0.01 CPU-s/8 s at 73 MB.

### Open
`docs/KNOWN_ISSUES.md` JARVIS-V12-1…13. MANUAL TEST REQUIRED: README 704–823.


## V0.13 — checkpoint 1: Project Continuity (in progress)
Recovered V0.12 (957f95e, clean, in sync; baseline 1326 tests green). Added `Sources/Jarvis/Continuity/` (derived project view, reconciler, selector, status answers, intents, the effectful `ProjectContinuity` service), schema v11 (`project_continuity`, `project_checkpoints`), the Project card, the Compact operator line and a Settings switch. “Continue” resolves against current truth and becomes an ordinary bounded V0.4/V0.12 task; nothing new may approve, buy, push, redesign or run while idle.

## V0.13 — checkpoint 4: experiments, asset suitability, correction loop (in progress)
Added schema v12 (`experiments`, `experiment_steps`, `visual_observations`, `asset_evaluations`; upsert, not REPLACE, so step rows survive a status update), the `experiment` step (contract validated at plan time and again at start, marker-checked disposable workspace, orphan reconcile at launch, always-cleanup, real-project fingerprint before/after, verdict `CONFIRMED / REFUTED / INCONCLUSIVE` where nothing tested ⇒ INCONCLUSIVE), `AssetEvaluator` (VERIFIED / TESTED / SUPPORTED BY SOURCE / INFERRED / UNKNOWN / INCOMPATIBLE), the bounded `unityCorrection` loop (aim the camera / add or raise light / raise ambient; taste words are SUBJECTIVE and never corrected). 17 new tests; full suite green apart from two source-level guards that were widened narrowly for the three new engine files. Not yet real-tested.


## V0.13 — final (READY FOR MANUAL TEST)
Checkpoints: continuity (40ba1fc) · Unity operator (9a341bb) · visual grounding (ec2b59c) · experiments / asset suitability / correction loop · live-verified fixes · continuity live test · UI · icon-only / ambiguous visual tests · real asset experiment · real model-planned graph · Safari measurement · soak / pressure · verify guards, docs, 163 manual checks.

### What the real tests found (and fixed)
* The workspace guard refuses the JARVIS data folder, so asset imports could never run there → experiments root moved to `~/Library/Caches/JARVIS` (found by the real asset run).
* A refuted experiment was first evaluated as "technically fine" → the evaluator now follows the verdict.
* A compile-only run first CONFIRMED a render hypothesis → every check the kind needs must be made (INCONCLUSIVE otherwise).
* `INSERT OR REPLACE` on `experiments` cascaded away the step log → upsert.
* A single box from the local model was not proof of a single match (two identical icons were clicked) → the helper counts matches first.
* A real model-planned Unity graph failed at the independent Review node: evidence lacked positions / values and a later step guessed a child's path → prompts carry earlier steps' real paths, evidence carries read-back values.
* A retry that failed too was restarted through the same recorded next step → exhausted work is never re-offered automatically; the status reports the newest unfollowed failure.
* Live tests leaked a started editor on an early `finish()` → they kill registered children before exit; `crash-*` sections are explicit-only.

### Results
Unit 1446 / 210 suites; verify PASSED (smoke 147/0/2; idle 0.01 CPU-s / 8 s at 73 MB); operator live 97/0/0 (+ soak 5, model-planned 7, asset-experiment 10, crash 3 + 6); continuity live 21/0/0 (+ 4 + 8); computer live 95/0/2; visual benchmark 15/16 (2B, 4B, chain).

### Open
`docs/KNOWN_ISSUES.md` JARVIS-V13-1…14. MANUAL TEST REQUIRED: README 824–986.

## 2026-10-14 — V0.13.1: Project Operator closure & stability

### Goal
Close V0.13: root-cause JARVIS-V13-7 without masking it, add Input System operations and real animation / audio experiments, show the Scene Profile on the Project card, audit the guards, run a bounded soak. Not V0.14.

### Done
* **V13-7**: instrumented the executor (polls, timing, hashes, world state, raw AX error class). The failing runs showed the fixture HAD counted the click while `AXPress` returned an "unsupported" class error: the executor trusted the return code. Fix (DEC-206): one read-only cross-check of the expected state, verified or failed, never repeated. The environmental trigger stopped reproducing and was not identified. Two further test-side flaws found by repetition: the safe restart cycle's `.stateChanged` check (now element-exists, child output captured on failure) and a cold VLM load aging the screenshot past 6 s (model now loaded before the picture; the 6 s rule is unchanged).
* **Input System**: 7 typed ops + optional bridge assembly (`defineConstraints`/`versionDefines`), owned-binding ledger, duplicate / conflict refusal, read-back by reload. A C# compile error in the bridge made the owned editor exit; `prepare` now fails fast with the output tail.
* **Experiments**: `animationPlayback` / `audioPlayback` through the same engine (`prepareFixture`, `playAndObserve`), generated clip / controller / tone, refused under pressure, cleanup on success / failure / cancel / hard-kill.
* **Scene Profile** on the Project card (live from a connected editor or labelled stale), memory-only never starts work, rent / cart / donate words blocked, `GUARD_MATRIX.md` (5 gaps closed), `StabilitySoak`.

### Evidence
See `PROJECT_STATE.md` status. Before: V13-7 failed 5 of 9 V0.13 runs. After (final code): 10/10 full, 40/40 focused, 10/10 restart cycles; operator live 131/0/0 on Unity 6000.5.1f1.

### Not done / next
Wait for the manual test (README 987–999). V0.14 is not started.


## 2026-10-14 — V0.14 Adaptive Learning, Controlled Self-Improvement & MCP/Skill Registry

### Goal
Bounded adaptive layer on V0.13.1: learning from recorded work, a closed rule vocabulary, Skills, capability gaps, controlled self-improvement, and an MCP/Skill registry with a sandboxed benchmark — learning is never authority (DEC-215…233).

### Done
* **Adaptive** (`Sources/Jarvis/Adaptive/`): signals with episodes, `PatternDetector` thresholds, ONE admission door, `RuleEngine`, `LearningService` lifecycle, `AdaptiveDecisionService` (HUD-only, scope-hash bound), `SelfImprovementService`, EN/TR `AdaptiveAssistant`, view models.
* **Capabilities** (`Sources/Jarvis/Capabilities/`): status machine, registry, JSON-RPC client over `ManagedProcess`, Seatbelt sandbox, inspector, benchmark, in-sandbox Rust staging, Skill registry. Discovery on the V0.9 stack.
* **UI**: Learning and Capabilities screens, Settings section, Compact line (392×448). Schema v13 / v14.
* **Guards**: `scripts/guards_v14.sh` (18 guards; each shown to fail on an injected violation). `GUARD_MATRIX.md` rows 36–53.
* **Live tests**: `--adaptive-live-test` (learning, gap, rules, workflow, selfimprove, rejection, overlearning, security, soak, ui), `--mcp-live-test` (research, sandbox, registry, security, voice, ui, candidate) with a fixture MCP server (normal / adversarial / shell / env / crash / slow / flaky / hang) and real Accessibility clicks from a child process (DEC-231).

### Found and fixed on the way
* The restart budget counted clean idle stops (found by the soak) → failures only (DEC-229).
* Approval hash used unstable JSON key order → sorted keys.
* A throw-away second `MCPRegistry` in the live test took the decision hooks (weak self) and made later installs "tampered" → `registerDecisionDomains()` re-registered by the test (test-only effect; the app has one registry).
* The MCP `ui` section needs an empty registry → explicit section like `candidate`.
* Adaptive/MCP live tests now reset their own isolated data directory (a second run found a 24-run workflow and failed for the wrong reason).
* Smoke: paste/composer checks were timing-sensitive (also on the V0.13.1 baseline) → `press` waits for the key window and settles longer; composer height waits for the layout. 7/7 consecutive passes afterwards.
* A source-scan unit test forbids shell literals; the explicit MCP live test runs its isolation probes via `/bin/sh` inside the sandbox → narrow exemption for that one file.

### Evidence
See `PROJECT_STATE.md` status. Real research (2026-10-14) covered 3D/Blender, design, audio, animation and Unity; one real open-source candidate (cochlea-mcp) built in the sandbox and benchmarked; final code `--mcp-section candidate` 14/0/0 (an earlier rerun hit the unauthenticated GitHub limit 0/60 and JARVIS reported licence/activity as unknown, as designed). Final `scripts/verify.sh` result is in PROJECT_STATE.md.

### Not done / next
Wait for the manual test (README 1000–1152). V0.15 is not started.

## 2026-10-14 — V0.15 Daily JARVIS, installable app, readiness and follow-ups

### Goal
Make the machinery usable every day without Terminal — presentation, bounded follow-ups, readiness + typed setup, packaging and lifecycle — with no new orchestrator and no new authority (DEC-234…245). Last feature milestone.

### Done
* **Daily/**: `ResponsePolicy` (depth detector, shortening that keeps negative facts, address policy, presenter, concise acknowledgements), `WorkingContext` (bounded ephemeral referents, follow-up parser/resolver, project switch). Wired into `ConversationService` after the approval guard.
* **Readiness/**: read-only `ReadinessService` + probes, `ReadinessAssistant` (EN/TR), `SetupRunner` (closed action list → packaged pinned scripts), `ReadinessActions`, `SystemIntegration` (SMAppService, notifications, single instance), `Diagnostics`; System & Readiness card, first-run walk-through, Settings (Startup, Daily JARVIS, About), menu additions.
* **Packaging**: `scripts/package-app.sh`, `install-app.sh`, `verify-installed.sh`, generated temporary icon, entitlements file, installed to `/Applications/JARVIS.app`.
* **Guards**: `scripts/guards_v15.sh` (14) + three narrow amendments; `DailyStructuralTests`; live tests `--daily-jarvis-live-test`, `--packaging-live-test`, `--setup-live-test`.

### Found and fixed on the way
* The follow-up parser first matched verbs in the middle of longer sentences (“Remember that we use the free model…”, “Modify my project and test it”) → verb must open or close a ≤ 7-word sentence.
* “go to system” was taken as a project switch (async reply broke the V0.2 ordering smoke check) → deterministic commands win; “back to <unknown>” is an ordinary sentence unless it names a project.
* Memory answers lost their citations when shortened → evidence-bearing answers are shown whole.
* Setup output: the process stream yields complete lines (they were concatenated); progress bars redraw with carriage returns.
* macOS 26 hosts status items in Control Center: the menu-bar presence is detected by the window named after the bundle id.
* `SMAppService` answers “not found” for a never-registered app; registering works (reversible round trip tested).
* Several guards were amended narrowly (notification API, System Settings URLs, SMAppService), each in one file.
* Pre-existing flaky ⌘V smoke checks were already hardened in V0.14; none flaked in V0.15 runs.

### Evidence
See `PROJECT_STATE.md` status.

### Not done / next
Wait for the manual test (README 1153–1234). V1.0 is not started.

## 2026-10-14 — V1.0 stabilisation fix 1 (installed-app findings)

### Root causes
* **Bug 1**: `ReadinessIntentParser` only accepted “ready / installed / var mı” forms; “erişebiliyorsun / kullanabiliyorsun” fell through `ConversationService` to the conversation model, which answered from its own identity (“I cannot access other AI models”). Only the strict forms were deterministic.
* **Bug 2**: `ResponsePresenter.lastFull` was a single global slot written only when a deterministic answer was shaped; a model's or a command's answer never replaced it, so “detaylı anlat” re-rendered the last deterministic answer.
* **Bug 3**: not an input-path bug. `Preferences.voiceEnabled` defaults to false and the installed app had no `prefs.voice.*` keys: `AppDelegate` attached the PTT handler only when Voice was on, so the right ⌥ hold was sampled and dropped; Readiness listed every voice dependency READY and no row said Voice was OFF.

### Fixes
* Introspection grammar + `providers / canUse / tools / capabilities` replies from the records (no model, nothing started; `ReadinessItem.installed`, `OpenCodeService.executableFoundOnDisk`); Turkish detection for diacritic-free capability words.
* Presenter keyed by displayed text; `rerender(previous:)` reads the immediately preceding JARVIS message; no stale answer, no invented detail.
* PTT handler attached whenever PTT is on; hint when Voice is off; Readiness “Voice input” row + Turn On Voice; “Microphone permission” wording; bounded PTT diagnostics (counters; activity log of state transitions).

### Evidence
Synthetic right ⌥ HID events (`CGEvent` flagsChanged, keyCode 61) change the session flag state exactly like a key (raw 0x40) and reach the installed app: Voice OFF → hint logged; Voice ON (non-persistent `-prefs.voice.enabled '<true/>'` override) → “hold reached — voice input requested”, voice state “requesting permission”, “released”. After reinstalling, Microphone / Accessibility read PERMISSION NEEDED (ad-hoc signature, JARVIS-V15-11).
