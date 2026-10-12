# JARVIS Project State

> New agent? Read this file first, then `docs/CURRENT_TASK.md`. See `AGENTS.md` for the bootstrap order.

## Current Version

V0.6 — Unity Project Agent & Editor Bridge (Unity as a controlled execution environment inside the V0.4 engine); builds on V0.5 — proactive reasoning, opportunity engine & approval policy (a decision layer above the V0.4 task engine) and on V0.4 — autonomous task engine (user-initiated goals; on top of V0.3.2 observatory, V0.3.1 intelligence infrastructure, V0.3 Claude Code / Codex and V0.2.1). App version string still `0.1.1`. V0.1–V0.2.1 were manually tested by the user; **V0.3, V0.3.1, V0.3.2 and V0.4 are not**.

## Current Milestone

V0.6: Unity Project Agent & Editor Bridge (typed, capability-controlled, observable Unity operations inside the V0.4 engine). NOT V0.7 (voice / web / assets), no real-game mutation, no visual validation.

## Status

**V0.6 — READY FOR MANUAL TEST** (V0.5 and earlier: READY FOR MANUAL TEST as before)
(Automated + REAL verification passed on this Mac: OpenCode 2.0.26 FREE end to end on an isolated fixture. Not user-verified. Do NOT mark COMPLETE, do NOT tag, do NOT start V0.5.)

## Current Objective

User manual test of `build/Jarvis.app` (README items 126–153 for V0.6 — on the disposable fixture first, 92–125 for V0.5, 67–91 for V0.4, 40–66 for V0.3.2, 33–39 for V0.3.1, 26–32 for V0.3). Use a throw-away project for the V0.4 items. Optional local-model setup: `scripts/setup_local_ai.sh`.

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

## V0.6 additions (IMPLEMENTED · AUTOMATED TESTED · REAL TESTED · UI/windowed-editor/real-game MANUAL TEST REQUIRED)

