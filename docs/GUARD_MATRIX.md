# Guard requirement matrix (V0.13.1 + V0.14 + V0.15)

Audit of the protections the V0.13 brief required against what `scripts/verify.sh` and the unit tests actually enforce. "Covered" means a guard or test fails when the protection is removed. Numbers of guards are not a goal; coverage is.
Legend — **G** = `scripts/verify.sh` guard (substring of its name), **T** = unit test, **L** = real live test.

| # | Requirement | Covered? | Guard / test | Why it is sufficient |
|---|---|---|---|---|
| 1 | No second orchestrator | yes (V0.12) + **new** | G "agents are roles…", G "no second orchestrator: graphs are planned… only by Orchestration/" | roles are not providers; continuity / experiments / vision / Unity layer cannot reference the planner, validator or scheduler |
| 2 | Continuation cannot bypass TaskEngine | yes | G "'continue' is an ordinary V0.4 task", T `ContinuityEngineTests`, L continuity | the service only calls `TaskEngine.submit`; no run / step / approval / process creation |
| 3 | Memory-only continuation forbidden | **gap closed** | G "memory alone never starts work", T `memoryOnlyNeverStarts` | a known issue that exists only as memory is PROPOSED (`needsChoice`); selector references no memory service (G "memory is context…") |
| 4 | Bounded continuation | yes | G "a continuation session is bounded", T bounds tests | 30 min · 12 nodes · 2 revisions · 2 correction rounds · 2 experiments, persisted as a constraint |
| 5 | Bounded correction | yes | G "the correction loop is bounded", T `bounds` | plan validator caps rounds (1–3); the session bound caps further |
| 6 | No arbitrary Unity C# execution | yes | G "Unity is reached only through the typed UnityOperation enum", `UnityGuardTests`, parity test | closed enum; bridge files grep-clean of menu / process / network / reflection |
| 7 | Play Mode persistent-mutation protection | yes | G "operator edits are verified…", T `UnityOperatorTests`, L (bridge `playModeMutationBlocked`) | refused in Swift first and by the bridge itself |
| 8 | Unsaved-scene protection | yes (+ explicit guard) | G "the user's unsaved scene is protected in Swift AND in the bridge", T policy tests | `userDirtyScenes` checked by policy; bridge has its own dirty check |
| 9 | Raw model coordinate actuation forbidden | yes (V0.11) | G "the model-facing action type carries no coordinates…", G "a model proposal that contains coordinates… is rejected whole" | typed action set has no point / frame field |
| 10 | Visual output cannot directly click | yes | G "visual grounding is perception, not authority", G "a coordinate click is the LAST rung" | proposals only through `VisionProposing`; executor re-validates |
| 11 | Visual content cannot grant authority | yes | G "visual safety is the WORST of…", T `VisualGroundingTests`, benchmark injection case | picture text is data; injection notes recorded and ignored; worst-of classification |
| 12 | No unapproved screenshot persistence | yes | G "a camera capture is memory-only", G "screenshots are memory-only", schema v12 grep | no picture column; spool PNG deleted at once |
| 13 | No idle capture / AX traversal / Unity polling | yes (+ explicit Unity guard) | G "nothing in continuity, experiments or visual grounding polls…", G "the Unity layer and the operator code never poll the editor on a timer", G V0.11 "nothing runs while idle", smoke "V0.13 IDLE" | no timers; the single-shot idle unload is the only delayed work |
| 14 | No credential visual extraction | yes | G "visual safety… credential", G "visual text output is sanitised", V0.11 secure-field guards | credential labels are blocked forever; model text passes the sanitizer (secrets redacted) |
| 15 | No cookie / session extraction | yes | G "no credential / token / cookie access", G "the browser/credential stores of the user are never touched" | no Keychain, cookie DB or profile code exists |
| 16 | No Keychain access | yes | G "no credential / token / cookie access" (`SecItemCopyMatching`) | pattern forbidden everywhere in Sources |
| 17 | No account-specific scraping | **gap closed** | G "no site- or account-specific scraper or automation" | no streaming / shop / social service is named in product code |
| 18 | Purchase / rent / subscribe bypass blocked | **gap closed** | G "purchase, rental, cart and donation words…", T `ComputerConsequenceTests` | "Rent", "Buy or Rent", "Kirala", "Add to Cart" … were classified ordinary before V0.13.1; now blocked forever |
| 19 | Terminal bypass blocked | yes (V0.11) | G "typing into a terminal or console is blocked" | bundle ids + console-like elements |
| 20 | Experiment cannot escape the JARVIS root | yes | G "experiments run in a marker-checked disposable workspace…", T `ExperimentContractTests` | removal only in `ExperimentWorkspace`, marker + symlink + root checks |
| 21 | Experiment cannot mutate the real project | yes | G "an experiment always cleans up… proves the real project was not touched", T, L | tree fingerprint before / after; contract naming a real path never starts |
| 22 | No automatic asset import into the real project | yes | G "an experiment never imports into a project" | `AssetImporter.apply` only against the disposable root |
| 23 | Licence claims need evidence | yes | G "experiment results are facts with a class…", T `claims` | unknown licence is never safe; licence stays SUPPORTED BY SOURCE |
| 24 | Style claims need evidence | yes | same guard, T `styleClaimAllowed` | needs pictures of both sides |
| 25 | No V0.13 self-modification | **gap closed** | G "no runtime code writes JARVIS's own rules, decisions, state or roadmap documents" | AGENTS / DECISIONS / PROJECT_STATE / CURRENT_TASK / ROADMAP are only read |
| 26 | No automatic rule promotion | yes | same guard + no rules store exists in V0.13 | nothing in V0.13 can persist a rule |
| 27 | No paid visual API | yes | G "visual providers are on-device…", G "no paid API, API key…" | no cloud provider registered |
| 28 | No API key | yes | G "API-key / token variable names appear ONLY in the scrub list" | |
| 29 | No permanent VLM daemon | **gap closed** | G "the vision helper is offline… unloads when idle…", G "no permanent vision daemon or login item" | idle unload + no LaunchAgent / launchctl / login item |
| 30 | Automated tests cannot mutate the real Hamam project | yes (+ explicit guard) | G "the operator live test uses a disposable fixture only", G "no real user path or user name is embedded" | live tests copy fixtures; no real path literal exists |
| 31 | No hidden chain-of-thought persistence | yes | G "no chain-of-thought or raw provider conversation is stored" (covers v10–v12) | schema grep |
| 32 | An AX action's return code is not trusted (V0.13.1) | **new** | G "an Accessibility action's 'unsupported' answer is neither trusted nor repeated", T `unsupportedAnswerButEffect` / `unsupportedAnswerNoEffect` | cross-checked against observed state; never repeated |
| 33 | Input System edits are structured and protect user bindings (V0.13.1) | **new** | G "Input System edits use Unity's own InputActionAsset API…", T `UnityInputSystemTests`, L | ownership list; conflicts refused with the facts |
| 34 | Animation / audio experiments are kinds of the one engine (V0.13.1) | **new** | G "animation and audio experiments are KINDS…", T `kinds` | no second engine type |
| 35 | Scene facts are live or labelled history (V0.13.1) | **new** | G "scene facts… never launch or poll", T `UnitySceneFactsTests` | remembered readings are never `live` |
| 36 | No second orchestrator for self-improvement / adaptive / MCP (V0.14) | **new** | G "there is no second orchestrator: no SelfImprovementOrchestrator…" | no such type; adaptive/capability layers never plan or save graphs |
| 37 | Source changes only via an ordinary V0.12 task (V0.14) | **new** | G "JARVIS changes its own source ONLY by creating an ordinary V0.12 development task", T `AdaptiveEngineTests`, L selfimprove | no file write/project tool/importer in the adaptive layer; exactly one `engine.submit` |
| 38 | Self-change gate (level 4, HUD request, checkpoint, clean tree, failed ⇒ not promoted) (V0.14) | **new** | G "a self-change needs level 4…", L selfimprove | default level Experiment; no level 5 |
| 39 | Approval is HUD-only (V0.14) | **new** | G "approval is HUD-only…", T `AdaptiveLearningTests`, L voice | `AdaptiveDecisionSource` = hud, test; voice/chat/memory/proactive/orchestration cannot decide |
| 40 | Rules are data from a closed vocabulary that only adds requirements (V0.14) | **new** | G "learned rules are DATA from a closed vocabulary…", T rule tests | seven actions, none named approve/grant/install/delete/send/purchase/sandbox/shell/execute |
| 41 | One admission door for learned text (V0.14) | **new** | G "learning text is gated…", L security | secret/authority/injection/vocabulary/evidence/overgeneralisation; refusals audited |
| 42 | Memory ⟂ learning (V0.14) | **new** | G "memory cannot activate learning…" | memory layer unaware of learning/MCP; adaptive layer never touches memory service |
| 43 | MCP never active by itself (V0.14) | **new** | G "an MCP never becomes active by itself…", T status machine | no edge from pre-approval statuses to ACTIVE |
| 44 | Install/update/removal are requests only (V0.14) | **new** | G "registration, update and removal are never automatic…", L registry/voice | created by view model/assistant/test, executed only by the decision service |
| 45 | Ownership-safe removal (V0.14) | **new** | G "MCP removal deletes only JARVIS-owned files…", L registry | exact recorded paths, symlinks not followed, folder only if empty, active-task recheck |
| 46 | MCP cannot grant authority (V0.14) | **new** | G "an MCP can never grant authority…", L security | output is data; capability layer references no approval/policy/capability code |
| 47 | Typed wrappers only; BROAD never exposed (V0.14) | **new** | G "agents never see a raw MCP tool…", L security (shell) | envelope maximum; never-automatic envelopes need a person |
| 48 | No inherited environment/secrets (V0.14) | **new** | G "an MCP never inherits your environment or secrets…", L sandbox | environment from scratch; Seatbelt denies network/outside writes/home reads |
| 49 | No wildcard scope, no auto-update, no hidden persistence (V0.14) | **new** | G "MCP servers have no wildcard filesystem scope…" | explicit project list; no timer; one-shot idle stop |
| 50 | Nothing runs while idle (V0.14) | **new** | G "nothing runs while idle: discovery, learning extraction…", smoke V0.14 IDLE | no timer/launch/poll starts discovery, extraction or a benchmark |
| 51 | No secret/picture/raw output/reasoning stored by learning (V0.14) | **new** | G "learning stores no secret, no picture…" | v13/v14 schema has no blob/image/transcript/reasoning column |
| 52 | Learned routing bounded (V0.14) | **new** | G "learned routing nudges are bounded…" | |bias| ≤ 0.2; explicit choice never reads it |
| 53 | Production repository is never a self-change target (V0.14) | **new** | G "the production repository of JARVIS is never a self-change target…" | `selfRepositoryPath` assigned only by live tests |
| 54 | No second orchestrator (V0.15 layers) (V0.15) | **new** | G "V0.15 adds no second orchestrator…", T `DailyStructuralTests` | no Voice/Conversation/Personality/Setup/App/Dependency orchestrator; Daily/ and Readiness/ plan nothing, run no agent, submit no task |
| 55 | Personality / context / readiness cannot touch approval or capability (V0.15) | **new** | G "personality, working context and readiness never touch an approval…", T `DailyStructuralTests` | no approve / deny / pendingApproval / capability reference in Daily/ or Readiness/ |
| 56 | A spoken or typed yes decides nothing, for every kind of decision (V0.15) | **new** | G "a spoken or typed yes/evet cannot decide anything…", T `DailyFollowUpTests.guardCoversAllDecisions`, L daily conversation (typed + spoken) | guard covers task approval, adaptive request, proposal; runs before follow-up resolution; a bare yes never answers a clarification |
| 57 | The working context is bounded and ephemeral (V0.15) | **new** | G "conversational working context is bounded and EPHEMERAL…", T `WorkingContextBoundsTests` | 16 items · 30 min · 30 turns; no persistence, no Codable, no memory / learning write |
| 58 | Destructive follow-ups never guess (V0.15) | **new** | G "a destructive follow-up never guesses its target…", T `DestructiveReferenceTests`, L daily conversation | explicit single choice only, else asks; approval still applies |
| 59 | Context cannot be poisoned by model / MCP / web text (V0.15) | **new** | T `mcpCannotSmuggle`, `labelsAreSanitised`, `DailyFollowUpTests.smuggling` | instruction- and secret-shaped labels refused; only validated records enter |
| 60 | Setup is typed and allowlisted (V0.15) | **new** | G "setup is typed and allowlisted…", T `SetupRunnerTests`, `DailyStructuralTests`, L `--setup-live-test` | closed action list; one process launch; no sudo / URL / command / shell / package manager |
| 61 | Readiness reads no credentials and starts nothing (V0.15) | **new** | G "readiness never enumerates or reads credentials…", G "nothing in Daily/ or Readiness/ runs on a timer…", L readiness | no Keychain / cookie / credential access; no timer or poll; process count unchanged |
| 62 | No paid API can be enabled by readiness or setup (V0.15) | **new** | G "no paid API can be enabled by readiness or setup…", T `paidAPI` | Paid API row has no action; no setup action names an API, key, subscription or purchase |
| 63 | The app is self-contained and holds no mutable state (V0.15) | **new** | G "the app is a self-contained bundle…", `package-app.sh` checks, L `--packaging-live-test` | no DB / model / fixture in the bundle; no repository, cwd or server dependency; one entitlement |
| 64 | No hidden persistence, no self-update (V0.15) | **new** | G "no hidden persistence and no self-update…" (and the amended V0.13 persistence guard) | SMAppService in one file; no LaunchAgent / Daemon / launchctl; nothing builds / installs / replaces the app |
| 65 | Single instance does not restrict developer launches (V0.15) | **new** | G "a plain launch hands over to the running copy…", T `plainLaunch`, `verify-installed.sh` | only a launch with no `--flag` is restricted |
| 66 | Presentation cannot reach task state (V0.15) | **new** | G "personality is presentation only…", T `DailyShapeTests` | ResponsePolicy has no engine / store reference; shortening keeps failures |
| 67 | V0.15 live tests touch no real project and no provider (V0.15) | **new** | G "the V0.15 live tests touch no real project…" | Hamam never named; scripted answers only; temporary fixtures |

Gaps actually found and closed in V0.13.1: **#3** (memory-only known issue could start work), **#17** (no explicit guard), **#18** (rental / cart words were not classified), **#25/26** (no guard), **#29** (no explicit guard). Everything else was already enforced.

V0.14 added 18 guards in `scripts/guards_v14.sh` (sourced by `verify.sh`); each was checked to FAIL when a violation is injected.

V0.15 added 14 guards in `scripts/guards_v15.sh` and amended three older ones narrowly (notification API, System Settings URLs, SMAppService — each allowed in `Readiness/SystemIntegration.swift` only); each new guard was shown to FAIL on an injected violation (rows 54–67).
