# Guard requirement matrix (V0.13.1)

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

Gaps actually found and closed in V0.13.1: **#3** (memory-only known issue could start work), **#17** (no explicit guard), **#18** (rental / cart words were not classified), **#25/26** (no guard), **#29** (no explicit guard). Everything else was already enforced.
