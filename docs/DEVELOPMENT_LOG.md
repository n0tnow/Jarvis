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