Reference: `docs/UNITY_PROJECT_AGENT.md`, DEC-047…056. Code: `Sources/Jarvis/Unity/`, `Tasks/TaskEngine+Unity.swift`, `Tasks/ReviewAuthority.swift`, `UnityBridge/` (C# Editor package + fixture), schema v5.
- **Bridge:** JARVIS-owned Editor package, embedded, installed only after approval; local file spool (no socket/network/MCP/permission); event-driven (no polling when idle). No third-party Unity MCP was installed.
- **Typed surface only:** closed `UnityOperation` enum; no C#/menu/shell/AppleScript/package/Asset Store/upgrade operation; the bridge rejects unknown operations itself; new Unity capabilities (deletion is approval-only, not a capability).
- **Engine:** Unity step types inside V0.4 (plan validation, capability gate, bounded repair with Unity's real error text, mutation lock, cancellation cleanup, checkpoint/report/observatory); the provider only proposes typed actions; scripts stay on the V0.4 file path; scenes via Editor APIs, never YAML.
- **Safety:** identity (never name-only), idempotent edits, scoped saves, user-dirty scenes + Git-dirty scene files need approval, Play Mode blocks persistent mutation (policy + bridge), version mismatch never upgrades silently, sanitization at choke points, Console baseline/delta, owned-editor-only shutdown.
- **Validation authority:** compile/tests/state/Console facts outrank reviews (DEC-049/050, generic `ReviewAuthority`); reports never claim visual validation.
- **UI:** project line (truthful state, CLOSE EDITOR), task Unity section, Compact phrase "Unity · Compiling…" (392×448 unchanged).

## V0.5 additions (IMPLEMENTED · AUTOMATED TESTED · REAL TESTED · UI/real-use MANUAL TEST REQUIRED)

Reference: `docs/PROACTIVE_REASONING.md`, DEC-041…046. Code: `Sources/Jarvis/Proactive/`, `Tasks/TaskScope.swift`, `Persistence/OpportunityRepository.swift` (schema v4), `UI/FullHUD/Tasks/ProposalsView.swift`.
- **Decision layer, not an engine:** finished V0.4 tasks (and optional reviewer suggestions) → findings from RECORDED facts → dedupe/cooldown/coalesce → deterministic assessment → pure `OpportunityPolicy` (critical > design/product > scope > low-risk maintenance) → ignore / record / propose / require approval / auto action. Allowed work becomes a NORMAL V0.4 task (`origin`, `originTaskID`, `originOpportunityID`, `autonomyDepth`, `TaskScope`, deterministic id).
- **Modes:** Observe Only / **Ask Before Acting (default)** / Low-Risk Autonomous (Settings → Autonomy). Budget: 1 auto task per user task, depth 1, auto tasks never create auto tasks. Confidence is evidence, not authority; model output can only add caution.
- **Approval:** only HUD buttons through `ProposalService`; bound to an `action_hash`; scope-bound (`scopeExceeded` stops the task); critical / unsupported actions (push, purchase, credentials, deletion…) can never run, approval does not create capabilities; stale proposals become obsolete.
- **Event-driven only:** no polling, no scanning, no idle provider calls; ≤1 budgeted assessor call per origin task (never the local model).
- **UI:** Suggestions in Tasks (Approve / Deny / Dismiss equal weight, recorded findings), Settings → Autonomy, Dashboard line, Compact "N SUGGESTIONS" tag (392×448 unchanged).

## V0.4 additions (IMPLEMENTED · AUTOMATED TESTED · REAL TESTED · UI/real-use MANUAL TEST REQUIRED)

Reference: `docs/AUTONOMOUS_TASK_ENGINE.md`, DEC-033…040. Code: `Sources/Jarvis/Tasks/`, `Persistence/TaskRepository.swift` (schema v3), `UI/FullHUD/Tasks/`.
- **Goal intake:** development/analysis goals become durable tasks (persisted BEFORE work); conversation, commands, knowledge questions and long text are untouched; needs a chosen project folder.
- **Plan:** one JSON object, `PlanValidator` (≤12 steps, DAG, known types/validations, capabilities per task kind, prohibited operations, recursive agents, paid/local, explicit destructive targets); malformed → one format re-ask → one other provider; policy violation → `securityBlocked`.
- **Execution:** event-driven scheduler; analysis/coding/review through `AgentRunManager` (routing/limits/sanitization unchanged, task prompts are development work ⇒ never local), build/test via approved no-shell profiles, edits as SEARCH/REPLACE blocks applied by `ProjectTools` (capability · workspace guard · dirty-file approval · write lease · atomic apply + rollback · hash check). Deterministic validation; bounded repair (1, same engine) + escalation (1, other engine, Auto only), ≤3 attempts per code step.
- **Safety:** `WorkspaceGuard`, never-grantable capabilities (network/browser/gitCommit/gitPush/purchase), read-only `GitTool`, destructive/user-dirty approvals (durable), cancellation through the existing paths, checkpoints + reports, INTERRUPTED reconciliation at launch, explicit resume (code step: verify disk → keep/redo/fail), stale leases reconciled.
- **UI:** Tasks screen (project card, needs-attention/active/recent, plan + evidence), Compact card with real validated progress (392×448 unchanged), approval card, Agents runs grouped `TASK · title`, Stop/Resume/Approve via the engine (no Pause).

## V0.3.2 additions (IMPLEMENTED · AUTOMATED TESTED · REAL TESTED · UI MANUAL TEST REQUIRED)

- **Security boundary (DEC-029):** every provider/worker output is sanitized ONCE (`Observability/OutputSanitizer.swift`, fail closed, split-secret safe) before SwiftUI state, console buffers, activity events, SQLite, artifacts; `SafeProvider` wraps every engine; `Redactor` delegates; no credential/integration API use; verify.sh confines the write paths.
- **Observatory (DEC-030…032, `docs/AGENT_OBSERVABILITY.md`):** `ExecutionHub` (bounded consoles, coalesced revisions, batched SQLite `agent_events`, sanitized output artifact), `AgentObservatory` read model, truthful `ProviderStateResolver` (READY ≠ RUNNING; downloaded ≠ loaded; STARTING while Qwen loads), `ProgressCalculator` (percentage only from declared steps; otherwise indeterminate; `progressSource` persisted), `RunPhase`, INTERRUPTED reconciliation at launch, Stop through the existing cancellation only, no Pause, console read-only (no integration supports same-session input), developer simulation `--demo-agents`/`--demo-stress` (never persisted, labelled).
- **UI:** Full HUD → AGENTS (provider cards, active runs + STOP, recent, Live/History/Timeline, run detail with `NSTextView` console, native ⌘C); Compact: 44 pt summary strip only while something runs (392×448 unchanged); router aliases (`show agents`, `ajanları aç`).

## V0.3.1 additions (IMPLEMENTED · REAL TESTED · MOCK TESTED · UI/physical MANUAL TEST REQUIRED)

- **Persistence (DEC-023, `docs/PERSISTENCE.md`):** system SQLite (WAL, serialised writer, migrations, corrupt-file move-aside) in `~/Library/Application Support/JARVIS/jarvis.sqlite`; 12 operational tables + `provider_health`; file-backed artifacts (hash-verified); `Redactor`; audit trail per run (engine, model, **machine-readable selection reason**, tools incl. refused attempts, validation, retries, escalation, prompt hash/length, redacted excerpt — none for sensitive tasks). Never in the repo (git-ignored; verify.sh checks).
- **Local Qwen3.5-4B (DEC-024):** isolated venv (605 MB, 57 pinned packages, no model download), JSON-lines worker, on-demand start, ping/pong health, cancel, idle/pressure/shutdown unload; `LocalModelPolicy` forbids coding/testing/repo/review/debug/architecture/Unity/security/project code/long context — in Auto, in explicit Local (refused, no fallback) and inside the provider itself.
- **OpenCode free pool (DEC-022/025, `docs/OPENCODE_RESEARCH.md`):** free = every cost tier 0 + active + enabled + keyless provider `opencode` (never by name; 24 h freshness; sticky block when the API reports a model removed). Both CLI generations supported (classic `models --verbose`/`run --pure`; v2 `api model.list`/`run --standalone`), chosen from `--help`. Tools rejected (v2: Code Mode escape found and closed). Benchmark suite v1 (13 cases, real validators, Swift only type-checked) gates Auto. Catalog is read lazily (reading may start OpenCode's ≈290 MB background service).
- **Routing (DEC-026, `docs/MODEL_ROUTING.md`):** pure `ModelRouter`; Auto = Local → OpenCode free → Claude/Codex (lightweight) · OpenCode free → Claude/Codex (development/knowledge) · Claude/Codex (heavy/sensitive paths); explicit modes never fall back; zero-retention preferred; sensitive never to free cloud, project code only to zero-retention; bounded escalation (1) with persisted reasons.
- **Supervisor/resources/agents (DEC-027/028):** persistent cooldown/backoff, bounded local restart, memory-pressure unload; limits for 16 GB (1 local job, 2 free-cloud, 1 heavy, 3 total, depth 1); `AgentRunManager` (race-free slots, parent/child, cancel, bounded repair + escalation, `ContextRetrieval`) — no UI entry point, no tools, no file writes.
- **UI:** Settings (5 modes, Routing, OpenCode free list with data-handling labels + Benchmark buttons, Local model status/metrics/Test/Unload), System panel (Local/OpenCode/Memory rows), Agents panel shows real active runs, provider badge (AUTO · n READY / engine). Compact stays 392×448; Compact XOR Full unchanged.

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

Nothing. Waiting for user manual verification of V0.3 / V0.3.1 / V0.3.2.

## Pending (outside V0.1)

Everything in `docs/ROADMAP.md` from V0.2 onward — PLANNED, not started.

## Known Issues

See `docs/KNOWN_ISSUES.md`. Headline: VoiceOver labels on custom buttons — MANUAL VERIFICATION REQUIRED; Retina rendering not verified (dev machine screen was 1×).

## Tested

**V0.6 (2026-10-12):** unit tests incl. ≈105 new V0.6 tests — foundation (versions, discovery, detection, protocol, parsing, plan validation), policy, spool transport against a scripted file-protocol editor, the whole engine against a **simulated editor (MOCK TESTED)** (scenarios A–N, install/upgrade approvals, lock, cancellation, restart, security, report), review authority (generic), V0.5 interplay, structural guards; `verify.sh` extended with V0.6 guards.
**REAL TESTED — `Jarvis --unity-live-test` (59 PASS / 0 FAIL, Unity 6000.5.1f1, headless editor started by JARVIS, disposable fixture in a temp folder, own data dir):** discovery, detection, bridge install by approval, connect, inspect, component/property edits + saves (verified in editor AND scene file), idempotent retries, compile + domain reload + reconnect, EditMode + PlayMode tests, Play Mode, Console delta + sanitization, dirty-scene approval (deny/approve), Play Mode mutation block (policy and bridge), ambiguity, path escape + unknown operation rejection, destructive approval (deny/approve/not-requested), V0.5 design proposal, cancellation, relaunch recovery, **OpenCode FREE fixing a real compile error and a real failing test**, no secret in the data directory, graceful owned-editor shutdown. Planner/Unity agent were scripted in the scene scenarios (the editor was under test); provider scenarios used the real router.
**NOT done:** visual validation, a windowed editor, any real game (never touched), Claude/Codex as Unity coders (no escalation was needed), multi-editor orchestration, real SIGKILL crash.
**MANUAL TEST REQUIRED:** README 126–153.

**V0.5 (2026-10-12) — `scripts/verify.sh` → VERIFY PASSED:** 536 unit tests (75 suites; +54 for policy, normaliser/dedup, assessor, scope, end-to-end Ask/Observe/Low-Risk flows on isolated temp Git fixtures, self-approval/tamper/scope-expansion, restart/idempotency, obsolete, budget, sanitization, structural guards), V0.5 policy greps, smoke 99 PASS / 0 FAIL / 2 SKIP, idle 0.02 CPU-s in 8 s / 71 MB RSS.
**REAL TESTED — `Jarvis --proactive-live-test` (final run 26 PASS / 0 FAIL, OpenCode FREE `opencode/space-bunny-free`, isolated temp Git fixtures, own data dir):** user task → proposal from recorded facts (0 provider calls) → real HUD-path approval → normal V0.4 task (planned, validated, test-only scope) ; Low-Risk Autonomous: one auto task, no second auto task; real denial + anti-nagging; real relaunch (one task after approval, second approval a no-op); one budgeted model assessment with recorded reason. Honest variance: earlier runs showed (a) real reviewer suggestions competing with the recorded-fact finding and (b) the V0.4 AI reviewer rejecting an otherwise in-scope, passing test — both are model behaviour; the test now selects the recorded-fact finding and treats a reviewer-only rejection as "stayed in scope" (reported as INFO).
**MANUAL TEST REQUIRED:** README 92–125.

**V0.4 (2026-10-11) — `scripts/verify.sh` → VERIFY PASSED:** 482 unit tests (69 suites; +105: state machines, plan validation, workspace guard/symlinks, tools/edits/rollback, command policy, leases, engine flows on isolated Git fixtures — success, repair, escalation, bounded failure, malformed/policy-blocked plans, read-only tasks, approvals (approve/deny/restart), dirty worktree, cancellation (incl. a real killed process tree), crash/interrupt/resume, stale leases, lease conflicts, secrets, observability, progress across states, scheduling, source-level policy scans, intake/conversation/HUD bridge) · smoke 94 PASS / 0 FAIL / 2 SKIP (5 new V0.4 checks: real task projected with 2/5 = 40 %, Compact 392×448, `show tasks` exclusivity, no Pause, Stop → CANCELLED) · new guards (no destructive Git, GitTool read-only, build/test allowlist without shell/env/downloader/Git, writes only through ProjectTools, no forbidden capability grants, UI never writes the task DB, no tracked task output) · idle 0.02 s CPU / 8 s, RSS 71 MB.
**REAL TESTED — `Jarvis --task-live-test` (29 PASS / 0 FAIL, OpenCode 2.0.26, isolated temp Git fixtures, own data dir):** Auto benchmarked `space-bunny-free` 13/13 and routed everything to it (zero-retention, verified free; never the local model): goal → durable task (before work) → 6-step validated plan (analysis → test(reproduce) → analysis → codeChange → test → review) → real file change (`return a - b` → `a + b`, hashes recorded, only calc.py) → real unit tests (reproduction exit 1, final exit 0 · 1 test, 1 passed) → real review → report; task ran in 16–18 s, working-tree change only (no commit/push), Observatory showed 7 runs with consoles, SQLite had steps/attempts/checkpoint/report · **cancel:** a real provider run stopped in 0.2 s, CANCELLED, 0 orphans, no leases, nothing changed · **interrupt/resume:** quit mid-task → INTERRUPTED + checkpoint, relaunch reconciliation leaves it interrupted, explicit resume completed it and did NOT redo validated steps · **approval:** the real planner planned a delete step → WAITING, nothing deleted, DENY → failed `approvalDenied`, file intact · no credential-looking text in SQLite/artifacts · no managed process left behind.
**Performance (release, M5, % of one core, same-host A/B against a V0.3.2 build):** closed idle 0.1 % (V0.3.2: 0.2) / 73 MB · Compact idle 0.4 % (0.4) · Full Dashboard 7.1 % (7.1) · Full Tasks 1.4 % · Full Agents 1.4 % (1.3) → **no regression**. Active tasks: 2 tasks parked on blocked agents — HUD closed 2.0 % (the pre-existing menu-bar Working animation alone costs 1.5 %: V0.3.2 with the demo task, same number; the rest is the demo runner's 20 Hz wait loop), Compact 2.1 %, Full Tasks 4.7 %, Full Agents 5.3 %; 2 task agents + 2 simulated streaming agents (4 concurrent): Full Agents 14.3 % (V0.3.2 with 2 simulated: 8.1 %), HUD closed 2.2 % (V0.3.2: 0.4 % because the menu-bar icon was idle). Real run: JARVIS 0.0 CPU-seconds over 18 s (peak RSS 75 MB), provider/test children ≈0.7 % CPU, peak 516 MB RSS (OpenCode), all gone afterwards. The engine never polls (scheduler wakes on step completion; one one-shot deadline per build/test command).
**MOCK TESTED:** repair/escalation/exclusion/pinning/explicit-mode refusal, capacity waits, malformed/policy plans, destructive approvals, dirty-file approvals, lease waiting/stale, crash/interrupt/resume paths (applied/reverted/diverged), cancel while waiting, source-level policy scans (scripted agents, real processes for tools, real SQLite, real Git).
**NOT real-tested:** Claude Code / Codex as task coders (no escalation was needed; subscription quota), large/multi-file/Unity projects, weak free models, macOS folder-permission prompts, VoiceOver on the Tasks screen, Retina.
**MANUAL TEST REQUIRED:** README 67–91.

**Earlier milestones**

**V0.3.2 (2026-10-11) — `scripts/verify.sh` → VERIFY PASSED:** 377 unit tests (56 suites; sanitizer incl. split/failing engine, progress, provider state, phases, console ordering/bounds/no second process/malformed events/cancellation, history through the real repository, stale-run recovery, UI helpers) · smoke 89 PASS / 0 FAIL / 2 SKIP (AX audit, unchanged; now also Agents section/Compact strip) · new policy guards (no pty/shell; console enters the hub only via SafeProvider; events/artifacts written only by hub/repository; no raw `agent_events` INSERT; coordinator wraps SafeProvider; no tracked logs) · idle 0.01 s CPU/8 s, RSS 70 MB.
**REAL TESTED — `Jarvis --intelligence-live-test` (35 PASS / 0 FAIL, OpenCode 1.19.0, local Qwen):** Qwen card UNLOADED → STARTING → RUNNING → LOADED·IDLE; real run phases starting→running→completed; the console shows the same execution's sanitized output and completed event; timeline/history list the run; unknown progress shows no percentage; OpenCode card RUNNING with the real free model; **Stop** via the hub killed the OpenCode tree in 0.13 s with CANCELLED in hub/SQLite/console and no cooldown; a synthetic fake key echoed by the real Qwen model was masked everywhere (UI state, console, activity, SQLite, artifacts); real-file reconciliation produced INTERRUPTED with a persisted reason. Not run with real Claude/Codex (observed via the same SafeProvider path in mock tests; V0.3 live test unchanged).
**Performance (release, M5, % of one core, same-host A/B against a V0.3.1 build):** closed idle 0.1 % / 73 MB · Compact idle 0.3 % / 112 MB (V0.3.1: 0.3 / 111) · Compact + 2 simulated runs 1.0 % · Full Dashboard idle 7.4 % / 137 MB (V0.3.1 on the same host: 7.5 % / 136 MB — the 3.4 % quoted for V0.3.1 was a quieter host) · Full System 1.8 % · Full Agents (no runs) 1.4 % / 127 MB · Full Agents + 2 simulated runs, console visible 10.0 % / 142 MB · Full Dashboard + 2 runs (console not mounted) 7.8 %. Synthetic stress 400 lines/s (≈25× a real stream): closed 13.9 %, Compact 11.2 %, Full console hidden 20.3 %, Full console visible 28.6 %; RSS flat over a 90 s stream (75→76 MB closed, 137→139 MB Full) → buffers are bounded. These are JARVIS-process numbers; provider child processes are unchanged by V0.3.2 (V0.3.1: OpenCode ≈0.5–1.0 % / 500–650 MB, Qwen worker 1.2–2.2 GB resident, ≈1 % CPU generating) and are not run by the stress/simulation modes.
**VISUALLY VERIFIED** (captures): Agents section live/detail/console, Compact summary strip (392×448 in all Compact captures).
**MANUAL TEST REQUIRED:** README 40–66 (VoiceOver, real clicks/STOP/selection/⌘C, long sessions, Retina, quit-while-running).

(Earlier milestones)

**V0.3.1 (2026-10-11) — `scripts/verify.sh` → VERIFY PASSED:** 327 unit tests (47 suites; serial; fake CLIs/worker with real child processes; temp SQLite) · smoke 85 PASS / 0 FAIL / 2 SKIP (AX audit, unchanged) · extended policy rules (no network clients/URL literals, no credential/integration API names, no `--auto`/`--attach`/service flags, Process only in ManagedProcess, no tracked DB/model/large file, no secrets, worker offline) · idle CPU 0.02 s/8 s.
**REAL TESTED — `Jarvis --intelligence-live-test --benchmark-models` (28/28 PASS, OpenCode 1.19.0; earlier runs 27/27 on 1.18.34 and 1.19.0):** SQLite written by the app, closed, reopened (12 runs with reasons, 28 activity events, 42 registry rows, schema v1) · discovery (Claude/Codex/OpenCode/Local READY; **11 verified-free models**, 31 rejected: 30 `price > 0`, `opencode-go` zero-price ones "credentialed plan") · **local Qwen**: answer `JARVIS_LOCAL_OK` through ConversationService→Coordinator→provider→worker, on-demand start, ping/pong, STOP in 0.03 s with the worker still usable, idle unload after 3 s with the process gone, explicit Local refuses a coding question · **OpenCode FREE** `longcat-2.5-preview-free` (zero-retention) answered `JARVIS_OPENCODE_OK` in 4.7 s through the stack, audited (engine, model, freeVerified, reason) · v2 tool canaries (shell/write/outside read/fetch/Code Mode/sub-agent): nothing executed · STOP kills both OpenCode processes in <0.2 s, run `cancelled`, no cooldown · **Auto routing**: summary → Local; coding question → **OpenCode · space-bunny-free** (benchmarked 13/13, zero-retention, verified free) with reason `{tier: development-free-first, codingBenchmarkPassed: true, freeVerified: true, localModelIneligible: true, …}`; architecture → Claude Code (`heavy-premium-only`); deterministic commands/worker requests: no engine, no run · app-termination path kills the local worker · no managed process left.
**Benchmarks (real, suite v1, passed/13):** big-pickle 13 · ling-3.1-flash 13 · longcat-2.5-preview 13 · nemotron-3-ultra 13 · space-bunny 13 · mimo-v2.6-flash 12 · muse-spark-1.3-contributor 12 · step-5-preview 12 · nemotron-3.5-lightning 10 (partial) · exo-free 0 (API 410 deprecated while listed active → blocked, benchmark aborted after 1 request) · ling-3.0-flash-fin 0 (upstream "Model is unavailable", aborted after 3 failures).
**Performance (release, M5, % of one core; baseline = V0.3 in brackets):** closed idle 0.1 % (0.2) · Compact working 1.0 % (1.2) · Full idle 3.4 % (4.5) · Full thinking 16.1 % (17) · RSS 67 MB idle / 150 MB Full HUD (65/150) · idle 8 s window 0.02 s CPU. SQLite/supervisor/resource-manager idle cost is within noise (no polling anywhere; memory pressure is an event source). Local model: load 1.6–2.4 s, first token 0.37–0.51 s, 58–60 tok/s, peak 3.4 GB unified, worker resident 1.2–2.2 GB, loaded-idle 0 % CPU, generation worker CPU ≈1 % (GPU-bound), unloaded: JARVIS RSS 59–65 MB. OpenCode run: JARVIS 0 %, opencode client+private server 0.5–1.0 % CPU, 500–650 MB RSS during the run, 4–5 s for a trivial prompt; its shared background service (not started by JARVIS runs) ≈290 MB resident. Real streaming/V0.3 numbers unchanged.
**MANUAL TEST REQUIRED:** Settings UI feel (Benchmark buttons, Test local model), real typing/STOP in the HUD, quitting while the local model is loaded, behaviour with OpenCode upgrades, multi-minute use, Retina/VoiceOver (unchanged).

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

See `docs/DECISIONS.md` (DEC-001…DEC-056). Key ones:
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

**Wait for the user's manual V0.3 … V0.6 test** (V0.6: README 126–153, on the fixture first) (`README.md` items 26–32, 33–39, 40–66, 67–91, 92–125 and 126–153). Do not start V0.7 without approval.

## Git

`main` only; `origin` = https://github.com/n0tnow/Jarvis.git; V0.3 commits start at `58c6948`; V0.3.1 at `f2665a5`; V0.3.2 at `e445f3f`; V0.4 at `41fd038`; V0.5 commits follow `7f6b3d5` (… `962c432`); V0.6 commits follow `962c432`; **no tag**; no AI co-author trailers (user rule). Policy: `AGENTS.md` → Git Workflow, DEC-011.

## Last Updated

2026-10-12 — V0.6 implemented, AUTOMATED TESTED, REAL TESTED (real headless Unity editor + OpenCode FREE on a disposable fixture), verified. READY FOR MANUAL TEST.
