# Production truth — no demo or mock state in the installed app (V1.0 stabilisation fix 2)

**Rule (DEC-247):** the installed JARVIS shows only real data. Demo, simulated, fixture and preview machinery exists for the developer (`--smoke-test`, `--capture`, `--dev-demo`, unit tests, live tests) and is
**unreachable from a normal launch**. Where there is nothing to show, the UI says so honestly ("No active tasks.", "No agents are running.", "No recent activity.").

## Root cause found in the real app
`AppContext.init(seedDemoData:)` defaulted to **true**. A normal launch therefore seeded `DemoScenario` into the store: a fake running task with a fake percentage, a fake project, fake agents, fake tools and fake
activity lines. The approval card also labelled every approval "DEMO". The ObservatoryDemo simulator was constructed too. All of that was visible in the Dashboard, the Compact HUD and the menu bar.

## Fix
* `seedDemoData` now defaults to **false**; `AppDelegate` passes `LaunchOptions.isDemoEnvironment` (true only for `--smoke-test`, `--capture`, `--state`, `--demo-agents`, `--demo-stress`, `--demo-tasks`, `--demo-proposals`, `--dev-demo`).
* `AppContext.demoMode` records it; `simulatorControlsVisible = demoMode && showDeveloperControls`. "Show Developer Controls" in Settings now only shows diagnostics — never the simulator.
* `ProjectPanel` shows the **real** selected project folder (and Unity state if a connection exists) or "No project selected".
* `AgentsPanel` has no demo fallback; `ToolsPanel` (demo list) renders only in demo mode; the Report destination is an honest "NO REPORT HERE" instead of "PLANNED · V0.8".
* A real approval is never labelled demo/simulated: `ApprovalRequest.simulated` is true only for the developer simulator's request.

## Audit table
| Source | Production reachable? | Purpose | Action |
|---|---|---|---|
| `AppContext(seedDemoData:)` default true → `DemoScenario.seed` | **Yes (was)** | V0.1 visual development data | **REMOVE** from production: opt-in via `isDemoEnvironment` |
| `Services/Demo/DemoScenario.swift`, `DemoData.swift` | No | state/visual demo data | DEVELOPER ONLY |
| `JarvisStore.tasks / project / agents / tools` display slots | Empty unless demo | display slots | REAL DATA (empty in production) |
| `ProjectPanel` ← `store.project` + "DEMO" tag | **Yes (was)** | Dashboard Project card | **REMOVE**; now REAL DATA (preferences.projectRoot, Unity connection) |
| `AgentsPanel` demo-slot fallback "DEMO · NOT CONNECTED" | **Yes (was)** | Dashboard Agents card | **REMOVE**; "No agents are running." |
| `ToolsPanel` (`store.tools`) | Demo only | Dashboard Tools card | DEVELOPER ONLY (`demoMode`) |
| `DevStateStrip` in Full HUD bottom bar and Compact HUD | **Yes (was, with Developer Controls)** | state simulator, "RESET DEMO TASK" | DEVELOPER ONLY (`simulatorControlsVisible`) |
| `TasksSectionView.demoTasks` ("DEMO TASKS · NOT REAL WORK") | **Yes (was, with Developer Controls)** | V0.1 demo task controls | DEVELOPER ONLY (`simulatorControlsVisible`) |
| `AgentsSectionView.simulateMenu` + `ObservatoryDemo` | **Yes (was)** | simulated agent runs | DEVELOPER ONLY (`demoMode`; `observatory.demo` is nil in production) |
| `CenterStage` approval card "DEMO" label | **Yes (was)** | label | **REMOVE**; "SIMULATED" only when `request.simulated` |
| `PlaceholderSectionView` "PLANNED · V0.8" (Report) | **Yes (was)** | placeholder | **REMOVE**; honest "NO REPORT HERE" |
| `ActivityPanel` tag "IN-MEMORY" | Yes | label | changed to "THIS SESSION" (the list is the current session's activity; history is on the Agents/Tasks screens) |
| `DevCapture`, `SmokeTest` (`DemoScenario`, `TaskDemo`, `ResearchDemo`, `AdaptiveDemo`, `ObservatoryDemo`) | No (flags) | render/verify JARVIS' own windows | PREVIEW ONLY / TEST ONLY |
| `TaskDemo`, `OrchestrationDemo`, `ScriptedAgentRunner`, `ResearchFixtures`, `FixtureAudio`, `VoiceTestRig`, `UnitySimulator` | No (live tests/unit tests) | disposable fixtures, scripted engines | TEST ONLY (guard: only `*LiveTest*`, `SmokeTest`, `DevCapture`, `AppDelegate` flags, `AppContext` seed) |
| `VoiceCoordinator.simulate`, `HandsFreeCoordinator.simulate` | No (smoke/capture only) | render a voice state without a microphone | PREVIEW ONLY (guard) |
| Voice level bar (`VoiceStrip`) | Yes | shows the **real** input level only while listening; no fake waveform exists | REAL DATA |
| `JarvisCoreView` / neural network animation | Yes | decorative state indicator (not data); off under Reduce Motion | REAL STATE (animation is not a value) |
| Compact HUD task card | Yes | `store.activeTask` (engine tasks) or "No active task" | REAL DATA |
| Research / Unity / MCP / Memory / Computer / Learning screens | Yes | persisted records or "No research yet", "not connected", "No MCP is registered or discovered", "No computer session yet" | REAL DATA, honest empty states |
| Menu bar | Yes | icon follows `store.state`; "Working: …" only for a real engine task | REAL DATA |

Genuine persisted history is **never deleted** by this change. (No persisted record carries a reliable demo marker: demo data lived only in memory, `persist: false`, so nothing needed removing from the user's database.)

## Proof
* `ProductionTruthTests`: a fresh production context (temp database) has **zero** tasks, project, agents, tools, approvals, observatory demo and no "demo/simulated/mock" activity text; the simulator is invisible even with Developer Controls on; a demo environment is only reachable through explicit launch options; every `DevStateStrip(` / `demoTasks` / `simulateMenu` use is gated on `simulatorControlsVisible`; demo/fixture type names appear only in allowed files; no placeholder strings remain in `UI/`.
* `scripts/guards_v15.sh` (V1.0 fix 2 section) repeats the source guards in `verify.sh`.
* Smoke test (`--smoke-test`, 7 new checks): a second, production-mode `AppContext` has empty read models and no simulator. Live test `--daily-jarvis-live-test --daily-section grounding` runs the real conversation stack (see DEVELOPMENT_LOG).
* The installed app's Dashboard is a visual check only a person can complete: README 1243.
