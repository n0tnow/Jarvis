# Unity Project Agent & Editor Bridge (V0.6 — DEC-047…DEC-056)

V0.6 makes Unity a **first-class controlled execution environment inside the V0.4 task engine**. It is not a parallel engine:

```
User / V0.5 ─► V0.4 TaskEngine ─► Unity-aware plan ─► Unity step ─► JARVIS-owned Unity tool layer ─► Unity Editor / project files
                                        ▲                                        │
                  V0.3.2 Observatory ◄──┴── sanitized events ◄── deterministic validation ◄── observe
```

V0.5 stays the decision/policy layer, V0.4 the only executor, V0.3.2 the observability layer, V0.3.1 the provider router. Nothing in V0.6
creates a second task engine, approval system or log viewer.

## 1. The bridge (DEC-047) — what was chosen and why

| Question | Answer |
|---|---|
| Third-party Unity MCP installed? | **No.** Nothing was downloaded, installed or executed from a third party. (The development machine's Claude session happens to have Unity MCP tools configured; JARVIS neither uses nor depends on them.) |
| Bridge | A small **JARVIS-owned Editor package**, source in `UnityBridge/com.jarvis.bridge` (C#, ≈900 lines, no dependencies), embedded into the app as `UnityBridgePackage.generated.swift` (`scripts/gen_unity_bridge.sh`; a unit test fails if it is stale). Installed as an *embedded package* in `Packages/com.jarvis.bridge` — **only after an approval**, no manifest edit, no registry, no download. |
| Transport | **Local file spool** in `<project>/Library/JarvisBridge/`: `requests/<id>.json` (written by JARVIS, atomic rename), `responses/<id>.json` (written by the editor, atomic rename), `status.json` (published by the editor only when something changes), `console.jsonl`, `compile.json`, `tests/current.json`. **No socket, no network, no new macOS permission.** Survives domain reloads naturally (a queued request is served after the reload). |
| JARVIS side | A vnode `DispatchSource` on the bridge folder + a process-exit source on the editor pid: **event-driven, no polling while idle**. A bounded 1 s safety re-read exists only while a wait is pending (and for a bridge folder that does not exist yet). |
| Editor side | One `EditorApplication.update` tick (throttled to 10 Hz, inside Unity) that serves at most one request per tick. |
| Why not Unity batchmode `-executeMethod`/`-runTests` per operation | Unity locks a project to one editor; per-call batch launches would be slow (domain reload each time), could not observe Play Mode or the live Console, and `-executeMethod` is exactly the "run a method by name" surface we refuse to expose. |
| Why not an existing MCP | Its security boundary is not ours (generic tools, network transport, third-party code in the user's project). The critical requirement is *typed, capability-controlled, observable operations*, not "MCP". |

Security boundary of the Editor package (guarded by `verify.sh` and a unit test): a **fixed handler table** (`unknownOperation` for anything else),
no `ExecuteMenuItem`, no `Process.Start`, no `UnityWebRequest`/sockets/`System.Net`, no `Assembly.Load`/reflection invoke, no environment access.
`shutdown` only works in an editor started by JARVIS (`-jarvisOwned`). Mutations are rejected by the bridge itself while Play Mode is active or the editor is
compiling/importing — even if a caller bypassed JARVIS' policy.

## 2. Typed operations — the only surface (DEC-048)

`UnityOperation` is a closed enum (`Sources/Jarvis/Unity/UnityProtocol.swift`); parameters are length/count-bounded when encoded. There is **no case that carries code,
a menu path, a command or a script**, and providers never receive a generic `execute…` tool.

| Group | Operations | Capability |
|---|---|---|
| Inspection | `ping`, `getProjectInfo`, `listScenes`, `getActiveScene`, `openScene`, `listRootGameObjects`, `findGameObjects`, `inspectGameObject`, `inspectComponents`, `inspectSerializedProperties`, `inspectPrefab`, `getPlayModeState`, `getCompilationState`, `getTestAvailability`, `getTestRun` | `inspectUnity` |
| Console | `readConsole` | `readUnityConsole` |
| Compile / tests / Play | `requestCompilation` · `runTests`, `cancelTests` · `enterPlayMode`, `exitPlayMode` | `runUnityCompile` · `runUnityTests` · `controlUnityPlayMode` |
| Mutations (bounded) | `createGameObject`, `addComponent`, `setSerializedProperty` | `modifyUnityScene` |
| Save / prefab | `saveScene` · `createPrefab` | `saveUnityScene` · `createUnityPrefab` |
| Destructive | `deleteGameObject` (GameObject only) | **not a task capability**: allowed only when the user's goal asked for deletion, and then per action through the approval gate |
| Lifecycle | `shutdown` | only for an editor JARVIS started |

Task kinds: read-only analysis tasks get `inspectUnity` + `readUnityConsole` only; development tasks get the bounded set above; `gitPush`/`gitCommit`/`purchase`/`useNetwork`/`useBrowser` stay never-grantable.
**Not provided at all:** arbitrary C#, menu items, shell, AppleScript, package installation/upgrade, Asset Store, downloads, project upgrade, scene-YAML rewriting.

## 3. Discovery, project detection, version safety

* `UnityDiscovery` reads only `/Applications/Unity/Hub/Editor/<version>/Unity.app` (+ Hub's secondary install folder file and legacy `/Applications/Unity*.app`). It never scans the filesystem, opens Unity Hub, logs in or reads account/licence data.
* `UnityProjectDetector` is structural: `Assets/` + `ProjectSettings/ProjectVersion.txt`; descriptor = declared version, render pipeline (from the manifest), packages (≤ 80), test framework, scenes (≤ 100), build scenes, asmdefs (≤ 100), bridge installed/version. The project is never sent to a model.
* **Version mismatch never upgrades silently.** An exact editor match is used; otherwise the task waits for an approval *"Open this project with Unity X (it declares Y) — this can migrate the project"* (same release line preferred). Launch also passes `-disable-assembly-updater`.

## 4. Connection lifecycle (truthful states)

`NOT CONFIGURED → DISCOVERING → AVAILABLE → CONNECTING → CONNECTED / BUSY / PLAY MODE → DISCONNECTED / ERROR`.
CONNECTED means *the editor published a status for this project and its process is alive and is a Unity editor* — never "an executable was found". PLAY MODE only when the editor says so; BUSY while compiling/importing/testing. State is transient (not persisted).

Identity: `status.json` carries the project path, pid and a per-editor-session id; JARVIS checks project path == workspace, pid alive, pid is a Unity editor (`proc_pidpath`). Editors are matched to projects by `-projectPath` (`UnityProcessScanner`, libproc/sysctl, read-only), **never "the first Unity process"**; each project has its own connection and spool.

Preparing a project (`UnityService.prepare`): live bridge → ready; user's editor open without the bridge → ask to install (approval), wait for it to load; no editor → (install approval) → exact version or upgrade approval → launch `Unity -batchmode -nographics -projectPath <ws> -logFile - -disable-assembly-updater -jarvisOwned` through `ManagedProcess` (fixed argument list, allowlisted environment, output drained through the sanitizer into a bounded tail, never stored).
JARVIS closes only editors it started (graceful `shutdown`, then process tree; also one-shot idle shutdown after 10 min without Unity tasks and at app quit via `ProcessRegistry`). A user's editor is never started, stopped, or taken over (an owned editor left in Play Mode by an interrupted run *is* reset).

## 5. Identity of objects and components

GameObjects are addressed by `globalId` (`GlobalObjectId`) and/or hierarchy path with a same-name sibling index (`Twin#1`). A bare **name is valid only for lookups**. A mutation naming one object must be unambiguous: the engine resolves exactly one object or fails `ambiguousTarget` with the candidates ("2 GameObjects are named “Twin” (Twin#0 …; Twin#1 …). Tell me which one"). Components are addressed by type + index; several matches without an index are an error. After a domain reload object handles are re-resolved (`UnityConnection.handlesAreFresh`; the editor session id changes only when the editor restarts). Component types are resolved against loaded public `Component` subclasses (validated name, no `UnityEditor.*`, ambiguity is an error).

## 6. Scene editing, saving, user-change protection

* Edits go through Editor APIs (`Undo.AddComponent`, `SerializedObject.ApplyModifiedProperties`, `Undo.RegisterCreatedObjectUndo`) — **never YAML**.
* `setSerializedProperty` carries `expectedOld`; the bridge verifies target, component, property, representability and the current value; `alreadyApplied` is success without change; a mismatch is refused, not forced. `addComponent`/`createGameObject` are `ifAbsent` by default (idempotent).
* The engine verifies every action in the editor afterwards (component present, value read back, object exists/gone) and then saves **only the scenes JARVIS made dirty** (plus a user-dirty scene the user approved).
* **Unsaved user work (DEC-054):** the bridge tracks which scenes JARVIS dirtied; a dirty scene that is not JARVIS' is *user-dirty*. A mutation touching such a scene waits for an approval *"Modify Unity scene with your unsaved changes"* (deny ⇒ nothing is modified or saved). Opening another scene or running tests with any dirty scene is refused by policy and by the bridge. The V0.4 Git protection also applies: a scene *file* with uncommitted changes needs its own approval. Unity-dirty and Git-dirty are separate checks.
* Deletion: only `deleteGameObject`; needs the goal to ask for it, then an approval per action naming the object; an object that is already gone is "already removed" (never replayed). Deleting components/prefabs/scenes/assets is **not supported** in V0.6.
* Prefabs: `createPrefab` (new `.prefab` under `Assets/`, never overwrites), `inspectGameObject` reports the prefab relationship. No unpack/apply/recursive prefab changes.

## 7. Play Mode (DEC-053)

Persistent mutation (including editing scripts through the V0.4 file path) is **prohibited while Play Mode is active** — in the Swift policy *and* in the bridge. Inspection and observation are allowed. A Unity Play step: requires clean compile state → `enterPlayMode` → waits for the editor to **report** `playing` (timeout 2 min) → bounded observation (1–30 s, ends early if the editor leaves Play Mode itself) → checks expectations → **always** leaves Play Mode and waits for the editor to confirm (also after failure/cancellation, via an unstructured cleanup task). A Play Mode the step did not start is never touched (unless it belongs to an editor JARVIS owns).

## 8. Compilation, tests, Console, validation authority

* **Compilation** is the editor's own state (`CompilationPipeline` events → `compile.json`: generation, errors with file/line, warnings; `EditorUtility.scriptCompilationFailed`). The step requests compilation, waits for the generation to advance and `isCompiling`/`compileRunning` to clear (timeout 7 min), then reads the state; a domain reload is reported ("domain reloaded"). Compile errors feed the V0.4 bounded repair (one repair + one escalation) with the *real* error text.
* **Tests** run in the open editor through the Unity Test Framework (`runTests` EditMode/PlayMode, filtered by test/group/assembly names; smallest scope the plan names; sync for EditMode, reload-surviving for PlayMode). Evidence records mode, requested scope, actual counts, failures (sanitized), duration. Zero matching tests is a failure, not a success. EditMode and PlayMode are distinct plan inputs.
* **Console**: structured entries (Log/Warning/Error/Exception/Assert) captured to a bounded file, **sanitized when the Swift entry is created** (no initializer takes raw text), fingerprints collapse digits. A **baseline** (existing error kinds) is captured at the start of a Unity task (and persisted in the checkpoint); validation distinguishes *new errors* from *repeats of errors that existed before*; the user's Console is never cleared.
* **Validation authority (DEC-049/050).** Facts the editor can prove (compile state, test results, expected object/component/property state, new Console errors) outrank opinions in both directions:
  hard PASS cannot be turned into FAILED by a reviewer who dislikes it; hard FAIL cannot be rescued by an optimistic review. A reviewer can fail a task that has passed hard validators only with a *blocking* issue whose quoted evidence JARVIS finds in the recorded diff/evidence, or when the user asked for a **review gate** (constraint "review gate"/"review must pass"). Otherwise the review becomes **advice** kept in the report ("Reviewer advice (did not change the validated result)"). With *no* hard validator the reviewer's verdict still counts (previous behaviour). Applies to every task, not only Unity.
  Separated in reports: **STRUCTURAL / COMPILATION / TEST** validation are performed; **VISUAL VALIDATION is never claimed** — the report always says *"Visual validation: NOT PERFORMED"* for Unity tasks (no Game/Scene View image is captured; this is documented as a future capability, see §13).

## 9. Planning, steps, the Unity agent

New step types (`unityInspect`, `unityEdit`, `unityCompile`, `unityTest`, `unityPlayMode`, `unityValidate`) with typed `unity` parameters (`UnityStepParams`: scene, targets, test mode/filters, observe seconds ≤ 30, expectations ≤ 10, explicit actions). Each has a required capability set, an idempotency class (inspect/compile/test/play/validate retryable; edit inspect-first) and a deterministic validation kind (`unityInspected`, `unityState`, `unityCompiled`, `unityTestsPass`, `unityPlayObserved`). `PlanValidator` rejects: Unity steps without the capability, invalid/oversized parameters, forbidden content (code/menu/shell/URL) anywhere in `unity`, prohibited phrases (execute C#, menu item, install package, Asset Store, upgrade project, Unity Hub/account/licence), tests/Play Mode that follow a code/scene change without a Unity compile in between, and the V0.4 rules (git push, paid, credentials, recursion, workspace escape, delete without explicit targets).

`unityEdit` = **Unity agent**: a provider job (`UnityAgent`, development profile, never the local model) receives the goal, the step, the targeted inspection text and answers a JSON list of typed actions. `UnityActionParser` accepts only `addComponent / setSerializedProperty / createGameObject / createPrefab / deleteGameObject`, bounded (≤ 8), and rejects any answer containing code/menu/shell/URL fields or tokens (a *policy block*, not re-asked). The agent owns no persistence, scheduling or approval. Script editing stays on the V0.4 `codeChange` path (workspace guard, hash checks, leases, Git baseline); scenes/prefabs only through Editor APIs. Context is targeted (no scene dumps; object lookups, ≤ 12 properties/component, bounded outputs).

## 10. Locks, cancellation, restart, idempotency

* **Unity mutation lock** (`UnityMutationLock`, per project, re-entrant per step, event-driven waiters): `unityEdit`, `unityCompile`, `unityTest`, `unityPlayMode` and `codeChange` in a Unity project take turns. Released at step end, cancellation and task end.
* **Cancellation** propagates: pending editor requests are withdrawn (request files deleted), waits wake, a Play Mode the step started is left, a test run is cancelled, the lock is released, partial report persisted. The user's editor is not closed.
* **Quit**: tasks become INTERRUPTED with a checkpoint (including Unity baseline/facts); owned editors die with the process tree; a user's editor is untouched. **Relaunch**: interrupted tasks resume only on explicit user action; the new `UnityService` reconnects from `status.json` alone (project + pid identity), reports PLAY MODE truthfully if the editor is still playing.
* **Idempotency**: inspect/console/compile/test retryable; add component, create object, set property are idempotent in the bridge; delete is never replayed (gone ⇒ "already removed"); save only writes when dirty.

## 11. Sanitization & credentials

Every editor answer passes `UnityResponseSanitizer` in the single choke point `UnityConnection.perform` (structural `globalId`s are validated by shape, everything else goes through `OutputSanitizer`). Console text is sanitized in `UnityConsoleEntry.init`. The launched editor's own stdout is drained through `SafeToolOutput` into a bounded in-memory tail. JARVIS never reads Unity account/licence/Package-Manager credentials, never calls `credential.*`/`integration.*`, no network client. (Unity itself contacts its own services; that is Unity's traffic, not JARVIS'.)

## 12. Fixtures & the real-game boundary

`UnityBridge/Fixture/` is a minimal disposable project (FixtureScene with TestCube/CounterObject/Main Camera, `Counter`, `Calculator`, `ErrorEmitter`, EditMode + PlayMode tests, fixture-only editor helpers for "user-dirty scene" and "log an error" triggers). `--unity-live-test` copies it to a temp folder, initialises a throw-away Git repo and runs against a **real headless editor started by JARVIS**; nothing touches the user's game. **The user's real game is never opened or modified by automated tests** (read-only detection of a configured real project was not performed — optional).

## 13. Limitations & future work

* No visual validation (screenshots of Game/Scene View) in V0.6 — would be task-linked, bounded, explicit; not implemented. Reports say so.
* Deleting components/prefabs/scenes/assets, prefab apply/unpack, package installation, project upgrade tooling: not supported (refused or approval-only).
* Rollback is Undo + verify/repair only; no scene-level transaction.
* The headless owned editor has no window (a person cannot watch it); connecting to the user's windowed editor works the same way once the package is installed (needs the user's approval and a domain reload in their editor).
* One bridge per project; one mutating Unity step per project at a time.
* **Future multi-editor / Multiplayer Play Mode:** nothing assumes a single editor or process — connections are per project with their own spool, status, pid and session; a second editor for another project (or a clone project) is just another connection. Orchestrating several Play Mode instances is a later milestone.
* A model-planned Unity task can only be as good as the plan; `unityInspect` shows ambiguity, but the planner may still choose poor steps (bounded by validation).

## 14. V0.6 vs later milestones

V0.6 operates *existing* project content through typed editor operations. V0.7 turned out to be Voice I/O (see `VOICE_IO.md`; web research / asset acquisition moved to V0.9, DEC-068). Voice adds no Unity capability: a spoken “is Unity connected?” is the same typed question; a spoken Unity goal is a normal task. Web/asset work is not started: no web access, downloads, Asset Store or licence handling exists in JARVIS.

## Natural voice (V0.8)
Voice still adds no Unity capability: "Jarvis, Unity'deki son testler ne durumda?" is an ordinary request through the typed pipeline (deterministic state answers where the router has them, otherwise a model or a V0.4 task). The Unity bridge, policy and mutation lock are untouched; the heavy-state measurement (real headless editor + Qwen + Whisper + neural voice + wake sentinel) is in `NATURAL_VOICE.md` §11.

## V0.9 — assets for Unity projects

Research reads the connected project's facts read-only (Unity version, render pipeline, test framework from the V0.6 descriptor) to judge compatibility (`UnityCompatibilityAssessor`: compatible / likely / unknown / incompatible). Importing a researched asset is a separate V0.4 development task: `AssetImporter` copies the inspected quarantine copy to `Assets/ThirdParty/<slug>-<id6>` with `JARVIS-PROVENANCE.json` (never overwriting, scripts/native/executables skipped unless approved); V0.6 then runs the compile step through the Editor bridge and its Play-Mode / dirty-scene protection applies unchanged. Automated tests import into disposable fixtures only.

## V0.10 — Unity facts vs memory

The Unity descriptor (version, render pipeline, test framework, packages) is read fresh as **truth** (`ProjectTruth`: `unity.version`, `unity.pipeline`, `unity.tests`, `unity.package:<id>`) and shown in the agent's packet *separately* from memory; a memory that disagrees (e.g. an old Unity version) is superseded by an inspection-derived record, never silently kept current. Unity agents get constraints, decisions, known issues/failures, asset decisions and project facts for the area at hand.

## V0.11 — Unity and the GUI
The V0.6 bridge stays primary. `CapabilityResolver` claims every Unity scene/component/compile/test/Console goal for it before Computer Use sees it. Computer Use may only **activate** a running Unity Editor ("switch to Unity" — verified frontmost) or look at a harmless dialog; it never launches an editor (the placeholder bundle id `com.unity3d.UnityEditor5.x` matches any running `com.unity3d.UnityEditor*`), never presses inside the editor, never types into the Console. Not live-tested against a running editor in V0.11 (none was open); the resolver preference is tested.

## V0.12 — Unity inside an orchestrated graph
The Unity role is the V0.6 typed bridge only: `unityInspect/Edit/Compile/Test/PlayMode/Validate` nodes run alone (mutation lock unchanged); a Unity scene/component/prefab goal is planned by the planner model with the typed Unity step types (never a template, never a Computer node); the fix-flow template adds `unityCompile` after a code change in a Unity project. Computer Use hands every Unity mutation back to V0.6 (live-tested at the resolver level). No Unity editor was launched by V0.12 tests; no real game is touched.
